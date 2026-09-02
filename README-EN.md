# LCAdBlocker

[日本語 README →](README.md)

A dylib that gets injected into iOS apps running under LiveContainer to disable in-app ads:

- Apple's native StoreKit ad surfaces (`SKStoreProductViewController` / `SKOverlay`)
- The "show" trigger of major third-party ad SDKs, when present

It targets common OS/SDK classes rather than any specific app, so it works generically.
See [docs/TECHNICAL-EN.md](docs/TECHNICAL-EN.md) for how it works under the hood.

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

## Supported ad SDKs

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
| Smaato (an Appodeal mediation destination) | `SMAInterstitial` / `SMARewardedInterstitial` / `SMABannerView` | No-ops the show call, hides the banner |
| Pangle (ByteDance/TikTok) | `PAGInterstitialAd` / `PAGLInterstitialAd` / `PAGRewardedAd` / `PAGBannerAd` | No-ops the show call, hides the banner |
| Vungle Ads SDK (new API) | `VungleAdsSDK.VungleInterstitial` / `VungleAdsSDK.VungleRewarded` / `VungleAdsSDK.VungleBannerView` | No-ops the show call, hides the banner |
| GFP (NAVER/LINE's in-house ad platform) | `GFPInterstitialAd` / `GFPRewardedAd` / `GFPBannerView` | No-ops the show call, hides the banner |

Since a given app/build may not include every third-party SDK, each hook checks the class exists
via `NSClassFromString` at launch before swizzling. Statically hooking a class that isn't present
would crash the app, so this is done dynamically instead.

## Install

Download the latest `LCAdBlocker.dylib` from the [Releases](../../releases) page and add it as an
injected dylib in LiveContainer's per-app tweak settings. Pushing a tag triggers GitHub Actions to
build automatically and publish `LCAdBlocker.dylib` to the Releases page.

### Build from source

Requires the [Theos](https://theos.dev/) development environment.

```bash
export THEOS=~/.theos
make
```

Produces `.theos/obj/debug/LCAdBlocker.dylib`.

## Known limitations

- If an ad SDK is implemented in Swift, exposes its show API only as a protocol existential, and
  the concrete implementation class doesn't subclass NSObject (i.e. is never registered with the
  Objective-C runtime at all), it's out of scope.
- Rewarded ads disable the show call, but still report success back to the SDK as if the ad had
  been watched. This isn't about granting an unfair advantage to third parties — it's this dylib's
  own user being able to use the feature without watching an ad, which is the whole point of an ad
  blocker.
- **The ad content itself (image, text, tap targets) can disappear while the banner slot around it
  (a blank strip of space) stays reserved on screen.** That strip is often a generic `UIView` with
  no SDK-specific hint in its class name, so it can't be hooked at the class level. A generic fix
  that walks up the ancestor chain hiding views was tried, but it ended up hiding unrelated,
  legitimate UI (buttons, etc.) too, confirmed on-device, and was reverted. This is a structural
  limitation of a generic blocker and is accepted as a known limitation for now.

See [docs/TECHNICAL-EN.md](docs/TECHNICAL-EN.md) for per-SDK implementation details and unresolved
limitations.

## Checking the diagnostic log

`Documents/lcadblocker.log` records hook install results and which hooks actually fired
(overwritten on every process launch, so it always holds only the most recent run). Useful when
investigating an ad that isn't getting blocked, or when filing an Issue.

To pull it out of a LiveContainer app:

1. In LiveContainer's "My Apps", long-press the target app and choose "Open Data Folder"
2. The Files app opens — go to `Documents` → `lcadblocker.log`

## Contributing

Even for a supported SDK, ads may still get through on a specific SDK version or a specific app's
implementation. If you find an app where an ad isn't blocked with this dylib installed, or where
installing it causes the app to misbehave (freeze, crash, etc.), please open an Issue with:

- The app's bundle ID (e.g. `com.example.app`)
- What kind of ad isn't going away / what's misbehaving (banner, interstitial, rewarded, app open,
  etc.), and the ad SDK name if you know it (AdMob, AppLovin MAX, etc.)
- The concrete symptom (ad stays visible, app won't launch, app becomes unresponsive, etc.)
