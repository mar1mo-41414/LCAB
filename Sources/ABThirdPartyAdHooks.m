#import "ABThirdPartyAdHooks.h"
#import "ABSwizzle.h"
#import "ABDebugLog.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - Objective-C型エンコーディング(全て "v@:" + 引数の並び。voidメソッドのみ扱う)

static const char *const kTypesVoid = "v@:";
static const char *const kTypesArg = "v@:@";
static const char *const kTypesArgArg = "v@:@@";
static const char *const kTypesArgBool = "v@:@B";
static const char *const kTypesArgArgArg = "v@:@@@";
static const char *const kTypesArgArgArgArg = "v@:@@@@";
static const char *const kTypesBool = "v@:B";
static const char *const kTypesDouble = "v@:d"; // CGFloatはarm64ではdouble(64bit)
static const char *const kTypesIdArgArg = "@@:@@"; // initWithX:andY:のようなid返り値のinitializer用

// 診断ヘルパー(定義は本ファイル後方)。実機でクラス構造が未知のSDKを調査する際に使う。
static void ABLogAllMethods(NSString *className);
static void ABLogAllProperties(NSString *className);
static void ABLogAllIvars(NSString *className);
static void ABLogSwizzle(NSString *label, BOOL ok);
static void ABLogClassesContainingSubstringNow(NSString *substring);
static UIView *_Nullable ABFindSubviewClassNameContaining(UIView *root, NSString *substring);
static void ABMAXTryForceUnityAdsRewardedDelegateCompletion(void);

/// 同じ内容のインストールログを繰り返し出さないようにする。dyldの新規イメージロードのたびに
/// インストール処理全体が再実行される(ABConstructor.m参照)ため、素朴に毎回ログを出すと
/// ファイルI/Oだけで無視できないコストになる。ラベルごとに「最後に記録した結果」を覚えておき、
/// 結果が変化した場合(NG→OK、あるいは未記録)のときだけ実際にログへ書き込む。
static BOOL ABShouldLogInstallResult(NSString *label, BOOL ok) {
    static NSMutableDictionary<NSString *, NSNumber *> *lastResults;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        lastResults = [NSMutableDictionary dictionary];
    });
    @synchronized (lastResults) {
        NSNumber *last = lastResults[label];
        if (last && last.boolValue == ok) {
            return NO;
        }
        lastResults[label] = @(ok);
        return YES;
    }
}

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

#pragma mark - リワード付与ヘルパー(広告を見た体でSDKに結果を通知し、ゲーム側の続行を可能にする)
#pragma mark   ユーザー自身が遊ぶための広告ブロッカーであり、広告を見ずに機能を使えることが目的のため、
#pragma mark   報酬は成功扱いにする(不正な第三者への報酬付与ではなく、自分自身の環境のみに閉じる)。

/// delegateの実クラス名から、それがアプリ自身の実装ではなくAppLovin MAX自前の
/// メディエーションアダプタ用ブリッジクラスかどうかを判定する。実機確認済みの例:
/// ALByteDanceRewardedVideoAdDelegate(Pangle)、ALUnityAdsRewardedDelegate(Unity Ads)、
/// AppLovinMediationMolocoAdapter.MolocoRewardedAdapterDelegate(Moloco)。これらは
/// 各SDK公式ドキュメント通りのdelegateプロトコル名を一切実装していないことが実機で
/// 判明しており、ブロック+偽delegate通知では報酬はおろかゲームが広告完了コールバックを
/// 待ち続けてフリーズする(tokyo.plott.tesのMolocoで実機確認)。この場合はブロックせず
/// 元の実装に任せ、MAUnityAdManager.didDisplayAd:フックに処理を委ねる必要がある。
static BOOL ABDelegateLooksLikeMAXBridge(id delegate) {
    if (!delegate) {
        return NO;
    }
    NSString *className = NSStringFromClass([delegate class]);
    return [className hasPrefix:@"AL"] || [className rangeOfString:@"AppLovin"].location != NSNotFound;
}

/// self.delegateを安全に取得する(delegateの型はSDKごとに異なるため素朴にrespondsToSelector:で
/// チェックしてから呼ぶ)。取得の成否・delegateの実クラス名を診断ログに残す。
static id ABGetDelegate(id self) {
    if (![self respondsToSelector:@selector(delegate)]) {
        ABDebugLog(@"[REWARD]   %@ has no -delegate accessor", NSStringFromClass([self class]));
        return nil;
    }
    id delegate = ((id (*)(id, SEL))objc_msgSend)(self, @selector(delegate));
    ABDebugLog(@"[REWARD]   %@.delegate = %@", NSStringFromClass([self class]), delegate ? NSStringFromClass([delegate class]) : @"nil");
    return delegate;
}

/// 1引数のdelegateコールバックを、存在すれば呼ぶ。引数はnil(Objective-Cのnilへのメッセージ送信は
/// プロパティアクセス程度なら安全にゼロ値を返すため、型不一致のオブジェクトを渡うより安全)。
static void ABCallDelegate1(id delegate, SEL sel, id arg) {
    if (!delegate) {
        return;
    }
    BOOL responds = [delegate respondsToSelector:sel];
    ABDebugLog(@"[REWARD]   %@ respondsTo %@ -> %@", NSStringFromClass([delegate class]), NSStringFromSelector(sel), responds ? @"YES, calling" : @"NO");
    if (responds) {
        ((void (*)(id, SEL, id))objc_msgSend)(delegate, sel, arg);
    }
}

/// 2引数のdelegateコールバックを、存在すれば呼ぶ。
static void ABCallDelegate2(id delegate, SEL sel, id arg1, id arg2) {
    if (!delegate) {
        return;
    }
    BOOL responds = [delegate respondsToSelector:sel];
    ABDebugLog(@"[REWARD]   %@ respondsTo %@ -> %@", NSStringFromClass([delegate class]), NSStringFromSelector(sel), responds ? @"YES, calling" : @"NO");
    if (responds) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, sel, arg1, arg2);
    }
}

