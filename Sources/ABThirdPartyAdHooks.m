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

/// 2引数(placement, customData等の文字列)の表示トリガーをno-op化する。
static void AB_NoOp_WithArgArg(id self, SEL _cmd, id arg1, id arg2) {
    // no-op
}

/// (id, BOOL)の2引数(showAdFromRootViewController:animated:等)をno-op化する。
static void AB_NoOp_WithArgBool(id self, SEL _cmd, id arg, BOOL flag) {
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
AB_DEFINE_HIDE_BANNER_HOOK(AB_MAAdView_didMoveToWindow, ABOriginalMAAdViewDidMoveToWindowIMP)
AB_DEFINE_HIDE_BANNER_HOOK(AB_IMBanner_didMoveToWindow, ABOriginalIMBannerDidMoveToWindowIMP)
AB_DEFINE_HIDE_BANNER_HOOK(AB_AdSurgeBannerAdView_didMoveToWindow, ABOriginalAdSurgeBannerAdViewDidMoveToWindowIMP)
AB_DEFINE_HIDE_BANNER_HOOK(AB_MolocoBannerAdView_didMoveToWindow, ABOriginalMolocoBannerAdViewDidMoveToWindowIMP)
AB_DEFINE_HIDE_BANNER_HOOK(AB_UADSBannerView_didMoveToWindow, ABOriginalUADSBannerViewDidMoveToWindowIMP)

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

static void ABInstallHideBannerHookBySuffix(NSString *classNameSuffix, IMP newImp, IMP *originalImpOut) {
    Class cls = ABFindClassBySuffix(classNameSuffix);
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

#pragma mark - AppLovin MAX (MAInterstitialAd/MARewardedAd/MAAppOpenAdは同じshow系APIを共有)

static void ABInstallMAXFullscreenAdHooks(NSString *className) {
    ABSwizzleInstanceMethod(className, NSSelectorFromString(@"showAd"), (IMP)AB_NoOp_Void);
    ABSwizzleInstanceMethod(className, NSSelectorFromString(@"showAdForPlacement:"), (IMP)AB_NoOp_WithArg);
    ABSwizzleInstanceMethod(className, NSSelectorFromString(@"showAdForPlacement:customData:"), (IMP)AB_NoOp_WithArgArg);
}

#pragma mark - AdSurgeSDK (AppLovin MAXのカスタムメディエーションアダプタ経由、Tencent GDTベース。
#pragma mark   インタースティシャル/リワード/アプリ起動時オープン広告でプレイアブル広告クリエイティブを配信する)

static void ABInstallAdSurgeFullscreenAdHooks(NSString *className) {
    ABSwizzleInstanceMethod(className, NSSelectorFromString(@"showAdFromRootViewController:"), (IMP)AB_NoOp_WithArg);
    ABSwizzleInstanceMethod(className, NSSelectorFromString(@"showAdFromRootViewController:customData:"), (IMP)AB_NoOp_WithArgArg);
}

#pragma mark - Install

void ABInstallThirdPartyAdHooks(void) {
    // Google AdMob
    ABSwizzleInstanceMethod(@"GADInterstitialAd", @selector(presentFromRootViewController:), (IMP)AB_NoOp_WithArg);
    ABSwizzleInstanceMethod(@"GADRewardedAd", @selector(presentFromRootViewController:userDidEarnRewardHandler:), (IMP)AB_NoOp_WithArgAndBlock);
    ABInstallHideBannerHook(@"GADBannerView", (IMP)AB_GADBannerView_didMoveToWindow, &ABOriginalGADBannerViewDidMoveToWindowIMP);

    // Meta Audience Network
    ABSwizzleInstanceMethod(@"FBInterstitialAd", @selector(showAdFromRootViewController:), (IMP)AB_NoOp_WithArg);
    ABSwizzleInstanceMethod(@"FBRewardedVideoAd", NSSelectorFromString(@"showAdFromRootViewController:"), (IMP)AB_NoOp_WithArg);
    ABSwizzleInstanceMethod(@"FBRewardedVideoAd", NSSelectorFromString(@"showAdFromRootViewController:animated:"), (IMP)AB_NoOp_WithArgBool);
    ABInstallHideBannerHook(@"FBAdView", (IMP)AB_FBAdView_didMoveToWindow, &ABOriginalFBAdViewDidMoveToWindowIMP);

    // ironSource
    ABInstallHideBannerHook(@"ISBannerView", (IMP)AB_ISBannerView_didMoveToWindow, &ABOriginalISBannerViewDidMoveToWindowIMP);

    // AppLovin MAX: インタースティシャル・リワード・アプリ起動時オープン広告は同じshow系APIを共有
    ABInstallMAXFullscreenAdHooks(@"MAInterstitialAd");
    ABInstallMAXFullscreenAdHooks(@"MARewardedAd");
    ABInstallMAXFullscreenAdHooks(@"MAAppOpenAd");
    ABInstallHideBannerHook(@"MAAdView", (IMP)AB_MAAdView_didMoveToWindow, &ABOriginalMAAdViewDidMoveToWindowIMP);

    // Chartboost
    ABSwizzleInstanceMethod(@"CHBInterstitial", NSSelectorFromString(@"showFromViewController:"), (IMP)AB_NoOp_WithArg);
    ABSwizzleInstanceMethod(@"CHBInterstitial", NSSelectorFromString(@"show"), (IMP)AB_NoOp_Void);

    // InMobi: Swift実装のためObjective-Cランタイム上のクラス名は
    // `_TtC9InMobiSDK14IMInterstitial`のようにモジュール名を含む形にマングルされ、
    // SDKバージョンで変わりうるためサフィックス一致で解決する。
    ABSwizzleInstanceMethodBySuffix(@"IMInterstitial", NSSelectorFromString(@"showFrom:"), (IMP)AB_NoOp_WithArg);
    ABInstallHideBannerHookBySuffix(@"IMBanner", (IMP)AB_IMBanner_didMoveToWindow, &ABOriginalIMBannerDidMoveToWindowIMP);

    // AdSurgeSDK (AppLovin MAXのカスタムメディエーションネットワーク、Tencent GDTベース)
    ABInstallAdSurgeFullscreenAdHooks(@"AdSurgeInterstitialAd");
    ABInstallAdSurgeFullscreenAdHooks(@"AdSurgeRewardedAd");
    ABInstallAdSurgeFullscreenAdHooks(@"AdSurgeAppOpenAd");
    ABInstallHideBannerHook(@"AdSurgeBannerAdView", (IMP)AB_AdSurgeBannerAdView_didMoveToWindow, &ABOriginalAdSurgeBannerAdViewDidMoveToWindowIMP);

    // MolocoSDK: インタースティシャル/リワード共用の実体クラスPublisherFullscreenAdは
    // NSObjectを継承したSwiftクラス。ランタイム上の名前はSDKバージョンで
    // マングルされうるためサフィックス一致で解決する。
    ABSwizzleInstanceMethodBySuffix(@"PublisherFullscreenAd", NSSelectorFromString(@"showFrom:"), (IMP)AB_NoOp_WithArg);
    ABSwizzleInstanceMethodBySuffix(@"PublisherFullscreenAd", NSSelectorFromString(@"showFrom:muted:"), (IMP)AB_NoOp_WithArgBool);
    ABInstallHideBannerHook(@"MolocoBannerAdView", (IMP)AB_MolocoBannerAdView_didMoveToWindow, &ABOriginalMolocoBannerAdViewDidMoveToWindowIMP);

    // Unity Ads本体(SDK 4.x系の新API)。UADSInterstitialAd/UADSRewardedAd/UADSBannerViewは
    // "UADS"プレフィックスでObjective-Cブリッジされたクラスで、旧来のUnityAds/UADSInterstitialAd
    // (Logosの%hookが効かないSwift実装)とは別に存在する実際の表示エントリポイント。
    // AppLovin MAXのALUnityAdsMediationAdapter経由でも、結局この2クラスのshow:delegate:が呼ばれる。
    ABSwizzleInstanceMethod(@"UADSInterstitialAd", NSSelectorFromString(@"show:delegate:"), (IMP)AB_NoOp_WithArgArg);
    ABSwizzleInstanceMethod(@"UADSRewardedAd", NSSelectorFromString(@"show:delegate:"), (IMP)AB_NoOp_WithArgArg);
    ABInstallHideBannerHook(@"UADSBannerView", (IMP)AB_UADSBannerView_didMoveToWindow, &ABOriginalUADSBannerViewDidMoveToWindowIMP);
}
