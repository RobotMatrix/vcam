//
//  ViewController.m
//  VCamDemo
//
//  Single-pipeline design (hook-friendly):
//   All captured artifacts (preview, photo, video) derive from the
//   AVCaptureVideoDataOutput delegate frames — the ONLY path that
//   per-app tweaks (vcama) can replace. AVCaptureVideoPreviewLayer /
//   AVCapturePhotoOutput / AVCaptureMovieFileOutput bypass that delegate
//   and would show un-replaced camera content in per-app mode.
//
//   - preview   : UIImageView rendered from replaced frames (throttled)
//   - photo     : latest replaced frame -> captured_photo.jpg
//   - video     : AVAssetWriter appending replaced frames -> captured_video.mov
//

#import "ViewController.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import "WatermarkOverlay.h"
#import <CoreLocation/CoreLocation.h>

@interface ViewController () <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoDataOutput;
@property (nonatomic, strong) dispatch_queue_t videoQueue;

@property (nonatomic, strong) UIImageView *previewImageView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *photoButton;
@property (nonatomic, strong) UIButton *recordButton;
@property (nonatomic, strong) UIButton *retryButton;

@property (nonatomic, assign) BOOL recording;
@property (nonatomic, assign) NSUInteger frameCount;

// latest replaced frame (retained), guarded by frameLock
@property (nonatomic, assign) CVPixelBufferRef latestFrame;
@property (nonatomic, strong) NSObject *frameLock;

// AVAssetWriter recording state
@property (nonatomic, strong) AVAssetWriter *assetWriter;
@property (nonatomic, strong) AVAssetWriterInput *writerInput;
@property (nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor *adaptor;
@property (nonatomic, assign) CMTime writerStartPTS;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.videoQueue = dispatch_queue_create("vcamdemo.videoqueue", DISPATCH_QUEUE_SERIAL);
    self.frameLock = [[NSObject alloc] init];

    [self buildUI];
    [self logStatus:@"viewDidLoad — checking camera permission..."];
    [self checkPermissionAndStart];
}

#pragma mark - Permission

- (void)checkPermissionAndStart {
    AVAuthorizationStatus st = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    [self logStatus:[NSString stringWithFormat:@"camera auth status: %ld", (long)st]];
    switch (st) {
        case AVAuthorizationStatusAuthorized: {
            [self setupAndStartSession];
            break;
        }
        case AVAuthorizationStatusNotDetermined: {
            [self logStatus:@"requesting camera access..."];
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self logStatus:granted ? @"permission GRANTED" : @"permission DENIED"];
                    if (granted) [self setupAndStartSession];
                });
            }];
            break;
        }
        case AVAuthorizationStatusDenied:
        case AVAuthorizationStatusRestricted: {
            [self logStatus:@"CAMERA PERMISSION DENIED.\nSettings > VCamDemo > Camera > Allow\nthen tap RETRY."];
            break;
        }
    }
}

#pragma mark - Session

- (void)setupAndStartSession {
    if (!self.session) {
        [self logStatus:@"setting up session..."];
        AVCaptureSession *session = [[AVCaptureSession alloc] init];
        if ([session canSetSessionPreset:AVCaptureSessionPresetHigh]) session.sessionPreset = AVCaptureSessionPresetHigh;
        self.session = session;

        AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        if (!device) { [self logStatus:@"ERROR: no camera device"]; return; }
        [self logStatus:[NSString stringWithFormat:@"device: %@", device.localizedName]];

        NSError *err = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&err];
        if (!input) { [self logStatus:[NSString stringWithFormat:@"ERROR input: %@", err.localizedDescription]]; return; }
        if ([session canAddInput:input]) { [session addInput:input]; [self logStatus:@"input added"]; }

        self.videoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
        self.videoDataOutput.videoSettings = @{(NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)};
        self.videoDataOutput.alwaysDiscardsLateVideoFrames = YES;
        [self.videoDataOutput setSampleBufferDelegate:self queue:self.videoQueue];
        if ([session canAddOutput:self.videoDataOutput]) { [session addOutput:self.videoDataOutput]; [self logStatus:@"videoDataOutput added"]; }
        else { [self logStatus:@"ERROR: cannot add videoDataOutput"]; }
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self.session startRunning];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self logStatus:[NSString stringWithFormat:@"startRunning done, running=%d", self.session.isRunning]];
            [self scheduleAutoTest];
        });
    });
}

