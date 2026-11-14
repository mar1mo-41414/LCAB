// iOS Simulator regression for safe banner hiding without an AdMob SDK.
#import <UIKit/UIKit.h>
#import "ABThirdPartyAdHooks.h"

static NSUInteger moveCalls;
static NSUInteger removalCalls;
@interface GADBannerView : UIView
@end
@implementation GADBannerView
- (void)didMoveToWindow {
    [super didMoveToWindow];
    moveCalls++;
}
- (void)removeFromSuperview {
    removalCalls++;
    [super removeFromSuperview];
}
@end

int main(void) {
    @autoreleasepool {
        ABInstallThirdPartyAdHooks();
        ABInstallThirdPartyAdHooks();
        UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 320, 640)];
        UIView *parent = [[UIView alloc] initWithFrame:window.bounds];
        UIView *sibling = [UIView new];
        GADBannerView *banner = [GADBannerView new];
        UIView *content = [UIView new];
        banner.translatesAutoresizingMaskIntoConstraints = NO;
        [banner addSubview:content];
        [parent addSubview:sibling];
        [parent addSubview:banner];
        [NSLayoutConstraint activateConstraints:@[
            [banner.centerXAnchor constraintEqualToAnchor:parent.centerXAnchor],
            [banner.bottomAnchor constraintEqualToAnchor:parent.bottomAnchor],
            [banner.widthAnchor constraintEqualToConstant:320],
            [banner.heightAnchor constraintEqualToConstant:50]
        ]];
        [window addSubview:parent]; // exercises real window-movement notifications
        NSCAssert(moveCalls > 0, @"original didMoveToWindow must run");
        for (NSUInteger i = 0; i < 3; i++) {
            banner.hidden = NO;
            banner.alpha = 1;
            [banner setNeedsLayout];
            [parent setNeedsLayout];
            [parent layoutIfNeeded];
            [banner layoutIfNeeded];
            NSCAssert(banner.superview == parent && banner.window == window, @"must retain banner hierarchy");
            NSCAssert(removalCalls == 0, @"LCAB must never remove the banner");
            NSCAssert(banner.hidden && banner.layer.hidden && banner.layer.opacity == 0, @"must remain hidden");
            NSCAssert(content.hidden, @"banner content must be hidden");
            NSCAssert(!parent.hidden && !sibling.hidden, @"unrelated UI must be unchanged");
        }
        // Normal SDK/app removal remains possible, but does not trigger LCAB removal.
        [banner removeFromSuperview];
        NSCAssert(removalCalls == 1 && banner.superview == nil, @"normal removal must remain available");
        [parent addSubview:banner];
        NSCAssert(removalCalls == 1 && banner.superview == parent, @"reattachment must not cause removal recursion");
        sibling.hidden = NO;
        sibling.alpha = 1;
        NSCAssert(!sibling.hidden && sibling.alpha == 1, @"UIView base methods must remain intact");
        NSLog(@"AdMob banner hierarchy tests passed");
    }
    return 0;
}
