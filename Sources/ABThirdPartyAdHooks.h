#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 主要サードパーティ広告SDK(存在するものだけ)の「表示」トリガーをno-op化する。
/// SDKの初期化・ロード処理には触れない(存在しないクラスへの静的%hookはクラッシュの原因になるため
/// 実行時にNSClassFromStringで確認してから動的にhookする)。
void ABInstallThirdPartyAdHooks(void);

NS_ASSUME_NONNULL_END
