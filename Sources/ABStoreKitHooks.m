#import "ABStoreKitHooks.h"
#import "ABSwizzle.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - SKStoreProductViewController: loadProductWithParameters:completionBlock:

/// 実処理(ネットワーク越しの商品情報取得)を一切呼ばず、失敗扱いのcompletionBlockだけ即座に呼ぶ。
static void AB_loadProductWithParameters_completionBlock(id self, SEL _cmd, NSDictionary *parameters, void (^completionBlock)(BOOL result, NSError *error)) {
    if (completionBlock) {
        NSError *error = [NSError errorWithDomain:@"LCAdBlocker" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Blocked by LCAdBlocker"}];
        completionBlock(NO, error);
    }
}

#pragma mark - SKStoreProductViewController: viewDidAppear: (保険)

/// presentViewController:のhookをすり抜けて画面に出てしまった場合の保険として、
/// 表示直後に自身をdismissする。UIKit側の状態管理を壊さないようsuper実装は呼ぶ。
static void AB_SKStoreProductViewController_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    Method superMethod = class_getInstanceMethod([UIViewController class], @selector(viewDidAppear:));
    if (superMethod) {
        IMP superImp = method_getImplementation(superMethod);
        ((void (*)(id, SEL, BOOL))superImp)(self, _cmd, animated);
    }
    [self dismissViewControllerAnimated:NO completion:nil];
}

#pragma mark - UIViewController: presentViewController:animated:completion:

/// SKStoreProductViewController(単体、またはUINavigationControllerに包まれたもの)の
/// present呼び出しをそもそも素通りさせない。それ以外は元の実装をそのまま呼ぶ。
static IMP ABOriginalPresentViewControllerIMP = NULL;

static BOOL ABIsBlockedStoreViewController(UIViewController *viewController) {
    Class skStoreClass = NSClassFromString(@"SKStoreProductViewController");
    if (!skStoreClass) {
        return NO;
    }
    if ([viewController isKindOfClass:skStoreClass]) {
        return YES;
    }
    if ([viewController isKindOfClass:[UINavigationController class]]) {
        UIViewController *root = ((UINavigationController *)viewController).viewControllers.firstObject;
        return root != nil && [root isKindOfClass:skStoreClass];
    }
    return NO;
}

static void AB_presentViewController_animated_completion(UIViewController *self, SEL _cmd, UIViewController *viewControllerToPresent, BOOL animated, void (^completion)(void)) {
    if (ABIsBlockedStoreViewController(viewControllerToPresent)) {
        if (completion) {
            completion();
        }
        return;
    }
    if (ABOriginalPresentViewControllerIMP) {
        ((void (*)(id, SEL, UIViewController *, BOOL, void (^)(void)))ABOriginalPresentViewControllerIMP)(self, _cmd, viewControllerToPresent, animated, completion);
    }
}

#pragma mark - SKOverlay: presentInScene:

/// iOS14+のバナー型「入手」オーバーレイ。表示要求そのものを握りつぶす。
static void AB_SKOverlay_presentInScene(id self, SEL _cmd, id scene) {
    // no-op: 何も表示しない
}

#pragma mark - Install

void ABInstallStoreKitHooks(void) {
    // SKStoreProductViewControllerは通常このセレクタを独自実装しないので、
    // class_getInstanceMethodはUIViewController(または中間クラス)の実装を返してしまう。
    // ABSwizzleInstanceMethodはclass_addMethodで対象クラス専用の実装として追加するため、
    // 継承元(全UIViewControllerのviewDidAppear:)を巻き込まない。
    ABSwizzleInstanceMethod(@"SKStoreProductViewController",
                             @selector(loadProductWithParameters:completionBlock:),
                             (IMP)AB_loadProductWithParameters_completionBlock,
                             "v@:@@?");

    ABSwizzleInstanceMethod(@"SKStoreProductViewController",
                             @selector(viewDidAppear:),
                             (IMP)AB_SKStoreProductViewController_viewDidAppear,
                             "v@:B");

    // UIViewController自身が対象なので継承元を巻き込む心配はないが、実装を統一するため
    // 同じ安全なヘルパー経由で差し替える。
    ABSwizzleInstanceMethodKeepingOriginal([UIViewController class],
                                            @selector(presentViewController:animated:completion:),
                                            (IMP)AB_presentViewController_animated_completion,
                                            "v@:@B@?",
                                            &ABOriginalPresentViewControllerIMP);

    ABSwizzleInstanceMethod(@"SKOverlay",
                             @selector(presentInScene:),
                             (IMP)AB_SKOverlay_presentInScene,
                             "v@:@");
}
