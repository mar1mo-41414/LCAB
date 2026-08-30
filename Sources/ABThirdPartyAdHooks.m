#import "ABThirdPartyAdHooks.h"
#import "ABSwizzle.h"
#import "ABDebugLog.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - 汎用no-op実装

/// 呼ばれたクラス名・セレクタを診断ログに残す。self=インスタンスならそのクラス、
/// self=Class(クラスメソッド呼び出し)ならそのメタクラスの名前が取れる。
static void ABLogBlocked(id self, SEL _cmd) {
    ABDebugLog(@"[BLOCKED] %@ %@", NSStringFromClass(object_getClass(self)), NSStringFromSelector(_cmd));
}

/// 引数なしの表示トリガー(例: AppLovin MAInterstitialAd showAd, Chartboost show)をno-op化する。
static void AB_NoOp_Void(id self, SEL _cmd) {
    ABLogBlocked(self, _cmd);
}

/// 1引数(rootViewController等)の表示トリガーをno-op化する。
static void AB_NoOp_WithArg(id self, SEL _cmd, id arg) {
    ABLogBlocked(self, _cmd);
}

/// GADRewardedAdのpresentFromRootViewController:userDidEarnRewardHandler:用。
/// 広告を見ていないのに報酬を付与するとアプリの経済設計を歪めるため、handlerも呼ばない。
static void AB_NoOp_WithArgAndBlock(id self, SEL _cmd, id arg, id block) {
    ABLogBlocked(self, _cmd);
}

/// 2引数(placement, customData等の文字列)の表示トリガーをno-op化する。
static void AB_NoOp_WithArgArg(id self, SEL _cmd, id arg1, id arg2) {
    ABLogBlocked(self, _cmd);
}

/// (id, BOOL)の2引数(showAdFromRootViewController:animated:等)をno-op化する。
static void AB_NoOp_WithArgBool(id self, SEL _cmd, id arg, BOOL flag) {
    ABLogBlocked(self, _cmd);
}

/// 3引数(id, id, id)の表示トリガーをno-op化する。
static void AB_NoOp_WithArgArgArg(id self, SEL _cmd, id arg1, id arg2, id arg3) {
    ABLogBlocked(self, _cmd);
}

/// 4引数(id, id, id, id)の表示トリガー(レガシーUnityAds.show:placementId:options:showDelegate:等)を
/// no-op化する。
static void AB_NoOp_WithArgArgArgArg(id self, SEL _cmd, id arg1, id arg2, id arg3, id arg4) {
    ABLogBlocked(self, _cmd);
}

#pragma mark - バナー系(表示トリガーがなく、window追加時に自動的に見えるようになるもの)

/// バナーViewをwindowに追加させつつ即座に隠す。didMoveToWindow自体はSDKの内部状態管理を
/// 兼ねている可能性があるため元実装は呼び、見た目だけ潰す。
#define AB_DEFINE_HIDE_BANNER_HOOK(funcName, originalImpVar) \
    static IMP originalImpVar = NULL; \
    static void funcName(UIView *self, SEL _cmd) { \
        ABLogBlocked(self, _cmd); \
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
        ABDebugLog(@"[INSTALL] %@.didMoveToWindow -> NG (class not found)", className);
        return;
    }
    Method method = class_getInstanceMethod(cls, @selector(didMoveToWindow));
    if (!method) {
        ABDebugLog(@"[INSTALL] %@.didMoveToWindow -> NG (method not found)", className);
        return;
    }
    *originalImpOut = method_getImplementation(method);
    method_setImplementation(method, newImp);
    ABDebugLog(@"[INSTALL] %@.didMoveToWindow -> OK", className);
}

