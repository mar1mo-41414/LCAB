// Includes implementation to inspect pending-state gating without presenting an ad.
// Compile this file with ABSwizzle.m and ABDebugLog.m, NOT ABThirdPartyAdHooks.m.
#import "../Sources/ABThirdPartyAdHooks.m"

@interface MockMAXAd : NSObject
@property(nonatomic, strong) NSString *format;
@end
@implementation MockMAXAd
@end
@interface MockMAXDelegate : NSObject
@property(nonatomic) NSUInteger displays;
- (void)didDisplayAd:(id)ad;
@end
@implementation MockMAXDelegate
- (void)didDisplayAd:(id)ad { self.displays++; }
@end
@interface DerivedMAXDelegate : MockMAXDelegate
@end
@implementation DerivedMAXDelegate
- (void)didDisplayAd:(id)ad { [super didDisplayAd:ad]; }
@end
@interface MockRewardedOwner : NSObject
@property(nonatomic, strong) id delegate;
@end
@implementation MockRewardedOwner
@end
static BOOL Pending(id delegate) {
    return [objc_getAssociatedObject(delegate, &ABMAXRewardedDisplayPendingKey) boolValue];
}
int main(void) {
    @autoreleasepool {
        MockRewardedOwner *owner = [MockRewardedOwner new];
        MockMAXDelegate *delegate = [MockMAXDelegate new];
        owner.delegate = delegate;
        ABMAXPrepareRewardedDelegate(owner);
        ABMAXPrepareRewardedDelegate(owner); // show overload delegation/retry
        NSCAssert(Pending(delegate), @"show must arm the actual delegate");
        MockMAXAd *ad = [MockMAXAd new];
        ad.format = @"INTERSTITIAL";
        [delegate didDisplayAd:ad];
        NSCAssert(delegate.displays == 1 && Pending(delegate), @"unrelated formats must not consume pending reward");
        ad.format = @"REWARDED";
        [delegate didDisplayAd:ad];
        NSCAssert(delegate.displays == 2 && !Pending(delegate), @"original callback once; consume pending once");
        [delegate didDisplayAd:ad];
        NSCAssert(delegate.displays == 3 && !Pending(delegate), @"repeated callback cannot rearm");
        MockMAXDelegate *unarmed = [MockMAXDelegate new];
        [unarmed didDisplayAd:ad];
        NSCAssert(unarmed.displays == 1 && !Pending(unarmed), @"same-class unarmed instance unaffected");
        DerivedMAXDelegate *derived = [DerivedMAXDelegate new];
        owner.delegate = derived;
        ABMAXPrepareRewardedDelegate(owner);
        [derived didDisplayAd:ad];
        NSCAssert(derived.displays == 1 && !Pending(derived), @"override calling hooked super must not recurse or double-consume");
        owner.delegate = [NSObject new];
        ABMAXPrepareRewardedDelegate(owner);
        NSCAssert(![owner.delegate respondsToSelector:@selector(didDisplayAd:)], @"must not add optional callback");
        owner.delegate = nil;
        ABMAXPrepareRewardedDelegate(owner);
        NSLog(@"MAX rewarded delegate gating tests passed");
        // No run-loop drain: real SDK/UI auto-close is a separate device test.
    }
    return 0;
}
