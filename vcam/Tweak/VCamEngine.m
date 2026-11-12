//
//  VCamEngine.m
//  Replacement media engine: config, AVAssetReader loop, pixel buffer drawing.
//
//  Buffer formats handled:
//   - kCVPixelFormatType_32BGRA : direct draw
//   - kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange (NV12) : convert via libyuv-style manual pass
//

#import "VCamEngine.h"
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreImage/CoreImage.h>
#include <notify.h>

#define VCAM_NOTIFY_RELOAD "com.bangcle.vcam.reload"
#define VCAM_LOG_OBJC(fmt, ...) do { \
    NSString *_vcam_s = [NSString stringWithFormat:(@"[vcam] " fmt), ##__VA_ARGS__]; \
    fprintf(stderr, "%s\n", _vcam_s.UTF8String); \
} while (0)
#define VCAM_LOG(fmt, ...) do { \
    NSString *_vcam_s = [NSString stringWithFormat:(@"[vcam] " fmt), ##__VA_ARGS__]; \
    fprintf(stderr, "%s\n", _vcam_s.UTF8String); \
} while (0)

static NSString * const kConfigPath = @"/var/mobile/Library/vcam/config.plist";
static NSString * const kPrefsDomain = @"com.bangcle.vcam";
static NSString * const kDefaultPhoto = @"/var/mobile/Library/vcam/photo.jpg";
static NSString * const kDefaultVideo = @"/var/mobile/Library/vcam/video.mp4";

@interface VCamEngine ()
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL global;
@property (nonatomic, copy) NSArray<NSString *> *apps;
@property (nonatomic, copy) NSString *photoPath;
@property (nonatomic, copy) NSString *videoPath;
@property (nonatomic, strong) AVAssetReader *reader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *readerOutput;
@property (nonatomic, strong) AVAsset *currentAsset;
@property (nonatomic, assign) CVPixelBufferRef heldFrame;   // last decoded BGRA frame (retained)
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, assign) CGImageSourceRef photoSource;
@property (nonatomic, strong) NSData *photoData;
@property (nonatomic, assign) int64_t frameIndex;
@property (nonatomic, strong) NSObject *mediaLock;
@property (nonatomic, assign) int reloadToken;
@property (nonatomic, assign) CVPixelBufferRef cachedPhotoPB; // decoded photo.jpg (BGRA, retained)
// Target decode dims: match camera buffer to avoid per-frame rescale.
// Locked on first render to the live buffer's size.
@property (nonatomic, assign) CGSize decodeDims;
@property (nonatomic, assign) BOOL decodeDimsLocked;
@end

@implementation VCamEngine

+ (instancetype)shared {
    static VCamEngine *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[VCamEngine alloc] init]; });
    return inst;
}

- (instancetype)init {
    if ((self = [super init])) {
        _mediaLock = [[NSObject alloc] init];
        // NOTE: CIContext is created LAZILY on first blit. Creating it here
        // crashed ptpcamerad (CoreImage init inside system daemons that link
        // UIKit but never render — panic in CIContext creation).
        _apps = @[];
        [self reload];
    }
    return self;
}

- (CIContext *)ciContext {
    @synchronized (self.mediaLock) {
        if (!_ciContext) {
            _ciContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer : @YES}];
        }
        return _ciContext;
    }
}

#pragma mark - Config

// Cheap daemon gate: reads config directly (plist + CFPreferences) WITHOUT
// creating the engine singleton. No AVFoundation, no locks, no media IO —
// safe to call from the emit path on any thread, every time or cached.
+ (BOOL)daemonShouldBeActive {
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kConfigPath] ?: @{};
    NSNumber *pEnabledUI = (__bridge NSNumber *)CFPreferencesCopyAppValue((__bridge CFStringRef)@"enabled", (__bridge CFStringRef)kPrefsDomain);
    NSNumber *pGlobalUI  = (__bridge NSNumber *)CFPreferencesCopyAppValue((__bridge CFStringRef)@"global",  (__bridge CFStringRef)kPrefsDomain);
    NSNumber *pEnabled = pEnabledUI ?: cfg[@"enabled"];
    NSNumber *pGlobal  = pGlobalUI  ?: cfg[@"global"];
    return [pEnabled boolValue] && [pGlobal boolValue];
}

