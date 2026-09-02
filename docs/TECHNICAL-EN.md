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

The view tree dump (`ABDumpVisibleBottomViews`) prints the view hierarchy near the bottom of the
screen while ignoring `hidden` state — useful for confirming whether a view that's still visible on
screen is actually hidden/detached at the runtime level.

## Unresolved known limitation: StoneGrass's `MAAdView` banner

On one app (StoneGrass, a Unity-integrated title), even extending the recursive hiding described
above to direct `CALayer` manipulation (`view.layer.hidden` / `view.layer.opacity = 0`), and even
detaching the view entirely from the view hierarchy with `removeFromSuperview`, the banner still
stayed visible. The view tree dump confirmed the view was fully hidden/detached at the Objective-C
runtime level, so this was judged to be a constraint of LiveContainer's rendering pipeline (likely
something specific to the Unity integration) that's out of reach of runtime-level fixes. If you hit
the same symptom, dump the view tree first — if it's fully hidden there but still visible on
screen, it matches this known limitation.

## Build from source

```bash
export THEOS=~/.theos
make
```

Produces `.theos/obj/debug/LCAdBlocker.dylib`. Release build: `make FINALPACKAGE=1`.
