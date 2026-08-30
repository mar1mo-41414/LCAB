#import "ABThirdPartyAdHooks.h"
#import "ABSwizzle.h"
#import "ABDebugLog.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - Objective-C型エンコーディング(全て "v@:" + 引数の並び。voidメソッドのみ扱う)

static const char *const kTypesVoid = "v@:";
static const char *const kTypesArg = "v@:@";
static const char *const kTypesArgArg = "v@:@@";
static const char *const kTypesArgBool = "v@:@B";
static const char *const kTypesArgArgArg = "v@:@@@";
static const char *const kTypesArgArgArgArg = "v@:@@@@";

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

/// 2引数(placement, customData等の文字列)の表示トリガーをno-op化する。
static void AB_NoOp_WithArgArg(id self, SEL _cmd, id arg1, id arg2) {
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

#pragma mark - リワード付与ヘルパー(広告を見た体でSDKに結果を通知し、ゲーム側の続行を可能にする)
#pragma mark   ユーザー自身が遊ぶための広告ブロッカーであり、広告を見ずに機能を使えることが目的のため、
#pragma mark   報酬は成功扱いにする(不正な第三者への報酬付与ではなく、自分自身の環境のみに閉じる)。

/// self.delegateを安全に取得する(delegateの型はSDKごとに異なるため素朴にrespondsToSelector:で
/// チェックしてから呼ぶ)。
static id ABGetDelegate(id self) {
    if (![self respondsToSelector:@selector(delegate)]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(self, @selector(delegate));
}

/// 1引数のdelegateコールバックを、存在すれば呼ぶ。引数はnil(Objective-Cのnilへのメッセージ送信は
/// プロパティアクセス程度なら安全にゼロ値を返すため、型不一致のオブジェクトを渡うより安全)。
static void ABCallDelegate1(id delegate, SEL sel, id arg) {
    if (delegate && [delegate respondsToSelector:sel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(delegate, sel, arg);
    }
}

/// 2引数のdelegateコールバックを、存在すれば呼ぶ。
static void ABCallDelegate2(id delegate, SEL sel, id arg1, id arg2) {
    if (delegate && [delegate respondsToSelector:sel]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, sel, arg1, arg2);
    }
}

/// AppLovin MAX系(MAAdDelegate/MARewardedAdDelegate)。表示成功→(報酬)→非表示を順に通知する。
static void ABNotifyMAXDelegate(id self, BOOL grantReward) {
    id delegate = ABGetDelegate(self);
    ABCallDelegate1(delegate, NSSelectorFromString(@"didDisplayAd:"), nil);
    if (grantReward) {
        ABCallDelegate2(delegate, NSSelectorFromString(@"didRewardUserForAd:withReward:"), nil, nil);
    }
    ABCallDelegate1(delegate, NSSelectorFromString(@"didHideAd:"), nil);
}

static void AB_MAX_ShowAd_Reward(id self, SEL _cmd) {
    ABLogBlocked(self, _cmd);
    ABNotifyMAXDelegate(self, YES);
}
static void AB_MAX_ShowAdForPlacement_Reward(id self, SEL _cmd, id placement) {
    ABLogBlocked(self, _cmd);
    ABNotifyMAXDelegate(self, YES);
}
static void AB_MAX_ShowAdForPlacementCustomData_Reward(id self, SEL _cmd, id placement, id customData) {
    ABLogBlocked(self, _cmd);
    ABNotifyMAXDelegate(self, YES);
}
static void AB_MAX_ShowAd_NoReward(id self, SEL _cmd) {
    ABLogBlocked(self, _cmd);
    ABNotifyMAXDelegate(self, NO);
}
static void AB_MAX_ShowAdForPlacement_NoReward(id self, SEL _cmd, id placement) {
    ABLogBlocked(self, _cmd);
    ABNotifyMAXDelegate(self, NO);
}
static void AB_MAX_ShowAdForPlacementCustomData_NoReward(id self, SEL _cmd, id placement, id customData) {
    ABLogBlocked(self, _cmd);
    ABNotifyMAXDelegate(self, NO);
}

/// Google AdMob GADRewardedAd。ブロックを直接引数で受け取るのでdelegate探索は不要、
/// handler(呼べば報酬付与)をそのまま呼ぶだけでよい。
static void AB_GADRewardedAd_present(id self, SEL _cmd, id viewController, void (^handler)(void)) {
    ABLogBlocked(self, _cmd);
    if (handler) {
        handler();
    }
}

/// Meta Audience Network FBRewardedVideoAd。
static void ABNotifyFBRewardDelegate(id self) {
    id delegate = ABGetDelegate(self);
    ABCallDelegate1(delegate, NSSelectorFromString(@"rewardedVideoAdVideoComplete:"), nil);
    ABCallDelegate1(delegate, NSSelectorFromString(@"rewardedVideoAdDidClose:"), nil);
}
static void AB_FBRewardedVideoAd_showAdFromRootViewController(id self, SEL _cmd, id vc) {
    ABLogBlocked(self, _cmd);
    ABNotifyFBRewardDelegate(self);
}
static void AB_FBRewardedVideoAd_showAdFromRootViewController_animated(id self, SEL _cmd, id vc, BOOL animated) {
    ABLogBlocked(self, _cmd);
    ABNotifyFBRewardDelegate(self);
}

/// Unity Ads本体(UADSRewardedAd)。show:delegate:の第2引数にそのままdelegateが渡ってくるので、
/// self.delegateを探す必要はない。プロトコルの正確なメソッド名は確証が薄いため、
/// 名前の異なりうる複数候補を試すベストエフォート実装。
static void AB_UADSRewardedAd_show_delegate(id self, SEL _cmd, id viewController, id delegate) {
    ABLogBlocked(self, _cmd);
    ABCallDelegate1(delegate, NSSelectorFromString(@"unityAdsShowComplete:"), nil);
    ABCallDelegate2(delegate, NSSelectorFromString(@"unityAdsShowComplete:withFinishState:"), nil, nil);
    ABCallDelegate1(delegate, NSSelectorFromString(@"unityAdsShowStart:"), nil);
}

/// MolocoSDK PublisherFullscreenAd。rewardedDelegate/interstitialDelegateのivarを直接読む。
/// プロトコルの正確なメソッド名は確証が薄いため、名前の異なりうる複数候補を試す。
static void ABNotifyMolocoDelegate(id self) {
    id rewardedDelegate = nil;
    if ([self respondsToSelector:@selector(rewardedDelegate)]) {
        rewardedDelegate = ((id (*)(id, SEL))objc_msgSend)(self, @selector(rewardedDelegate));
    }
    id interstitialDelegate = nil;
    if ([self respondsToSelector:@selector(interstitialDelegate)]) {
        interstitialDelegate = ((id (*)(id, SEL))objc_msgSend)(self, @selector(interstitialDelegate));
    }
    ABCallDelegate1(rewardedDelegate, NSSelectorFromString(@"didRewardUser:"), nil);
    ABCallDelegate1(rewardedDelegate, NSSelectorFromString(@"didHide:"), nil);
    ABCallDelegate1(interstitialDelegate, NSSelectorFromString(@"didHide:"), nil);
}
static void AB_Moloco_showFrom(id self, SEL _cmd, id vc) {
    ABLogBlocked(self, _cmd);
    ABNotifyMolocoDelegate(self);
}
static void AB_Moloco_showFrom_muted(id self, SEL _cmd, id vc, BOOL muted) {
    ABLogBlocked(self, _cmd);
    ABNotifyMolocoDelegate(self);
}

/// AdSurgeSDK。プロトコルの正確なメソッド名は確証が薄いため、AppLovin MAXと同様の
/// MAAdDelegate風の命名パターンを想定してベストエフォートで試す。
static void ABNotifyAdSurgeDelegate(id self, BOOL grantReward) {
    id delegate = ABGetDelegate(self);
    ABCallDelegate1(delegate, NSSelectorFromString(@"didDisplayAd:"), nil);
    if (grantReward) {
        ABCallDelegate2(delegate, NSSelectorFromString(@"didRewardUserForAd:withReward:"), nil, nil);
    }
    ABCallDelegate1(delegate, NSSelectorFromString(@"didHideAd:"), nil);
}
static void AB_AdSurge_showAdFromRootViewController_Reward(id self, SEL _cmd, id vc) {
    ABLogBlocked(self, _cmd);
    ABNotifyAdSurgeDelegate(self, YES);
}
static void AB_AdSurge_showAdFromRootViewController_customData_Reward(id self, SEL _cmd, id vc, id customData) {
    ABLogBlocked(self, _cmd);
    ABNotifyAdSurgeDelegate(self, YES);
}
static void AB_AdSurge_showAdFromRootViewController_NoReward(id self, SEL _cmd, id vc) {
    ABLogBlocked(self, _cmd);
    ABNotifyAdSurgeDelegate(self, NO);
}
static void AB_AdSurge_showAdFromRootViewController_customData_NoReward(id self, SEL _cmd, id vc, id customData) {
    ABLogBlocked(self, _cmd);
    ABNotifyAdSurgeDelegate(self, NO);
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

/// 対象クラス自身がdidMoveToWindowをオーバーライドしていない場合でも、継承元(UIViewなど)を
/// 巻き込まずそのクラス専用の実装として安全に差し込む(ABSwizzleInstanceMethodKeepingOriginal参照)。
static void ABInstallHideBannerHook(NSString *className, IMP newImp, IMP *originalImpOut) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        ABDebugLog(@"[INSTALL] %@.didMoveToWindow -> NG (class not found)", className);
        return;
    }
    BOOL ok = ABSwizzleInstanceMethodKeepingOriginal(cls, @selector(didMoveToWindow), newImp, kTypesVoid, originalImpOut);
    ABDebugLog(@"[INSTALL] %@.didMoveToWindow -> %@", className, ok ? @"OK" : @"NG (method not found)");
}

static void ABInstallHideBannerHookBySuffix(NSString *classNameSuffix, IMP newImp, IMP *originalImpOut) {
    Class cls = ABFindClassBySuffix(classNameSuffix);
    if (!cls) {
        ABDebugLog(@"[INSTALL] *%@.didMoveToWindow -> NG (class not found)", classNameSuffix);
        return;
    }
    BOOL ok = ABSwizzleInstanceMethodKeepingOriginal(cls, @selector(didMoveToWindow), newImp, kTypesVoid, originalImpOut);
    ABDebugLog(@"[INSTALL] %@.didMoveToWindow -> %@ (matched *%@)", NSStringFromClass(cls), ok ? @"OK" : @"NG (method not found)", classNameSuffix);
}

static void ABLogSwizzle(NSString *label, BOOL ok) {
    ABDebugLog(@"[INSTALL] %@ -> %@", label, ok ? @"OK" : @"NG");
}

#pragma mark - AppLovin MAX (MAInterstitialAd/MARewardedAd/MAAppOpenAdは同じshow系APIを共有)

static void ABInstallMAXFullscreenAdHooks(NSString *className, BOOL grantReward) {
    IMP showAdImp = grantReward ? (IMP)AB_MAX_ShowAd_Reward : (IMP)AB_MAX_ShowAd_NoReward;
    IMP showAdForPlacementImp = grantReward ? (IMP)AB_MAX_ShowAdForPlacement_Reward : (IMP)AB_MAX_ShowAdForPlacement_NoReward;
    IMP showAdForPlacementCustomDataImp = grantReward ? (IMP)AB_MAX_ShowAdForPlacementCustomData_Reward : (IMP)AB_MAX_ShowAdForPlacementCustomData_NoReward;
    ABLogSwizzle([NSString stringWithFormat:@"%@.showAd", className],
                 ABSwizzleInstanceMethod(className, NSSelectorFromString(@"showAd"), showAdImp, kTypesVoid));
    ABLogSwizzle([NSString stringWithFormat:@"%@.showAdForPlacement:", className],
                 ABSwizzleInstanceMethod(className, NSSelectorFromString(@"showAdForPlacement:"), showAdForPlacementImp, kTypesArg));
    ABLogSwizzle([NSString stringWithFormat:@"%@.showAdForPlacement:customData:", className],
                 ABSwizzleInstanceMethod(className, NSSelectorFromString(@"showAdForPlacement:customData:"), showAdForPlacementCustomDataImp, kTypesArgArg));
}

#pragma mark - AdSurgeSDK (AppLovin MAXのカスタムメディエーションアダプタ経由、Tencent GDTベース。
#pragma mark   インタースティシャル/リワード/アプリ起動時オープン広告でプレイアブル広告クリエイティブを配信する)

static void ABInstallAdSurgeFullscreenAdHooks(NSString *className, BOOL grantReward) {
    IMP showImp = grantReward ? (IMP)AB_AdSurge_showAdFromRootViewController_Reward : (IMP)AB_AdSurge_showAdFromRootViewController_NoReward;
    IMP showCustomDataImp = grantReward ? (IMP)AB_AdSurge_showAdFromRootViewController_customData_Reward : (IMP)AB_AdSurge_showAdFromRootViewController_customData_NoReward;
    ABLogSwizzle([NSString stringWithFormat:@"%@.showAdFromRootViewController:", className],
                 ABSwizzleInstanceMethod(className, NSSelectorFromString(@"showAdFromRootViewController:"), showImp, kTypesArg));
    ABLogSwizzle([NSString stringWithFormat:@"%@.showAdFromRootViewController:customData:", className],
                 ABSwizzleInstanceMethod(className, NSSelectorFromString(@"showAdFromRootViewController:customData:"), showCustomDataImp, kTypesArgArg));
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
                 ABSwizzleInstanceMethod(@"GADInterstitialAd", @selector(presentFromRootViewController:), (IMP)AB_NoOp_WithArg, kTypesArg));
    ABLogSwizzle(@"GADRewardedAd.presentFromRootViewController:userDidEarnRewardHandler:",
                 ABSwizzleInstanceMethod(@"GADRewardedAd", @selector(presentFromRootViewController:userDidEarnRewardHandler:), (IMP)AB_GADRewardedAd_present, kTypesArgArg));
    ABInstallHideBannerHook(@"GADBannerView", (IMP)AB_GADBannerView_didMoveToWindow, &ABOriginalGADBannerViewDidMoveToWindowIMP);

    // Meta Audience Network
    ABLogSwizzle(@"FBInterstitialAd.showAdFromRootViewController:",
                 ABSwizzleInstanceMethod(@"FBInterstitialAd", @selector(showAdFromRootViewController:), (IMP)AB_NoOp_WithArg, kTypesArg));
    ABLogSwizzle(@"FBRewardedVideoAd.showAdFromRootViewController:",
                 ABSwizzleInstanceMethod(@"FBRewardedVideoAd", NSSelectorFromString(@"showAdFromRootViewController:"), (IMP)AB_FBRewardedVideoAd_showAdFromRootViewController, kTypesArg));
    ABLogSwizzle(@"FBRewardedVideoAd.showAdFromRootViewController:animated:",
                 ABSwizzleInstanceMethod(@"FBRewardedVideoAd", NSSelectorFromString(@"showAdFromRootViewController:animated:"), (IMP)AB_FBRewardedVideoAd_showAdFromRootViewController_animated, kTypesArgBool));
    ABInstallHideBannerHook(@"FBAdView", (IMP)AB_FBAdView_didMoveToWindow, &ABOriginalFBAdViewDidMoveToWindowIMP);

    // ironSource
    ABInstallHideBannerHook(@"ISBannerView", (IMP)AB_ISBannerView_didMoveToWindow, &ABOriginalISBannerViewDidMoveToWindowIMP);

    // AppLovin MAX: インタースティシャル・リワード・アプリ起動時オープン広告は同じshow系APIを共有
    ABInstallMAXFullscreenAdHooks(@"MAInterstitialAd", NO);
    ABInstallMAXFullscreenAdHooks(@"MARewardedAd", YES);
    ABInstallMAXFullscreenAdHooks(@"MAAppOpenAd", NO);
    ABInstallHideBannerHook(@"MAAdView", (IMP)AB_MAAdView_didMoveToWindow, &ABOriginalMAAdViewDidMoveToWindowIMP);

    // Chartboost
    ABLogSwizzle(@"CHBInterstitial.showFromViewController:",
                 ABSwizzleInstanceMethod(@"CHBInterstitial", NSSelectorFromString(@"showFromViewController:"), (IMP)AB_NoOp_WithArg, kTypesArg));
    ABLogSwizzle(@"CHBInterstitial.show",
                 ABSwizzleInstanceMethod(@"CHBInterstitial", NSSelectorFromString(@"show"), (IMP)AB_NoOp_Void, kTypesVoid));

    // InMobi: Swift実装のためObjective-Cランタイム上のクラス名は
    // `_TtC9InMobiSDK14IMInterstitial`のようにモジュール名を含む形にマングルされ、
    // SDKバージョンで変わりうるためサフィックス一致で解決する。
    ABLogSwizzle(@"*IMInterstitial.showFrom:",
                 ABSwizzleInstanceMethodBySuffix(@"IMInterstitial", NSSelectorFromString(@"showFrom:"), (IMP)AB_NoOp_WithArg, kTypesArg));
    ABInstallHideBannerHookBySuffix(@"IMBanner", (IMP)AB_IMBanner_didMoveToWindow, &ABOriginalIMBannerDidMoveToWindowIMP);

    // AdSurgeSDK (AppLovin MAXのカスタムメディエーションネットワーク、Tencent GDTベース)
    ABInstallAdSurgeFullscreenAdHooks(@"AdSurgeInterstitialAd", NO);
    ABInstallAdSurgeFullscreenAdHooks(@"AdSurgeRewardedAd", YES);
    ABInstallAdSurgeFullscreenAdHooks(@"AdSurgeAppOpenAd", NO);
    ABInstallHideBannerHook(@"AdSurgeBannerAdView", (IMP)AB_AdSurgeBannerAdView_didMoveToWindow, &ABOriginalAdSurgeBannerAdViewDidMoveToWindowIMP);

    // MolocoSDK: インタースティシャル/リワード共用の実体クラスPublisherFullscreenAdは
    // NSObjectを継承したSwiftクラス。ランタイム上の名前はSDKバージョンで
    // マングルされうるためサフィックス一致で解決する。
    ABLogSwizzle(@"*PublisherFullscreenAd.showFrom:",
                 ABSwizzleInstanceMethodBySuffix(@"PublisherFullscreenAd", NSSelectorFromString(@"showFrom:"), (IMP)AB_Moloco_showFrom, kTypesArg));
    ABLogSwizzle(@"*PublisherFullscreenAd.showFrom:muted:",
                 ABSwizzleInstanceMethodBySuffix(@"PublisherFullscreenAd", NSSelectorFromString(@"showFrom:muted:"), (IMP)AB_Moloco_showFrom_muted, kTypesArgBool));
    ABInstallHideBannerHook(@"MolocoBannerAdView", (IMP)AB_MolocoBannerAdView_didMoveToWindow, &ABOriginalMolocoBannerAdViewDidMoveToWindowIMP);

    // Unity Ads本体(SDK 4.x系の新API)。UADSInterstitialAd/UADSRewardedAd/UADSBannerViewは
    // "UADS"プレフィックスでObjective-Cブリッジされたクラスで、実際の表示エントリポイント。
    // AppLovin MAXのALUnityAdsMediationAdapter経由でも、結局この2クラスのshow:delegate:が呼ばれる。
    ABLogSwizzle(@"UADSInterstitialAd.show:delegate:",
                 ABSwizzleInstanceMethod(@"UADSInterstitialAd", NSSelectorFromString(@"show:delegate:"), (IMP)AB_NoOp_WithArgArg, kTypesArgArg));
    ABLogSwizzle(@"UADSRewardedAd.show:delegate:",
                 ABSwizzleInstanceMethod(@"UADSRewardedAd", NSSelectorFromString(@"show:delegate:"), (IMP)AB_UADSRewardedAd_show_delegate, kTypesArgArg));
    ABInstallHideBannerHook(@"UADSBannerView", (IMP)AB_UADSBannerView_didMoveToWindow, &ABOriginalUADSBannerViewDidMoveToWindowIMP);

    // Unity Ads本体のレガシー静的API。`+[UnityAds show:placementId:options:]` /
    // `+[UnityAds show:placementId:options:showDelegate:]`というクラスメソッド(インスタンスではない)。
    // UnityAdsクラス自体はSwift実装のためランタイム上の名前がSDKバージョンでマングルされうる
    // (実測値: `_TtC8UnityAds8UnityAds`)ためサフィックス一致で解決する。
    ABLogSwizzle(@"*UnityAds(class).show:placementId:options:",
                 ABSwizzleClassMethodBySuffix(@"UnityAds", NSSelectorFromString(@"show:placementId:options:"), (IMP)AB_NoOp_WithArgArgArg, kTypesArgArgArg));
    ABLogSwizzle(@"*UnityAds(class).show:placementId:options:showDelegate:",
                 ABSwizzleClassMethodBySuffix(@"UnityAds", NSSelectorFromString(@"show:placementId:options:showDelegate:"), (IMP)AB_NoOp_WithArgArgArgArg, kTypesArgArgArgArg));

    // 診断: 広告関連クラスの登録状況をログに残す(dylibロード直後時点のスナップショット)
    ABLogSuspiciousAdClasses();
}
