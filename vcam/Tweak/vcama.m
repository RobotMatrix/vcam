//
//  vcama.m — in-app hook (PER-APP camera replacement via interface selection)
//
//  Injected into apps (filter Bundles covers common UIKit apps). Active only
//  when the app's bundle ID is in config "apps" list (and global mode off).
//
//  Hook points (app process):
//   - AVCaptureVideoDataOutput setSampleBufferDelegate:queue:  -> wrap delegate,
//     replace buffer content before forwarding captureOutput:didOutputSampleBuffer:
//   - AVCapturePhotoOutput capturePhotoWithSettings:delegate:  -> swap JPEG data
//     in didFinishProcessingPhoto via proxy delegate
//   - AVCaptureSession startRunning                            -> log marker
//
//  This covers AVFoundation-direct apps. Global mode (vcamd in mediaserverd)
//  covers everything else including this path — engine de-dupes by checking
//  config before touching buffers.
//

#import "VCamEngine.h"
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define ALOG(fmt, ...) do { \
    NSString *_alog_s = [NSString stringWithFormat:(@"[vcama] " fmt), ##__VA_ARGS__]; \
    fprintf(stderr, "%s\n", _alog_s.UTF8String); \
} while (0)

static void (*orig_setDelegate)(id self, SEL _cmd, id delegate, dispatch_queue_t queue);
static void (*orig_capturePhoto)(id self, SEL _cmd, AVCapturePhotoSettings *settings, id<AVCapturePhotoCaptureDelegate> delegate);
static void (*orig_startRunning)(id self, SEL _cmd);

static BOOL vcama_installed = NO;

#pragma mark - Delegate proxy (video frames)

@interface VCamaFrameProxy : NSObject
@property (nonatomic, weak) id realDelegate;
@end
@implementation VCamaFrameProxy

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    @try {
        CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (pb) [[VCamEngine shared] renderIntoPixelBuffer:pb];
    } @catch (NSException *e) {
        ALOG("frame replace EXC: %@", e.reason);
    }
    // forward (possibly replaced) buffer to the real delegate (guard: delegate
    // may legitimately not implement this — forwarding handles it, but msgSend
    // on missing SEL crashes, so check first)
    if (self.realDelegate && [self.realDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        ((void (*)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *))objc_msgSend)(
            self.realDelegate, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, sampleBuffer, connection);
    }
}

- (BOOL)respondsToSelector:(SEL)sel {
    // proxy only claims frame callback; everything else -> real delegate
    if (sel == @selector(captureOutput:didOutputSampleBuffer:fromConnection:)) return YES;
    return [self.realDelegate respondsToSelector:sel];
}

- (id)forwardingTargetForSelector:(SEL)sel {
    return self.realDelegate;
}

@end

#pragma mark - Photo delegate proxy

@interface VCamaPhotoProxy : NSObject
@property (nonatomic, strong) id<AVCapturePhotoCaptureDelegate> realDelegate;
@property (nonatomic, assign) SEL callbackSel;
@end
@implementation VCamaPhotoProxy

- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
    if (!error && photo && [[VCamEngine shared] hasPhotoMedia]) {
        NSData *fake = [[VCamEngine shared] replacementPhotoData];
        if (fake) {
            AVCapturePhoto *cloned = nil;
            // Best-effort KVC swap of the photo's encoded data. On iOS 13 the
            // canonical replacement path is the daemon still-pipeline hook
            // (vcamd BWPhotoEncoderNode) which rewrites pixels pre-encode.
            // This proxy covers apps where daemon hook is inactive.
            @try {
                cloned = [VCamaPhotoProxy photoWithSwappedData:photo newData:fake];
            } @catch (NSException *e) {
                ALOG("photo swap EXC: %@", e.reason);
            }
            if (cloned) photo = cloned;
        }
    }
    if (self.realDelegate && self.callbackSel && [self.realDelegate respondsToSelector:self.callbackSel]) {
        ((void (*)(id, SEL, AVCapturePhotoOutput *, AVCapturePhoto *, NSError *))objc_msgSend)(
            self.realDelegate, self.callbackSel, output, photo, error);
    }
}

+ (AVCapturePhoto *)photoWithSwappedData:(AVCapturePhoto *)photo newData:(NSData *)data {
    // Deep approach: encode fake JPEG into a CVPixelBuffer-backed AVCapturePhoto
    // is not public. Pragmatic path: keep original photo object but replace its
    // internal CGImage-based representation by re-coding.
    // iOS 13 AVCapturePhoto exposes resolvedSettings + PixelBuffer via KVC keys.
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!src) return photo;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!img) return photo;

    CVPixelBufferRef pb = NULL;
    CVReturn ret = CVPixelBufferCreate(kCFAllocatorDefault, CGImageGetWidth(img), CGImageGetHeight(img), kCVPixelFormatType_32BGRA, NULL, &pb);
    if (ret != kCVReturnSuccess) { CGImageRelease(img); return photo; }
    CVPixelBufferLockBaseAddress(pb, 0);
    CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pb), CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 8,
                                             CVPixelBufferGetBytesPerRow(pb), CGColorSpaceCreateDeviceRGB(),
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextDrawImage(ctx, CGRectMake(0, 0, CGImageGetWidth(img), CGImageGetHeight(img)), img);
    CFRelease(ctx);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    CGImageRelease(img);

    // Rebuild the photo's internal preview/still image dictionary (private but stable on iOS 13)
    @try {
        // _internalPhotoData holds encoded bytes for fileDataRepresentation
        if ([photo respondsToSelector:@selector(setValue:forKey:)] ) {
            [photo setValue:data forKey:@"_encodedPhotoData"];
            [photo setValue:data forKey:@"_internalData"];
        }
    } @catch (NSException *e) {
        ALOG("KVC swap miss: %@", e.name);
    }
    // Attach buffer as associated object fallback for consumers reading pixelBuffer
    objc_setAssociatedObject(photo, "vcam_replaced_pb", (__bridge id)pb, OBJC_ASSOCIATION_RETAIN);
    return photo;
}

