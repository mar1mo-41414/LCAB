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
| Unity Ads itself (SDK 4.x) | `UADSInterstitialAd` / `UADSRewardedAd` / `UADSBannerView` | No-ops the show call, hides the banner |

Since a given app/build may not include every third-party SDK, each hook checks the class exists
via `NSClassFromString` at launch before swizzling. Statically hooking a class that isn't present
would crash the app, so this is done dynamically instead.

## How it works

Instead of CydiaSubstrate's `%hook` (Logos), this uses plain Objective-C runtime method swizzling
(`method_setImplementation`). LiveContainer's in-process injection environment can't assume
CydiaSubstrate is available, so this follows the same approach as the sister project
[LCME (iOS_LC_MemEditor)](https://github.com/mar1mo-41414/LCME).

Hooks are installed automatically on dylib load via `__attribute__((constructor))`.

- `Sources/ABSwizzle.{h,m}`: shared helper that swaps an IMP only after confirming the class/selector exist at runtime
- `Sources/ABStoreKitHooks.{h,m}`: hooks for Apple's native StoreKit mechanisms
- `Sources/ABThirdPartyAdHooks.{h,m}`: hooks for third-party ad SDKs
- `Sources/ABConstructor.m`: entry point

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
- Rewarded ads (`GADRewardedAd` / `FBRewardedVideoAd` / `MARewardedAd`) disable the show call
  entirely, so the reward callback is never invoked either — this avoids creating an exploit
  where a reward is granted without the user actually watching an ad.
