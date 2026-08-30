#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

/// クラス・セレクタが実行時に存在する場合のみインスタンスメソッドの実装を差し替える。
/// サードパーティSDKは端末/ビルドによってクラスが存在しないことがあるため、
/// 静的%hookではなく実行時チェック付きで安全に差し替える。
/// 差し替えに成功した場合はYESを返す。
BOOL ABSwizzleInstanceMethod(NSString *className, SEL selector, IMP newImp);

NS_ASSUME_NONNULL_END