- (BOOL)respondsToSelector:(SEL)sel {
    return sel == self.callbackSel || [self.realDelegate respondsToSelector:sel];
}

- (id)forwardingTargetForSelector:(SEL)sel {
    return self.realDelegate;
}

@end

#pragma mark - Hooks

static void hook_setSampleBufferDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    if ([[VCamEngine shared] activeForCurrentProcess]) {
        VCamaFrameProxy *proxy = [[VCamaFrameProxy alloc] init];
        proxy.realDelegate = delegate;
        objc_setAssociatedObject(self, "vcam_frame_proxy", proxy, OBJC_ASSOCIATION_RETAIN);
        ALOG("frame delegate proxied for %@", [[NSBundle mainBundle] bundleIdentifier]);
        orig_setDelegate(self, _cmd, proxy, queue);
    } else {
        orig_setDelegate(self, _cmd, delegate, queue);
    }
}

static void hook_capturePhoto(id self, SEL _cmd, AVCapturePhotoSettings *settings, id<AVCapturePhotoCaptureDelegate> delegate) {
    if ([[VCamEngine shared] activeForCurrentProcess] && delegate && [[VCamEngine shared] hasPhotoMedia]) {
        VCamaPhotoProxy *proxy = [[VCamaPhotoProxy alloc] init];
        proxy.realDelegate = delegate;
        // find the callback selector the delegate implements
        static SEL selA = nil, selB = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            selA = @selector(captureOutput:didFinishProcessingPhoto:error:);
            selB = @selector(captureOutput:didFinishCaptureForResolvedPhotoSettings:error:);
        });
        proxy.callbackSel = [delegate respondsToSelector:selA] ? selA : ([delegate respondsToSelector:selB] ? selB : selA);
        objc_setAssociatedObject(settings, "vcam_photo_proxy", proxy, OBJC_ASSOCIATION_RETAIN);
        ALOG("photo delegate proxied");
        orig_capturePhoto(self, _cmd, settings, proxy);
    } else {
        orig_capturePhoto(self, _cmd, settings, delegate);
    }
}

static void hook_startRunning(id self, SEL _cmd) {
    orig_startRunning(self, _cmd);
    if ([[VCamEngine shared] activeForCurrentProcess]) {
        ALOG("AVCaptureSession startRunning (replacement active) app=%@", [[NSBundle mainBundle] bundleIdentifier]);
    }
}

__attribute__((constructor)) static void vcama_main(void) {
    if (vcama_installed) return;
    vcama_installed = YES;

    // SAFETY: never inject into Apple system processes. ptpcamerad/remindd
    // etc. link UIKit, so a Bundles=com.apple.UIKit filter catches them too,
    // and touching AVFoundation/CoreImage there crashes the daemon
    // (observed: ptpcamerad crash loop -> ReportCrash 300% CPU).
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (!bid || [bid hasPrefix:@"com.apple."]) {
        return;
    }

    // In-app process: AVFoundation XPC is fine here (mediaserverd is launched
    // on demand by the system). Hooks + reload observer only; engine created
    // lazily on first hook invocation.
    [[VCamEngine shared] startObservingReload];

    Class cls = objc_getClass("AVCaptureVideoDataOutput");
    if (cls) {
        Method m = class_getInstanceMethod(cls, @selector(setSampleBufferDelegate:queue:));
        if (m) {
            orig_setDelegate = (void (*)(id, SEL, id, dispatch_queue_t))method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_setSampleBufferDelegate);
            ALOG("hooked AVCaptureVideoDataOutput setSampleBufferDelegate:queue:");
        }
    }
    Class po = objc_getClass("AVCapturePhotoOutput");
    if (po) {
        Method m = class_getInstanceMethod(po, @selector(capturePhotoWithSettings:delegate:));
        if (m) {
            orig_capturePhoto = (void (*)(id, SEL, AVCapturePhotoSettings *, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_capturePhoto);
            ALOG("hooked AVCapturePhotoOutput capturePhotoWithSettings:delegate:");
        }
    }
    Class sess = objc_getClass("AVCaptureSession");
    if (sess) {
        Method m = class_getInstanceMethod(sess, @selector(startRunning));
        if (m) {
            orig_startRunning = (void (*)(id, SEL))method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_startRunning);
            ALOG("hooked AVCaptureSession startRunning");
        }
    }
}
