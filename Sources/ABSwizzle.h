#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

/// クラス・セレクタが実行時に存在する場合のみインスタンスメソッドの実装を差し替える。
/// サードパーティSDKは端末/ビルドによってクラスが存在しないことがあるため、
/// 静的%hookではなく実行時チェック付きで安全に差し替える。
/// 差し替えに成功した場合はYESを返す。
BOOL ABSwizzleInstanceMethod(NSString *className, SEL selector, IMP newImp);

/// クラス名が指定したサフィックスで終わる、実行時に登録済みのクラスを探す。
/// SwiftのSDK(InMobiなど)はObjective-Cランタイム上のクラス名が
/// `_TtC9ModuleName14ClassName`のようにモジュール名を含む形でマングルされ、
/// SDKバージョン(モジュール名/クラス名の文字数)によって変化しうるため、
/// 完全一致ではなくサフィックス一致で探す。
Class _Nullable ABFindClassBySuffix(NSString *suffix);

/// ABFindClassBySuffixで見つけたクラスに対してABSwizzleInstanceMethodと同様の差し替えを行う。
BOOL ABSwizzleInstanceMethodBySuffix(NSString *classNameSuffix, SEL selector, IMP newImp);

/// ABSwizzleInstanceMethodのクラスメソッド版(例: `+[UnityAds show:placementId:options:]`のような
/// レガシーな静的APIの表示トリガー)。
BOOL ABSwizzleClassMethod(NSString *className, SEL selector, IMP newImp);

/// ABSwizzleClassMethodのサフィックス一致版。
BOOL ABSwizzleClassMethodBySuffix(NSString *classNameSuffix, SEL selector, IMP newImp);

NS_ASSUME_NONNULL_END
