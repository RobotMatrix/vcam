//
//  vcamd.m — mediaserverd daemon hook (GLOBAL camera replacement)
//
//  Hook points (verified present on iOS 13.5 mediaserverd via probe):
//   - BWNodeOutput            emitSampleBuffer:            (live preview / video stream)
//   - BWStillImageScalerNode  renderSampleBuffer:forInput: (photo scaling stage)
//   - BWPhotoEncoderNode      renderSampleBuffer:forInput: (photo encoding stage)
//
//  Strategy: replace the CVPixelBuffer CONTENT in-place (same pool/format/dims),
//  then pass to the original. Keeps CMSampleBuffer metadata/timing valid.
//
//  Filter: Executables=mediaserverd (see vcamd.plist)
//  Env guard: VCAM_DAEMON=1 so engine's global path activates
//

#import "VCamEngine.h"
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>

#define DLOG(fmt, ...) do { \
    NSString *_dlog_s = [NSString stringWithFormat:(@"[vcamd] " fmt), ##__VA_ARGS__]; \
    fprintf(stderr, "%s\n", _dlog_s.UTF8String); \
} while (0)

static void (*orig_emitSampleBuffer)(id self, SEL _cmd, CMSampleBufferRef sb);
static void (*orig_stillRender)(id self, SEL _cmd, CMSampleBufferRef sb, id input);
static void (*orig_photoRender)(id self, SEL _cmd, CMSampleBufferRef sb, id input);

static BOOL vcamd_installed = NO;
__unused static BOOL reloadArmed = NO;

// Lazy engine access: creates + loads media on a background queue on first
// camera buffer. NEVER call from constructor.
static dispatch_queue_t gEngineQueue;
static VCamEngine *gEngine;

static VCamEngine *vcamd_engineSync(void) {
    if (!gEngineQueue) gEngineQueue = dispatch_queue_create("vcamd.engine", DISPATCH_QUEUE_SERIAL);
    __block VCamEngine *e = nil;
    dispatch_sync(gEngineQueue, ^{ e = gEngine; });
    return e;
}

static void vcamd_engineEnsure(void) {
    if (!gEngineQueue) gEngineQueue = dispatch_queue_create("vcamd.engine", DISPATCH_QUEUE_SERIAL);
    dispatch_async(gEngineQueue, ^{
        if (!gEngine) {
            gEngine = [[VCamEngine alloc] init]; // loads config+media (off main thread, safe now)
            [gEngine startObservingReload];
            DLOG("engine created lazily on engine queue");
        }
    });
}

static void vcamd_replaceLiveBuffer(CMSampleBufferRef sb) {
    if (!sb) return;
    // GATE FIRST (cheap, no locks, no engine): when inactive the daemon must
    // not touch anything. Creating/loading the engine inside mediaserverd does
    // AVAsset work which XPCs into mediaserverd itself -> engine-queue
    // deadlock -> emit path blocked -> NO frames delivered to ANY app
    // (observed 2026-11-11: demo frame callback never fired, photo/video
    // capture starved). Engine is created ONLY when global mode is on.
    static int gate = -1; // -1 unknown, 0 inactive, 1 active
    if (gate < 0) {
        gate = [VCamEngine daemonShouldBeActive] ? 1 : 0;
        DLOG("live gate evaluated: %d", gate);
    }
    if (gate != 1) return;

    @try {
        CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
        if (!pb) return;
        static BOOL engineChecked = NO;
        if (!engineChecked) {
            engineChecked = YES;
            vcamd_engineEnsure();
        }
        VCamEngine *engine = vcamd_engineSync();
        if (!engine) return; // still initializing: pass through
        static BOOL firstLogged = NO;
        if (!firstLogged) {
            DLOG("live buffer: %zux%zu fmt=%u",
                 CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb),
                 CVPixelBufferGetPixelFormatType(pb));
            firstLogged = YES;
        }
        [engine renderIntoPixelBuffer:pb];
    } @catch (NSException *e) {
        DLOG("EXC replace(live): %@", e.reason);
    }
}

