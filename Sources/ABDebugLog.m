#import "ABDebugLog.h"

static NSString *ABLogFilePath(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"lcadblocker.log"];
}

/// プロセス起動ごとにログファイルを新規作成し(=前回起動分は破棄)、
/// そのファイルハンドルを使い回す。以前は1行書き出すたびに
/// open/seek/write/closeをフルで行っており、609クラスの診断ダンプのような
/// 大量ログ出力時にメインスレッドを長時間拘束しうる実装だった。
static NSFileHandle *ABLogFileHandle(void) {
    static NSFileHandle *handle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = ABLogFilePath();
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:path error:nil];
        [fm createFileAtPath:path contents:nil attributes:nil];
        handle = [NSFileHandle fileHandleForWritingAtPath:path];
    });
    return handle;
}

void ABDebugLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"HH:mm:ss.SSS";
    });
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [formatter stringFromDate:[NSDate date]], message];

    @synchronized ([NSFileManager defaultManager]) {
        NSFileHandle *handle = ABLogFileHandle();
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    }
}