- (BOOL)activeForCurrentProcess {
    if (!self.enabled) return NO;
    // Daemon (mediaserverd) replaces ONLY in global mode. In per-app mode the
    // daemon must pass frames through untouched, otherwise every app would be
    // replaced regardless of the app list.
    if (getenv("VCAM_DAEMON")) return self.global;
    if (self.global) return YES;
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (!bid) return NO;
    return [self.apps containsObject:bid];
}

- (void)reload {
    @synchronized (self.mediaLock) {
        // Config sources (merged, Preferences UI wins over raw plist):
        //  1. /var/mobile/Library/vcam/config.plist     (headless / scripted control)
        //  2. CFPreferences domain com.bangcle.vcam     (Settings UI via PreferenceLoader)
        NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kConfigPath] ?: @{};
        // PreferenceLoader writes each key directly into the domain kPrefsDomain.
        NSNumber *pEnabledUI = (__bridge NSNumber *)CFPreferencesCopyAppValue((__bridge CFStringRef)@"enabled", (__bridge CFStringRef)kPrefsDomain);
        NSNumber *pGlobalUI  = (__bridge NSNumber *)CFPreferencesCopyAppValue((__bridge CFStringRef)@"global",  (__bridge CFStringRef)kPrefsDomain);
        NSString *pPhotoUI   = (__bridge NSString *)CFPreferencesCopyAppValue((__bridge CFStringRef)@"photoPath", (__bridge CFStringRef)kPrefsDomain);
        NSString *pVideoUI   = (__bridge NSString *)CFPreferencesCopyAppValue((__bridge CFStringRef)@"videoPath", (__bridge CFStringRef)kPrefsDomain);
        NSString *appsTextUI = (__bridge NSString *)CFPreferencesCopyAppValue((__bridge CFStringRef)@"appsText", (__bridge CFStringRef)kPrefsDomain);
        // appsText (UI multiline) overrides apps array
        NSString *appsText = appsTextUI ?: cfg[@"appsText"];
        NSMutableArray *apps = [NSMutableArray array];
        if ([appsText isKindOfClass:[NSString class]] && appsText.length) {
            for (NSString *line in [appsText componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
                NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (t.length) [apps addObject:t];
            }
        } else {
            NSArray *arr = cfg[@"apps"];
            if ([arr isKindOfClass:[NSArray class]]) [apps addObjectsFromArray:arr];
        }

        NSNumber *pEnabled = pEnabledUI ?: cfg[@"enabled"];
        NSNumber *pGlobal  = pGlobalUI  ?: cfg[@"global"];
        NSString *pPhoto   = pPhotoUI ?: cfg[@"photoPath"];
        NSString *pVideo   = pVideoUI ?: cfg[@"videoPath"];

        self.enabled = [pEnabled boolValue];
        self.global  = [pGlobal boolValue];
        self.apps    = apps;
        self.photoPath = ([pPhoto isKindOfClass:[NSString class]] && pPhoto.length) ? pPhoto : kDefaultPhoto;
        self.videoPath = ([pVideo isKindOfClass:[NSString class]] && pVideo.length) ? pVideo : kDefaultVideo;

        // decode dims may change with new media: unlock
        self.decodeDimsLocked = NO;

        VCAM_LOG_OBJC(@"config: enabled=%d global=%d apps=%lu photo=%@ video=%@",
                      self.enabled, self.global, (unsigned long)self.apps.count, self.photoPath, self.videoPath);

        [self loadVideoMedia];
        [self loadPhotoMedia];
    }
}

- (void)startObservingReload {
    notify_register_dispatch(VCAM_NOTIFY_RELOAD, &_reloadToken,
                             dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(int token) {
        [[VCamEngine shared] reload];
    });
}

#pragma mark - Video media (AVAssetReader loop)

- (void)teardownReaderLocked {
    if (self.reader) { [self.reader cancelReading]; }
    self.reader = nil;
    self.readerOutput = nil;
    self.currentAsset = nil;
}