- (void)scheduleAutoTest {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self logStatus:@"AUTO photo at +8s"];
        [self takePhoto];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self logStatus:@"AUTO photo retry at +20s"];
        [self takePhoto];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self logStatus:@"AUTO record start at +15s"];
        if (!self.recording) [self toggleRecord];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(32 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self logStatus:@"AUTO record stop at +32s"];
        if (self.recording) [self toggleRecord];
    });
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.previewImageView.frame = self.view.bounds;
}

#pragma mark - UI

- (void)buildUI {
    self.previewImageView = [[UIImageView alloc] initWithFrame:self.view.bounds];
    self.previewImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.previewImageView.clipsToBounds = YES;
    [self.view addSubview:self.previewImageView];

    // WMC-style watermark overlay: floats above preview, composited into photos
    WatermarkOverlay *wm = [WatermarkOverlay sharedOverlay];
    wm.frame = CGRectMake(0, 0, self.view.bounds.size.width, self.view.bounds.size.height);
    [self.view addSubview:wm];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 30, 359, 100)];
    self.statusLabel.textColor = [UIColor greenColor];
    self.statusLabel.font = [UIFont boldSystemFontOfSize:11];
    self.statusLabel.numberOfLines = 6;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.text = @"init...";
    [self.view addSubview:self.statusLabel];

    self.photoButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.photoButton setTitle:@"PHOTO" forState:UIControlStateNormal];
    self.photoButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.35];
    self.photoButton.layer.cornerRadius = 8;
    [self.photoButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.photoButton addTarget:self action:@selector(takePhoto) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.photoButton];

    self.recordButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.recordButton setTitle:@"REC" forState:UIControlStateNormal];
    self.recordButton.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.55];
    self.recordButton.layer.cornerRadius = 8;
    [self.recordButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.recordButton addTarget:self action:@selector(toggleRecord) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.recordButton];

    self.retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.retryButton setTitle:@"RETRY" forState:UIControlStateNormal];
    self.retryButton.backgroundColor = [[UIColor blueColor] colorWithAlphaComponent:0.55];
    self.retryButton.layer.cornerRadius = 8;
    [self.retryButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.retryButton addTarget:self action:@selector(retryTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.retryButton];

    UIButton *resultButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [resultButton setTitle:@"RESULT" forState:UIControlStateNormal];
    resultButton.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    resultButton.backgroundColor = [[UIColor orangeColor] colorWithAlphaComponent:0.7];
    resultButton.layer.cornerRadius = 6;
    [resultButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [resultButton addTarget:self action:@selector(showResult) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:resultButton];

    [self.view bringSubviewToFront:self.statusLabel];
    [self.view bringSubviewToFront:self.photoButton];
    [self.view bringSubviewToFront:self.recordButton];
    [self.view bringSubviewToFront:self.retryButton];
    [self.view bringSubviewToFront:resultButton];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    CGFloat h = self.view.bounds.size.height;
    self.photoButton.frame = CGRectMake(30, h - 110, 90, 46);
    self.recordButton.frame = CGRectMake(142, h - 110, 90, 46);
    self.retryButton.frame = CGRectMake(254, h - 110, 90, 46);
}

- (void)logStatus:(NSString *)text {
    NSLog(@"[VCamDemo] %@", text);
    self.statusLabel.text = text;
    static NSString *logPath = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        logPath = [dir stringByAppendingPathComponent:@"vcamdemo.log"];
    });
    NSString *line = [NSString stringWithFormat:@"%@ | %@\n",
                      [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                     dateStyle:NSDateFormatterNoStyle
                                                     timeStyle:NSDateFormatterMediumStyle], text];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!fh) {
        [line writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

- (void)retryTapped {
    [self logStatus:@"RETRY tapped"];
    [self checkPermissionAndStart];
}

#pragma mark - Frame delegate (the hookable path)

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    self.frameCount++;
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pb) return;

    // stash latest frame (already content-replaced by hook when active)
    CVPixelBufferRef old = nil;
    CVPixelBufferRetain(pb);
    @synchronized (self.frameLock) {
        old = self.latestFrame;
        self.latestFrame = pb;
    }
    if (old) CFRelease(old);

    // append to recorder
    if (self.recording) [self appendFrameIfRecording:sampleBuffer buffer:pb];

    // throttled preview update (every 3rd frame ≈10fps)
    if (self.frameCount % 3 == 0) {
        UIImage *img = [self imageFromPixelBuffer:pb];
        if (img) dispatch_async(dispatch_get_main_queue(), ^{
            self.previewImageView.image = img;
            [[WatermarkOverlay sharedOverlay] refreshWithFrameCount:self.frameCount];
        });
    }

    if (self.frameCount == 1 || (self.frameCount % 150) == 0) {
        size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
        NSLog(@"[VCamDemo] FRAME #%lu %zux%zu fmt=%u", (unsigned long)self.frameCount, w, h, CVPixelBufferGetPixelFormatType(pb));
        dispatch_async(dispatch_get_main_queue(), ^{
            [self logStatus:[NSString stringWithFormat:@"RUNNING frame #%lu (%zux%zu)", (unsigned long)self.frameCount, w, h]];
        });
    }
}

