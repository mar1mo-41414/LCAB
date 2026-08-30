#import "ABSwizzle.h"

BOOL ABSwizzleInstanceMethod(NSString *className, SEL selector, IMP newImp) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        return NO;
    }
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        return NO;
    }
    method_setImplementation(method, newImp);
    return YES;
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

BOOL ABSwizzleInstanceMethodBySuffix(NSString *classNameSuffix, SEL selector, IMP newImp) {
    Class cls = ABFindClassBySuffix(classNameSuffix);
    if (!cls) {
        return NO;
    }
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        return NO;
    }
    method_setImplementation(method, newImp);
    return YES;
}

BOOL ABSwizzleClassMethod(NSString *className, SEL selector, IMP newImp) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        return NO;
    }
    Method method = class_getClassMethod(cls, selector);
    if (!method) {
        return NO;
    }
    method_setImplementation(method, newImp);
    return YES;
}

BOOL ABSwizzleClassMethodBySuffix(NSString *classNameSuffix, SEL selector, IMP newImp) {
    Class cls = ABFindClassBySuffix(classNameSuffix);
    if (!cls) {
        return NO;
    }
    Method method = class_getClassMethod(cls, selector);
    if (!method) {
        return NO;
    }
    method_setImplementation(method, newImp);
    return YES;
}