- (void)loadVideoMedia {
    [self teardownReaderLocked];
    NSURL *url = [NSURL fileURLWithPath:self.videoPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.videoPath]) {
        VCAM_LOG_OBJC(@"video media missing: %@", self.videoPath);
        return;
    }
    AVAsset *asset = [AVAsset assetWithURL:url];
    NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (tracks.count == 0) {
        VCAM_LOG_OBJC(@"video has no video track: %@", self.videoPath);
        return;
    }
    NSError *err = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
    if (!reader) {
        VCAM_LOG_OBJC(@"reader create err: %@", err.localizedDescription);
        return;
    }
    // Decode at target dims (camera buffer size) so fast memcpy path hits.
    // AVAssetReader scales for us — hardware-backed, cheap.
    NSMutableDictionary *outSettings = [@{
        (NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)
    } mutableCopy];
    if (self.decodeDims.width > 0) {
        outSettings[(NSString *)kCVPixelBufferWidthKey] = @((NSInteger)self.decodeDims.width);
        outSettings[(NSString *)kCVPixelBufferHeightKey] = @((NSInteger)self.decodeDims.height);
    }
    AVAssetReaderTrackOutput *out = [[AVAssetReaderTrackOutput alloc] initWithTrack:tracks.firstObject outputSettings:outSettings];
    [reader addOutput:out];
    [reader startReading];
    self.reader = reader;
    self.readerOutput = out;
    self.currentAsset = asset;
    VCAM_LOG_OBJC(@"video media loaded: %@ (%@) decode=%lldx%lld", self.videoPath,
                  @(asset.duration.value / asset.duration.timescale),
                  (long long)self.decodeDims.width, (long long)self.decodeDims.height);
}

// Get next frame (BGRA pixel buffer, retained). Loops the video.
// Loop strategy: when reader exhausts, restart it INLINE but note the disk/IO
// cost lands on the camera frame thread. To keep stalls bounded we decode one
// frame ahead into `heldFrame`: on restart the held frame is returned while
// the fresh reader spins up on the engine queue.
- (CVPixelBufferRef)nextVideoFrameLocked {
    if (!self.reader || self.reader.status == AVAssetReaderStatusCompleted || self.reader.status == AVAssetReaderStatusFailed) {
        // Serve the held frame while restarting (frame-ahead)
        CVPixelBufferRef serving = NULL;
        if (self.heldFrame) { serving = self.heldFrame; self.heldFrame = NULL; }
        [self loadVideoMedia];
        if (serving) return serving;
        if (!self.reader) return NULL;
    }
    CMSampleBufferRef sb = [self.readerOutput copyNextSampleBuffer];
    if (!sb) {
        CVPixelBufferRef serving = NULL;
        if (self.heldFrame) { serving = self.heldFrame; self.heldFrame = NULL; }
        [self loadVideoMedia];
        if (!self.reader) return serving;
        sb = [self.readerOutput copyNextSampleBuffer];
        if (!sb) return serving;
    }
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    CVPixelBufferRef copy = NULL;
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    OSType fmt = CVPixelBufferGetPixelFormatType(pb);
    size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
    CVReturn ret = CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt, NULL, &copy);
    if (ret == kCVReturnSuccess) {
        CVPixelBufferLockBaseAddress(copy, 0);
        // Copy plane-by-plane (handles BGRA single-plane and 420 double-plane)
        for (size_t plane = 0; plane < MAX(1, CVPixelBufferGetPlaneCount(pb)); plane++) {
            void *src = CVPixelBufferGetPlaneCount(pb) ? CVPixelBufferGetBaseAddressOfPlane(pb, plane) : CVPixelBufferGetBaseAddress(pb);
            void *dst = CVPixelBufferGetPlaneCount(copy) ? CVPixelBufferGetBaseAddressOfPlane(copy, plane) : CVPixelBufferGetBaseAddress(copy);
            size_t srcBPR = CVPixelBufferGetPlaneCount(pb) ? CVPixelBufferGetBytesPerRowOfPlane(pb, plane) : CVPixelBufferGetBytesPerRow(pb);
            size_t dstBPR = CVPixelBufferGetPlaneCount(copy) ? CVPixelBufferGetBytesPerRowOfPlane(copy, plane) : CVPixelBufferGetBytesPerRow(copy);
            size_t height = CVPixelBufferGetPlaneCount(pb) ? CVPixelBufferGetHeightOfPlane(pb, plane) : CVPixelBufferGetHeight(pb);
            size_t copyB = MIN(srcBPR, dstBPR);
            for (size_t row = 0; row < height; row++) {
                memcpy((uint8_t *)dst + row * dstBPR, (uint8_t *)src + row * srcBPR, copyB);
            }
        }
        CVPixelBufferUnlockBaseAddress(copy, 0);
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    CFRelease(sb);
    return copy;
}

#pragma mark - Photo media