/// (id, NSInteger)のdelegateコールバックを、存在すれば呼ぶ。第2引数がenumなどの整数型の場合、
/// objc_msgSendへの単純キャストでは正しく渡せない(idとして渡すとnil=0以外の値を表現できない)ため
/// NSInvocationを使う。
static void ABCallDelegate1ThenInteger(id delegate, SEL sel, id arg1, NSInteger arg2) {
    if (!delegate) {
        return;
    }
    BOOL responds = [delegate respondsToSelector:sel];
    ABDebugLog(@"[REWARD]   %@ respondsTo %@ -> %@", NSStringFromClass([delegate class]), NSStringFromSelector(sel), responds ? @"YES, calling" : @"NO");
    if (!responds) {
        return;
    }
    NSMethodSignature *sig = [delegate methodSignatureForSelector:sel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.selector = sel;
    inv.target = delegate;
    [inv setArgument:&arg1 atIndex:2];
    [inv setArgument:&arg2 atIndex:3];
    [inv invoke];
}

/// (id, BOOL)のdelegateコールバックを、存在すれば呼ぶ(例: Pangleの
/// `rewardedAd:userEarnedReward:`)。BOOLもNSIntegerと同様、objc_msgSendへの単純キャストでは
/// 正しく渡せないためNSInvocationを使う。
static void ABCallDelegate1ThenBool(id delegate, SEL sel, id arg1, BOOL arg2) {
    if (!delegate) {
        return;
    }
    BOOL responds = [delegate respondsToSelector:sel];
    ABDebugLog(@"[REWARD]   %@ respondsTo %@ -> %@", NSStringFromClass([delegate class]), NSStringFromSelector(sel), responds ? @"YES, calling" : @"NO");
    if (!responds) {
        return;
    }
    NSMethodSignature *sig = [delegate methodSignatureForSelector:sel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.selector = sel;
    inv.target = delegate;
    [inv setArgument:&arg1 atIndex:2];
    [inv setArgument:&arg2 atIndex:3];
    [inv invoke];
}

/// 引数の意味・個数は分かっているが型が不明なセレクタを、実行時のメソッド型エンコーディング
/// (methodSignatureForSelector:)に従って全引数nil/0で埋めて安全に呼ぶ。objc_msgSendへの
/// 単純キャストは引数の実際の型(BOOL/NSInteger/構造体等)を事前に知らないと正しく呼べないが、
/// NSInvocationを使えば実行時に取得した型に従って正しくレジスタへ値を積めるため、AppLovin内部の
/// 非公開API(ALUnityAdsRewardedDelegateのshowDidStart:等)のような、ドキュメント化されていない
/// メソッドでも引数の型を推測せずに安全に叩ける。構造体のように8バイトを超える引数が来た場合は
/// ゼロ埋め用バッファを超えて読み取られる危険があるため、呼び出し自体を中止する。
static void ABCallSelectorWithZeroFilledArgs(id delegate, SEL sel) {
    if (!delegate) {
        return;
    }
    if (![delegate respondsToSelector:sel]) {
        ABDebugLog(@"[AUTOCLOSE] %@ does not respond to %@", NSStringFromClass([delegate class]), NSStringFromSelector(sel));
        return;
    }
    NSMethodSignature *sig = [delegate methodSignatureForSelector:sel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.selector = sel;
    inv.target = delegate;
    NSUInteger argCount = sig.numberOfArguments;
    id nilObj = nil;
    SEL nilSel = nil;
    long long zero = 0;
    for (NSUInteger i = 2; i < argCount; i++) {
        const char *argType = [sig getArgumentTypeAtIndex:i];
        char firstChar = argType[0];
        if (firstChar == '@' || firstChar == '#') {
            [inv setArgument:&nilObj atIndex:(NSInteger)i];
        } else if (firstChar == ':') {
            [inv setArgument:&nilSel atIndex:(NSInteger)i];
        } else {
            NSUInteger size = 0;
            NSGetSizeAndAlignment(argType, &size, NULL);
            if (size > sizeof(zero)) {
                ABDebugLog(@"[AUTOCLOSE] %@ arg %lu type \"%s\" too large (%lu bytes) to zero-fill safely, skipping call", NSStringFromSelector(sel), (unsigned long)i, argType, (unsigned long)size);
                return;
            }
            [inv setArgument:&zero atIndex:(NSInteger)i];
        }
    }
    ABDebugLog(@"[AUTOCLOSE] calling %@ on %@ (zero/nil-filled args)", NSStringFromSelector(sel), NSStringFromClass([delegate class]));
    [inv invoke];
}

#pragma mark - AppLovin MAX: ロード済みMAAdのキャプチャ
#pragma mark   MAUnityAdManager(AppLovin公式Unityプラグインのdelegate実装、GitHub上のソースで確認済み)は
#pragma mark   didDisplayAd:/didHideAd:/didRewardUserForAd:withReward:の冒頭で必ずad.formatを参照し、
#pragma mark   nilなら即return、その先のadInfoForAd:ではad.adUnitIdentifier等をNSDictionaryリテラルに
#pragma mark   直接詰めるため値がnilだとクラッシュする。ad引数を安全な偽オブジェクトで代用するのは
#pragma mark   現実的でないため、事前にdidLoadAd:を横取りして本物のMAAdインスタンスを保存しておき、
#pragma mark   show断念時にそれを使い回す。

static NSMapTable<NSString *, id> *ABMAXLastLoadedAdByFormatKey = nil;

/// ad.formatを見て "REWARDED" / "INTERSTITIAL" / "APPOPEN" のいずれかに分類する。
static NSString *_Nullable ABMAXFormatKeyForAd(id ad) {
    if (!ad || ![ad respondsToSelector:@selector(format)]) {
        return nil;
    }
    id format = ((id (*)(id, SEL))objc_msgSend)(ad, @selector(format));
    if (!format) {
        return nil;
    }
    NSString *desc = [format description] ?: @"";
    // "REWARDED_INTERSTITIAL"は"REWARD"にも"INTER"にも部分一致するため、
    // 汎用の"REWARDED"/"INTERSTITIAL"より先に判定する。
    if ([desc rangeOfString:@"REWARDED_INTERSTITIAL" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return @"REWARDED_INTERSTITIAL";
    }
    if ([desc rangeOfString:@"REWARD" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return @"REWARDED";
    }
    if ([desc rangeOfString:@"APP_OPEN" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [desc rangeOfString:@"APPOPEN" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return @"APPOPEN";
    }
    if ([desc rangeOfString:@"INTER" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return @"INTERSTITIAL";
    }
    return nil;
}

static NSString *_Nullable ABMAXFormatKeyForInstance(id self) {
    NSString *className = NSStringFromClass([self class]);
    if ([className isEqualToString:@"MARewardedAd"]) return @"REWARDED";
    if ([className isEqualToString:@"MARewardedInterstitialAd"]) return @"REWARDED_INTERSTITIAL";
    if ([className isEqualToString:@"MAInterstitialAd"]) return @"INTERSTITIAL";
    if ([className isEqualToString:@"MAAppOpenAd"]) return @"APPOPEN";
    return nil;
}

static IMP ABOriginalMAUnityAdManagerDidLoadAdIMP = NULL;
static void AB_MAUnityAdManager_didLoadAd(id self, SEL _cmd, id ad) {
    NSString *key = ABMAXFormatKeyForAd(ad);
    if (key) {
        if (!ABMAXLastLoadedAdByFormatKey) {
            ABMAXLastLoadedAdByFormatKey = [NSMapTable strongToStrongObjectsMapTable];
        }
        [ABMAXLastLoadedAdByFormatKey setObject:ad forKey:key];
        ABDebugLog(@"[REWARD]   captured loaded MAAd for format=%@", key);
    }
    // 元の実装(Unity C#へのイベント転送、バナーのpositioning等)は必ず継続させる。
    if (ABOriginalMAUnityAdManagerDidLoadAdIMP) {
        ((void (*)(id, SEL, id))ABOriginalMAUnityAdManagerDidLoadAdIMP)(self, _cmd, ad);
    }
}

/// MAUnityAdManagerクラス名を直接対象にdidLoadAd:をフックする。show呼び出し時点で
/// delegateから遡ってフックしようとすると、その広告のdidLoadAd:は既に発火した後で
/// 手遅れになるため、dylibロード時(他のフックと同じタイミング)に前もってインストールする。
static BOOL ABMAUnityAdManagerHookInstalled = NO;
static void ABInstallMAUnityAdManagerCaptureHook(void) {
    if (ABMAUnityAdManagerHookInstalled) {
        return;
    }
    Class cls = NSClassFromString(@"MAUnityAdManager");
    if (!cls) {
        if (ABShouldLogInstallResult(@"MAUnityAdManager.didLoadAd:", NO)) {
            ABDebugLog(@"[INSTALL] MAUnityAdManager.didLoadAd: -> NG (class not found)");
        }
        return;
    }
    BOOL ok = ABSwizzleInstanceMethodKeepingOriginal(cls, NSSelectorFromString(@"didLoadAd:"), (IMP)AB_MAUnityAdManager_didLoadAd, kTypesArg, &ABOriginalMAUnityAdManagerDidLoadAdIMP);
    if (ok) {
        ABMAUnityAdManagerHookInstalled = YES;
    }
    if (ABShouldLogInstallResult(@"MAUnityAdManager.didLoadAd:", ok)) {
        ABDebugLog(@"[INSTALL] MAUnityAdManager.didLoadAd: -> %@", ok ? @"OK" : @"NG");
    }
}

/// `didRewardUserForAd:withReward:`のreward引数用に、AppLovin MAX公式ヘッダ上の
/// `MAReward`(実体は`MALabeledValue`のtypedef、label/amountのreadonlyプロパティのみを
/// 持つ素のValueオブジェクト)の空インスタンスを生成する。これまでnilを渡していたが、
/// tokyo.plott.tesで「見た体」の報酬がゲーム側に反映されない不具合が見つかった。
/// MAUnityAdManagerの実装がUnity C#側へreward.amount/reward.labelを転送しており、
/// ゲーム側がamount==0(nilへのメッセージ送信で安全に返るデフォルト値)を「無効な報酬」
/// として無視している可能性が高い。レシーバがnilではなく実在のオブジェクトであれば
/// 読み取られる値自体は0のままでも、"rewardがnilかどうか"のチェックだけは通過できる
/// ことを期待した対策。designated initializerの制約でクラッシュする可能性があるため
/// @try/@catchで保護し、失敗時はnilにフォールバックする(従来の挙動のまま)。
static id ABMAXMakeFallbackReward(void) {
    NSArray<NSString *> *candidateClassNames = @[@"MAReward", @"MALabeledValue"];
    for (NSString *className in candidateClassNames) {
        Class cls = NSClassFromString(className);
        if (!cls) {
            continue;
        }
        @try {
            id instance = [[cls alloc] init];
            if (instance) {
                ABDebugLog(@"[REWARD]   fallback reward instance: %@", className);
                return instance;
            }
        } @catch (NSException *exception) {
            ABDebugLog(@"[REWARD]   %@ alloc/init threw %@: %@", className, exception.name, exception.reason);
        }
    }
    return nil;
}

/// capturedAd(実クラスALMediatedFullscreenAd)が保持する`ALAtomicBoolean`型のフラグ
/// (didRewardUserCalled/cancelRewardTask/didReportUserNotRewarded等)を強制的にセットする。
/// `-set:`(BOOL)を実機のメソッドダンプで確認済み。SDK内部が`didRewardUserForAd:withReward:`
/// 呼び出し前にこれらのフラグの整合性を検証している可能性があるため、delegateへの通知前に
/// 「視聴完了・キャンセルなし・未報告」の状態を明示的に作る。
static void ABMAXForceAtomicFlag(id capturedAd, SEL propertySelector, BOOL value) {
    if (!capturedAd || ![capturedAd respondsToSelector:propertySelector]) {
        return;
    }
    id flag = ((id (*)(id, SEL))objc_msgSend)(capturedAd, propertySelector);
    if (!flag || ![flag respondsToSelector:@selector(set:)]) {
        return;
    }
    ((void (*)(id, SEL, BOOL))objc_msgSend)(flag, @selector(set:), value);
    ABDebugLog(@"[REWARD]   forced %@.set:%@", NSStringFromSelector(propertySelector), value ? @"YES" : @"NO");
}

/// AppLovin MAX系(MAAdDelegate/MARewardedAdDelegate)。表示成功→(報酬)→非表示を順に通知する。
/// ad引数は可能な限り本物のMAAdインスタンス(事前にロード済みならキャプチャ済み)を使う。
static void ABNotifyMAXDelegate(id self, BOOL grantReward) {
    id delegate = ABGetDelegate(self);
    NSString *formatKey = ABMAXFormatKeyForInstance(self);
    id capturedAd = (formatKey && ABMAXLastLoadedAdByFormatKey) ? [ABMAXLastLoadedAdByFormatKey objectForKey:formatKey] : nil;
    ABDebugLog(@"[REWARD]   formatKey=%@ capturedAd=%@", formatKey, capturedAd ? @"found" : @"nil(fallback)");
    if (grantReward && delegate) {
        // tokyo.plott.tes調査用: didDisplayAd:/didRewardUserForAd:withReward:/didHideAd:を
        // 全てrespondsToSelector:=YESで呼べているのに報酬がゲーム側に反映されない不具合が
        // あったため、delegate(MAUnityAdManager)・capturedAdの実クラス・MARewardの構造を
        // 1回だけ詳細ダンプする。capturedAdの実クラスはALMediatedFullscreenAdで、
        // pendingReward(ALPendingReward型)/cancelRewardTask・didRewardUserCalled・
        // cancelRewardValidationTask(いずれもALAtomicBoolean型)という、非同期のリワード
        // 検証タスクを示唆するプロパティを持っていることが判明したため、それらの構造も調べる。
        static dispatch_once_t maxIntrospectionOnceToken;
        dispatch_once(&maxIntrospectionOnceToken, ^{
            ABLogAllMethods(NSStringFromClass([delegate class]));
            ABLogAllProperties(NSStringFromClass([delegate class]));
            ABLogAllIvars(NSStringFromClass([delegate class]));
            if (capturedAd) {
                ABLogAllProperties(NSStringFromClass([capturedAd class]));
                if ([capturedAd respondsToSelector:@selector(pendingReward)]) {
                    id pendingReward = ((id (*)(id, SEL))objc_msgSend)(capturedAd, @selector(pendingReward));
                    ABDebugLog(@"[REWARD]   capturedAd.pendingReward = %@", pendingReward ? NSStringFromClass([pendingReward class]) : @"nil");
                    if (pendingReward) {
                        ABLogAllMethods(NSStringFromClass([pendingReward class]));
                        ABLogAllProperties(NSStringFromClass([pendingReward class]));
                    }
                }
                if ([capturedAd respondsToSelector:@selector(didRewardUserCalled)]) {
                    id flag = ((id (*)(id, SEL))objc_msgSend)(capturedAd, @selector(didRewardUserCalled));
                    ABDebugLog(@"[REWARD]   capturedAd.didRewardUserCalled = %@", flag ? NSStringFromClass([flag class]) : @"nil");
                    if (flag) {
                        ABLogAllMethods(NSStringFromClass([flag class]));
                    }
                }
                if ([capturedAd respondsToSelector:@selector(cancelRewardTask)]) {
                    id flag = ((id (*)(id, SEL))objc_msgSend)(capturedAd, @selector(cancelRewardTask));
                    ABDebugLog(@"[REWARD]   capturedAd.cancelRewardTask = %@", flag ? NSStringFromClass([flag class]) : @"nil");
                }
            }
        });
    }
    ABCallDelegate1(delegate, NSSelectorFromString(@"didDisplayAd:"), capturedAd);
    if (grantReward) {
        // tokyo.plott.tesで本物の広告再生をパススルーして実機観察した結果、本物のフローは
        // 常にdidDisplayAd: -> didClickAd: -> didRewardUserForAd:withReward: -> didHideAd:
        // の順だった(reward.label/amountは本物でも空・0で、我々の偽装値と一致していたため
        // reward引数自体は原因ではなかった)。didClickAd:を一切呼んでいなかったのが欠けていた
        // 可能性が高いため追加する。
        ABCallDelegate1(delegate, NSSelectorFromString(@"didClickAd:"), capturedAd);
        id reward = ABMAXMakeFallbackReward();
        // capturedAdがSDK内部に「本物の」pendingReward(ALPendingReward)を保持している場合、
        // 空のMARewardより先にこちらを優先して使う(label/amountが実際の値を持つ可能性が
        // 高いため)。pendingRewardがMAReward/MALabeledValue互換のプロトコルを実装していると
        // は限らないが、didRewardUserForAd:withReward:の型チェックが緩ければ通る可能性がある。
        if (capturedAd && [capturedAd respondsToSelector:@selector(pendingReward)]) {
            id realPendingReward = ((id (*)(id, SEL))objc_msgSend)(capturedAd, @selector(pendingReward));
            if (realPendingReward) {
                reward = realPendingReward;
            }
        }
        // SDK内部のリワード検証タスク関連フラグを「視聴完了・キャンセルなし・未報告」の
        // 状態に強制してからdelegateへ通知する。capturedAdがALMediatedFullscreenAdでない
        // 場合やこれらのプロパティを持たない場合はrespondsToSelector:チェックで安全に無視される。
        ABMAXForceAtomicFlag(capturedAd, @selector(cancelRewardTask), NO);
        ABMAXForceAtomicFlag(capturedAd, @selector(didReportUserNotRewarded), NO);
        ABMAXForceAtomicFlag(capturedAd, @selector(didRewardUserCalled), YES);
        ABCallDelegate2(delegate, NSSelectorFromString(@"didRewardUserForAd:withReward:"), capturedAd, reward);
    }
    ABCallDelegate1(delegate, NSSelectorFromString(@"didHideAd:"), capturedAd);
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

#pragma mark - AppLovin MAX MARewardedAd: 表示→自動クローズ方式(tokyo.plott.tes対応)
#pragma mark   ALMediatedFullscreenAdが持つadViewControllerObserverDelaySeconds等のプロパティ
#pragma mark   から、SDKはshow呼び出し後「実際に広告ViewControllerが画面に現れたか」を別途
#pragma mark   タイマーで監視しており、show自体を完全にブロックしてしまうとこの監視に
#pragma mark   引っかかり、一定時間後に「広告の取得に失敗しました」という表示とともに
#pragma mark   didFailToDisplayAd:withError:相当の失敗処理に倒れ、報酬も付与されないことが
#pragma mark   実機で判明した(delegateへの偽装通知だけでは通らない)。そのためMARewardedAdに
#pragma mark   限り、showはブロックせず元の実装に任せ、SDK自身がdidDisplayAd:を呼んだ直後に
#pragma mark   広告ViewControllerを自動で閉じる方式に切り替える。

/// handleCloseButtonに応答すればそれを呼び(SDK正規の「閉じるボタンが押された」ハンドラ)、
/// なければdismissViewControllerAnimated:にフォールバックする。既に画面から外れていれば
/// (view.windowがnil)何もしない。AVPlayerシークが使えないクラス(プレイアブル等)や、
/// シーク後のフォールバックとして使う。
static void ABMAXCloseIfStillPresented(UIViewController *top) {
    if (!top.isViewLoaded || !top.view.window) {
        ABDebugLog(@"[AUTOCLOSE] %@ already dismissed, nothing to do", NSStringFromClass([top class]));
        return;
    }
    SEL closeButtonSel = NSSelectorFromString(@"handleCloseButton");
    if ([top respondsToSelector:closeButtonSel]) {
        ABDebugLog(@"[AUTOCLOSE] calling handleCloseButton on %@", NSStringFromClass([top class]));
        ((void (*)(id, SEL))objc_msgSend)(top, closeButtonSel);
    } else {
        ABDebugLog(@"[AUTOCLOSE] dismissing %@", NSStringFromClass([top class]));
        [top dismissViewControllerAnimated:NO completion:^{
            ABDebugLog(@"[AUTOCLOSE] dismiss completion called");
        }];
    }
}

/// ALBaseVideoViewControllerの実機ダンプ(tokyo.plott.tes)で、SDK自身が「完全視聴」を
/// 表すフラグ群(wasPlayedToEnd/adViewFullyWatched/treatAdAsFullyWatched)と、それらを
/// もとに実際に報酬報告処理をスケジュールする-scheduleReportRewardTaskIfNeededを発見した。
/// handleCloseButton/強制dismiss/AVPlayerシークは全て「外側から閉じる・再生させる」操作に
/// 過ぎず、SDK自身の報酬報告ロジック(ALMediatedFullscreenAdのcancelRewardTask等と対になる
/// 内部実装)を一度も直接起動していなかった可能性がある。そこでこれらのフラグを強制し、
/// scheduleReportRewardTaskIfNeededを直接呼んで、SDKに「視聴完了」と判断させる。
/// avPlayer経由のシークはtokyo.plott.tesの広告(HTML/MRAIDテンプレート内の<video>タグを
/// WKWebViewが再生しており、ALBaseVideoViewController自身のavPlayerは毎回nil)では
/// 機能しなかったため、この方式に置き換えた。
static void ABMAXForceRewardCompletionIfPossible(UIViewController *top) {
    SEL setWasPlayedToEndSel = NSSelectorFromString(@"setWasPlayedToEnd:");
    SEL setAdViewFullyWatchedSel = NSSelectorFromString(@"setAdViewFullyWatched:");
    SEL setTreatAdAsFullyWatchedSel = NSSelectorFromString(@"setTreatAdAsFullyWatched:");
    SEL scheduleReportRewardSel = NSSelectorFromString(@"scheduleReportRewardTaskIfNeeded");

    if ([top respondsToSelector:setWasPlayedToEndSel]) {
        ABDebugLog(@"[AUTOCLOSE] setWasPlayedToEnd:YES on %@", NSStringFromClass([top class]));
        ((void (*)(id, SEL, BOOL))objc_msgSend)(top, setWasPlayedToEndSel, YES);
    }
    if ([top respondsToSelector:setAdViewFullyWatchedSel]) {
        ABDebugLog(@"[AUTOCLOSE] setAdViewFullyWatched:YES on %@", NSStringFromClass([top class]));
        ((void (*)(id, SEL, BOOL))objc_msgSend)(top, setAdViewFullyWatchedSel, YES);
    }
    if ([top respondsToSelector:setTreatAdAsFullyWatchedSel]) {
        ABDebugLog(@"[AUTOCLOSE] setTreatAdAsFullyWatched:YES on %@", NSStringFromClass([top class]));
        ((void (*)(id, SEL, BOOL))objc_msgSend)(top, setTreatAdAsFullyWatchedSel, YES);
    }
    if ([top respondsToSelector:scheduleReportRewardSel]) {
        ABDebugLog(@"[AUTOCLOSE] calling scheduleReportRewardTaskIfNeeded on %@", NSStringFromClass([top class]));
        ((void (*)(id, SEL))objc_msgSend)(top, scheduleReportRewardSel);
    } else {
        ABDebugLog(@"[AUTOCLOSE] %@ does not respond to scheduleReportRewardTaskIfNeeded", NSStringFromClass([top class]));
    }
}

/// 本物のAVPlayerに直接アクセスできる場合(ALBaseVideoViewController系)のみの追加施策。
/// tokyo.plott.tesの実機では毎回nilだった(HTML/MRAIDテンプレート広告のため)が、他の
/// 広告フォーマットでは効く可能性があるため残す。成功すればYESを返す。
static BOOL ABMAXTrySeekVideoNearEndAndClose(UIViewController *top) {
    if (![top respondsToSelector:@selector(avPlayer)]) {
        return NO;
    }
    id playerObj = ((id (*)(id, SEL))objc_msgSend)(top, @selector(avPlayer));
    if (![playerObj isKindOfClass:[AVPlayer class]]) {
        ABDebugLog(@"[AUTOCLOSE] avPlayer is not AVPlayer: %@", playerObj ? NSStringFromClass([playerObj class]) : @"nil");
        return NO;
    }
    AVPlayer *player = (AVPlayer *)playerObj;
    AVPlayerItem *item = player.currentItem;
    CMTime duration = item ? item.duration : kCMTimeInvalid;
    if (!item || !CMTIME_IS_VALID(duration) || CMTimeGetSeconds(duration) <= 0) {
        ABDebugLog(@"[AUTOCLOSE] avPlayer.currentItem.duration not ready yet");
        return NO;
    }
    double durationSeconds = CMTimeGetSeconds(duration);
    double backOffSeconds = MIN(0.3, durationSeconds * 0.1);
    CMTime nearEnd = CMTimeSubtract(duration, CMTimeMakeWithSeconds(backOffSeconds, duration.timescale));
    ABDebugLog(@"[AUTOCLOSE] seeking AVPlayer to near end (duration=%.2fs)", durationSeconds);
    [player seekToTime:nearEnd toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
        ABDebugLog(@"[AUTOCLOSE] seek finished=%@, resuming playback", finished ? @"YES" : @"NO");
        [player play];
        // 動画終了検知・報酬タイマーが走る時間を見込んで少し待ってから、まだ広告が
        // 画面に残っていればフォールバックでhandleCloseButton/dismissを呼ぶ。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ABMAXCloseIfStillPresented(top);
        });
    }];
    return YES;
}

/// キーウィンドウの最前面にpresentされているViewControllerを探して閉じる。
/// 広告show直後というタイミングの前提で、通常はそれが広告のViewControllerのはず。
static void ABMAXAutoDismissPresentedViewController(void) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray<UIWindow *> *windows = [UIApplication sharedApplication].windows;
#pragma clang diagnostic pop
    UIWindow *keyWindow = nil;
    for (UIWindow *window in windows) {
        if (window.isKeyWindow) {
            keyWindow = window;
            break;
        }
    }
    if (!keyWindow) {
        keyWindow = windows.firstObject;
    }
    UIViewController *root = keyWindow.rootViewController;
    UIViewController *top = root;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    if (top && top != root) {
        // tokyo.plott.tes調査用: 強制dismissだけでは「早期スキップ」とみなされ報酬が付与
        // されないと実機で判明したため、まずdismiss対象のViewController(映像広告なら
        // ALAppLovinVideoViewController)の内部構造を1回だけダンプし、AVPlayer等を
        // 直接操作して動画終端までシークする手段がないか調査する。
        // dispatch_onceだと最初に表示された広告フォーマット(プレイアブル等)のクラスでしか
        // 診断が走らず、2回目以降の別フォーマット(映像広告のALAppLovinVideoViewController等)
        // を取りこぼすと判明したため、クラス名ごとに1回だけ診断する方式に変更する。
        static NSMutableSet<NSString *> *introspectedClassNames;
        static dispatch_once_t introspectedSetOnceToken;
        dispatch_once(&introspectedSetOnceToken, ^{
            introspectedClassNames = [NSMutableSet set];
        });
        NSString *topClassName = NSStringFromClass([top class]);
        BOOL alreadyIntrospected;
        @synchronized (introspectedClassNames) {
            alreadyIntrospected = [introspectedClassNames containsObject:topClassName];
            if (!alreadyIntrospected) {
                [introspectedClassNames addObject:topClassName];
            }
        }
        if (!alreadyIntrospected) {
            ABLogAllMethods(topClassName);
            ABLogAllProperties(topClassName);
            ABLogAllIvars(topClassName);
            // handleCloseButtonを呼んでも報酬が付与されなかったため、動画再生の実体を
            // 持っていそうな継承元クラスとcurrentAd(ALAdServerAd、広告データ本体)の構造も
            // 追加で調べる。
            Class superCls = class_getSuperclass([top class]);
            if (superCls) {
                NSString *superName = NSStringFromClass(superCls);
                ABDebugLog(@"[SCAN] %@ superclass = %@", topClassName, superName);
                ABLogAllMethods(superName);
                ABLogAllProperties(superName);
                ABLogAllIvars(superName);
            }
            if ([top respondsToSelector:@selector(currentAd)]) {
                id currentAd = ((id (*)(id, SEL))objc_msgSend)(top, @selector(currentAd));
                if (currentAd) {
                    NSString *adClassName = NSStringFromClass([currentAd class]);
                    ABDebugLog(@"[SCAN] currentAd class = %@", adClassName);
                    ABLogAllMethods(adClassName);
                    ABLogAllProperties(adClassName);
                }
            }
            // プレイアブル広告(UnityAds.WebViewContainerViewController)はそれ自体が
            // ほぼ空の薄いコンテナで、scheduleReportRewardTaskIfNeeded相当のメソッドを
            // 持たない。実際のWebView(VIEWDUMPで確認済みのUnityAds.ViewStateObservableWebView)
            // と、その時点でロード済みのUnityAds関連クラス一式を追加で調べ、報酬報告の
            // 実体(ブリッジ/リスナー等)がどこにあるか手がかりを探す。
            if ([topClassName rangeOfString:@"WebViewContainer"].location != NSNotFound) {
                ABLogClassesContainingSubstringNow(@"UnityAds");
                UIView *webView = ABFindSubviewClassNameContaining(top.view, @"WebView");
                if (webView) {
                    NSString *webViewClassName = NSStringFromClass([webView class]);
                    ABDebugLog(@"[SCAN] playable webview instance class = %@", webViewClassName);
                    ABLogAllMethods(webViewClassName);
                    ABLogAllProperties(webViewClassName);
                    ABLogAllIvars(webViewClassName);
                } else {
                    ABDebugLog(@"[SCAN] no WebView-named subview found under %@", topClassName);
                }
            }
        }
        // まずSDK自身の「完全視聴」フラグ群を強制し、scheduleReportRewardTaskIfNeededを
        // 直接呼んで報酬報告処理そのものを起動する(上記ABMAXForceRewardCompletionIfPossible
        // 参照)。avPlayerが使える広告フォーマットならシークも追加で試す。
        ABMAXForceRewardCompletionIfPossible(top);
        // プレイアブル(UnityAds.WebViewContainerViewController)は上記のVC自身の
        // フラグ・メソッドを一切持たないため、代わりにinitializerフックで捕まえておいた
        // ALUnityAdsRewardedDelegateへ直接showDidReceiveReward:等を送り込む。
        if ([topClassName rangeOfString:@"WebViewContainer"].location != NSNotFound) {
            ABMAXTryForceUnityAdsRewardedDelegateCompletion();
        }
        if (!ABMAXTrySeekVideoNearEndAndClose(top)) {
            // scheduleReportRewardTaskIfNeededが内部でタイマー(reportRewardTimer)を
            // 使っている可能性があるため、即座に閉じず少し待つ。早すぎるcloseは
            // ALMediatedFullscreenAd側のcancelRewardTaskを誘発し、せっかく起動した
            // 報酬報告を取り消してしまう懸念がある。
            ABDebugLog(@"[AUTOCLOSE] waiting for reward report to settle before closing %@", NSStringFromClass([top class]));
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                ABMAXCloseIfStillPresented(top);
            });
        }
    } else {
        ABDebugLog(@"[AUTOCLOSE] no presented view controller found to dismiss");
    }
}

static IMP ABOriginalMAUnityAdManagerDidDisplayAdForAutoCloseIMP = NULL;
/// MAUnityAdManager(アプリ側=Unity Plugin自身が実装するdelegate)のdidDisplayAd:を横取りし、
/// SDK自身が「表示開始」を認識した直後に自動クローズをスケジュールする。SDK自身の表示処理
/// (ViewControllerのpresent)は妨げないため、タイミング監視には正しく捕捉される。
static void AB_MAUnityAdManager_didDisplayAd_AutoClose(id self, SEL _cmd, id ad) {
    ABDebugLog(@"[AUTOCLOSE] MAUnityAdManager didDisplayAd: ad=%@ -> scheduling auto-dismiss", ad ? NSStringFromClass([ad class]) : @"nil");
    if (ABOriginalMAUnityAdManagerDidDisplayAdForAutoCloseIMP) {
        ((void (*)(id, SEL, id))ABOriginalMAUnityAdManagerDidDisplayAdForAutoCloseIMP)(self, _cmd, ad);
    }
    // プレイアブル(UnityAds.WebViewContainerViewController)は映像広告のALBaseVideoViewController
    // と違い、報酬報告メソッドを自分自身で持っていない。実機のクラス一覧スキャンで
    // ALUnityAdsRewardedDelegate(AppLovin MAX自前のUnity Adsメディエーションアダプタ
    // delegate、Pangle用のALByteDanceRewardedVideoAdDelegateと同系統)を発見したため、
    // その構造(本物のUnityAdsShowDelegateプロトコルメソッド名)を調べる。あわせて
    // ad引数(ALMediatedFullscreenAd)自体がこのdelegateへの参照をivarとして保持して
    // いないかも1回だけ調べ、保持していれば直接completion系メソッドを呼べないか探る。
    ABLogAllMethods(@"ALUnityAdsRewardedDelegate");
    ABLogAllProperties(@"ALUnityAdsRewardedDelegate");
    ABLogAllIvars(@"ALUnityAdsRewardedDelegate");
    if (ad) {
        static NSMutableSet<NSString *> *introspectedAdClassNames;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            introspectedAdClassNames = [NSMutableSet set];
        });
        NSString *adClassName = NSStringFromClass([ad class]);
        BOOL already;
        @synchronized (introspectedAdClassNames) {
            already = [introspectedAdClassNames containsObject:adClassName];
            if (!already) {
                [introspectedAdClassNames addObject:adClassName];
            }
        }
        if (!already) {
            ABDebugLog(@"[SCAN] ad (didDisplayAd: argument) class = %@", adClassName);
            ABLogAllIvars(adClassName);
            ABLogAllProperties(adClassName);
        }
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ABMAXAutoDismissPresentedViewController();
    });
}

