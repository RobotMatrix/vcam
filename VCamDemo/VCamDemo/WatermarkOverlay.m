//
//  WatermarkOverlay.m
//  VCamDemo
//
//  WMC-inspired design (腾讯水印相机):
//   preview = camera frame + floating watermark view (updates live)
//   photo   = camera frame image + watermark view snapshot composited
//   EXIF    = DateTimeOriginal / GPS metadata written into JPEG
//

#import "WatermarkOverlay.h"
#import <ImageIO/ImageIO.h>
#import <CoreLocation/CoreLocation.h>
#import <CoreGraphics/CoreGraphics.h>

// EXIF injection entry (defined at bottom; used by ViewController)
NSString * VCamWriteEXIFToJPEG(NSString *path, CLLocationCoordinate2D coord);

@interface WatermarkOverlay ()
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UILabel *metaLabel;
@property (nonatomic, strong) UILabel *brandLabel;
@end

@implementation WatermarkOverlay

+ (instancetype)sharedOverlay {
    static WatermarkOverlay *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[WatermarkOverlay alloc] initWithFrame:CGRectZero]; });
    return inst;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;

        // top-left brand tag: proves replacement source
        self.brandLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, 200, 22)];
        self.brandLabel.text = @"VCAM REPLACED";
        self.brandLabel.font = [UIFont boldSystemFontOfSize:15];
        self.brandLabel.textColor = [UIColor whiteColor];
        self.brandLabel.shadowColor = [UIColor blackColor];
        self.brandLabel.shadowOffset = CGSizeMake(1, 1);
        [self addSubview:self.brandLabel];

        // bottom-left timestamp (WMC: time watermark is the core feature)
        self.timeLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, 320, 34)];
        self.timeLabel.frame = CGRectMake(12, frame.size.height - 92, 320, 34);
        self.timeLabel.font = [UIFont boldSystemFontOfSize:24];
        self.timeLabel.textColor = [UIColor whiteColor];
        self.timeLabel.shadowColor = [UIColor blackColor];
        self.timeLabel.shadowOffset = CGSizeMake(1, 1);
        [self addSubview:self.timeLabel];

        // below timestamp: frame counter + res
        self.metaLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, frame.size.height - 58, 320, 22)];
        self.metaLabel.font = [UIFont systemFontOfSize:13];
        self.metaLabel.textColor = [UIColor whiteColor];
        self.metaLabel.shadowColor = [UIColor blackColor];
        self.metaLabel.shadowOffset = CGSizeMake(1, 1);
        [self addSubview:self.metaLabel];

        [self refreshWithFrameCount:0];
    }
    return self;
}

- (void)refreshWithFrameCount:(NSUInteger)frameCount {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    self.timeLabel.text = [fmt stringFromDate:[NSDate date]];
    self.metaLabel.text = [NSString stringWithFormat:@"frame #%lu  ·  %@", (unsigned long)frameCount, [[UIDevice currentDevice] model]];
}

// Render overlay contents into a transparent image at target size
// (view is laid out at capture aspect; snapshot scales content).
- (UIImage *)snapshotForSize:(CGSize)size {
    CGSize fit = self.bounds.size;
    if (fit.width <= 0 || fit.height <= 0) return nil;
    CGFloat scale = MIN(size.width / fit.width, size.height / fit.height);

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    UIImage *img = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        // anchor content top-left, scale text via transform
        CGContextScaleCTM(ctx.CGContext, scale, scale);
        [self.layer renderInContext:ctx.CGContext];
    }];
    return img;
}

@end

#pragma mark - EXIF injection helpers

// Write DateTimeOriginal + GPS into JPEG (WMC writes _exifDic the same way:
// kCGImagePropertyExifDateTimeOriginal + GPS dictionary, via ImageIO).
NSString * VCamWriteEXIFToJPEG(NSString *path, CLLocationCoordinate2D coord) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;

    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!src) return nil;

    NSMutableDictionary *meta = [(__bridge NSDictionary *)CGImageSourceCopyPropertiesAtIndex(src, 0, NULL) mutableCopy] ?: [NSMutableDictionary dictionary];

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy:MM:dd HH:mm:ss";
    NSString *now = [fmt stringFromDate:[NSDate date]];

    NSMutableDictionary *exif = [meta[(NSString *)kCGImagePropertyExifDictionary] mutableCopy] ?: [NSMutableDictionary dictionary];
    exif[(NSString *)kCGImagePropertyExifDateTimeOriginal] = now;
    exif[(NSString *)kCGImagePropertyExifDateTimeDigitized] = now;
    exif[(NSString *)kCGImagePropertyExifUserComment] = @"VCamDemo replaced frame";
    meta[(NSString *)kCGImagePropertyExifDictionary] = exif;

    // kCLLocationCoordinate2DInvalid is non-zero (DBL_MAX) — a != 0 test would
    // inject garbage ±180° GPS. Only write when the coordinate is real.
    if (CLLocationCoordinate2DIsValid(coord)) {
        NSMutableDictionary *gps = [meta[(NSString *)kCGImagePropertyGPSDictionary] mutableCopy] ?: [NSMutableDictionary dictionary];
        gps[(NSString *)kCGImagePropertyGPSLatitude] = @(fabs(coord.latitude));
        gps[(NSString *)kCGImagePropertyGPSLatitudeRef] = coord.latitude >= 0 ? @"N" : @"S";
        gps[(NSString *)kCGImagePropertyGPSLongitude] = @(fabs(coord.longitude));
        gps[(NSString *)kCGImagePropertyGPSLongitudeRef] = coord.longitude >= 0 ? @"E" : @"W";
        gps[(NSString *)kCGImagePropertyGPSDateStamp] = [fmt stringFromDate:[NSDate date]];
        meta[(NSString *)kCGImagePropertyGPSDictionary] = gps;
    }

    NSMutableData *out = [NSMutableData data];
    CGImageDestinationRef dst = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out, (__bridge CFStringRef)@"public.jpeg", 1, NULL);
    if (dst) {
        CGImageDestinationAddImageFromSource(dst, src, 0, (__bridge CFDictionaryRef)meta);
        CGImageDestinationFinalize(dst);
        CFRelease(dst);
        [out writeToFile:path atomically:YES];
    }
    CFRelease(src);
    return path;
}
