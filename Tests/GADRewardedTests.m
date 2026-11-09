// iOS Simulator mock-runtime regression; no Google SDK is linked.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ABThirdPartyAdHooks.h"

static NSUInteger originalCalls;
@interface GADRewardedAd : NSObject
@property(nonatomic, weak) id fullScreenContentDelegate;
- (void)presentFromRootViewController:(id)vc userDidEarnRewardHandler:(void (^)(void))handler;
@end
@implementation GADRewardedAd
- (void)presentFromRootViewController:(id)vc userDidEarnRewardHandler:(void (^)(void))handler {
    originalCalls++;
}
@end

@interface LifecycleDelegate : NSObject
@property(nonatomic, strong) NSMutableArray *events;
@property(nonatomic, weak) id expectedAd;
@end
@implementation LifecycleDelegate
- (instancetype)init {
    if ((self = [super init])) _events = [NSMutableArray array];
    return self;
}
- (void)record:(NSString *)event ad:(id)ad {
    NSCAssert([NSThread isMainThread] && ad == self.expectedAd, @"queue/ad identity mismatch");
    [self.events addObject:event];
}
- (void)adWillPresentFullScreenContent:(id)ad { [self record:@"present" ad:ad]; }
- (void)adWillDismissFullScreenContent:(id)ad { [self record:@"will-dismiss" ad:ad]; }
- (void)adDidDismissFullScreenContent:(id)ad { [self record:@"dismiss" ad:ad]; }
- (void)adDidRecordClick:(id)ad { NSCAssert(NO, @"must not fake clicks"); }
- (void)adDidRecordImpression:(id)ad { NSCAssert(NO, @"must not fake impressions"); }
@end

static void Drain(void) {
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
}
int main(void) {
    @autoreleasepool {
        ABInstallThirdPartyAdHooks();
        ABInstallThirdPartyAdHooks();
        LifecycleDelegate *delegate = [LifecycleDelegate new];
        GADRewardedAd *ad = [GADRewardedAd new];
        ad.fullScreenContentDelegate = delegate;
        delegate.expectedAd = ad;
        __block NSUInteger rewards = 0;
        [ad presentFromRootViewController:nil userDidEarnRewardHandler:^{
            NSCAssert([NSThread isMainThread], @"reward must run on main queue");
            rewards++;
            [delegate.events addObject:@"reward"];
        }];
        NSCAssert(originalCalls == 0 && delegate.events.count == 0 && rewards == 0, @"block presentation; defer callbacks");
        Drain();
        NSCAssert(([delegate.events isEqual:@[@"present", @"reward", @"will-dismiss", @"dismiss"]]), @"one ordered lifecycle");
        NSCAssert(rewards == 1, @"reward exactly once");
        // Nil reward handler must not suppress completion.
        [delegate.events removeAllObjects];
        [ad presentFromRootViewController:nil userDidEarnRewardHandler:nil];
        Drain();
        NSCAssert(([delegate.events isEqual:@[@"present", @"will-dismiss", @"dismiss"]]), @"nil handler still closes");
        ad.fullScreenContentDelegate = nil;
        [ad presentFromRootViewController:nil userDidEarnRewardHandler:^{ rewards++; }];
        Drain();
        NSCAssert(rewards == 2, @"nil delegate still rewards");
        NSObject *unimplementedDelegate = [NSObject new];
        ad.fullScreenContentDelegate = unimplementedDelegate;
        [ad presentFromRootViewController:nil userDidEarnRewardHandler:nil];
        Drain();
        NSCAssert(originalCalls == 0, @"original must never run");
        NSLog(@"AdMob rewarded lifecycle tests passed");
    }
    return 0;
}