static IMP ABOriginalMARewardedAdShowAdIMP = NULL;
static IMP ABOriginalMARewardedAdShowAdForPlacementIMP = NULL;
static IMP ABOriginalMARewardedAdShowAdForPlacementCustomDataIMP = NULL;
static void AB_MARewardedAd_ShowAd_Passthrough(id self, SEL _cmd) {
    ABDebugLog(@"[AUTOCLOSE] MARewardedAd showAd PASSTHROUGH(表示後に自動クローズ)");
    if (ABOriginalMARewardedAdShowAdIMP) {
        ((void (*)(id, SEL))ABOriginalMARewardedAdShowAdIMP)(self, _cmd);
    }
}
static void AB_MARewardedAd_ShowAdForPlacement_Passthrough(id self, SEL _cmd, id placement) {
    ABDebugLog(@"[AUTOCLOSE] MARewardedAd showAdForPlacement: PASSTHROUGH placement=%@", placement);
    if (ABOriginalMARewardedAdShowAdForPlacementIMP) {
        ((void (*)(id, SEL, id))ABOriginalMARewardedAdShowAdForPlacementIMP)(self, _cmd, placement);
    }
}
static void AB_MARewardedAd_ShowAdForPlacementCustomData_Passthrough(id self, SEL _cmd, id placement, id customData) {
    ABDebugLog(@"[AUTOCLOSE] MARewardedAd showAdForPlacement:customData: PASSTHROUGH placement=%@ customData=%@", placement, customData);
    if (ABOriginalMARewardedAdShowAdForPlacementCustomDataIMP) {
        ((void (*)(id, SEL, id, id))ABOriginalMARewardedAdShowAdForPlacementCustomDataIMP)(self, _cmd, placement, customData);
    }
}