- (UIImage *)imageFromPixelBuffer:(CVPixelBufferRef)pb {
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    void *base = CVPixelBufferGetBaseAddress(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, bpr, cs,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx) { CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly); return nil; }
    memcpy(CGBitmapContextGetData(ctx), base, bpr * h);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CFRelease(ctx);
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    if (!img) return nil;
    UIImage *ui = [UIImage imageWithCGImage:img];
    CGImageRelease(img);
    return ui;
}

#pragma mark - Photo (from replaced frames)

- (void)takePhoto {
    CVPixelBufferRef pb = nil;
    @synchronized (self.frameLock) {
        pb = self.latestFrame;
        if (pb) CVPixelBufferRetain(pb);
    }
    if (!pb) { [self logStatus:@"PHOTO ERR: no frame yet"]; return; }

    UIImage *frameImg = [self imageFromPixelBuffer:pb];
    CVPixelBufferRelease(pb);
    if (!frameImg) { [self logStatus:@"PHOTO ERR: convert failed"]; return; }

    // WMC mergeWatermarks: pattern — composite watermark overlay into photo
    UIImage *watermark = [[WatermarkOverlay sharedOverlay] snapshotForSize:frameImg.size];
    UIImage *finalImg = frameImg;
    if (watermark) {
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:frameImg.size];
        finalImg = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [frameImg drawInRect:CGRectMake(0, 0, frameImg.size.width, frameImg.size.height)];
            [watermark drawInRect:CGRectMake(0, 0, frameImg.size.width, frameImg.size.height)];
        }];
    }

    NSData *jpeg = UIImageJPEGRepresentation(finalImg, 0.9);
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [dir stringByAppendingPathComponent:@"captured_photo.jpg"];
    [jpeg writeToFile:path atomically:YES];

    // EXIF injection (WMC _exifDic pattern): time + GPS if available
    CLLocationCoordinate2D coord = kCLLocationCoordinate2DInvalid;
    CLLocationManager *lm = [[CLLocationManager alloc] init];
    CLLocation *loc = lm.location; // last known, no prompt
    if (loc) coord = loc.coordinate;
    VCamWriteEXIFToJPEG(path, coord);

    [self logStatus:[NSString stringWithFormat:@"PHOTO saved %lu bytes (watermark+EXIF)", (unsigned long)jpeg.length]];
}

#pragma mark - Record (AVAssetWriter from replaced frames)

- (void)toggleRecord {
    if (!self.recording) {
        NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *path = [dir stringByAppendingPathComponent:@"captured_video.mov"];
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];

        CVPixelBufferRef pb = nil;
        @synchronized (self.frameLock) { pb = self.latestFrame; if (pb) CVPixelBufferRetain(pb); }
        if (!pb) { [self logStatus:@"REC ERR: no frame yet"]; return; }
        size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
        CVPixelBufferRelease(pb);

        NSError *err = nil;
        self.assetWriter = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:path]
                                                    fileType:AVFileTypeQuickTimeMovie
                                                       error:&err];
        if (!self.assetWriter) { [self logStatus:[NSString stringWithFormat:@"REC ERR: %@", err.localizedDescription]]; return; }

        self.writerInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                              outputSettings:@{AVVideoCodecKey: AVVideoCodecTypeH264,
                                                                               AVVideoWidthKey: @(w),
                                                                               AVVideoHeightKey: @(h)}];
        self.writerInput.expectsMediaDataInRealTime = YES;
        self.adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:self.writerInput
                                                                                         sourcePixelBufferAttributes:@{(NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                                                                                                                       (NSString *)kCVPixelBufferWidthKey: @(w),
                                                                                                                       (NSString *)kCVPixelBufferHeightKey: @(h)}];
        [self.assetWriter addInput:self.writerInput];
        [self.assetWriter startWriting];
        self.writerStartPTS = CMTimeMake(-1, 1);
        self.recording = YES;
        [self.recordButton setTitle:@"STOP" forState:UIControlStateNormal];
        [self logStatus:@"recording..."];
    } else {
        self.recording = NO;
        [self.recordButton setTitle:@"REC" forState:UIControlStateNormal];
        AVAssetWriter *writer = self.assetWriter;
        [self.writerInput markAsFinished];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [writer finishWritingWithCompletionHandler:^{
                NSString *msg = (writer.status == AVAssetWriterStatusCompleted)
                    ? [NSString stringWithFormat:@"VIDEO saved (%@ bytes)", [self fileSizeOf:writer.outputURL.path]]
                    : [NSString stringWithFormat:@"REC ERR: status=%ld err=%@", (long)writer.status, writer.error.localizedDescription];
                dispatch_async(dispatch_get_main_queue(), ^{ [self logStatus:msg]; });
            }];
        });
    }
}