- (void)loadPhotoMedia {
    self.photoData = nil;
    if (self.cachedPhotoPB) { CFRelease(self.cachedPhotoPB); self.cachedPhotoPB = NULL; }
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.photoPath]) {
        VCAM_LOG("photo media missing: %@", self.photoPath);
        return;
    }
    self.photoData = [NSData dataWithContentsOfFile:self.photoPath];
    if (self.photoData) VCAM_LOG("photo media loaded: %@ (%lu bytes)", self.photoPath, (unsigned long)self.photoData.length);
}

- (NSData *)replacementPhotoData {
    return self.photoData;
}

- (BOOL)hasPhotoMedia {
    return self.photoData != nil;
}

- (BOOL)hasVideoMedia {
    return self.reader != nil;
}

#pragma mark - Render into destination buffer

- (BOOL)renderIntoPixelBuffer:(CVPixelBufferRef)dst {
    if (![self activeForCurrentProcess]) return NO;

    @synchronized (self.mediaLock) {
        // One-time: retarget decoder to camera buffer dims for fast memcpy path
        if (!self.decodeDimsLocked) {
            size_t dw = CVPixelBufferGetWidth(dst), dh = CVPixelBufferGetHeight(dst);
            OSType dfmt = CVPixelBufferGetPixelFormatType(dst);
            if (dw > 0 && dh > 0) {
                self.decodeDims = CGSizeMake(dw, dh);
                self.decodeDimsLocked = YES;
                VCAM_LOG_OBJC(@"decode dims locked to camera buffer: %zux%zu fmt=%u", dw, dh, dfmt);
                [self loadVideoMedia];
            }
        }
        CVPixelBufferRef src = [self nextVideoFrameLocked];
        if (!src) {
            // fall back to photo as static frame
            if (!self.photoData) return NO;
            src = [self photoAsPixelBuffer];
            if (!src) return NO;
            BOOL ok = [self blit:src to:dst];
            CFRelease(src);
            return ok;
        }
        BOOL ok = [self blit:src to:dst];
        CFRelease(src);
        return ok;
    }
}

- (CVPixelBufferRef)photoAsPixelBuffer {
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)self.photoData, NULL);
    if (!src) return NULL;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!img) return NULL;

    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    CVPixelBufferRef pb = NULL;
    CVReturn ret = CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, NULL, &pb);
    if (ret != kCVReturnSuccess) { CFRelease(img); return NULL; }

    CVPixelBufferLockBaseAddress(pb, 0);
    void *base = CVPixelBufferGetBaseAddress(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    if (ctx) {
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
        CFRelease(ctx);
    }
    CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    CFRelease(img);
    return pb;
}

#pragma mark - Photo render (still capture hooks)

- (BOOL)renderPhotoIntoPixelBuffer:(CVPixelBufferRef)dst {
    if (![self activeForCurrentProcess]) return NO;
    @synchronized (self.mediaLock) {
        if (!self.photoData) return NO;
        // CPU-safety: decode photo ONCE at the STILL BUFFER's size. Decoding
        // at native (e.g. 12MP) then CI-scaling per frame on mediaserverd's
        // capture thread = 2-5s stall = watchdogd kill = kernel panic.
        // Re-decode only when dst dims change.
        size_t dw = CVPixelBufferGetWidth(dst), dh = CVPixelBufferGetHeight(dst);
        if (!self.cachedPhotoPB ||
            CVPixelBufferGetWidth(self.cachedPhotoPB) != dw ||
            CVPixelBufferGetHeight(self.cachedPhotoPB) != dh) {
            if (self.cachedPhotoPB) { CFRelease(self.cachedPhotoPB); self.cachedPhotoPB = NULL; }
            self.cachedPhotoPB = [self photoAsPixelBufferScaledToWidth:dw height:dh];
            if (self.cachedPhotoPB) VCAM_LOG_OBJC(@"photo decoded at still-buffer size %zux%zu", dw, dh);
        }
        if (!self.cachedPhotoPB) return NO;
        // Same fmt+dims -> fast memcpy path guaranteed
        return [self blit:self.cachedPhotoPB to:dst];
    }
}