/// ALUnityAdsRewardedDelegate(AppLovin MAX自前のUnity Adsメディエーションアダプタ用delegate、
/// 実機ダンプで-showDidStart:/-showDidClick:/-showDidReceiveReward:/-showDidComplete:with:/
/// -showDidFail:error:を発見済み)の生きたインスタンスを、initializer
/// -initWithParentAdapter:andNotify:をフックして捕まえておく。プレイアブル広告
/// (UnityAds.WebViewContainerViewController)はALBaseVideoViewControllerのような
/// 自前の報酬報告メソッドを持たないため、代わりにこのdelegateへ直接showDidReceiveReward:等を
/// 送り込んで報酬を成立させる。1個の広告フローにつき1個のインスタンスという前提で、
/// 直近1個だけを強参照で保持する(複数の広告が同時に飛ぶことは想定していない)。
static id ABCapturedUnityAdsRewardedDelegate = nil;

static IMP ABOriginalALUnityAdsRewardedDelegateInitIMP = NULL;
static id AB_ALUnityAdsRewardedDelegate_initWithParentAdapter_andNotify(id self, SEL _cmd, id parentAdapter, id notify) {
    id result = self;
    if (ABOriginalALUnityAdsRewardedDelegateInitIMP) {
        result = ((id (*)(id, SEL, id, id))ABOriginalALUnityAdsRewardedDelegateInitIMP)(self, _cmd, parentAdapter, notify);
    }
    ABDebugLog(@"[AUTOCLOSE] captured ALUnityAdsRewardedDelegate instance (parentAdapter=%@)", parentAdapter ? NSStringFromClass([parentAdapter class]) : @"nil");
    ABCapturedUnityAdsRewardedDelegate = result;
    return result;
}

/// 直前に捕まえたALUnityAdsRewardedDelegateに対し、showDidStart:→showDidReceiveReward:→
/// showDidComplete:with:の順で送る。各セレクタの引数の実際の型は不明だが
/// ABCallSelectorWithZeroFilledArgsが実行時のメソッド型エンコーディングに従って安全に
/// nil/0埋めするため、構造体のような想定外の大きい型でない限り安全に呼べる。
/// showDidClick:(クリックイベント)は、実際にクリックしていないのに広告ネットワーク側の
/// クリック計測を汚すことになるため、意図的に呼ばない。
static void ABMAXTryForceUnityAdsRewardedDelegateCompletion(void) {
    if (!ABCapturedUnityAdsRewardedDelegate) {
        ABDebugLog(@"[AUTOCLOSE] no captured ALUnityAdsRewardedDelegate instance to force-complete");
        return;
    }
    ABCallSelectorWithZeroFilledArgs(ABCapturedUnityAdsRewardedDelegate, NSSelectorFromString(@"showDidStart:"));
    ABCallSelectorWithZeroFilledArgs(ABCapturedUnityAdsRewardedDelegate, NSSelectorFromString(@"showDidReceiveReward:"));
    ABCallSelectorWithZeroFilledArgs(ABCapturedUnityAdsRewardedDelegate, NSSelectorFromString(@"showDidComplete:with:"));
}

