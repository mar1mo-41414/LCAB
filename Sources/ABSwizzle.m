#import "ABSwizzle.h"

/// 一度成功したフックは二度と試みない(NSClassFromString/objc_getClassListの再実行やログ出力の
/// コストを避ける)。dyldが新しい共有ライブラリをロードするたびにインストール処理全体を
/// 再実行する仕組み(ABConstructor.m参照)と組み合わせて使うため必須。これがないと、
/// アプリ起動時に大量にロードされる共有ライブラリの数だけ毎回全フックを試み直すことになり、
/// メインスレッドがファイルI/Oとクラス検索で埋め尽くされ、アプリが実質フリーズしたまま
/// 起動できなくなる不具合が実際に発生した(Autodiggersで確認)。
static NSMutableSet<NSString *> *ABSuccessCache(void) {
    static NSMutableSet<NSString *> *cache;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        cache = [NSMutableSet set];
    });
    return cache;
}

static BOOL ABCacheContains(NSString *key) {
    NSMutableSet *cache = ABSuccessCache();
    @synchronized (cache) {
        return [cache containsObject:key];
    }
}

static void ABCacheAdd(NSString *key) {
    NSMutableSet *cache = ABSuccessCache();
    @synchronized (cache) {
        [cache addObject:key];
    }
}

/// class_addMethodで対象クラス自身に新規実装として追加を試み、追加できなければ(=既にそのクラス
/// 自身がオーバーライド済みなら)method_setImplementationで直接差し替える。cls自体がnilなら失敗。
static BOOL ABAddOrReplaceInstanceMethod(Class cls, SEL selector, IMP newImp, const char *types) {
    if (!cls) {
        return NO;
    }
    Method existingMethod = class_getInstanceMethod(cls, selector);
    if (!existingMethod) {
        return NO;
    }
    BOOL added = class_addMethod(cls, selector, newImp, types);
    if (!added) {
        Method ownMethod = class_getInstanceMethod(cls, selector);
        method_setImplementation(ownMethod, newImp);
    }
    return YES;
}

BOOL ABSwizzleInstanceMethod(NSString *className, SEL selector, IMP newImp, const char *types) {
    NSString *key = [NSString stringWithFormat:@"instance|%@|%@", className, NSStringFromSelector(selector)];
    if (ABCacheContains(key)) {
        return YES;
    }
    Class cls = NSClassFromString(className);
    BOOL ok = ABAddOrReplaceInstanceMethod(cls, selector, newImp, types);
    if (ok) {
        ABCacheAdd(key);
    }
    return ok;
}

Class ABFindClassBySuffix(NSString *suffix) {
    int bufferCount = objc_getClassList(NULL, 0);
    if (bufferCount <= 0) {
        return nil;
    }
    Class *classes = (Class *)malloc(sizeof(Class) * (unsigned long)bufferCount);
    if (!classes) {
        return nil;
    }
    // objc_getClassListの戻り値は「登録されている全クラス数」であり、呼び出し間に
    // 新しいクラスが増えているとbufferCountより大きくなりうる。それをそのままループ上限に
    // 使うとmalloc確保分を超えて読み取ってしまう(未定義動作、他クラスの誤検出)ため、
    // 実際にバッファへ書き込まれた数(=bufferCountとの小さい方)に必ずクランプする。
    int actualCount = objc_getClassList(classes, bufferCount);
    int limit = actualCount < bufferCount ? actualCount : bufferCount;
    Class found = nil;
    for (int i = 0; i < limit; i++) {
        const char *name = class_getName(classes[i]);
        if (name && [@(name) hasSuffix:suffix]) {
            found = classes[i];
            break;
        }
    }
    free(classes);
    return found;
}

BOOL ABSwizzleInstanceMethodBySuffix(NSString *classNameSuffix, SEL selector, IMP newImp, const char *types) {
    NSString *key = [NSString stringWithFormat:@"instanceSuffix|%@|%@", classNameSuffix, NSStringFromSelector(selector)];
    if (ABCacheContains(key)) {
        return YES;
    }
    Class cls = ABFindClassBySuffix(classNameSuffix);
    BOOL ok = ABAddOrReplaceInstanceMethod(cls, selector, newImp, types);
    if (ok) {
        ABCacheAdd(key);
    }
    return ok;
}

BOOL ABSwizzleClassMethod(NSString *className, SEL selector, IMP newImp, const char *types) {
    NSString *key = [NSString stringWithFormat:@"class|%@|%@", className, NSStringFromSelector(selector)];
    if (ABCacheContains(key)) {
        return YES;
    }
    Class cls = NSClassFromString(className);
    if (!cls) {
        return NO;
    }
    BOOL ok = ABAddOrReplaceInstanceMethod(object_getClass(cls), selector, newImp, types);
    if (ok) {
        ABCacheAdd(key);
    }
    return ok;
}

BOOL ABSwizzleClassMethodBySuffix(NSString *classNameSuffix, SEL selector, IMP newImp, const char *types) {
    NSString *key = [NSString stringWithFormat:@"classSuffix|%@|%@", classNameSuffix, NSStringFromSelector(selector)];
    if (ABCacheContains(key)) {
        return YES;
    }
    Class cls = ABFindClassBySuffix(classNameSuffix);
    if (!cls) {
        return NO;
    }
    BOOL ok = ABAddOrReplaceInstanceMethod(object_getClass(cls), selector, newImp, types);
    if (ok) {
        ABCacheAdd(key);
    }
    return ok;
}

BOOL ABSwizzleInstanceMethodKeepingOriginal(Class cls, SEL selector, IMP newImp, const char *types, IMP *originalImpOut) {
    if (!cls) {
        return NO;
    }
    NSString *key = [NSString stringWithFormat:@"keepOrig|%s|%@", class_getName(cls), NSStringFromSelector(selector)];
    if (ABCacheContains(key)) {
        return YES;
    }
    Method existingMethod = class_getInstanceMethod(cls, selector);
    if (!existingMethod) {
        return NO;
    }
    if (originalImpOut) {
        *originalImpOut = method_getImplementation(existingMethod);
    }
    BOOL added = class_addMethod(cls, selector, newImp, types);
    if (!added) {
        Method ownMethod = class_getInstanceMethod(cls, selector);
        method_setImplementation(ownMethod, newImp);
    }
    ABCacheAdd(key);
    return YES;
}
