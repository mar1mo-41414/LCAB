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
static void ABOnImageAdded(const struct mach_header *mh, intptr_t vmaddr_slide) {
    dispatch_async(dispatch_get_main_queue(), ^{
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
}
