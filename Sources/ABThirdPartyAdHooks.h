#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 主要サードパーティ広告SDK(存在するものだけ)の「表示」トリガーをno-op化する。
/// SDKの初期化・ロード処理には触れない(存在しないクラスへの静的%hookはクラッシュの原因になるため
/// 実行時にNSClassFromStringで確認してから動的にhookする)。
void ABInstallThirdPartyAdHooks(void);

/// 診断用: 画面下部(下40%)に実際に見えている(hidden=NOかつalpha>0の)Viewのクラス名・frameを
/// ログに書き出す。非表示化フックが本当に正しいクラスを捉えているか、それとも別のクラスが
/// 表示の実体なのかを直接特定するための最終手段。メインスレッドから呼ぶこと。
void ABDumpVisibleBottomViews(void);

NS_ASSUME_NONNULL_END
