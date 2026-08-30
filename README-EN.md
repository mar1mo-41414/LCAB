# LCAdBlocker

[日本語 README →](README.md)

A dylib that gets injected into iOS apps running under LiveContainer to disable in-app ads:

- Apple's native StoreKit ad surfaces (`SKStoreProductViewController` / `SKOverlay`)
- The "show" trigger of major third-party ad SDKs, when present

It targets common OS/SDK classes rather than any specific app, so it works generically.

## Important constraints

- **Does not interfere with the app's own network traffic in any way.** Only the "present an ad"
  trigger methods are hooked — the networking layer (URLSession, etc.) and the ad SDK's
  initialization/load logic are left untouched.
- Ads that are the app's own bespoke implementation (e.g. YouTube-style embedded ads that don't
  go through a shared SDK class) are out of scope.
- No jailbreak required. Works via LiveContainer's in-process dylib injection (does not depend on
  CydiaSubstrate).

## Supported environment

- iOS 15.0+ (arm64)
- LiveContainer

## Supported ad mechanisms

| Kind | Target class | Behavior |
|---|---|---|
| Apple StoreKit | `SKStoreProductViewController` | Fails the product load and blocks presentation |
| Apple StoreKit | `SKOverlay` | Ignores the present request |
| Google AdMob | `GADInterstitialAd` / `GADRewardedAd` / `GADBannerView` | No-ops the show call, hides the banner |
| Meta Audience Network | `FBInterstitialAd` / `FBRewardedVideoAd` / `FBAdView` | No-ops the show call, hides the banner |
| ironSource | `ISBannerView` | Hides the banner |
| AppLovin MAX | `MAInterstitialAd` / `MARewardedAd` / `MAAppOpenAd` / `MAAdView` | No-ops the show call, hides the banner |
| Chartboost | `CHBInterstitial` | No-ops the show call |
| InMobi | `IMInterstitial` / `IMBanner` | No-ops the show call, hides the banner |
| AdSurgeSDK (AppLovin MAX custom mediation network, Tencent GDT-based) | `AdSurgeInterstitialAd` / `AdSurgeRewardedAd` / `AdSurgeAppOpenAd` / `AdSurgeBannerAdView` | No-ops the show call, hides the banner |
| Moloco | `PublisherFullscreenAd` (shared Interstitial/Rewarded implementation) / `MolocoBannerAdView` | No-ops the show call, hides the banner |
| Unity Ads itself (SDK 4.x) | `UADSInterstitialAd` / `UADSRewardedAd` / `UADSBannerView` / `UADSBannerWrapperView` / `UADSBannerAd` | No-ops show/displayBanner, hides the banner |
| Unity Ads itself (legacy static API) | `UnityAds` class methods `show:placementId:options:` / `show:placementId:options:showDelegate:` | No-ops the show call |

Since a given app/build may not include every third-party SDK, each hook checks the class exists
via `NSClassFromString` at launch before swizzling. Statically hooking a class that isn't present
would crash the app, so this is done dynamically instead.

## How it works

