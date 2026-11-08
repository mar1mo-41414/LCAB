// iOS Simulator regression harness; see Tests/README.md.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ABThirdPartyAdHooks.h"

static NSUInteger originalCalls;
static void OriginalShow(id self, SEL cmd, id vc, id placement, id delegate) {
    originalCalls++;
}

static void OriginalNativeShow(id self, SEL cmd, id vc, id delegate) { originalCalls++; }

@interface ShowDelegate : NSObject
@property(nonatomic, strong) NSMutableArray *events;
@property(nonatomic, strong) NSString *placement;
@property(nonatomic, strong) id nativeAd;
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
- (void)showDidStart:(id)ad {
    NSCAssert([NSThread isMainThread], @"native callback must run on main thread");
    self.nativeAd = ad;
    [self.events addObject:@"native-start"];
}
- (void)showDidComplete:(id)ad with:(NSInteger)state {
    NSCAssert([NSThread isMainThread] && ad == self.nativeAd && state == 2, @"native callback arguments");
    [self.events addObject:@"native-close"];
}
- (void)adapterInterstitialDidOpen { [self.events addObject:@"open"]; }
- (void)adapterInterstitialDidShow { [self.events addObject:@"show"]; }
- (void)adapterInterstitialDidClose { [self.events addObject:@"close"]; }
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
        NSCAssert(([delegate.events isEqual:@[@"start", @"complete"]]), @"expected exactly one ordered callback pair");
        // Nil and non-conforming delegates must not crash.
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(cls, show, nil, nil, nil);
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(cls, show, nil, placement, [NSObject new]);
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        NSCAssert(originalCalls == 0, @"original show must never run");
        Class adapterClass = objc_allocateClassPair([NSObject class], "ISUnityAdsAdapter", 0);
        SEL adapterShow = NSSelectorFromString(@"showInterstitialWithViewController:adapterConfig:delegate:");
        class_addMethod(adapterClass, adapterShow, (IMP)OriginalShow, "v@:@@@");
        objc_registerClassPair(adapterClass);
        Class bannerClass = objc_allocateClassPair([UIView class], "LPMBannerAdView", 0);
        objc_registerClassPair(bannerClass);
        ABInstallThirdPartyAdHooks();
        ABInstallThirdPartyAdHooks();
        ShowDelegate *adapterDelegate = [ShowDelegate new];
        id adapter = [adapterClass new];
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(adapter, adapterShow, nil, @"config", adapterDelegate);
        NSCAssert(adapterDelegate.events.count == 0, @"adapter callback must be asynchronous");
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        NSCAssert(([adapterDelegate.events isEqual:@[@"open", @"show", @"close"]]), @"adapter callback order/count");
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(adapter, adapterShow, nil, nil, nil);
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(adapter, adapterShow, nil, nil, [NSObject new]);
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        NSCAssert(originalCalls == 0, @"adapter original show must not run");
        UIView *parent = [UIView new];
        UIView *sibling = [UIView new];
        UIView *banner = [bannerClass new];
        [parent addSubview:sibling];
        [parent addSubview:banner];
        banner.hidden = NO;
        banner.alpha = 1;
        [banner layoutSubviews];
        NSCAssert(banner.hidden && banner.layer.hidden && banner.layer.opacity == 0, @"banner must remain hidden");
        NSCAssert(banner.superview == parent && !parent.hidden && !sibling.hidden, @"must not remove banner or hide unrelated UI");
        sibling.hidden = NO;
        NSCAssert(!sibling.hidden, @"UIView inherited implementation must remain intact");
        // Swift runtime spelling must work independently of all legacy class hooks.
        Class nativeClass = objc_allocateClassPair([NSObject class], "_TtC8UnityAds18UADSInterstitialAd", 0);
        Class rewardedClass = objc_allocateClassPair([NSObject class], "_TtC8UnityAds14UADSRewardedAd", 0);
        SEL nativeShow = NSSelectorFromString(@"show:delegate:");
        class_addMethod(nativeClass, nativeShow, (IMP)OriginalNativeShow, "v@:@@");
        class_addMethod(rewardedClass, nativeShow, (IMP)OriginalNativeShow, "v@:@@");
        objc_registerClassPair(nativeClass);
        objc_registerClassPair(rewardedClass);
        ABInstallThirdPartyAdHooks();
        ABInstallThirdPartyAdHooks();
        id nativeAd = [nativeClass new];
        ShowDelegate *nativeDelegate = [ShowDelegate new];
        ((void (*)(id, SEL, id, id))objc_msgSend)(nativeAd, nativeShow, nil, nativeDelegate);
        NSCAssert(originalCalls == 0 && nativeDelegate.events.count == 0, @"native presentation blocked; callbacks deferred");
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        NSCAssert(([nativeDelegate.events isEqual:@[@"native-start", @"native-close"]] && nativeDelegate.nativeAd == nativeAd), @"one native start/close pair with the actual ad");
        ((void (*)(id, SEL, id, id))objc_msgSend)(nativeAd, nativeShow, nil, nil);
        ((void (*)(id, SEL, id, id))objc_msgSend)(nativeAd, nativeShow, nil, [NSObject new]);
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        NSCAssert(originalCalls == 0, @"nil/non-conforming delegates must not present");
        ((void (*)(id, SEL, id, id))objc_msgSend)([rewardedClass new], nativeShow, nil, nil);
        NSCAssert(originalCalls == 1, @"this fix must leave Swift rewarded presentation unchanged");
        NSLog(@"Unity Ads show tests passed");
    }
    return 0;
}