// Still pipeline (photo capture): replace with photo.jpg content.
// Strategy: overwrite the still buffer's pixel data with the decoded photo,
// scaled to the buffer dims. photo.jpg decoded once and cached.
static void vcamd_replaceStillBuffer(CMSampleBufferRef sb, const char *tag) {
    if (!sb) return;
    static int gate = -1;
    if (gate < 0) {
        gate = [VCamEngine daemonShouldBeActive] ? 1 : 0;
        DLOG("still gate evaluated: %d", gate);
    }
    if (gate != 1) return;
    @try {
        CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
        if (!pb) return;
        static BOOL engineChecked = NO;
        if (!engineChecked) {
            engineChecked = YES;
            vcamd_engineEnsure();
        }
        VCamEngine *engine = vcamd_engineSync();
        if (!engine) return;
        static BOOL firstLogged = NO;
        if (!firstLogged) {
            DLOG("still buffer (%s): %zux%zu fmt=%u", tag,
                 CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb),
                 CVPixelBufferGetPixelFormatType(pb));
            firstLogged = YES;
        }
        [engine renderPhotoIntoPixelBuffer:pb];
    } @catch (NSException *e) {
        DLOG("EXC replace(%s): %@", tag, e.reason);
    }
}

static void hook_emitSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sb) {
    vcamd_replaceLiveBuffer(sb);
    orig_emitSampleBuffer(self, _cmd, sb);
}

static void hook_stillRender(id self, SEL _cmd, CMSampleBufferRef sb, id input) {
    vcamd_replaceStillBuffer(sb, "stillScaler");
    orig_stillRender(self, _cmd, sb, input);
}

static void hook_photoRender(id self, SEL _cmd, CMSampleBufferRef sb, id input) {
    vcamd_replaceStillBuffer(sb, "photoEncoder");
    orig_photoRender(self, _cmd, sb, input);
}

__attribute__((constructor)) static void vcamd_main(void) {
    if (vcamd_installed) return;
    vcamd_installed = YES;

    setenv("VCAM_DAEMON", "1", 1);
    DLOG("constructor in pid %d", getpid());
    { FILE *mf = fopen("/var/tmp/vcamd_marker", "w"); if (mf) { fprintf(mf, "pid=%d\n", getpid()); fclose(mf); } }

    // SAFETY (learned from watchdogd kernel-panic incident 2026-11-11):
    // The constructor runs on mediaserverd's main thread during dyld init.
    // Touching AVFoundation here (AVAsset/AVAssetReader) issues a SYNCHRONOUS
    // XPC call to mediaserverd itself, which hasn't finished starting ->
    // main thread hangs -> watchdogd SIGKILLs mediaserverd -> after 3 kills
    // the userspace watchdog PANICS the kernel -> device reboots and the
    // jailbreak is lost.
    //
    // Rules enforced below:
    //  1. Constructor only installs objc hooks (objc_getClass + method swap:
    //     no XPC, no framework init). Safe.
    //  2. VCamEngine creation and ALL media loading happen lazily on the
    //     first camera buffer, on a background queue, never in constructor.
    //  3. Config reload observer uses a dispatch queue (notify_register_dispatch)
    //     which is safe — but the engine singleton must not be touched from
    //     within until lazily created, hence the reload-armed flag.

    reloadArmed = YES; // darwin notify will trigger reload once engine exists

    Class outCls = objc_getClass("BWNodeOutput");
    Class stillCls = objc_getClass("BWStillImageScalerNode");
    Class encCls = objc_getClass("BWPhotoEncoderNode");

    if (outCls) {
        Method m = class_getInstanceMethod(outCls, @selector(emitSampleBuffer:));
        if (m) {
            orig_emitSampleBuffer = (void (*)(id, SEL, CMSampleBufferRef))method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_emitSampleBuffer);
            DLOG("hooked BWNodeOutput emitSampleBuffer:");
        } else DLOG("MISS emitSampleBuffer:");
    } else DLOG("MISS class BWNodeOutput");

    if (stillCls) {
        Method m = class_getInstanceMethod(stillCls, @selector(renderSampleBuffer:forInput:));
        if (m) {
            orig_stillRender = (void (*)(id, SEL, CMSampleBufferRef, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_stillRender);
            DLOG("hooked BWStillImageScalerNode renderSampleBuffer:forInput:");
        }
    }

    if (encCls) {
        Method m = class_getInstanceMethod(encCls, @selector(renderSampleBuffer:forInput:));
        if (m) {
            orig_photoRender = (void (*)(id, SEL, CMSampleBufferRef, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_photoRender);
            DLOG("hooked BWPhotoEncoderNode renderSampleBuffer:forInput:");
        }
    }
}