static void ABInstallMAXRewardedAutoClose(void) {
    Class rewardedCls = NSClassFromString(@"MARewardedAd");
    ABLogSwizzle(@"MARewardedAd.showAd (auto-close mode)",
                 ABSwizzleInstanceMethodKeepingOriginal(rewardedCls, NSSelectorFromString(@"showAd"), (IMP)AB_MARewardedAd_ShowAd_Passthrough, kTypesVoid, &ABOriginalMARewardedAdShowAdIMP));
    ABLogSwizzle(@"MARewardedAd.showAdForPlacement: (auto-close mode)",
                 ABSwizzleInstanceMethodKeepingOriginal(rewardedCls, NSSelectorFromString(@"showAdForPlacement:"), (IMP)AB_MARewardedAd_ShowAdForPlacement_Passthrough, kTypesArg, &ABOriginalMARewardedAdShowAdForPlacementIMP));
    ABLogSwizzle(@"MARewardedAd.showAdForPlacement:customData: (auto-close mode)",
                 ABSwizzleInstanceMethodKeepingOriginal(rewardedCls, NSSelectorFromString(@"showAdForPlacement:customData:"), (IMP)AB_MARewardedAd_ShowAdForPlacementCustomData_Passthrough, kTypesArgArg, &ABOriginalMARewardedAdShowAdForPlacementCustomDataIMP));

    Class delegateCls = NSClassFromString(@"MAUnityAdManager");
    if (delegateCls) {
        ABLogSwizzle(@"MAUnityAdManager.didDisplayAd: (auto-close hook)",
                     ABSwizzleInstanceMethodKeepingOriginal(delegateCls, NSSelectorFromString(@"didDisplayAd:"), (IMP)AB_MAUnityAdManager_didDisplayAd_AutoClose, kTypesArg, &ABOriginalMAUnityAdManagerDidDisplayAdForAutoCloseIMP));
    }

    // プレイアブル広告のUnity Ads経路用。-initWithParentAdapter:andNotify:はshow呼び出しより
    // 前に実行される(リスナーのセットアップ)ため、ここで早めにフックしておく必要がある
    // (didDisplayAd:が発火してから初めてフックしても、そのインスタンスはもう作られた後で遅い)。
    Class unityDelegateCls = NSClassFromString(@"ALUnityAdsRewardedDelegate");
    if (unityDelegateCls) {
        ABLogSwizzle(@"ALUnityAdsRewardedDelegate.initWithParentAdapter:andNotify: (capture)",
                     ABSwizzleInstanceMethodKeepingOriginal(unityDelegateCls, NSSelectorFromString(@"initWithParentAdapter:andNotify:"), (IMP)AB_ALUnityAdsRewardedDelegate_initWithParentAdapter_andNotify, kTypesIdArgArg, &ABOriginalALUnityAdsRewardedDelegateInitIMP));
    }
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

/// Unity Ads本体のレガシー静的API `+[UnityAds show:placementId:options:showDelegate:]`。
/// 第4引数がdelegate。素のUnityAdsShowDelegateプロトコル(unityAdsShowStart:/
/// unityAdsShowComplete:withState:、Unity公式ドキュメントに基づく)を第一候補として試すが、
/// Godusでは実際に渡ってくるdelegateがゲーム自身の実装ではなく、ironSourceのAdQuality計測
/// レイヤー(実測クラス名`SMLDelegate`、`ISAdQualityAdDelegate`のサブクラス)だった。
/// SMLDelegate自身への通知だけでは報酬が付与されず、実機診断の結果、ivar `_strongDelegate`が
/// 実際のメディエーションアダプタ本体(実測: `ISUnityAdsRewardedVideoDelegate`)を保持して
/// いることが判明。これに対しunityAdsAdLoaded:(ロード完了)→unityAdsShowStart:(表示開始)→
/// unityAdsShowComplete:withFinishState:(表示完了)の順で送ることで実機での報酬付与を確認した。
/// finishStateの正しい値(UnityAdsFinishStateのenum)は未確証のため、候補値0/1/2を順に送る。
/// ivar名`_strongDelegate`はSDKバージョン依存の可能性があるため存在確認してから使う。
static void AB_UnityAdsClass_show_placementId_options_showDelegate(id self, SEL _cmd, id viewController, id placementId, id options, id showDelegate) {
    ABLogBlocked(self, _cmd);
    ABCallDelegate1(showDelegate, NSSelectorFromString(@"unityAdsShowStart:"), placementId);
    ABCallDelegate1ThenInteger(showDelegate, NSSelectorFromString(@"unityAdsShowComplete:withState:"), placementId, 2 /* kUnityShowCompletionStateCompleted */);
    ABCallDelegate1(showDelegate, NSSelectorFromString(@"unityAdsShowComplete:"), placementId);
    ABCallDelegate1ThenInteger(showDelegate, NSSelectorFromString(@"unityAdsShowComplete:withFinishState:"), placementId, 2 /* kUnityAdsFinishStateCompleted */);
    ABCallDelegate1ThenInteger(showDelegate, NSSelectorFromString(@"unityAdsDidFinish:withFinishState:"), placementId, 2 /* kUnityAdsFinishStateCompleted */);

    Ivar strongDelegateIvar = class_getInstanceVariable([showDelegate class], "_strongDelegate");
    if (strongDelegateIvar) {
        id strongDelegate = object_getIvar(showDelegate, strongDelegateIvar);
        if (strongDelegate) {
            ABCallDelegate1(strongDelegate, NSSelectorFromString(@"unityAdsAdLoaded:"), placementId);
            ABCallDelegate1(strongDelegate, NSSelectorFromString(@"unityAdsShowStart:"), placementId);
            for (NSInteger state = 0; state <= 2; state++) {
                ABCallDelegate1ThenInteger(strongDelegate, NSSelectorFromString(@"unityAdsShowComplete:withFinishState:"), placementId, state);
            }
        }
    }
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
    ABDebugLog(@"[REWARD]   Moloco rewardedDelegate=%@ interstitialDelegate=%@",
               rewardedDelegate ? NSStringFromClass([rewardedDelegate class]) : @"nil",
               interstitialDelegate ? NSStringFromClass([interstitialDelegate class]) : @"nil");
    ABCallDelegate1(rewardedDelegate, NSSelectorFromString(@"didRewardUser:"), nil);
    ABCallDelegate1(rewardedDelegate, NSSelectorFromString(@"didHide:"), nil);
    ABCallDelegate1(interstitialDelegate, NSSelectorFromString(@"didHide:"), nil);
}
/// tokyo.plott.tesの実機検証で、MolocoSDK.PublisherFullscreenAdがAppLovin MAXの
/// Molocoメディエーションアダプタ経由で使われているケース(rewardedDelegateの実クラスが
/// "AppLovinMediationMolocoAdapter.MolocoRewardedAdapterDelegate")を確認した。この場合
/// Moloco公式ドキュメント通りのdelegateプロトコル名(didRewardUser:/didHide:)を一切
/// 実装しておらず、ブロック+偽delegate通知では報酬が付与されないどころか、実際の広告が
/// 一切表示されないままゲーム側が広告完了コールバックを待ち続け、UIがフリーズする不具合が
/// 実機で発生した(BGMは鳴り続けるがタップに無反応になる症状と一致)。この場合はブロック
/// せず元の実装に任せ、MAUnityAdManager.didDisplayAd:フックに処理を委ねる。それ以外
/// (アプリ自身のMoloco SDK直接利用)は従来通りブロック+偽delegate通知を使う。
static BOOL ABMolocoShouldPassthrough(id self) {
    id rewardedDelegate = nil;
    if ([self respondsToSelector:@selector(rewardedDelegate)]) {
        rewardedDelegate = ((id (*)(id, SEL))objc_msgSend)(self, @selector(rewardedDelegate));
    }
    id interstitialDelegate = nil;
    if ([self respondsToSelector:@selector(interstitialDelegate)]) {
        interstitialDelegate = ((id (*)(id, SEL))objc_msgSend)(self, @selector(interstitialDelegate));
    }
    return ABDelegateLooksLikeMAXBridge(rewardedDelegate) || ABDelegateLooksLikeMAXBridge(interstitialDelegate);
}

static IMP ABOriginalMolocoShowFromIMP = NULL;
static IMP ABOriginalMolocoShowFromMutedIMP = NULL;
static void AB_Moloco_showFrom(id self, SEL _cmd, id vc) {
    if (ABMolocoShouldPassthrough(self)) {
        ABDebugLog(@"[AUTOCLOSE] MolocoSDK.PublisherFullscreenAd showFrom: PASSTHROUGH (MAX bridging delegate)");
        if (ABOriginalMolocoShowFromIMP) {
            ((void (*)(id, SEL, id))ABOriginalMolocoShowFromIMP)(self, _cmd, vc);
        }
        return;
    }
    ABLogBlocked(self, _cmd);
    ABNotifyMolocoDelegate(self);
}
static void AB_Moloco_showFrom_muted(id self, SEL _cmd, id vc, BOOL muted) {
    if (ABMolocoShouldPassthrough(self)) {
        ABDebugLog(@"[AUTOCLOSE] MolocoSDK.PublisherFullscreenAd showFrom:muted: PASSTHROUGH (MAX bridging delegate)");
        if (ABOriginalMolocoShowFromMutedIMP) {
            ((void (*)(id, SEL, id, BOOL))ABOriginalMolocoShowFromMutedIMP)(self, _cmd, vc, muted);
        }
        return;
    }
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

/// Smaato(SmaatoSDKInterstitial/SmaatoSDKRewardedAds、Appodealのメディエーション先の一つ)。
/// SMAInterstitial/SMARewardedInterstitialとも表示トリガーはshowFromViewController:で共通。
/// リワードのdelegateコールバック名はrewardedVideoPresenterDidComplete:と推測(確証はベストエフォート)。
static void AB_Smaato_showFromViewController_NoReward(id self, SEL _cmd, id vc) {
    ABLogBlocked(self, _cmd);
    id delegate = ABGetDelegate(self);
    ABCallDelegate1(delegate, NSSelectorFromString(@"adPresenterDisplayed:"), nil);
    ABCallDelegate1(delegate, NSSelectorFromString(@"adPresenterCompleted:"), nil);
}
static void AB_Smaato_showFromViewController_Reward(id self, SEL _cmd, id vc) {
    ABLogBlocked(self, _cmd);
    id delegate = ABGetDelegate(self);
    ABCallDelegate1(delegate, NSSelectorFromString(@"rewardedVideoPresenterWillAppear:"), nil);
    ABCallDelegate1(delegate, NSSelectorFromString(@"rewardedVideoPresenterDidAppear:"), nil);
    ABCallDelegate1(delegate, NSSelectorFromString(@"rewardedVideoPresenterDidComplete:"), nil);
    ABCallDelegate1(delegate, NSSelectorFromString(@"adPresenterCompleted:"), nil);
}

/// Pangle(ByteDance/TikTok系、Snowで実機確認)。表示トリガーはPAGInterstitialAd/PAGRewardedAd
/// 共通で`presentFromRootViewController:`(Pangle公式ドキュメントに基づく)。Snowでは
/// インタースティシャルのクラス名が現行の`PAGInterstitialAd`ではなく旧世代命名の
/// `PAGLInterstitialAd`("L"付き)だったため両方を対象にする。delegateプロトコル名
/// (`adDidPresentFullScreen:`/`adDidDismissFullScreen:`/`rewardedAd:userEarnedReward:`)は
/// 公式ドキュメントに基づくが確証はベストエフォート。
static void AB_Pangle_presentFromRootViewController_NoReward(id self, SEL _cmd, id vc) {
    ABLogBlocked(self, _cmd);
    id delegate = ABGetDelegate(self);
    ABCallDelegate1(delegate, NSSelectorFromString(@"adDidPresentFullScreen:"), self);
    ABCallDelegate1(delegate, NSSelectorFromString(@"adDidDismissFullScreen:"), self);
}
static void AB_Pangle_presentFromRootViewController_Reward(id self, SEL _cmd, id vc) {
    ABLogBlocked(self, _cmd);
    id delegate = ABGetDelegate(self);
    ABCallDelegate1(delegate, NSSelectorFromString(@"adDidPresentFullScreen:"), self);
    ABCallDelegate1ThenBool(delegate, NSSelectorFromString(@"rewardedAd:userEarnedReward:"), self, YES);
    ABCallDelegate1(delegate, NSSelectorFromString(@"adDidDismissFullScreen:"), self);
}

/// tokyo.plott.tesの実機検証で、PAGRewardedAdがアプリ自身のPangle SDK直接利用ではなく
/// AppLovin MAXのPangleメディエーションアダプタ経由で使われているケースを確認した。この
/// 場合delegateの実クラスは"ALByteDanceRewardedVideoAdDelegate"のようなAppLovin自前の
/// ブリッジクラス("AL"プレフィックス)で、Pangle公式ドキュメント通りのdelegateプロトコル名
/// (adDidPresentFullScreen:等)を一切実装しておらず、上のAB_Pangle_presentFromRootViewController_Reward
/// (ブロック+偽delegate通知)では報酬が付与されない。この場合はブロックせず元の実装に
/// 任せ、MAUnityAdManager.didDisplayAd:フック(ABMAXAutoDismissPresentedViewController、
/// MARewardedAd用に実装済み)に処理を委ねる。delegateが"AL"プレフィックスでない場合
/// (Snowで確認したような、アプリ自身のPangle SDK直接利用)は従来通りブロック+偽delegate
/// 通知を使う。
static IMP ABOriginalPAGRewardedAdPresentFromRootViewControllerIMP = NULL;
static void AB_PAGRewardedAd_presentFromRootViewController_Conditional(id self, SEL _cmd, id vc) {
    id delegate = ABGetDelegate(self);
    if (ABDelegateLooksLikeMAXBridge(delegate)) {
        ABDebugLog(@"[AUTOCLOSE] PAGRewardedAd presentFromRootViewController: PASSTHROUGH (MAX bridging delegate %@)", NSStringFromClass([delegate class]));
        if (ABOriginalPAGRewardedAdPresentFromRootViewControllerIMP) {
            ((void (*)(id, SEL, id))ABOriginalPAGRewardedAdPresentFromRootViewControllerIMP)(self, _cmd, vc);
        }
        return;
    }
    AB_Pangle_presentFromRootViewController_Reward(self, _cmd, vc);
}

/// Vungle Ads SDK(新API、名前空間`VungleAdsSDK`、Snowで実機確認)。Swift実装で
/// `func present(with viewController: UIViewController)`のObjective-Cブリッジ名は
/// Swiftの命名規則から`presentWith:`と推測されるが確証は薄いため、`present:`も併せて
/// 試す。delegateの報酬通知(`rewardedAdDidRewardUser:`)はVungle公式ドキュメントに基づく。
static void AB_VungleAdsSDK_presentWith_NoReward(id self, SEL _cmd, id vc) {
    ABLogBlocked(self, _cmd);
    id delegate = ABGetDelegate(self);
    ABCallDelegate1(delegate, NSSelectorFromString(@"interstitialAdDidPresent:"), self);
    ABCallDelegate1(delegate, NSSelectorFromString(@"interstitialAdDidClose:"), self);
}
static void AB_VungleAdsSDK_presentWith_Reward(id self, SEL _cmd, id vc) {
    ABLogBlocked(self, _cmd);
    id delegate = ABGetDelegate(self);
    ABCallDelegate1(delegate, NSSelectorFromString(@"rewardedAdDidPresent:"), self);
    ABCallDelegate1(delegate, NSSelectorFromString(@"rewardedAdDidRewardUser:"), self);
    ABCallDelegate1(delegate, NSSelectorFromString(@"rewardedAdDidClose:"), self);
}

/// GFP(NAVER/LINE系列の自社広告プラットフォーム"Global Fit Platform"、Snowで実機確認。
/// iマークのリンク先がterms.line.meだったことから正体を特定)。実機でのメソッド一覧ダンプにより
/// 表示トリガーは`show:`(showFromRootViewController:ではない)、delegate通知は
/// interstitialAdDidStart:/interstitialAdDidComplete:/interstitialAdDidClose:、
/// rewardedAdDidStart:/rewardedAdAdaptor:didCompleteWithReward:/rewardedAdDidClose:と
/// 確認済み(確度は高い)。
static void AB_GFPInterstitialAd_show(id self, SEL _cmd, id vc) {
    ABLogBlocked(self, _cmd);
    id delegate = ABGetDelegate(self);
    ABCallDelegate1(delegate, NSSelectorFromString(@"interstitialAdDidStart:"), self);
    ABCallDelegate1(delegate, NSSelectorFromString(@"interstitialAdDidComplete:"), self);
    ABCallDelegate1(delegate, NSSelectorFromString(@"interstitialAdDidClose:"), self);
}
static void AB_GFPRewardedAd_show(id self, SEL _cmd, id vc) {
    ABLogBlocked(self, _cmd);
    id delegate = ABGetDelegate(self);
    ABCallDelegate1(delegate, NSSelectorFromString(@"rewardedAdDidStart:"), self);
    ABCallDelegate2(delegate, NSSelectorFromString(@"rewardedAdAdaptor:didCompleteWithReward:"), self, nil);
    ABCallDelegate1(delegate, NSSelectorFromString(@"rewardedAdDidClose:"), self);
}

#pragma mark - バナー系(表示トリガーがなく、window追加時に自動的に見えるようになるもの)

/// バナーViewをwindowに追加させつつ即座に隠す。SDKによってはdidMoveToWindow後に自動リフレッシュ
/// 等の非同期処理が改めてhiddenを書き戻してくることがあるため(AppLovin MAXのMAAdViewで実際に
/// 確認)、didMoveToWindow単発では不十分。setHidden:を乗っ取って常にYESを強制することで、
/// SDK側が何度書き戻しても最終的に非表示状態を維持する。
///
/// frameを直接CGRectZeroに書き換える方式は試したが、Auto Layout制約下のView
/// (InMobiのIMBannerで確認)ではframe変更→制約違反→再レイアウト要求→layoutSubviews再呼び出し→
/// SDK側がframeを書き戻す→……という循環でメインスレッドがフリーズしたため廃止した。
/// hiddenだけで画面上には表示されなくなるので、frameはSDK/Auto Layoutの管理に委ねる。
///
/// MAAdViewはsetAlpha:を独自オーバーライドしており(自動リフレッシュ時にalphaを明示的に
/// 1.0へ戻すコードが、副作用としてhiddenも書き戻していると推測される)、setHidden:だけでは
/// 不十分でバナーが消えないケースを実際に確認した。setAlpha:も乗っ取り、渡された値に関わらず
/// 常に0を強制しつつ、その直後にhiddenも再度強制する。
static void ABForceHidden(UIView *view) {
    if (!view.hidden) {
        view.hidden = YES;
    }
    // UIViewのhiddenプロパティ(=layer.hidden経由の通常のコンポジット制御)を再帰的に
    // 子孫までYESにしても、Unity統合特有の描画パスではまだ画面に見え続けるケースを実際に
    // 確認した(StoneGrassのMAAdView: View階層上はhidden=1が子まで正しく伝播しているのに
    // バナーが消えなかった)。CALayerを直接操作すれば、UIViewのプロパティ経由の同期を
    // バイパスしている場合でも効く可能性があるため、layer.hidden/opacityも直接強制する。
    view.layer.hidden = YES;
    if (view.layer.opacity != 0.0f) {
        view.layer.opacity = 0.0f;
    }
}

/// MAAdViewのようなSDKは、自身は正しくhidden=YESにしても、子ビュー(独自のUIViewインスタンス)が
/// hidden=NOのまま残り、かつ何らかの独自レンダリングパス(Unity統合でのMetal直接描画等、
/// UIKitのhiddenプロパティを無視して描画されるパス)で表示され続けるケースを実際に確認した
/// (StoneGrassのMAAdView: 自身はhidden=1なのに子のUIViewがhidden=0のままバナーが見え続けた)。
/// UIViewクラス自体をフックするのは危険(継承元=UIView全体を壊す既知のバグ)なので、代わりに
/// 「このバナーコンテナの子孫」という特定インスタンス単位でhiddenを再帰的に強制する
/// (クラスの実装を変えるのではなくプロパティ値を設定するだけなので安全)。
static void ABForceHiddenRecursive(UIView *view) {
    ABForceHidden(view);
    for (UIView *subview in view.subviews) {
        ABForceHiddenRecursive(subview);
    }
}

/// バナーコンテナ自身をhidden化しても、それを画面幅いっぱいの帯として包む専用ラッパーView
/// (SDKが用意する素のUIView、クラス自体はフックできない汎用クラスのため対象にできない)が
/// 高さ分のレイアウトスペースを確保したまま残り、白い帯として見え続けるケースを実機で確認した
/// (SnowのFADAdViewCustomLayoutを唯一の子として持つ無名UIView)。「祖先が唯一の子として
/// このバナーを持つ限り再帰的にhiddenを強制する」対策を一度試したが、Snowの実際のUI階層では
/// 中間コンテナが一時的に子1つだけの状態になることが多く、想定よりはるかに高い階層(画面下部の
/// カメラ切替ボタン等、広告と無関係な正当なUI)まで巻き込んで消してしまい撤回した。
/// この「白い帯」自体は既知の未解決制約として扱う(下記の既知の制約と同種の問題)。

#define AB_DEFINE_HIDE_BANNER_HOOK_SET_IMPL(prefix, didMoveVar, setHiddenVar, layoutVar, setAlphaVar, doRemove) \
    static IMP didMoveVar = NULL; \
    static IMP setHiddenVar = NULL; \
    static IMP layoutVar = NULL; \
    static IMP setAlphaVar = NULL; \
    static void prefix##_didMoveToWindow(UIView *self, SEL _cmd) { \
        ABLogBlocked(self, _cmd); \
        if (didMoveVar) { \
            ((void (*)(id, SEL))didMoveVar)(self, _cmd); \
        } \
        ABForceHiddenRecursive(self); \
        /* hidden=YES/layer.opacity=0まで再帰的に強制してもUnity統合特有の描画パスでは */ \
        /* まだ画面に見え続けるケースを実際に確認した(StoneGrassのMAAdView)。最終手段として */ \
        /* View階層そのものから切り離す。子孫ではなくこのバナーコンテナ自身のみ親から外す */ \
        /* (子孫を外すとSDK内部の参照が壊れてクラッシュしうるため対象を最小限にする)。 */ \
        /* ただしremoveFromSuperview自体が、このViewと別のView(兄弟や無関係な階層)を跨いで */ \
        /* 張られたAuto Layout制約を「共通の祖先を持たない」不正な状態にすることがあり、 */ \
        /* しかもその不整合はremoveFromSuperviewを呼んだ場では例外にならず、次のUIKit */ \
        /* レイアウトサイクル(呼び出し元のスタックの外)で例外を投げてクラッシュする */ \
        /* (SnowのGFPネイティブ広告FADCustomLayoutBaseViewで実機確認: centerX制約が */ \
        /* FADAdViewCustomLayoutという別Viewと結ばれており、@try/@catchでも防げなかった)。 */ \
        /* このため危険なクラスではdoRemove=NOにしてremoveFromSuperview自体を行わず、 */ \
        /* hidden化のみに留める(AB_DEFINE_HIDE_BANNER_HOOK_SET_NO_REMOVE参照)。 */ \
        if ((doRemove) && self.superview) { \
            @try { \
                [self removeFromSuperview]; \
            } @catch (NSException *exception) { \
                ABDebugLog(@"[BLOCKED] %@ removeFromSuperview threw %@: %@", NSStringFromClass([self class]), exception.name, exception.reason); \
            } \
        } \
    } \
    static void prefix##_setHidden(UIView *self, SEL _cmd, BOOL hidden) { \
        ABDebugLog(@"[BLOCKED] %@ setHidden:%@", NSStringFromClass([self class]), hidden ? @"YES" : @"NO"); \
        if (setHiddenVar) { \
            ((void (*)(id, SEL, BOOL))setHiddenVar)(self, _cmd, YES); \
        } \
        ABForceHiddenRecursive(self); \
    } \
    static void prefix##_layoutSubviews(UIView *self, SEL _cmd) { \
        if (layoutVar) { \
            ((void (*)(id, SEL))layoutVar)(self, _cmd); \
        } \
        ABForceHiddenRecursive(self); \
    } \
    static void prefix##_setAlpha(UIView *self, SEL _cmd, CGFloat alpha) { \
        ABDebugLog(@"[BLOCKED] %@ setAlpha:%.2f", NSStringFromClass([self class]), (double)alpha); \
        if (setAlphaVar) { \
            ((void (*)(id, SEL, CGFloat))setAlphaVar)(self, _cmd, 0.0); \
        } \
        ABForceHiddenRecursive(self); \
    }

