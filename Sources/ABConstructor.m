#import "ABStoreKitHooks.h"
#import "ABThirdPartyAdHooks.h"
#import "ABDebugLog.h"
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>

static void ABReinstallAllHooks(void) {
    ABInstallStoreKitHooks();
    ABInstallThirdPartyAdHooks();
}

/// dyldが新しい共有ライブラリ/フレームワークをロードするたびに呼ばれる。
/// Appodealのようなメディエーションプラットフォームでは、個々の広告ネットワークSDK
/// (AppLovinSDK.frameworkなど)がアプリ起動時ではなく、メディエーション側の初期化タイミング
/// (Unity C#コード実行後など、didFinishLaunchingよりずっと後)まで実際にロードされない
/// ことがあり、constructor+didFinishLaunchingの2点キャプチャだけでは間に合わない
/// (Autodiggersで実際に確認: 全フックがclass not foundのまま失敗し続けていた)。
/// これを取りこぼさないよう、以後にロードされる全イメージに対して再インストールを試みる。
/// _dyld_register_func_for_add_imageは登録時点で既にロード済みの全イメージについても
/// 遡ってコールバックするため、初回分の重複は問題ない(NSClassFromStringベースの
/// インストールは何度実行しても安全)。
///
/// アプリ起動時には数百の共有ライブラリ(システムライブラリ含む)がロードされることがあり、
/// 素朴に毎回メインキューへ再インストールタスクを積むと、そのタスクの山でメインスレッドが
/// 埋め尽くされアプリが実質フリーズしたまま起動できなくなる不具合が実際に発生した
/// (Autodiggers)。そのため「既にメインキューに再インストールタスクが積まれている間は
/// 新たに積まない」というコアレッシングを行う(ABSwizzle側の成功キャッシュと合わせて、
/// 1回の再インストール処理自体もイメージロードのたびに軽くなっていく)。
static void ABOnImageAdded(const struct mach_header *mh, intptr_t vmaddr_slide) {
    static BOOL pending = NO;
    static NSObject *lock;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        lock = [NSObject new];
    });
    @synchronized (lock) {
        if (pending) {
            return;
        }
        pending = YES;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized (lock) {
            pending = NO;
        }
        ABReinstallAllHooks();
    });
}

__attribute__((constructor))
static void ABEntryPoint(void) {
    ABDebugLog(@"=== LCAdBlocker constructor: initial install pass ===");
    ABReinstallAllHooks();

    // アプリ起動完了後にもう一度試みる(保険)。
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                        object:nil
                                                         queue:[NSOperationQueue mainQueue]
                                                    usingBlock:^(NSNotification * _Nonnull note) {
        ABDebugLog(@"=== LCAdBlocker: didFinishLaunching re-install pass ===");
        ABReinstallAllHooks();
    }];

    // 遅延ロードされる広告ネットワークSDKを取りこぼさないための本命の仕組み。
    _dyld_register_func_for_add_image(ABOnImageAdded);

    // 診断用: 非表示化フックが本当に正しいクラスを捉えているのか、画面下部に実際に
    // 見えているViewを定期的にダンプして確認する(StoneGrassでMAAdView.hidden=YESに
    // なっているはずのバナーが消えない問題の調査用)。Snowはアプリ起動直後ではなく
    // シャッター後の保存/編集選択画面まで遷移してからバナーが出るため、30秒では
    // 監視期間が足りなかった。5秒おき、2分間に延長する。
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                        object:nil
                                                         queue:[NSOperationQueue mainQueue]
                                                    usingBlock:^(NSNotification * _Nonnull note) {
        __block NSInteger remainingTicks = 24;
        __block NSTimer *timer = nil;
        timer = [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(NSTimer * _Nonnull t) {
            ABDumpVisibleBottomViews();
            remainingTicks--;
            if (remainingTicks <= 0) {
                [t invalidate];
            }
        }];
        (void)timer;
    }];
}
