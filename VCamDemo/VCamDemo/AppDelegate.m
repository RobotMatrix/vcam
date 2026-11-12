//
//  AppDelegate.m
//  VCamDemo
//

#import "AppDelegate.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    NSLog(@"[VCamDemo] launch, bundle=%@", [[NSBundle mainBundle] bundleIdentifier]);
    return YES;
}

@end