#define AB_DEFINE_HIDE_BANNER_HOOK_SET(prefix, didMoveVar, setHiddenVar, layoutVar, setAlphaVar) \
    AB_DEFINE_HIDE_BANNER_HOOK_SET_IMPL(prefix, didMoveVar, setHiddenVar, layoutVar, setAlphaVar, YES)

/// removeFromSuperviewが外部のAuto Layout制約と衝突してクラッシュしうると判明したクラス用。
/// hidden化のみに留め、View階層からの切り離しは行わない。
#define AB_DEFINE_HIDE_BANNER_HOOK_SET_NO_REMOVE(prefix, didMoveVar, setHiddenVar, layoutVar, setAlphaVar) \
    AB_DEFINE_HIDE_BANNER_HOOK_SET_IMPL(prefix, didMoveVar, setHiddenVar, layoutVar, setAlphaVar, NO)

AB_DEFINE_HIDE_BANNER_HOOK_SET(AB_GADBannerView, ABOriginalGADBannerViewDidMoveToWindowIMP, ABOriginalGADBannerViewSetHiddenIMP, ABOriginalGADBannerViewLayoutSubviewsIMP, ABOriginalGADBannerViewSetAlphaIMP)
AB_DEFINE_HIDE_BANNER_HOOK_SET(AB_FBAdView, ABOriginalFBAdViewDidMoveToWindowIMP, ABOriginalFBAdViewSetHiddenIMP, ABOriginalFBAdViewLayoutSubviewsIMP, ABOriginalFBAdViewSetAlphaIMP)
AB_DEFINE_HIDE_BANNER_HOOK_SET(AB_ISBannerView, ABOriginalISBannerViewDidMoveToWindowIMP, ABOriginalISBannerViewSetHiddenIMP, ABOriginalISBannerViewLayoutSubviewsIMP, ABOriginalISBannerViewSetAlphaIMP)
AB_DEFINE_HIDE_BANNER_HOOK_SET(AB_MAAdView, ABOriginalMAAdViewDidMoveToWindowIMP, ABOriginalMAAdViewSetHiddenIMP, ABOriginalMAAdViewLayoutSubviewsIMP, ABOriginalMAAdViewSetAlphaIMP)
AB_DEFINE_HIDE_BANNER_HOOK_SET(AB_IMBanner, ABOriginalIMBannerDidMoveToWindowIMP, ABOriginalIMBannerSetHiddenIMP, ABOriginalIMBannerLayoutSubviewsIMP, ABOriginalIMBannerSetAlphaIMP)
AB_DEFINE_HIDE_BANNER_HOOK_SET(AB_AdSurgeBannerAdView, ABOriginalAdSurgeBannerAdViewDidMoveToWindowIMP, ABOriginalAdSurgeBannerAdViewSetHiddenIMP, ABOriginalAdSurgeBannerAdViewLayoutSubviewsIMP, ABOriginalAdSurgeBannerAdViewSetAlphaIMP)
AB_DEFINE_HIDE_BANNER_HOOK_SET(AB_MolocoBannerAdView, ABOriginalMolocoBannerAdViewDidMoveToWindowIMP, ABOriginalMolocoBannerAdViewSetHiddenIMP, ABOriginalMolocoBannerAdViewLayoutSubviewsIMP, ABOriginalMolocoBannerAdViewSetAlphaIMP)
AB_DEFINE_HIDE_BANNER_HOOK_SET(AB_UADSBannerView, ABOriginalUADSBannerViewDidMoveToWindowIMP, ABOriginalUADSBannerViewSetHiddenIMP, ABOriginalUADSBannerViewLayoutSubviewsIMP, ABOriginalUADSBannerViewSetAlphaIMP)
AB_DEFINE_HIDE_BANNER_HOOK_SET(AB_UADSBannerWrapperView, ABOriginalUADSBannerWrapperViewDidMoveToWindowIMP, ABOriginalUADSBannerWrapperViewSetHiddenIMP, ABOriginalUADSBannerWrapperViewLayoutSubviewsIMP, ABOriginalUADSBannerWrapperViewSetAlphaIMP)
AB_DEFINE_HIDE_BANNER_HOOK_SET(AB_SMABannerView, ABOriginalSMABannerViewDidMoveToWindowIMP, ABOriginalSMABannerViewSetHiddenIMP, ABOriginalSMABannerViewLayoutSubviewsIMP, ABOriginalSMABannerViewSetAlphaIMP)
AB_DEFINE_HIDE_BANNER_HOOK_SET(AB_PAGBannerAd, ABOriginalPAGBannerAdDidMoveToWindowIMP, ABOriginalPAGBannerAdSetHiddenIMP, ABOriginalPAGBannerAdLayoutSubviewsIMP, ABOriginalPAGBannerAdSetAlphaIMP)
AB_DEFINE_HIDE_BANNER_HOOK_SET(AB_VungleAdsSDKBannerView, ABOriginalVungleAdsSDKBannerViewDidMoveToWindowIMP, ABOriginalVungleAdsSDKBannerViewSetHiddenIMP, ABOriginalVungleAdsSDKBannerViewLayoutSubviewsIMP, ABOriginalVungleAdsSDKBannerViewSetAlphaIMP)
AB_DEFINE_HIDE_BANNER_HOOK_SET(AB_GFPBannerView, ABOriginalGFPBannerViewDidMoveToWindowIMP, ABOriginalGFPBannerViewSetHiddenIMP, ABOriginalGFPBannerViewLayoutSubviewsIMP, ABOriginalGFPBannerViewSetAlphaIMP)
AB_DEFINE_HIDE_BANNER_HOOK_SET_NO_REMOVE(AB_FADCustomLayoutBaseView, ABOriginalFADCustomLayoutBaseViewDidMoveToWindowIMP, ABOriginalFADCustomLayoutBaseViewSetHiddenIMP, ABOriginalFADCustomLayoutBaseViewLayoutSubviewsIMP, ABOriginalFADCustomLayoutBaseViewSetAlphaIMP)
AB_DEFINE_HIDE_BANNER_HOOK_SET_NO_REMOVE(AB_FADAdViewCustomLayout, ABOriginalFADAdViewCustomLayoutDidMoveToWindowIMP, ABOriginalFADAdViewCustomLayoutSetHiddenIMP, ABOriginalFADAdViewCustomLayoutLayoutSubviewsIMP, ABOriginalFADAdViewCustomLayoutSetAlphaIMP)

/// 対象クラス自身がメソッドをオーバーライドしていない場合でも、継承元(UIViewなど)を
/// 巻き込まずそのクラス専用の実装として安全に差し込む(ABSwizzleInstanceMethodKeepingOriginal参照)。
/// didMoveToWindow/setHidden:/layoutSubviewsの3点セットをまとめてインストールする。
static void ABInstallHideBannerHookSet(NSString *className,
                                        IMP didMoveImp, IMP *didMoveOriginal,
                                        IMP setHiddenImp, IMP *setHiddenOriginal,
                                        IMP layoutImp, IMP *layoutOriginal,
                                        IMP setAlphaImp, IMP *setAlphaOriginal) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        if (ABShouldLogInstallResult(className, NO)) {
            ABDebugLog(@"[INSTALL] %@ banner hooks -> NG (class not found)", className);
        }
        return;
    }
    BOOL ok1 = ABSwizzleInstanceMethodKeepingOriginal(cls, @selector(didMoveToWindow), didMoveImp, kTypesVoid, didMoveOriginal);
    BOOL ok2 = ABSwizzleInstanceMethodKeepingOriginal(cls, @selector(setHidden:), setHiddenImp, kTypesBool, setHiddenOriginal);
    BOOL ok3 = ABSwizzleInstanceMethodKeepingOriginal(cls, @selector(layoutSubviews), layoutImp, kTypesVoid, layoutOriginal);
    BOOL ok4 = ABSwizzleInstanceMethodKeepingOriginal(cls, @selector(setAlpha:), setAlphaImp, kTypesDouble, setAlphaOriginal);
    BOOL allOk = ok1 && ok2 && ok3 && ok4;
    if (ABShouldLogInstallResult(className, allOk)) {
        ABDebugLog(@"[INSTALL] %@ didMoveToWindow=%@ setHidden:=%@ layoutSubviews=%@ setAlpha:=%@", className,
                   ok1 ? @"OK" : @"NG", ok2 ? @"OK" : @"NG", ok3 ? @"OK" : @"NG", ok4 ? @"OK" : @"NG");
    }
}

static void ABInstallHideBannerHookSetBySuffix(NSString *classNameSuffix,
                                                IMP didMoveImp, IMP *didMoveOriginal,
                                                IMP setHiddenImp, IMP *setHiddenOriginal,
                                                IMP layoutImp, IMP *layoutOriginal,
                                                IMP setAlphaImp, IMP *setAlphaOriginal) {
    Class cls = ABFindClassBySuffix(classNameSuffix);
    if (!cls) {
        if (ABShouldLogInstallResult(classNameSuffix, NO)) {
            ABDebugLog(@"[INSTALL] *%@ banner hooks -> NG (class not found)", classNameSuffix);
        }
        return;
    }
    BOOL ok1 = ABSwizzleInstanceMethodKeepingOriginal(cls, @selector(didMoveToWindow), didMoveImp, kTypesVoid, didMoveOriginal);
    BOOL ok2 = ABSwizzleInstanceMethodKeepingOriginal(cls, @selector(setHidden:), setHiddenImp, kTypesBool, setHiddenOriginal);
    BOOL ok3 = ABSwizzleInstanceMethodKeepingOriginal(cls, @selector(layoutSubviews), layoutImp, kTypesVoid, layoutOriginal);
    BOOL ok4 = ABSwizzleInstanceMethodKeepingOriginal(cls, @selector(setAlpha:), setAlphaImp, kTypesDouble, setAlphaOriginal);
    BOOL allOk = ok1 && ok2 && ok3 && ok4;
    if (ABShouldLogInstallResult(classNameSuffix, allOk)) {
        ABDebugLog(@"[INSTALL] %@ (matched *%@) didMoveToWindow=%@ setHidden:=%@ layoutSubviews=%@ setAlpha:=%@", NSStringFromClass(cls), classNameSuffix,
                   ok1 ? @"OK" : @"NG", ok2 ? @"OK" : @"NG", ok3 ? @"OK" : @"NG", ok4 ? @"OK" : @"NG");
    }
}

