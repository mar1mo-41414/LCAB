#import "ABThirdPartyAdHooks.h"
#import "ABSwizzle.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - 汎用no-op実装

/// 引数なしの表示トリガー(例: AppLovin MAInterstitialAd showAd, Chartboost show)をno-op化する。
static void AB_NoOp_Void(id self, SEL _cmd) {
    // no-op
}

/// 1引数(rootViewController等)の表示トリガーをno-op化する。
static void AB_NoOp_WithArg(id self, SEL _cmd, id arg) {
    // no-op
}

/// GADRewardedAdのpresentFromRootViewController:userDidEarnRewardHandler:用。
/// 広告を見ていないのに報酬を付与するとアプリの経済設計を歪めるため、handlerも呼ばない。
static void AB_NoOp_WithArgAndBlock(id self, SEL _cmd, id arg, id block) {
    // no-op
}

#pragma mark - バナー系(表示トリガーがなく、window追加時に自動的に見えるようになるもの)

/// バナーViewをwindowに追加させつつ即座に隠す。didMoveToWindow自体はSDKの内部状態管理を
/// 兼ねている可能性があるため元実装は呼び、見た目だけ潰す。
#define AB_DEFINE_HIDE_BANNER_HOOK(funcName, originalImpVar) \
    static IMP originalImpVar = NULL; \
    static void funcName(UIView *self, SEL _cmd) { \
        if (originalImpVar) { \
            ((void (*)(id, SEL))originalImpVar)(self, _cmd); \
        } \
        self.hidden = YES; \
        self.frame = CGRectZero; \
    }

AB_DEFINE_HIDE_BANNER_HOOK(AB_GADBannerView_didMoveToWindow, ABOriginalGADBannerViewDidMoveToWindowIMP)
AB_DEFINE_HIDE_BANNER_HOOK(AB_FBAdView_didMoveToWindow, ABOriginalFBAdViewDidMoveToWindowIMP)
AB_DEFINE_HIDE_BANNER_HOOK(AB_ISBannerView_didMoveToWindow, ABOriginalISBannerViewDidMoveToWindowIMP)

static void ABInstallHideBannerHook(NSString *className, IMP newImp, IMP *originalImpOut) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        return;
    }
    Method method = class_getInstanceMethod(cls, @selector(didMoveToWindow));
    if (!method) {
        return;
    }
    *originalImpOut = method_getImplementation(method);
    method_setImplementation(method, newImp);
}

#pragma mark - Install

void ABInstallThirdPartyAdHooks(void) {
    // Google AdMob
    ABSwizzleInstanceMethod(@"GADInterstitialAd", @selector(presentFromRootViewController:), (IMP)AB_NoOp_WithArg);
    ABSwizzleInstanceMethod(@"GADRewardedAd", @selector(presentFromRootViewController:userDidEarnRewardHandler:), (IMP)AB_NoOp_WithArgAndBlock);
    ABInstallHideBannerHook(@"GADBannerView", (IMP)AB_GADBannerView_didMoveToWindow, &ABOriginalGADBannerViewDidMoveToWindowIMP);

    // Meta Audience Network
    ABSwizzleInstanceMethod(@"FBInterstitialAd", @selector(showAdFromRootViewController:), (IMP)AB_NoOp_WithArg);
    ABInstallHideBannerHook(@"FBAdView", (IMP)AB_FBAdView_didMoveToWindow, &ABOriginalFBAdViewDidMoveToWindowIMP);

    // ironSource
    ABInstallHideBannerHook(@"ISBannerView", (IMP)AB_ISBannerView_didMoveToWindow, &ABOriginalISBannerViewDidMoveToWindowIMP);

    // AppLovin MAX (バージョンによりセレクタが異なるため候補を複数試す)
    ABSwizzleInstanceMethod(@"MAInterstitialAd", NSSelectorFromString(@"showAd"), (IMP)AB_NoOp_Void);
    ABSwizzleInstanceMethod(@"MAInterstitialAd", NSSelectorFromString(@"showAdForPlacement:"), (IMP)AB_NoOp_WithArg);

    // Chartboost
    ABSwizzleInstanceMethod(@"CHBInterstitial", NSSelectorFromString(@"showFromViewController:"), (IMP)AB_NoOp_WithArg);
    ABSwizzleInstanceMethod(@"CHBInterstitial", NSSelectorFromString(@"show"), (IMP)AB_NoOp_Void);
}
