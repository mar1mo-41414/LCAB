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
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) {
        return nil;
    }
    Class *classes = (Class *)malloc(sizeof(Class) * (unsigned long)count);
    if (!classes) {
        return nil;
    }
    count = objc_getClassList(classes, count);
    Class found = nil;
    for (int i = 0; i < count; i++) {
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