static void ABLogSwizzle(NSString *label, BOOL ok) {
    if (ABShouldLogInstallResult(label, ok)) {
        ABDebugLog(@"[INSTALL] %@ -> %@", label, ok ? @"OK" : @"NG");
    }
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

#pragma mark - 診断: 画面下部に実際に見えているViewをダンプする
#pragma mark   非表示化フックが本当に対象クラスを捉えているのか、それとも全く別のクラスが
#pragma mark   表示の実体なのかを直接特定するための最終手段。

static void ABDumpViewIfBottomVisible(UIView *view, CGRect screenBounds, NSInteger depth) {
    CGRect frameInWindow = [view convertRect:view.bounds toView:nil];
    // hiddenの値に関わらず、画面下部の領域に関わる全Viewを親子関係(インデント)付きで出す。
    // MAAdView自体はhidden=YESになっているはずなので、それがこの階層のどこにいて、
    // 実際に見えているプレーンなUIViewとどういう親子関係にあるかを特定するのが目的。
    BOOL isBottomArea = CGRectGetMaxY(frameInWindow) > screenBounds.size.height * 0.6 && frameInWindow.size.height > 3;
    if (isBottomArea) {
        NSString *indent = [@"" stringByPaddingToLength:(NSUInteger)(depth * 2) withString:@" " startingAtIndex:0];
        ABDebugLog(@"[VIEWDUMP] %@%@(super=%@) frame=%@ hidden=%d alpha=%.2f subviews=%lu", indent,
                   NSStringFromClass([view class]), NSStringFromClass([view superclass]),
                   NSStringFromCGRect(frameInWindow), view.hidden, (double)view.alpha,
                   (unsigned long)view.subviews.count);
    }
    for (UIView *subview in view.subviews) {
        ABDumpViewIfBottomVisible(subview, screenBounds, depth + 1);
    }
}

void ABDumpVisibleBottomViews(void) {
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    ABDebugLog(@"[VIEWDUMP] === scan start ===");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray<UIWindow *> *windows = [UIApplication sharedApplication].windows;
#pragma clang diagnostic pop
    for (UIWindow *window in windows) {
        ABDumpViewIfBottomVisible(window, screenBounds, 0);
    }
    ABDebugLog(@"[VIEWDUMP] === scan end ===");
}

#pragma mark - 診断: ロード済みの広告関連クラスを洗い出す

/// 実行時に登録されている全クラスのうち、広告SDKらしい名前(キーワードを含む)のものを
/// 診断ログに列挙する。「そもそもクラスが見つからずフックが失敗している」のか
/// 「クラス名の想定が間違っている」のかを切り分けるための保険。
static void ABLogSuspiciousAdClasses(void) {
    // GFPはNAVER(Snowの親会社系列)の自社広告プラットフォーム"Global Fit Platform"の
    // 疑いがある(Snowでバナー広告未対応・iマークがterms.line.meへ飛ぶことから判明)。
    // Bannerを含めるとGFPBannerAdView等のバナークラスも拾えるようにする。
    // "FAD"はSnowの画面下部にFADInformationIconView(=iマーク本体)を含む未知のネイティブ広告
    // レンダラーとして実機確認できたため追加。正体・全容はまだ不明。
    NSArray<NSString *> *keywords = @[@"Interstitial", @"Rewarded", @"UnityAds", @"UADS", @"Playable", @"GFP", @"Banner", @"FAD"];
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

/// ABLogSuspiciousAdClassesの汎用版。起動時の1回だけでなく、プレイアブル広告の
/// ViewController提示直後など任意のタイミングで呼び出し、その時点でロード済みの
/// クラスをキーワードで絞り込んで列挙する。Unity Adsのプレイアブル広告本体
/// (UnityAds.WebViewContainerViewController)はメソッドがほぼ無い薄いコンテナに過ぎず、
/// 報酬報告ロジックを持つ本体クラス(ブリッジ/リスナー等)は広告がロードされるまで
/// クラスローダーに現れない可能性があるため、起動時スキャンでは取りこぼす。
static void ABLogClassesContainingSubstringNow(NSString *substring) {
    int bufferCount = objc_getClassList(NULL, 0);
    if (bufferCount <= 0) {
        return;
    }
    Class *classes = (Class *)malloc(sizeof(Class) * (unsigned long)bufferCount);
    if (!classes) {
        return;
    }
    int actualCount = objc_getClassList(classes, bufferCount);
    int limit = actualCount < bufferCount ? actualCount : bufferCount;
    NSMutableArray<NSString *> *matched = [NSMutableArray array];
    for (int i = 0; i < limit; i++) {
        const char *cName = class_getName(classes[i]);
        if (!cName) {
            continue;
        }
        NSString *name = @(cName);
        if ([name rangeOfString:substring].location != NSNotFound) {
            [matched addObject:name];
        }
    }
    free(classes);
    ABDebugLog(@"[SCAN] %lu classes containing \"%@\" found (live scan):", (unsigned long)matched.count, substring);
    for (NSString *name in matched) {
        ABDebugLog(@"[SCAN]   %@", name);
    }
}

/// root自身、または子孫のうちクラス名にsubstringを含む最初のUIViewを探す。プレイアブル
/// 広告のViewController(UnityAds.WebViewContainerViewController)自体は実体を持たず、
/// 実際のWebView(VIEWDUMPで確認済みのUnityAds.ViewStateObservableWebView)が
/// 真の広告ロジックを保持している可能性が高いため、そちらを直接introspectする。
static UIView *_Nullable ABFindSubviewClassNameContaining(UIView *root, NSString *substring) {
    if (!root) {
        return nil;
    }
    if ([NSStringFromClass([root class]) rangeOfString:substring].location != NSNotFound) {
        return root;
    }
    for (UIView *subview in root.subviews) {
        UIView *found = ABFindSubviewClassNameContaining(subview, substring);
        if (found) {
            return found;
        }
    }
    return nil;
}

/// 指定クラス(インスタンスメソッド+クラスメソッド)の全メソッド名を診断ログに残す。
/// GFPInterstitialAd/GFPRewardedAdのshowFromRootViewController:フックがNGだったため、
/// 正しいメソッド名を実機で特定するための保険(Snow調査用)。
static void ABLogAllMethods(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        ABDebugLog(@"[SCAN] class not found: %@", className);
        return;
    }
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    ABDebugLog(@"[SCAN] %@ instance methods (%u):", className, count);
    for (unsigned int i = 0; i < count; i++) {
        ABDebugLog(@"[SCAN]   -%@", NSStringFromSelector(method_getName(methods[i])));
    }
    free(methods);

    Class metaCls = object_getClass(cls);
    unsigned int classCount = 0;
    Method *classMethods = class_copyMethodList(metaCls, &classCount);
    ABDebugLog(@"[SCAN] %@ class methods (%u):", className, classCount);
    for (unsigned int i = 0; i < classCount; i++) {
        ABDebugLog(@"[SCAN]   +%@", NSStringFromSelector(method_getName(classMethods[i])));
    }
    free(classMethods);
}

/// 指定クラスの全プロパティ名と型エンコーディングを診断ログに残す。GFPBannerViewの
/// didMoveToWindowフックが発火しなかったため、YRKBannerGFPAdが実際に保持している
/// バナーView(bannerAdView等)の実クラスがGFPBannerViewとは別物である疑いがある。
static void ABLogAllProperties(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        ABDebugLog(@"[SCAN] class not found: %@", className);
        return;
    }
    unsigned int count = 0;
    objc_property_t *props = class_copyPropertyList(cls, &count);
    ABDebugLog(@"[SCAN] %@ properties (%u):", className, count);
    for (unsigned int i = 0; i < count; i++) {
        const char *name = property_getName(props[i]);
        const char *attrs = property_getAttributes(props[i]);
        ABDebugLog(@"[SCAN]   %s : %s", name ?: "?", attrs ?: "?");
    }
    free(props);
}

/// 指定クラスの全ivar名と型エンコーディングを診断ログに残す。プロパティとして公開されて
/// いない内部状態(S2S検証フラグ、UnitySendMessage送信先のGameObject名など)を推測する
/// 手がかりにする(tokyo.plott.tes調査用)。
static void ABLogAllIvars(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        ABDebugLog(@"[SCAN] class not found: %@", className);
        return;
    }
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    ABDebugLog(@"[SCAN] %@ ivars (%u):", className, count);
    for (unsigned int i = 0; i < count; i++) {
        const char *name = ivar_getName(ivars[i]);
        const char *type = ivar_getTypeEncoding(ivars[i]);
        ABDebugLog(@"[SCAN]   %s : %s", name ?: "?", type ?: "?");
    }
    free(ivars);
}

#pragma mark - Install