static void ABInstallHideBannerHookBySuffix(NSString *classNameSuffix, IMP newImp, IMP *originalImpOut) {
    Class cls = ABFindClassBySuffix(classNameSuffix);
    if (!cls) {
        ABDebugLog(@"[INSTALL] *%@.didMoveToWindow -> NG (class not found)", classNameSuffix);
        return;
    }
    Method method = class_getInstanceMethod(cls, @selector(didMoveToWindow));
    if (!method) {
        ABDebugLog(@"[INSTALL] %@.didMoveToWindow -> NG (method not found)", NSStringFromClass(cls));
        return;
    }
    *originalImpOut = method_getImplementation(method);
    method_setImplementation(method, newImp);
    ABDebugLog(@"[INSTALL] %@.didMoveToWindow -> OK (matched *%@)", NSStringFromClass(cls), classNameSuffix);
}

static void ABLogSwizzle(NSString *label, BOOL ok) {
    ABDebugLog(@"[INSTALL] %@ -> %@", label, ok ? @"OK" : @"NG");
}

#pragma mark - AppLovin MAX (MAInterstitialAd/MARewardedAd/MAAppOpenAdは同じshow系APIを共有)

static void ABInstallMAXFullscreenAdHooks(NSString *className) {
    ABLogSwizzle([NSString stringWithFormat:@"%@.showAd", className],
                 ABSwizzleInstanceMethod(className, NSSelectorFromString(@"showAd"), (IMP)AB_NoOp_Void));
    ABLogSwizzle([NSString stringWithFormat:@"%@.showAdForPlacement:", className],
                 ABSwizzleInstanceMethod(className, NSSelectorFromString(@"showAdForPlacement:"), (IMP)AB_NoOp_WithArg));
    ABLogSwizzle([NSString stringWithFormat:@"%@.showAdForPlacement:customData:", className],
                 ABSwizzleInstanceMethod(className, NSSelectorFromString(@"showAdForPlacement:customData:"), (IMP)AB_NoOp_WithArgArg));
}

#pragma mark - AdSurgeSDK (AppLovin MAXのカスタムメディエーションアダプタ経由、Tencent GDTベース。
#pragma mark   インタースティシャル/リワード/アプリ起動時オープン広告でプレイアブル広告クリエイティブを配信する)

static void ABInstallAdSurgeFullscreenAdHooks(NSString *className) {
    ABLogSwizzle([NSString stringWithFormat:@"%@.showAdFromRootViewController:", className],
                 ABSwizzleInstanceMethod(className, NSSelectorFromString(@"showAdFromRootViewController:"), (IMP)AB_NoOp_WithArg));
    ABLogSwizzle([NSString stringWithFormat:@"%@.showAdFromRootViewController:customData:", className],
                 ABSwizzleInstanceMethod(className, NSSelectorFromString(@"showAdFromRootViewController:customData:"), (IMP)AB_NoOp_WithArgArg));
}

#pragma mark - 診断: ロード済みの広告関連クラスを洗い出す

/// 実行時に登録されている全クラスのうち、広告SDKらしい名前(キーワードを含む)のものを
/// 診断ログに列挙する。「そもそもクラスが見つからずフックが失敗している」のか
/// 「クラス名の想定が間違っている」のかを切り分けるための保険。
static void ABLogSuspiciousAdClasses(void) {
    NSArray<NSString *> *keywords = @[@"Interstitial", @"Rewarded", @"UnityAds", @"UADS", @"Playable"];
    int bufferCount = objc_getClassList(NULL, 0);
    if (bufferCount <= 0) {
        return;
    }
    Class *classes = (Class *)malloc(sizeof(Class) * (unsigned long)bufferCount);
    if (!classes) {
        return;
    }
    // ABFindClassBySuffixと同じ理由で、実際にバッファへ書き込まれた数にクランプする。
    int actualCount = objc_getClassList(classes, bufferCount);
    int limit = actualCount < bufferCount ? actualCount : bufferCount;
    NSMutableArray<NSString *> *matched = [NSMutableArray array];
    for (int i = 0; i < limit; i++) {
        const char *cName = class_getName(classes[i]);
        if (!cName) {
            continue;
        }
        NSString *name = @(cName);
        for (NSString *keyword in keywords) {
            if ([name rangeOfString:keyword].location != NSNotFound) {
                [matched addObject:name];
                break;
            }
        }
    }
    free(classes);
    ABDebugLog(@"[SCAN] %lu ad-like classes found:", (unsigned long)matched.count);
    for (NSString *name in matched) {
        ABDebugLog(@"[SCAN]   %@", name);
    }
}

