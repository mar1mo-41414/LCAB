#import "ABDebugLog.h"

static NSString *ABLogFilePath(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"lcadblocker.log"];
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
        NSString *path = ABLogFilePath();
        NSFileManager *fm = [NSFileManager defaultManager];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (![fm fileExistsAtPath:path]) {
            [fm createFileAtPath:path contents:data attributes:nil];
        } else {
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
            [handle seekToEndOfFile];
            [handle writeData:data];
            [handle closeFile];
        }
    }
}