void ABInstallThirdPartyAdHooks(void) {
    // Google AdMob
    ABLogSwizzle(@"GADInterstitialAd.presentFromRootViewController:",
                 ABSwizzleInstanceMethod(@"GADInterstitialAd", @selector(presentFromRootViewController:), (IMP)AB_NoOp_WithArg, kTypesArg));
    ABLogSwizzle(@"GADRewardedAd.presentFromRootViewController:userDidEarnRewardHandler:",
                 ABSwizzleInstanceMethod(@"GADRewardedAd", @selector(presentFromRootViewController:userDidEarnRewardHandler:), (IMP)AB_GADRewardedAd_present, kTypesArgArg));
    ABInstallHideBannerHookSet(@"GADBannerView",
                               (IMP)AB_GADBannerView_didMoveToWindow, &ABOriginalGADBannerViewDidMoveToWindowIMP,
                               (IMP)AB_GADBannerView_setHidden, &ABOriginalGADBannerViewSetHiddenIMP,
                               (IMP)AB_GADBannerView_layoutSubviews, &ABOriginalGADBannerViewLayoutSubviewsIMP,
                               (IMP)AB_GADBannerView_setAlpha, &ABOriginalGADBannerViewSetAlphaIMP);

    // Meta Audience Network
    ABLogSwizzle(@"FBInterstitialAd.showAdFromRootViewController:",
                 ABSwizzleInstanceMethod(@"FBInterstitialAd", @selector(showAdFromRootViewController:), (IMP)AB_NoOp_WithArg, kTypesArg));
    ABLogSwizzle(@"FBRewardedVideoAd.showAdFromRootViewController:",
                 ABSwizzleInstanceMethod(@"FBRewardedVideoAd", NSSelectorFromString(@"showAdFromRootViewController:"), (IMP)AB_FBRewardedVideoAd_showAdFromRootViewController, kTypesArg));
    ABLogSwizzle(@"FBRewardedVideoAd.showAdFromRootViewController:animated:",
                 ABSwizzleInstanceMethod(@"FBRewardedVideoAd", NSSelectorFromString(@"showAdFromRootViewController:animated:"), (IMP)AB_FBRewardedVideoAd_showAdFromRootViewController_animated, kTypesArgBool));
    ABInstallHideBannerHookSet(@"FBAdView",
                               (IMP)AB_FBAdView_didMoveToWindow, &ABOriginalFBAdViewDidMoveToWindowIMP,
                               (IMP)AB_FBAdView_setHidden, &ABOriginalFBAdViewSetHiddenIMP,
                               (IMP)AB_FBAdView_layoutSubviews, &ABOriginalFBAdViewLayoutSubviewsIMP,
                               (IMP)AB_FBAdView_setAlpha, &ABOriginalFBAdViewSetAlphaIMP);

    // ironSource
    ABInstallHideBannerHookSet(@"ISBannerView",
                               (IMP)AB_ISBannerView_didMoveToWindow, &ABOriginalISBannerViewDidMoveToWindowIMP,
                               (IMP)AB_ISBannerView_setHidden, &ABOriginalISBannerViewSetHiddenIMP,
                               (IMP)AB_ISBannerView_layoutSubviews, &ABOriginalISBannerViewLayoutSubviewsIMP,
                               (IMP)AB_ISBannerView_setAlpha, &ABOriginalISBannerViewSetAlphaIMP);

    // AppLovin MAX: インタースティシャル・リワード・アプリ起動時オープン広告は同じshow系APIを共有
    ABInstallMAXFullscreenAdHooks(@"MAInterstitialAd", NO);
    // MARewardedAdはdelegate偽装(ABNotifyMAXDelegate、didClickAd:追加・ALAtomicBooleanフラグ
    // 強制まで試した)では「広告の取得に失敗しました」表示とともに報酬が付与されない問題が
    // tokyo.plott.tesの実機検証で確定した。ALMediatedFullscreenAdのadViewControllerObserver
    // DelaySeconds等のプロパティから、SDKがshow後に実際のViewController提示を別タイマーで
    // 監視しており、show自体を完全にブロックするとこの監視に失敗することが原因と判断。
    // showはブロックせず元の実装に任せ、表示直後に自動で閉じる方式に切り替えた
    // (ABInstallMAXRewardedAutoClose、上記参照)。
    ABInstallMAXRewardedAutoClose();
    // MARewardedInterstitialAd(リワード付きインタースティシャル、プレイアブルクリエイティブが
    // 配信されることもある)はREADME公開時点で対応漏れだった。Godusの実機テストで、対応済みの
    // MARewardedAd/MAInterstitialAdはブロックできているのに別の広告(AppLovinのプレイアブル)が
    // 素通りする不具合として発覚した。show系APIはMARewardedAdと共通のため同じ汎用フックで足りる。
    ABInstallMAXFullscreenAdHooks(@"MARewardedInterstitialAd", YES);
    ABInstallMAXFullscreenAdHooks(@"MAAppOpenAd", NO);
    ABInstallHideBannerHookSet(@"MAAdView",
                               (IMP)AB_MAAdView_didMoveToWindow, &ABOriginalMAAdViewDidMoveToWindowIMP,
                               (IMP)AB_MAAdView_setHidden, &ABOriginalMAAdViewSetHiddenIMP,
                               (IMP)AB_MAAdView_layoutSubviews, &ABOriginalMAAdViewLayoutSubviewsIMP,
                               (IMP)AB_MAAdView_setAlpha, &ABOriginalMAAdViewSetAlphaIMP);
    // Unity統合ではMAUnityAdManagerがロード済み広告のMAAdインスタンスを保持しているため、
    // その受け渡し口(didLoadAd:)を横取りしてキャプチャしておく(ABNotifyMAXDelegateが使う)。
    ABInstallMAUnityAdManagerCaptureHook();

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
    ABInstallHideBannerHookSetBySuffix(@"IMBanner",
                                       (IMP)AB_IMBanner_didMoveToWindow, &ABOriginalIMBannerDidMoveToWindowIMP,
                                       (IMP)AB_IMBanner_setHidden, &ABOriginalIMBannerSetHiddenIMP,
                                       (IMP)AB_IMBanner_layoutSubviews, &ABOriginalIMBannerLayoutSubviewsIMP,
                                       (IMP)AB_IMBanner_setAlpha, &ABOriginalIMBannerSetAlphaIMP);

    // AdSurgeSDK (AppLovin MAXのカスタムメディエーションネットワーク、Tencent GDTベース)
    ABInstallAdSurgeFullscreenAdHooks(@"AdSurgeInterstitialAd", NO);
    ABInstallAdSurgeFullscreenAdHooks(@"AdSurgeRewardedAd", YES);
    ABInstallAdSurgeFullscreenAdHooks(@"AdSurgeAppOpenAd", NO);
    ABInstallHideBannerHookSet(@"AdSurgeBannerAdView",
                               (IMP)AB_AdSurgeBannerAdView_didMoveToWindow, &ABOriginalAdSurgeBannerAdViewDidMoveToWindowIMP,
                               (IMP)AB_AdSurgeBannerAdView_setHidden, &ABOriginalAdSurgeBannerAdViewSetHiddenIMP,
                               (IMP)AB_AdSurgeBannerAdView_layoutSubviews, &ABOriginalAdSurgeBannerAdViewLayoutSubviewsIMP,
                               (IMP)AB_AdSurgeBannerAdView_setAlpha, &ABOriginalAdSurgeBannerAdViewSetAlphaIMP);

    // MolocoSDK: インタースティシャル/リワード共用の実体クラスPublisherFullscreenAdは
    // NSObjectを継承したSwiftクラス。ランタイム上の名前はSDKバージョンで
    // マングルされうるためサフィックス一致で解決する。MAX経由(delegateがAppLovin自前の
    // ブリッジクラス)の場合は元の実装に任せる必要があるため、original IMPを保持できる
    // KeepingOriginal版を使う(ABFindClassBySuffixでクラス自体は解決してから渡す)。
    Class molocoCls = ABFindClassBySuffix(@"PublisherFullscreenAd");
    ABLogSwizzle(@"*PublisherFullscreenAd.showFrom: (MAX-aware)",
                 ABSwizzleInstanceMethodKeepingOriginal(molocoCls, NSSelectorFromString(@"showFrom:"), (IMP)AB_Moloco_showFrom, kTypesArg, &ABOriginalMolocoShowFromIMP));
    ABLogSwizzle(@"*PublisherFullscreenAd.showFrom:muted: (MAX-aware)",
                 ABSwizzleInstanceMethodKeepingOriginal(molocoCls, NSSelectorFromString(@"showFrom:muted:"), (IMP)AB_Moloco_showFrom_muted, kTypesArgBool, &ABOriginalMolocoShowFromMutedIMP));
    ABInstallHideBannerHookSet(@"MolocoBannerAdView",
                               (IMP)AB_MolocoBannerAdView_didMoveToWindow, &ABOriginalMolocoBannerAdViewDidMoveToWindowIMP,
                               (IMP)AB_MolocoBannerAdView_setHidden, &ABOriginalMolocoBannerAdViewSetHiddenIMP,
                               (IMP)AB_MolocoBannerAdView_layoutSubviews, &ABOriginalMolocoBannerAdViewLayoutSubviewsIMP,
                               (IMP)AB_MolocoBannerAdView_setAlpha, &ABOriginalMolocoBannerAdViewSetAlphaIMP);

    // Unity Ads本体(SDK 4.x系の新API)。UADSInterstitialAd/UADSRewardedAd/UADSBannerViewは
    // "UADS"プレフィックスでObjective-Cブリッジされたクラスで、実際の表示エントリポイント。
    // AppLovin MAXのALUnityAdsMediationAdapter経由でも、結局この2クラスのshow:delegate:が呼ばれる。
    ABLogSwizzle(@"UADSInterstitialAd.show:delegate:",
                 ABSwizzleInstanceMethod(@"UADSInterstitialAd", NSSelectorFromString(@"show:delegate:"), (IMP)AB_NoOp_WithArgArg, kTypesArgArg));
    ABLogSwizzle(@"UADSRewardedAd.show:delegate:",
                 ABSwizzleInstanceMethod(@"UADSRewardedAd", NSSelectorFromString(@"show:delegate:"), (IMP)AB_UADSRewardedAd_show_delegate, kTypesArgArg));
    ABInstallHideBannerHookSet(@"UADSBannerView",
                               (IMP)AB_UADSBannerView_didMoveToWindow, &ABOriginalUADSBannerViewDidMoveToWindowIMP,
                               (IMP)AB_UADSBannerView_setHidden, &ABOriginalUADSBannerViewSetHiddenIMP,
                               (IMP)AB_UADSBannerView_layoutSubviews, &ABOriginalUADSBannerViewLayoutSubviewsIMP,
                               (IMP)AB_UADSBannerView_setAlpha, &ABOriginalUADSBannerViewSetAlphaIMP);
    // UADSBannerViewを包む中間View(SDKバージョンによって存在)。バナー自体を隠す保険として両方叩く。
    ABInstallHideBannerHookSet(@"UADSBannerWrapperView",
                               (IMP)AB_UADSBannerWrapperView_didMoveToWindow, &ABOriginalUADSBannerWrapperViewDidMoveToWindowIMP,
                               (IMP)AB_UADSBannerWrapperView_setHidden, &ABOriginalUADSBannerWrapperViewSetHiddenIMP,
                               (IMP)AB_UADSBannerWrapperView_layoutSubviews, &ABOriginalUADSBannerWrapperViewLayoutSubviewsIMP,
                               (IMP)AB_UADSBannerWrapperView_setAlpha, &ABOriginalUADSBannerWrapperViewSetAlphaIMP);
    // UADSBannerAdはロード管理を担うクラスで、displayBannerが実際の表示トリガー。
    ABLogSwizzle(@"UADSBannerAd.displayBanner",
                 ABSwizzleInstanceMethod(@"UADSBannerAd", NSSelectorFromString(@"displayBanner"), (IMP)AB_NoOp_Void, kTypesVoid));

    // Unity Ads本体のレガシー静的API。`+[UnityAds show:placementId:options:]` /
    // `+[UnityAds show:placementId:options:showDelegate:]`というクラスメソッド(インスタンスではない)。
    // UnityAdsクラス自体はSwift実装のためランタイム上の名前がSDKバージョンでマングルされうる
    // (実測値: `_TtC8UnityAds8UnityAds`)ためサフィックス一致で解決する。
    ABLogSwizzle(@"*UnityAds(class).show:placementId:options:",
                 ABSwizzleClassMethodBySuffix(@"UnityAds", NSSelectorFromString(@"show:placementId:options:"), (IMP)AB_NoOp_WithArgArgArg, kTypesArgArgArg));
    ABLogSwizzle(@"*UnityAds(class).show:placementId:options:showDelegate:",
                 ABSwizzleClassMethodBySuffix(@"UnityAds", NSSelectorFromString(@"show:placementId:options:showDelegate:"), (IMP)AB_UnityAdsClass_show_placementId_options_showDelegate, kTypesArgArgArgArg));

    // Smaato (Appodealのメディエーション先の一つ)
    ABLogSwizzle(@"SMAInterstitial.showFromViewController:",
                 ABSwizzleInstanceMethod(@"SMAInterstitial", NSSelectorFromString(@"showFromViewController:"), (IMP)AB_Smaato_showFromViewController_NoReward, kTypesArg));
    ABLogSwizzle(@"SMARewardedInterstitial.showFromViewController:",
                 ABSwizzleInstanceMethod(@"SMARewardedInterstitial", NSSelectorFromString(@"showFromViewController:"), (IMP)AB_Smaato_showFromViewController_Reward, kTypesArg));
    ABInstallHideBannerHookSet(@"SMABannerView",
                               (IMP)AB_SMABannerView_didMoveToWindow, &ABOriginalSMABannerViewDidMoveToWindowIMP,
                               (IMP)AB_SMABannerView_setHidden, &ABOriginalSMABannerViewSetHiddenIMP,
                               (IMP)AB_SMABannerView_layoutSubviews, &ABOriginalSMABannerViewLayoutSubviewsIMP,
                               (IMP)AB_SMABannerView_setAlpha, &ABOriginalSMABannerViewSetAlphaIMP);

    // Pangle (ByteDance/TikTok系。Snowで実機確認: Interstitialは現行名PAGInterstitialAdでは
    // なく旧世代命名PAGLInterstitialAdだったため両方フックする)
    ABLogSwizzle(@"PAGInterstitialAd.presentFromRootViewController:",
                 ABSwizzleInstanceMethod(@"PAGInterstitialAd", NSSelectorFromString(@"presentFromRootViewController:"), (IMP)AB_Pangle_presentFromRootViewController_NoReward, kTypesArg));
    ABLogSwizzle(@"PAGLInterstitialAd.presentFromRootViewController:",
                 ABSwizzleInstanceMethod(@"PAGLInterstitialAd", NSSelectorFromString(@"presentFromRootViewController:"), (IMP)AB_Pangle_presentFromRootViewController_NoReward, kTypesArg));
    // PAGRewardedAdはアプリ自身のPangle SDK直接利用とAppLovin MAXのPangleメディエーション
    // アダプタ経由の両方があり得るため、delegateの実クラス名で分岐する(上記
    // AB_PAGRewardedAd_presentFromRootViewController_Conditional参照)。
    ABLogSwizzle(@"PAGRewardedAd.presentFromRootViewController: (MAX-aware)",
                 ABSwizzleInstanceMethodKeepingOriginal(NSClassFromString(@"PAGRewardedAd"), NSSelectorFromString(@"presentFromRootViewController:"), (IMP)AB_PAGRewardedAd_presentFromRootViewController_Conditional, kTypesArg, &ABOriginalPAGRewardedAdPresentFromRootViewControllerIMP));
    ABInstallHideBannerHookSet(@"PAGBannerAd",
                               (IMP)AB_PAGBannerAd_didMoveToWindow, &ABOriginalPAGBannerAdDidMoveToWindowIMP,
                               (IMP)AB_PAGBannerAd_setHidden, &ABOriginalPAGBannerAdSetHiddenIMP,
                               (IMP)AB_PAGBannerAd_layoutSubviews, &ABOriginalPAGBannerAdLayoutSubviewsIMP,
                               (IMP)AB_PAGBannerAd_setAlpha, &ABOriginalPAGBannerAdSetAlphaIMP);

    // Vungle Ads SDK(新API、名前空間VungleAdsSDK。Snowで実機確認)
    ABLogSwizzle(@"VungleAdsSDK.VungleInterstitial.presentWith:",
                 ABSwizzleInstanceMethod(@"VungleAdsSDK.VungleInterstitial", NSSelectorFromString(@"presentWith:"), (IMP)AB_VungleAdsSDK_presentWith_NoReward, kTypesArg));
    ABLogSwizzle(@"VungleAdsSDK.VungleRewarded.presentWith:",
                 ABSwizzleInstanceMethod(@"VungleAdsSDK.VungleRewarded", NSSelectorFromString(@"presentWith:"), (IMP)AB_VungleAdsSDK_presentWith_Reward, kTypesArg));
    ABInstallHideBannerHookSet(@"VungleAdsSDK.VungleBannerView",
                               (IMP)AB_VungleAdsSDKBannerView_didMoveToWindow, &ABOriginalVungleAdsSDKBannerViewDidMoveToWindowIMP,
                               (IMP)AB_VungleAdsSDKBannerView_setHidden, &ABOriginalVungleAdsSDKBannerViewSetHiddenIMP,
                               (IMP)AB_VungleAdsSDKBannerView_layoutSubviews, &ABOriginalVungleAdsSDKBannerViewLayoutSubviewsIMP,
                               (IMP)AB_VungleAdsSDKBannerView_setAlpha, &ABOriginalVungleAdsSDKBannerViewSetAlphaIMP);

    // GFP (NAVER/LINE系列の自社広告プラットフォーム"Global Fit Platform"。Snowで実機確認)
    ABLogSwizzle(@"GFPInterstitialAd.show:",
                 ABSwizzleInstanceMethod(@"GFPInterstitialAd", NSSelectorFromString(@"show:"), (IMP)AB_GFPInterstitialAd_show, kTypesArg));
    ABLogSwizzle(@"GFPRewardedAd.show:",
                 ABSwizzleInstanceMethod(@"GFPRewardedAd", NSSelectorFromString(@"show:"), (IMP)AB_GFPRewardedAd_show, kTypesArg));
    ABInstallHideBannerHookSet(@"GFPBannerView",
                               (IMP)AB_GFPBannerView_didMoveToWindow, &ABOriginalGFPBannerViewDidMoveToWindowIMP,
                               (IMP)AB_GFPBannerView_setHidden, &ABOriginalGFPBannerViewSetHiddenIMP,
                               (IMP)AB_GFPBannerView_layoutSubviews, &ABOriginalGFPBannerViewLayoutSubviewsIMP,
                               (IMP)AB_GFPBannerView_setAlpha, &ABOriginalGFPBannerViewSetAlphaIMP);

    // FAD(正体不明、Snowの画面下部に実機VIEWDUMPでFADInformationIconView=iマーク本体を含む
    // ネイティブ広告レイアウトとして確認。GFPBannerViewのdidMoveToWindowが発火しなかった
    // ことから、GFPBannerViewではなくこちらが実際に使われているバナー広告の実体と推測)。
    ABInstallHideBannerHookSet(@"FADCustomLayoutBaseView",
                               (IMP)AB_FADCustomLayoutBaseView_didMoveToWindow, &ABOriginalFADCustomLayoutBaseViewDidMoveToWindowIMP,
                               (IMP)AB_FADCustomLayoutBaseView_setHidden, &ABOriginalFADCustomLayoutBaseViewSetHiddenIMP,
                               (IMP)AB_FADCustomLayoutBaseView_layoutSubviews, &ABOriginalFADCustomLayoutBaseViewLayoutSubviewsIMP,
                               (IMP)AB_FADCustomLayoutBaseView_setAlpha, &ABOriginalFADCustomLayoutBaseViewSetAlphaIMP);
    // FADCustomLayoutBaseView自身はhidden化に成功しても、その親であるFADAdViewCustomLayoutが
    // 高さ64pt分のレイアウトスペースを確保したまま画面に残り、白い帯として見え続けることを
    // 実機で確認した(Snow)。親コンテナ自体も非表示化する。
    ABInstallHideBannerHookSet(@"FADAdViewCustomLayout",
                               (IMP)AB_FADAdViewCustomLayout_didMoveToWindow, &ABOriginalFADAdViewCustomLayoutDidMoveToWindowIMP,
                               (IMP)AB_FADAdViewCustomLayout_setHidden, &ABOriginalFADAdViewCustomLayoutSetHiddenIMP,
                               (IMP)AB_FADAdViewCustomLayout_layoutSubviews, &ABOriginalFADAdViewCustomLayoutLayoutSubviewsIMP,
                               (IMP)AB_FADAdViewCustomLayout_setAlpha, &ABOriginalFADAdViewCustomLayoutSetAlphaIMP);

    // 診断: 広告関連クラスの登録状況をログに残す。ABInstallThirdPartyAdHooks自体は
    // dyldの新規イメージロード通知のたびに何度も呼ばれうる(ABConstructor.m参照)ため、
    // 全クラスを毎回スキャンするこの処理はdispatch_onceで1回だけに制限する。
    static dispatch_once_t scanOnceToken;
    dispatch_once(&scanOnceToken, ^{
        ABLogSuspiciousAdClasses();
        // Snow調査用: GFPInterstitialAd/GFPRewardedAdのshowFromRootViewController:フックが
        // NGだったため、正しいメソッド名と、Snowアプリ自身のGFPラッパー(YRInterstitialPopupGFPAd
        // 等、実際の表示エントリーポイントである可能性)のメソッド名を確認する。
        ABLogAllMethods(@"GFPInterstitialAd");
        ABLogAllMethods(@"GFPRewardedAd");
        ABLogAllMethods(@"YRInterstitialPopupGFPAd");
        ABLogAllMethods(@"YRInterstitialRewardGFPAd");
        ABLogAllMethods(@"YRInterstitialDaroAd");
        ABLogAllMethods(@"YRKBannerGFPAd");
        ABLogAllProperties(@"YRKBannerGFPAd");
        // GFPInterstitialAd.show:/GFPRewardedAd.show:はフックできているのに発火しなかった。
        // YRInterstitialPopupGFPAd/YRInterstitialRewardGFPAdのメソッド名(interstitialAdManager:
        // didXXX:)から、実際の表示要求はGFPInterstitialAdManager/GFPRewardedAdManager経由で
        // 行われ、show:はそこから内部的に呼ばれる別の経路の可能性がある。Managerクラス自体の
        // メソッド一覧を調べる。
        ABLogAllMethods(@"GFPInterstitialAdManager");
        ABLogAllMethods(@"GFPRewardedAdManager");
    });
}