#pragma mark - Install

void ABInstallThirdPartyAdHooks(void) {
    // Google AdMob
    ABLogSwizzle(@"GADInterstitialAd.presentFromRootViewController:",
                 ABSwizzleInstanceMethod(@"GADInterstitialAd", @selector(presentFromRootViewController:), (IMP)AB_NoOp_WithArg));
    ABLogSwizzle(@"GADRewardedAd.presentFromRootViewController:userDidEarnRewardHandler:",
                 ABSwizzleInstanceMethod(@"GADRewardedAd", @selector(presentFromRootViewController:userDidEarnRewardHandler:), (IMP)AB_NoOp_WithArgAndBlock));
    ABInstallHideBannerHook(@"GADBannerView", (IMP)AB_GADBannerView_didMoveToWindow, &ABOriginalGADBannerViewDidMoveToWindowIMP);

    // Meta Audience Network
    ABLogSwizzle(@"FBInterstitialAd.showAdFromRootViewController:",
                 ABSwizzleInstanceMethod(@"FBInterstitialAd", @selector(showAdFromRootViewController:), (IMP)AB_NoOp_WithArg));
    ABLogSwizzle(@"FBRewardedVideoAd.showAdFromRootViewController:",
                 ABSwizzleInstanceMethod(@"FBRewardedVideoAd", NSSelectorFromString(@"showAdFromRootViewController:"), (IMP)AB_NoOp_WithArg));
    ABLogSwizzle(@"FBRewardedVideoAd.showAdFromRootViewController:animated:",
                 ABSwizzleInstanceMethod(@"FBRewardedVideoAd", NSSelectorFromString(@"showAdFromRootViewController:animated:"), (IMP)AB_NoOp_WithArgBool));
    ABInstallHideBannerHook(@"FBAdView", (IMP)AB_FBAdView_didMoveToWindow, &ABOriginalFBAdViewDidMoveToWindowIMP);

    // ironSource
    ABInstallHideBannerHook(@"ISBannerView", (IMP)AB_ISBannerView_didMoveToWindow, &ABOriginalISBannerViewDidMoveToWindowIMP);

    // AppLovin MAX: インタースティシャル・リワード・アプリ起動時オープン広告は同じshow系APIを共有
    ABInstallMAXFullscreenAdHooks(@"MAInterstitialAd");
    ABInstallMAXFullscreenAdHooks(@"MARewardedAd");
    ABInstallMAXFullscreenAdHooks(@"MAAppOpenAd");
    ABInstallHideBannerHook(@"MAAdView", (IMP)AB_MAAdView_didMoveToWindow, &ABOriginalMAAdViewDidMoveToWindowIMP);

    // Chartboost
    ABLogSwizzle(@"CHBInterstitial.showFromViewController:",
                 ABSwizzleInstanceMethod(@"CHBInterstitial", NSSelectorFromString(@"showFromViewController:"), (IMP)AB_NoOp_WithArg));
    ABLogSwizzle(@"CHBInterstitial.show",
                 ABSwizzleInstanceMethod(@"CHBInterstitial", NSSelectorFromString(@"show"), (IMP)AB_NoOp_Void));

    // InMobi: Swift実装のためObjective-Cランタイム上のクラス名は
    // `_TtC9InMobiSDK14IMInterstitial`のようにモジュール名を含む形にマングルされ、
    // SDKバージョンで変わりうるためサフィックス一致で解決する。
    ABLogSwizzle(@"*IMInterstitial.showFrom:",
                 ABSwizzleInstanceMethodBySuffix(@"IMInterstitial", NSSelectorFromString(@"showFrom:"), (IMP)AB_NoOp_WithArg));
    ABInstallHideBannerHookBySuffix(@"IMBanner", (IMP)AB_IMBanner_didMoveToWindow, &ABOriginalIMBannerDidMoveToWindowIMP);

    // AdSurgeSDK (AppLovin MAXのカスタムメディエーションネットワーク、Tencent GDTベース)
    ABInstallAdSurgeFullscreenAdHooks(@"AdSurgeInterstitialAd");
    ABInstallAdSurgeFullscreenAdHooks(@"AdSurgeRewardedAd");
    ABInstallAdSurgeFullscreenAdHooks(@"AdSurgeAppOpenAd");
    ABInstallHideBannerHook(@"AdSurgeBannerAdView", (IMP)AB_AdSurgeBannerAdView_didMoveToWindow, &ABOriginalAdSurgeBannerAdViewDidMoveToWindowIMP);

    // MolocoSDK: インタースティシャル/リワード共用の実体クラスPublisherFullscreenAdは
    // NSObjectを継承したSwiftクラス。ランタイム上の名前はSDKバージョンで
    // マングルされうるためサフィックス一致で解決する。
    ABLogSwizzle(@"*PublisherFullscreenAd.showFrom:",
                 ABSwizzleInstanceMethodBySuffix(@"PublisherFullscreenAd", NSSelectorFromString(@"showFrom:"), (IMP)AB_NoOp_WithArg));
    ABLogSwizzle(@"*PublisherFullscreenAd.showFrom:muted:",
                 ABSwizzleInstanceMethodBySuffix(@"PublisherFullscreenAd", NSSelectorFromString(@"showFrom:muted:"), (IMP)AB_NoOp_WithArgBool));
    ABInstallHideBannerHook(@"MolocoBannerAdView", (IMP)AB_MolocoBannerAdView_didMoveToWindow, &ABOriginalMolocoBannerAdViewDidMoveToWindowIMP);

    // Unity Ads本体(SDK 4.x系の新API)。UADSInterstitialAd/UADSRewardedAd/UADSBannerViewは
    // "UADS"プレフィックスでObjective-Cブリッジされたクラスで、実際の表示エントリポイント。
    // AppLovin MAXのALUnityAdsMediationAdapter経由でも、結局この2クラスのshow:delegate:が呼ばれる。
    ABLogSwizzle(@"UADSInterstitialAd.show:delegate:",
                 ABSwizzleInstanceMethod(@"UADSInterstitialAd", NSSelectorFromString(@"show:delegate:"), (IMP)AB_NoOp_WithArgArg));
    ABLogSwizzle(@"UADSRewardedAd.show:delegate:",
                 ABSwizzleInstanceMethod(@"UADSRewardedAd", NSSelectorFromString(@"show:delegate:"), (IMP)AB_NoOp_WithArgArg));
    ABInstallHideBannerHook(@"UADSBannerView", (IMP)AB_UADSBannerView_didMoveToWindow, &ABOriginalUADSBannerViewDidMoveToWindowIMP);

    // Unity Ads本体のレガシー静的API。`+[UnityAds show:placementId:options:]` /
    // `+[UnityAds show:placementId:options:showDelegate:]`というクラスメソッド(インスタンスではない)。
    // UnityAdsクラス自体はSwift実装のためランタイム上の名前がSDKバージョンでマングルされうる
    // (実測値: `_TtC8UnityAds8UnityAds`)ためサフィックス一致で解決する。
    ABLogSwizzle(@"*UnityAds(class).show:placementId:options:",
                 ABSwizzleClassMethodBySuffix(@"UnityAds", NSSelectorFromString(@"show:placementId:options:"), (IMP)AB_NoOp_WithArgArgArg));
    ABLogSwizzle(@"*UnityAds(class).show:placementId:options:showDelegate:",
                 ABSwizzleClassMethodBySuffix(@"UnityAds", NSSelectorFromString(@"show:placementId:options:showDelegate:"), (IMP)AB_NoOp_WithArgArgArgArg));

    // 診断: 広告関連クラスの登録状況をログに残す(dylibロード直後時点のスナップショット)
    ABLogSuspiciousAdClasses();
}
