//
//  VCamEngine.h
//  Shared replacement engine for mediaserverd (global) and in-app hooks.
//
//  Config (plist at /var/mobile/Library/vcam/config.plist):
//    enabled      : bool   master switch
//    global       : bool   true = replace for ALL apps (daemon hook only)
//    apps         : array  bundle IDs for per-app mode
//    photoPath    : string jpg/png used for still capture replacement
//    videoPath    : string mp4/mov looped for live preview replacement
//
//  Reload: darwin notification "com.bangcle.vcam.reload"
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCamEngine : NSObject

+ (instancetype)shared;

/// Should this process replace frames? (checks enabled + global + app list)
- (BOOL)activeForCurrentProcess;

/// Load/reload config and media. Safe to call repeatedly.
- (void)reload;

/// Draw the next replacement frame into dst (BGRA preferred, NV12 handled).
/// Returns YES if content was replaced.
- (BOOL)renderIntoPixelBuffer:(CVPixelBufferRef)dst;

/// Draw the configured PHOTO (photo.jpg) into dst — for still capture hooks.
/// Photo decoded once, cached as BGRA pixel buffer. Returns YES on replace.
- (BOOL)renderPhotoIntoPixelBuffer:(CVPixelBufferRef)dst;

/// Cheap gate for daemon hooks: reads config WITHOUT creating the engine
/// (no AVFoundation, no locks). Returns YES only when enabled && global.
/// mediaserverd must never build the engine in per-app mode — AVAsset work
/// inside mediaserverd XPCs into itself and deadlocks the emit path.
+ (BOOL)daemonShouldBeActive;

/// Build a replacement still image (JPEG data) for photo capture.
/// Returns nil if no photo media configured.
- (nullable NSData *)replacementPhotoData;

/// Whether replacement video media is loaded and playable.
- (BOOL)hasVideoMedia;

/// Whether replacement photo media is loaded.
- (BOOL)hasPhotoMedia;

/// Register darwin-notification observer for config reload. Call once.
- (void)startObservingReload;

@end

NS_ASSUME_NONNULL_END
