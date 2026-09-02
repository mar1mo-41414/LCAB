#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// アプリのDocuments/lcadblocker.log に書き出す簡易ログ。
/// プロセス起動のたびにファイルを上書きするので、常に直近の起動分のみが残る。
/// 診断のため、フックの発火・インストール成否を記録する。
void ABDebugLog(NSString *format, ...);

NS_ASSUME_NONNULL_END
