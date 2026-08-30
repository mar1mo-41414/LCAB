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
| Meta Audience Network | `FBInterstitialAd` / `FBAdView` | No-ops the show call, hides the banner |
| ironSource | `ISBannerView` | Hides the banner |
| AppLovin MAX | `MAInterstitialAd` | No-ops the show call |
| Chartboost | `CHBInterstitial` | No-ops the show call |

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

- If the underlying ad SDK (e.g. Unity Ads) is implemented in Swift, non-`@objc` Swift methods
  can't be hooked directly via the Objective-C runtime, so they're out of scope. Objective-C
  mediation adapters statically linked into the app (AdMob/Meta/AppLovin/ironSource/Chartboost, etc.)
  are the actual targets.
- Rewarded ads (`GADRewardedAd`) disable the show call entirely, so the reward callback is never
  invoked either — this avoids creating an exploit where a reward is granted without the user
  actually watching an ad.
