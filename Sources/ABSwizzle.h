#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

/// クラス・セレクタが実行時に存在する場合のみメソッドの実装を差し替える。
///
/// `types`は差し替えるメソッドのObjective-C型エンコーディング(例: 引数なしvoidメソッドなら
/// `"v@:"`)。対象クラス自身がそのセレクタを実装していない場合(=親クラスから継承しているだけの
/// 場合)、`class_getInstanceMethod`は親クラスのMethodを返すため、それを`method_setImplementation`
/// で直接書き換えると親クラス(UIViewなど、多数のクラスが継承する基底クラス)ごと壊してしまう。
/// これを避けるため、まず`class_addMethod`で対象クラス自身に新規実装として追加を試み、
/// 追加できた場合(=継承していただけ)はそれで終わり、既にそのクラス自身がオーバーライド済みで
/// 追加できなかった場合のみ`method_setImplementation`で直接差し替える。
///
/// サードパーティSDKは端末/ビルドによってクラスが存在しないことがあるため、
/// 静的%hookではなく実行時チェック付きで安全に差し替える。差し替えに成功した場合はYESを返す。
BOOL ABSwizzleInstanceMethod(NSString *className, SEL selector, IMP newImp, const char *types);

/// クラス名が指定したサフィックスで終わる、実行時に登録済みのクラスを探す。
/// SwiftのSDK(InMobiなど)はObjective-Cランタイム上のクラス名が
/// `_TtC9ModuleName14ClassName`のようにモジュール名を含む形でマングルされ、
/// SDKバージョン(モジュール名/クラス名の文字数)によって変化しうるため、
/// 完全一致ではなくサフィックス一致で探す。
Class _Nullable ABFindClassBySuffix(NSString *suffix);

/// ABFindClassBySuffixで見つけたクラスに対してABSwizzleInstanceMethodと同様の差し替えを行う。
BOOL ABSwizzleInstanceMethodBySuffix(NSString *classNameSuffix, SEL selector, IMP newImp, const char *types);

/// ABSwizzleInstanceMethodのクラスメソッド版(例: `+[UnityAds show:placementId:options:]`のような
/// レガシーな静的APIの表示トリガー)。継承元への誤爆を避ける仕組みはインスタンスメソッド版と同じ
/// (メタクラスに対して同様の処理を行う)。
BOOL ABSwizzleClassMethod(NSString *className, SEL selector, IMP newImp, const char *types);

/// ABSwizzleClassMethodのサフィックス一致版。
BOOL ABSwizzleClassMethodBySuffix(NSString *classNameSuffix, SEL selector, IMP newImp, const char *types);

/// didMoveToWindowのような「対象クラス自身がオーバーライドしているとは限らない」インスタンス
/// メソッドを安全に差し替え、差し替え前の実装(継承元のものである場合を含む)を`originalImpOut`に
/// 返す。バナー広告Viewの非表示化フックのように、元の実装を呼んでから追加処理をしたい場合に使う。
BOOL ABSwizzleInstanceMethodKeepingOriginal(Class _Nullable cls, SEL selector, IMP newImp, const char *types, IMP _Nullable * _Nonnull originalImpOut);

NS_ASSUME_NONNULL_END