// Decode photo.jpg into a BGRA pixel buffer of exactly w x h (CG affine draw).
- (CVPixelBufferRef)photoAsPixelBufferScaledToWidth:(size_t)w height:(size_t)h {
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)self.photoData, NULL);
    if (!src) return NULL;
    CGImageRef fullImg = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!fullImg) return NULL;

    CVPixelBufferRef pb = NULL;
    CVReturn ret = CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, NULL, &pb);
    if (ret != kCVReturnSuccess) { CFRelease(fullImg); return NULL; }

    CVPixelBufferLockBaseAddress(pb, 0);
    void *base = CVPixelBufferGetBaseAddress(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    if (ctx) {
        // aspect-fill then center-crop draw (one-time cost, not per frame)
        size_t iw = CGImageGetWidth(fullImg), ih = CGImageGetHeight(fullImg);
        CGFloat scale = MAX((CGFloat)w / iw, (CGFloat)h / ih);
        CGFloat dw = iw * scale, dh = ih * scale;
        CGRect drawRect = CGRectMake((w - dw) / 2.0, (h - dh) / 2.0, dw, dh);
        CGContextDrawImage(ctx, drawRect, fullImg);
        CFRelease(ctx);
    }
    CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    CFRelease(fullImg);
    return pb;
}

// Draw src over dst handling format differences (BGRA<->BGRA direct; BGRA->NV12 convert)
// CPU budget note (mediaserverd): fast path = same fmt+dims memcpy; slow path =
// software CI render. Slow path per 1080p frame ~15-25ms on A10 — acceptable
// only if decoder dims mismatch (fixed on first frame via decodeDims lock).
- (BOOL)blit:(CVPixelBufferRef)src to:(CVPixelBufferRef)dst {
    if (!src || !dst) return NO;

    OSType sfmt = CVPixelBufferGetPixelFormatType(src);
    OSType dfmt = CVPixelBufferGetPixelFormatType(dst);
    size_t dw = CVPixelBufferGetWidth(dst), dh = CVPixelBufferGetHeight(dst);
    size_t sw = CVPixelBufferGetWidth(src), sh = CVPixelBufferGetHeight(src);

    if (sfmt == dfmt && sw == dw && sh == dh) {
        // fast path: plane-wise copy
        CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferLockBaseAddress(dst, 0);
        size_t planes = MAX(1, CVPixelBufferGetPlaneCount(src));
        for (size_t p = 0; p < planes; p++) {
            void *sp = CVPixelBufferGetPlaneCount(src) ? CVPixelBufferGetBaseAddressOfPlane(src, p) : CVPixelBufferGetBaseAddress(src);
            void *dp = CVPixelBufferGetPlaneCount(dst) ? CVPixelBufferGetBaseAddressOfPlane(dst, p) : CVPixelBufferGetBaseAddress(dst);
            size_t sbpr = CVPixelBufferGetPlaneCount(src) ? CVPixelBufferGetBytesPerRowOfPlane(src, p) : CVPixelBufferGetBytesPerRow(src);
            size_t dbpr = CVPixelBufferGetPlaneCount(dst) ? CVPixelBufferGetBytesPerRowOfPlane(dst, p) : CVPixelBufferGetBytesPerRow(dst);
            size_t h = CVPixelBufferGetPlaneCount(src) ? CVPixelBufferGetHeightOfPlane(src, p) : CVPixelBufferGetHeight(src);
            size_t cb = MIN(sbpr, dbpr);
            for (size_t row = 0; row < h; row++)
                memcpy((uint8_t *)dp + row * dbpr, (uint8_t *)sp + row * sbpr, cb);
        }
        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferUnlockBaseAddress(dst, 0);
        return YES;
    }

    // General path: CIImage render (handles scale + format via software renderer)
    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CIImage *ci = [CIImage imageWithCVPixelBuffer:src];
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    if (!ci) return NO;

    // scale to destination size (fill)
    CIImage *scaled = [ci imageByClampingToExtent];
    CGAffineTransform t = CGAffineTransformMakeScale((CGFloat)dw / sw, (CGFloat)dh / sh);
    scaled = [scaled imageByApplyingTransform:t];
    scaled = [scaled imageByCroppingToRect:CGRectMake(0, 0, dw, dh)];

    CVPixelBufferLockBaseAddress(dst, 0);
    [self.ciContext render:scaled toCVPixelBuffer:dst bounds:CGRectMake(0, 0, dw, dh) colorSpace:CGColorSpaceCreateDeviceRGB()];
    CVPixelBufferUnlockBaseAddress(dst, 0);
    return YES;
}

@end
