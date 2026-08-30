#import "ABSwizzle.h"

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
    Class cls = NSClassFromString(className);
    return ABAddOrReplaceInstanceMethod(cls, selector, newImp, types);
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
    Class cls = ABFindClassBySuffix(classNameSuffix);
    return ABAddOrReplaceInstanceMethod(cls, selector, newImp, types);
}

BOOL ABSwizzleClassMethod(NSString *className, SEL selector, IMP newImp, const char *types) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        return NO;
    }
    return ABAddOrReplaceInstanceMethod(object_getClass(cls), selector, newImp, types);
}

BOOL ABSwizzleClassMethodBySuffix(NSString *classNameSuffix, SEL selector, IMP newImp, const char *types) {
    Class cls = ABFindClassBySuffix(classNameSuffix);
    if (!cls) {
        return NO;
    }
    return ABAddOrReplaceInstanceMethod(object_getClass(cls), selector, newImp, types);
}

BOOL ABSwizzleInstanceMethodKeepingOriginal(Class cls, SEL selector, IMP newImp, const char *types, IMP *originalImpOut) {
    if (!cls) {
        return NO;
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
    return YES;
}
