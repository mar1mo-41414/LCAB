#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// アプリのDocuments/lcadblocker.log に追記する簡易ログ。
/// 診断のため、フックの発火・インストール成否を記録する。
void ABDebugLog(NSString *format, ...);

NS_ASSUME_NONNULL_END
