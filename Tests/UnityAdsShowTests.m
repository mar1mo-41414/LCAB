// iOS Simulator regression harness; see Tests/README.md.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ABThirdPartyAdHooks.h"

static NSUInteger originalCalls;
static void OriginalShow(id self, SEL cmd, id vc, id placement, id delegate) {
    originalCalls++;
}

@interface ShowDelegate : NSObject
@property(nonatomic, strong) NSMutableArray *events;
@property(nonatomic, strong) NSString *placement;
@end
@implementation ShowDelegate
- (instancetype)init {
    if ((self = [super init])) _events = [NSMutableArray array];
    return self;
}
- (void)unityAdsShowStart:(NSString *)placement {
    NSCAssert([NSThread isMainThread], @"callback must run on main thread");
    self.placement = placement;
    [self.events addObject:@"start"];
}
- (void)unityAdsShowComplete:(NSString *)placement withFinishState:(NSInteger)state {
    NSCAssert([NSThread isMainThread], @"callback must run on main thread");
    NSCAssert(placement == self.placement && state == 2, @"placement/completed enum mismatch");
    [self.events addObject:@"complete"];
}
@end

int main(void) {
    @autoreleasepool {
        // Missing SDK must be safe; a later install must still succeed.
        ABInstallThirdPartyAdHooks();
        Class cls = objc_allocateClassPair([NSObject class], "LCABTestUnityAds", 0);
        NSCAssert(cls != Nil, @"mock class allocation failed");
        SEL show = NSSelectorFromString(@"show:placementId:showDelegate:");
        class_addMethod(object_getClass(cls), show, (IMP)OriginalShow, "v@:@@@");
        objc_registerClassPair(cls);
        ABInstallThirdPartyAdHooks();
        ABInstallThirdPartyAdHooks(); // idempotent retry
        ShowDelegate *delegate = [ShowDelegate new];
        NSString *placement = @"game-over";
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(cls, show, nil, placement, delegate);
        NSCAssert(originalCalls == 0 && delegate.events.count == 0, @"show must block and notify asynchronously");
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1];
        while (delegate.events.count < 2 && deadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        NSCAssert([delegate.events isEqual:@[@"start", @"complete"]], @"expected exactly one ordered callback pair");
        // Nil and non-conforming delegates must not crash.
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(cls, show, nil, nil, nil);
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(cls, show, nil, placement, [NSObject new]);
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        NSCAssert(originalCalls == 0, @"original show must never run");
        NSLog(@"Unity Ads show tests passed");
    }
    return 0;
}
