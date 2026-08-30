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
