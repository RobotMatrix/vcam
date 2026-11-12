//
//  AppDelegate.h
//  VCamDemo
//

#import <UIKit/UIKit.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate>
// Required for main-storyboard apps: UIKit needs this to attach the
// storyboard-created UIWindow. Without it: "app delegate must implement the
// window property" and the UI stays black.
@property (strong, nonatomic) UIWindow *window;
@end