- (NSString *)fileSizeOf:(NSString *)path {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    return [NSString stringWithFormat:@"%@", attrs[NSFileSize] ?: @"?"];
}

- (void)appendFrameIfRecording:(CMSampleBufferRef)sampleBuffer buffer:(CVPixelBufferRef)pb {
    if (!self.assetWriter || self.assetWriter.status != AVAssetWriterStatusWriting) return;
    if (!CMSampleBufferDataIsReady(sampleBuffer)) return;
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    if (self.writerStartPTS.value < 0) {
        self.writerStartPTS = pts;
        [self.assetWriter startSessionAtSourceTime:pts];
    }
    if (self.adaptor.assetWriterInput.isReadyForMoreMediaData) {
        [self.adaptor appendPixelBuffer:pb withPresentationTime:pts];
    }
}

#pragma mark - RESULT viewer

- (void)showResult {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;

    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor blackColor];
    vc.title = @"Captured (replaced?)";

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    UIViewController *root = nav.viewControllers.firstObject;
    root.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                          target:self action:@selector(closeResult)];
    [self presentViewController:nav animated:YES completion:nil];

    CGFloat y = 90;
    NSString *photoPath = [dir stringByAppendingPathComponent:@"captured_photo.jpg"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:photoPath]) {
        UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage imageWithContentsOfFile:photoPath]];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.frame = CGRectMake(10, y, 355, 220);
        iv.backgroundColor = [UIColor darkGrayColor];
        [vc.view addSubview:iv];
        [self addCaption:@"PHOTO (expect: color grid + V mark)" to:vc atY:y + 222];
        y += 250;
    } else {
        [self addCaption:@"photo: not captured yet" to:vc atY:y gray:YES];
        y += 26;
    }

    NSString *videoPath = [dir stringByAppendingPathComponent:@"captured_video.mov"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:videoPath]) {
        AVPlayer *player = [AVPlayer playerWithURL:[NSURL fileURLWithPath:videoPath]];
        AVPlayerLayer *pl = [AVPlayerLayer playerLayerWithPlayer:player];
        pl.frame = CGRectMake(10, y, 355, 200);
        pl.videoGravity = AVLayerVideoGravityResizeAspect;
        pl.backgroundColor = [UIColor darkGrayColor].CGColor;
        [vc.view.layer addSublayer:pl];
        [player play];
        objc_setAssociatedObject(vc, "player", player, OBJC_ASSOCIATION_RETAIN);
        [self addCaption:@"VIDEO (expect: stripes + frame counter)" to:vc atY:y + 202];
    } else {
        [self addCaption:@"video: not captured yet" to:vc atY:y gray:YES];
    }
}

- (void)addCaption:(NSString *)text to:(UIViewController *)vc atY:(CGFloat)y gray:(BOOL)gray {
    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(10, y, 355, 18)];
    lbl.text = text;
    lbl.textColor = gray ? [UIColor grayColor] : [UIColor yellowColor];
    lbl.font = [UIFont systemFontOfSize:11];
    lbl.textAlignment = NSTextAlignmentCenter;
    [vc.view addSubview:lbl];
}

- (void)addCaption:(NSString *)text to:(UIViewController *)vc atY:(CGFloat)y {
    [self addCaption:text to:vc atY:y gray:NO];
}

- (void)closeResult {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
