# LCAdBlocker Technical Details

[日本語版 →](TECHNICAL.md)

This document explains the implementation for developers. For installation and usage, see
[README.md](../README-EN.md).

## Source layout

| File | Role |
|---|---|
| `Sources/ABSwizzle.{h,m}` | shared helper that swaps an IMP only after confirming the class/selector exist at runtime |
| `Sources/ABStoreKitHooks.{h,m}` | hooks for Apple's native StoreKit mechanisms |
| `Sources/ABThirdPartyAdHooks.{h,m}` | hooks for third-party ad SDKs |
| `Sources/ABDebugLog.{h,m}` | lightweight diagnostic logger (`Documents/lcadblocker.log`) |
| `Sources/ABConstructor.m` | entry point (`__attribute__((constructor))`) |

## Why not CydiaSubstrate

LiveContainer's in-process injection environment can't assume CydiaSubstrate is available, so
this uses plain Objective-C runtime method swizzling instead of Logos (`%hook`). Same approach as
the sister project [LCME (iOS_LC_MemEditor)](https://github.com/mar1mo-41414/LCME).

## Hook installation timing

Hooks are installed automatically on dylib load via `__attribute__((constructor))`, and the same
install pass runs a second time after `UIApplicationDidFinishLaunchingNotification` (an extra
dylib like UnityFramework may not have loaded/registered its classes yet at constructor time). On
top of that, `_dyld_register_func_for_add_image` re-runs the install pass for every shared
library/framework loaded afterward.

On mediation platforms like Appodeal, individual ad network SDKs (e.g. `AppLovinSDK.framework`)
may not actually get loaded at app launch at all — only once the mediation layer initializes them,
which can happen well after `didFinishLaunching` (e.g. after Unity's own C# code starts running) —
so the two earlier capture points alone miss them.

That said, an app launch can load hundreds of shared libraries (including system ones), and a
naive "re-try every hook from scratch every time" implementation actually caused the app to hang
and never finish launching, buried under a pile of queued reinstall tasks. Two mitigations fix
this:

1. `ABSwizzle` keeps a success cache — a hook that already succeeded is never retried, so repeated
   `NSClassFromString` lookups and class-list rescans are skipped
2. The dyld callback itself is coalesced — while a reinstall task is already queued on the main
   queue, new image-load events don't queue another one

Together, the work done per image load gets lighter over time.

## Preferring `class_addMethod` over a direct swap

Using `class_getInstanceMethod`+`method_setImplementation` directly is dangerous when the target
class doesn't implement the selector itself (i.e. it's only inherited) — the swap lands on the
shared base class (e.g. `UIView`, inherited by countless classes) instead, which actually happened
once and broke UI rendering across the whole app.

To avoid this, the helper first tries `class_addMethod` to add a class-specific implementation;
only when that fails (the class already overrides the selector itself) does it fall back to
`method_setImplementation`.

## Hiding banner ads

Banner ad views have no explicit "show" trigger — they become visible automatically once added to
the window hierarchy. Hooking `didMoveToWindow` alone isn't enough, since some SDKs asynchronously
write `hidden` back to `NO` later (observed with AppLovin MAX's `MAAdView` during auto-refresh), so
`setHidden:` is also hijacked to always force `YES` regardless of the value passed in.

An earlier version also forced `frame` to `CGRectZero` directly, but this caused a hang on views
under Auto Layout constraints (observed with InMobi's `IMBanner`): frame change → constraint
violation → re-layout request → `layoutSubviews` fires again → the SDK writes the frame back →
… — the main thread got stuck in this cycle. Forcing `hidden` alone is enough to make the view
invisible, so `frame` is now left to the SDK/Auto Layout.

Even `didMoveToWindow` + `setHidden:` turned out insufficient in one case: `MAAdView` overrides
`setAlpha:`, and its auto-refresh logic appears to explicitly reset `alpha` back to 1.0 — with the
side effect of also resetting `hidden` back to `NO`. Hijacking `setAlpha:` too was tried, but the
banner still stayed visible in one case (see the known limitation below). Dumping the actual view
tree showed why: the banner view itself was correctly `hidden = 1`, but its **child view** (an
anonymous `UIView` instance added by the SDK) stayed `hidden = 0` and kept rendering anyway —
likely through a Unity-integration-specific drawing path (assumed) that ignores UIKit's `hidden`.
Hooking `UIView` itself would be dangerous (same known bug as above — it would corrupt the shared
base class every `UIView` inherits from), so instead the banner container's descendants are forced
to `hidden = YES` recursively at the **specific instance** level (`ABForceHiddenRecursive`). Every
banner hook now uses a common four-method set — `didMoveToWindow`/`setHidden:`/`layoutSubviews`/
`setAlpha:` — and each one recursively forces `hidden` on itself and all of its descendants.

## The parent wrapper around a banner container can stay behind as a blank strip (unresolved)

Even when `ABForceHiddenRecursive` successfully hides a banner container and all its
descendants, the **dedicated wrapper View** that wraps it as a full-width strip (a generic,
unhookable `UIView` the SDK provides) can keep reserving its height and stay visible as a blank
white strip. Confirmed on-device on Snow: `GFPNativeAd` gets rendered through a custom layout
(`FADAdViewCustomLayout`), whose own parent is a plain, anonymous `UIView`.

A heuristic was implemented and tried: walk up the ancestor chain and recursively force `hidden`
as long as each ancestor has exactly one child (this banner). It was reverted after on-device
testing showed the opposite problem — in Snow's actual UI hierarchy, intermediate containers
frequently end up with exactly one child purely as a matter of layout, not because they're
ad-specific wrappers. The condition kept holding much further up the hierarchy than expected,
and the hiding cascaded into unrelated, legitimate UI (the entire bottom toolbar). "Has exactly
one child" feels like a reasonable signal for an ad-only wrapper, but it's a weak heuristic in
practice, and the risk of a false positive grows the further you walk up the tree.

This blank strip is accepted as a known limitation for now. The ad content itself (image, text,
tap targets) does get hidden, so the practical impact is reduced even though the strip remains.

## When the delegate argument is a measurement/relay layer, not the real one

The `delegate` passed in for reward notification can turn out to be, not the game's own
implementation, but a **measurement/relay wrapper object** supplied by the mediation SDK (Godus:
the `showDelegate` argument of Unity Ads' legacy static API
`show:placementId:options:showDelegate:` turned out to be ironSource's AdQuality measurement
layer, `SMLDelegate`, a subclass of `ISAdQualityAdDelegate`). This wrapper answers YES to
`respondsToSelector:` and the call itself succeeds, but it can perform additional internal
validation (ad lifecycle state tracking, inventory-existence checks, etc.), so simply calling the
protocol method doesn't always take effect.

In this situation, don't trust `respondsToSelector:` alone — dump the delegate's actual class
name, class chain (walk `class_getSuperclass`), and ivar list (`class_copyIvarList` +
`ivar_getTypeEncoding` + `object_getIvar`) to a diagnostic log, and check whether it's holding the
real delegate in a separate ivar. On Godus, `SMLDelegate`'s `_strongDelegate` ivar held a
reference to the actual mediation adapter (`ISUnityAdsRewardedVideoDelegate`); notifying that
object directly — `unityAdsAdLoaded:` (load complete) → `unityAdsShowStart:` (show start) →
`unityAdsShowComplete:withFinishState:` (show complete), in that order — got the reward granted.
Some SDKs also internally validate a "load complete → show start → show complete" lifecycle order
for reward callbacks, so sending the load-complete notification first (not just show-complete)
tends to help it go through. When you're not confident about the exact enum value (e.g.
`finishState`), sending several candidate values (0/1/2, etc.) in sequence is a practical,
if inelegant, way to land on the one that works.

## `removeFromSuperview` can crash on a delay

The "last resort" of detaching a banner container from the view hierarchy via `removeFromSuperview`
(described above) triggered a new kind of crash on Snow. `FADCustomLayoutBaseView` (a GFP native
ad) had an Auto Layout constraint tying its `centerX` to another, unrelated View's
(`FADAdViewCustomLayout`) `centerX` — not a sibling, not an ancestor. Detaching it with
`removeFromSuperview` left that constraint in an invalid state ("no common ancestor").

The crash (`NSInternalInconsistencyException`: "because they have no common ancestor") didn't
happen at the point `removeFromSuperview` was called — it happened on the **next UIKit layout
cycle** (`UpdateCycle` → `QuartzCore` → `UIKitCore`, a completely separate, asynchronous point in
the call stack) when the leftover constraint got re-evaluated. Because of this, wrapping the
`removeFromSuperview` call itself in `@try`/`@catch` (which was tried) did not prevent the crash —
the exception's origin was outside the calling stack frame that could catch it.

This happens because `removeFromSuperview` only detaches the view from the hierarchy; it doesn't
automatically deactivate an `NSLayoutConstraint` instance that some other, external code is
holding a reference to and that still references the removed view. The fix was to add a dedicated
variant (`AB_DEFINE_HIDE_BANNER_HOOK_SET_NO_REMOVE`) that skips `removeFromSuperview` entirely for
classes known to carry this crash risk, settling for `hidden` alone.

## Reward granting and capturing a real MAAd

After blocking a rewarded ad's show call, the SDK's delegate is notified of success as if the ad
had actually been watched, so the game's own logic can proceed. For AppLovin MAX specifically, the
delegate implementation (`MAUnityAdManager` from the official Unity Plugin, source available on
GitHub) packs `ad.adUnitIdentifier` and other properties directly into an NSDictionary literal, so
passing `nil` or a fake object as `ad` can crash. To work around this, `didLoadAd:` is hijacked to
capture the real `MAAd` instance the SDK actually loaded (keyed by format:
interstitial/rewarded/appOpen), and that captured instance is reused when notifying the delegate
after a blocked show call.

## Diagnostic logging and view tree dumps

`ABDebugLog` records whether each hook installed successfully, which hooks actually fired, and the
outcome of delegate notifications for reward granting. When investigating an unknown ad SDK or an
SDK-version API difference, this narrows the problem down much faster than static analysis alone.
The log is overwritten on every process launch, so it always holds only the most recent run
(it used to append, which mixed up multiple launches and made investigation confusing).

One implementation pitfall: `ABDebugLog` originally opened/seeked/wrote/closed the file on every
single line. Combined with a diagnostic class-dump feature (below) that can emit 600+ lines in one
go, this blocked the main thread long enough to get killed by the launch watchdog — a real crash
observed on Godus. The fix was to open the file handle once at process start and reuse it. Even
logging, which looks cheap, needs its I/O cost estimated once there's a code path that can emit a
lot of it.

The view tree dump (`ABDumpVisibleBottomViews`) prints the view hierarchy near the bottom of the
screen while ignoring `hidden` state — useful for confirming whether a view that's still visible on
screen is actually hidden/detached at the runtime level. Since some apps only show ads after a
specific screen transition (tens of seconds to minutes after launch) rather than immediately at
launch, don't hard-code the monitoring window — tune it to the symptom (one case needed extending
it from 30 seconds to 2 minutes).

## Discovering an unknown ad SDK

When every supported SDK is hooked but an ad still won't go away, `ABLogSuspiciousAdClasses` (used
inside `ABInstallThirdPartyAdHooks`) enumerates runtime-registered classes matching a diagnostic
keyword list (`Interstitial`/`Rewarded`/`GFP`/etc.) and logs them. Classes with a naming scheme not
in that list won't show up at first, though. On Snow, an unknown prefix "FAD" was completely
invisible at first; only after the view tree dump happened to reveal a class name that mapped
directly to the "i" info icon itself (`FADInformationIconView`) — and after adding `FAD` to the
keyword list — did the full picture (the `FADCustomLayoutBaseView` hierarchy, etc.) emerge.

