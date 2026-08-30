#import "ABStoreKitHooks.h"
#import "ABThirdPartyAdHooks.h"
#import "ABDebugLog.h"
#import <UIKit/UIKit.h>

__attribute__((constructor))
static void ABEntryPoint(void) {
    ABDebugLog(@"=== LCAdBlocker constructor: initial install pass ===");
    ABInstallStoreKitHooks();
    ABInstallThirdPartyAdHooks();

    // UnityFrameworkのような追加dylibが、このdylibのconstructor実行時点ではまだ
    // ロード/クラス登録されていない可能性への保険として、アプリ起動完了後にもう一度試みる。
    // method_setImplementationは何度実行しても安全(既に自分の実装なら同じものを再設定するだけ)。
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                        object:nil
                                                         queue:[NSOperationQueue mainQueue]
                                                    usingBlock:^(NSNotification * _Nonnull note) {
        ABDebugLog(@"=== LCAdBlocker: didFinishLaunching re-install pass ===");
        ABInstallStoreKitHooks();
        ABInstallThirdPartyAdHooks();
    }];
}