Instead of CydiaSubstrate's `%hook` (Logos), this uses plain Objective-C runtime method
swizzling. LiveContainer's in-process injection environment can't assume CydiaSubstrate is
available, so this follows the same approach as the sister project
[LCME (iOS_LC_MemEditor)](https://github.com/mar1mo-41414/LCME).

Hooks are installed automatically on dylib load via `__attribute__((constructor))`, and the same
install pass runs a second time after `UIApplicationDidFinishLaunchingNotification` (an extra
dylib like UnityFramework may not have loaded/registered its classes yet at constructor time).
On top of that, `_dyld_register_func_for_add_image` re-runs the install pass for every shared
library/framework loaded afterward. On mediation platforms like Appodeal, individual ad network
SDKs (e.g. `AppLovinSDK.framework`) may not actually get loaded at app launch at all — only once
the mediation layer initializes them, which can happen well after `didFinishLaunching` (e.g. after
Unity's own C# code starts running) — so the two earlier capture points alone miss them. Since the
`NSClassFromString`-based install pass is safe to run any number of times, this callback can be
invoked freely without worrying about overhead.

- `Sources/ABSwizzle.{h,m}`: shared helper that swaps an IMP only after confirming the
  class/selector exist at runtime. Using `class_getInstanceMethod`+`method_setImplementation`
  directly is dangerous when the target class doesn't implement the selector itself (i.e. it's
  only inherited) — the swap lands on the shared base class (e.g. `UIView`, inherited by
  countless classes) instead, which actually happened once and broke UI rendering across the
  whole app. To avoid this, the helper first tries `class_addMethod` to add a class-specific
  implementation; only when that fails (the class already overrides the selector itself) does it
  fall back to `method_setImplementation`.
- `Sources/ABStoreKitHooks.{h,m}`: hooks for Apple's native StoreKit mechanisms
- `Sources/ABThirdPartyAdHooks.{h,m}`: hooks for third-party ad SDKs
- `Sources/ABDebugLog.{h,m}`: a lightweight diagnostic logger. Writes `lcadblocker.log` under the
  app's Documents directory, recording whether each hook installed successfully, which hooks
  actually fired, and the outcome of delegate notifications for reward granting. Used to
  investigate unknown ad SDKs or SDK-version API differences.
- `Sources/ABConstructor.m`: entry point

### Hiding banner ads

Banner ad views have no explicit "show" trigger — they become visible automatically once added to
the window hierarchy. Hooking `didMoveToWindow` alone isn't enough, since some SDKs asynchronously
write `hidden` back to `NO` later (observed with AppLovin MAX's `MAAdView` during auto-refresh), so
`setHidden:` is also hijacked to always force `YES` regardless of the value passed in.

An earlier version also forced `frame` to `CGRectZero` directly, but this caused a hang on views
under Auto Layout constraints (observed with InMobi's `IMBanner`): frame change → constraint
violation → re-layout request → `layoutSubviews` fires again → the SDK writes the frame back →
… — the main thread got stuck in this cycle. Forcing `hidden` alone is enough to make the view
invisible, so `frame` is now left to the SDK/Auto Layout.

### Reward granting and capturing a real MAAd

After blocking a rewarded ad's show call, the SDK's delegate is notified of success as if the ad
had actually been watched, so the game's own logic can proceed (see "Known limitations" below).
For AppLovin MAX specifically, the delegate implementation (`MAUnityAdManager` from the official
Unity Plugin, source available on GitHub) packs `ad.adUnitIdentifier` and other properties
directly into an NSDictionary literal, so passing `nil` or a fake object as `ad` can crash. To
work around this, `didLoadAd:` is hijacked to capture the real `MAAd` instance the SDK actually
loaded (keyed by format: interstitial/rewarded/appOpen), and that captured instance is reused when
notifying the delegate after a blocked show call.

## Build

```bash
export THEOS=~/.theos
make
```

Produces `.theos/obj/debug/LCAdBlocker.dylib`.

## Install

In LiveContainer's per-app tweak settings, add the built `LCAdBlocker.dylib` as an injected dylib.

## Known limitations

- If an ad SDK is implemented in Swift, exposes its show API only as a protocol existential, and
  the concrete implementation class doesn't subclass NSObject (i.e. is never registered with the
  Objective-C runtime at all), it's out of scope. Objective-C / NSObject-bridged mediation
  adapters statically linked into the app (AdMob/Meta/AppLovin/ironSource/Chartboost/InMobi/
  Moloco/Unity Ads, etc.) are the actual targets.
  - Both InMobi and Moloco are implemented in Swift internally, but their target classes
    (`IMInterstitial`/`IMBanner`, `PublisherFullscreenAd`/`MolocoBannerAdView`) are NSObject
    subclasses bridged to Objective-C, so they're hooked by matching a class-name suffix instead
    of an exact name (the runtime class name is mangled by SDK version, e.g.
    `_TtC9InMobiSDK14IMInterstitial`).
  - Unity Ads exposes a newer "UADS"-prefixed Objective-C-bridged API since SDK 4.x
    (`UADSInterstitialAd`/`UADSRewardedAd`/`UADSBannerView`), with no name mangling, so it's
    hooked directly via `NSClassFromString`. Even when routed through a mediation adapter (e.g.
    AppLovin MAX's Unity Ads adapter), the call ultimately reaches these two classes' `show:delegate:`.
- Rewarded ads (`GADRewardedAd` / `FBRewardedVideoAd` / `MARewardedAd` / `AdSurgeRewardedAd` /
  `UADSRewardedAd` / Moloco's PublisherFullscreenAd) disable the show call, but still report
  success back to the SDK as if the ad had been watched (the delegate's
  `didRewardUserForAd:withReward:`-equivalent callback, or the completion block). This isn't
  about granting an unfair advantage to third parties — it's this dylib's own user being able to
  use the feature without watching an ad, which is the whole point of an ad blocker. Confidence in
  the exact delegate method name/signature varies by SDK (AppLovin MAX and Google AdMob are based
  on documented public APIs and are fairly reliable; the others are best-effort), and the
  ad/reward arguments are passed as nil (sending a message to nil in Objective-C safely returns a
  zero value for simple property access, so this is fine in practice).