Useful leads:

- The link target of the "why this ad" / AdChoices-style info icon shown on the ad. On Snow this
  turned out to be LINE's ad-optimization terms page (`terms.line.me`), which is what identified
  the SDK as NAVER/LINE's in-house ad platform "GFP".
- Class name prefixes/patterns visible in a view tree dump. A thin wrapper class the app itself
  implements (Snow's `YRInterstitialPopupGFPAd`-style naming) often holds a reference to the real
  SDK class internally; dumping its property types (`class_copyPropertyList` +
  `property_getAttributes`) reveals the actual class name.
- When a class is found but the right method name isn't obvious, dumping the full instance- and
  class-method list with `class_copyMethodList` is the reliable route — using method names
  confirmed on-device beats stacking up guesses, and is faster.

## Unresolved known limitations

### StoneGrass's `MAAdView` banner

On one app (StoneGrass, a Unity-integrated title), even extending the recursive hiding described
above to direct `CALayer` manipulation (`view.layer.hidden` / `view.layer.opacity = 0`), and even
detaching the view entirely from the view hierarchy with `removeFromSuperview`, the banner still
stayed visible. The view tree dump confirmed the view was fully hidden/detached at the Objective-C
runtime level, so this was judged to be a constraint of LiveContainer's rendering pipeline (likely
something specific to the Unity integration) that's out of reach of runtime-level fixes. If you hit
the same symptom, dump the view tree first — if it's fully hidden there but still visible on
screen, it matches this known limitation.

### Snow's banner strip staying behind

See "The parent wrapper around a banner container can stay behind as a blank strip" above.

## Build from source

```bash
export THEOS=~/.theos
make
```

Produces `.theos/obj/debug/LCAdBlocker.dylib`. Release build: `make FINALPACKAGE=1`.
