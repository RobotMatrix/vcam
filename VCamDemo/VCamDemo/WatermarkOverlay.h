//
//  WatermarkOverlay.h
//  VCamDemo
//
//  WMC-style watermark overlay (inspired by 腾讯水印相机 WaterMarkCamera):
//   - realtime overlay view showing timestamp / frame counter / device info
//   - preview: overlay floats above the frame image view
//   - photo capture: overlay is composited INTO the JPEG
//     (WMC pattern: preview watermark view + mergeWatermarks: at capture)
//

#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WatermarkOverlay : UIView

/// Render the current overlay into an image sized to the given frame
/// (for compositing into captured photos).
- (UIImage *)snapshotForSize:(CGSize)size;

/// Update dynamic fields (called per preview frame, throttled).
- (void)refreshWithFrameCount:(NSUInteger)frameCount;

+ (instancetype)sharedOverlay;

@end

/// Write EXIF (DateTimeOriginal + GPS + UserComment) into a JPEG file.
/// Returns the path on success.
NSString * VCamWriteEXIFToJPEG(NSString *path, CLLocationCoordinate2D coord);

NS_ASSUME_NONNULL_END
