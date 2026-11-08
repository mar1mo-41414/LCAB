# Unity Ads show regression harness

On macOS with Xcode and an already booted iOS Simulator (no ad SDK required):

```sh
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
ARCH=$(uname -m)
xcrun --sdk iphonesimulator clang -arch "$ARCH" \
  -isysroot "$SDK" -mios-simulator-version-min=15.0 -fobjc-arc \
  -ISources Tests/UnityAdsShowTests.m Sources/ABThirdPartyAdHooks.m \
  Sources/ABSwizzle.m Sources/ABDebugLog.m \
  -framework Foundation -framework UIKit -framework AVFoundation \
  -o /tmp/LCABUnityAdsShowTests
xcrun simctl spawn booted /tmp/LCABUnityAdsShowTests
```

Checks missing SDK / late class registration, repeated installation, interception
of the three-object-argument class method, asynchronous ordered callbacks on the
main queue, placement preservation, completed state `2`, and nil/non-conforming
delegates. This is a mock-runtime test, not proof of behavior in a real mediation SDK.

Device acceptance check (2048 v4.0.8 under LiveContainer):

1. Inject the rebuilt dylib and restart the app.
2. Confirm `[INSTALL] *UnityAds(class).show:placementId:showDelegate: -> OK`.
3. Play until game over; confirm the matching `[BLOCKED]` entry, no playable
   presentation, and that restart/next-game controls still work. Repeat several times.
4. Check other ad flows, particularly voluntary rewarded ads, still return control.
5. If a playable still appears, collect the new log; do not hide generic WKWebViews
   or block networking as a fallback.

The Linux development environment cannot compile or execute this Apple SDK harness.

## ironSource / LevelPlay follow-up

The same harness now registers mock `ISUnityAdsAdapter` and `LPMBannerAdView`
classes after an initial install pass. It checks adapter interception, one async
open/show/close sequence, nil/non-conforming delegates, banner re-hide after SDK
hidden/alpha writes and layout, retained superview, and unaffected sibling/parent
views (including inherited UIView method isolation).

Device acceptance additionally requires:

- `[INSTALL] ISUnityAdsAdapter.showInterstitialWithViewController:adapterConfig:delegate: -> OK`
  and the matching `[BLOCKED]` when game over occurs.
- `[CALLBACK]` entries for adapter open/show/close; playable does not appear and
  the next game starts normally, repeatedly.
- `LPMBannerAdView` banner hooks install OK; bottom banner stays hidden across
  refreshes/rotation, without losing game controls. A reserved blank slot may remain.
- Other mediated/rewarded flows still work. If the adapter hook does not fire,
  collect a fresh log rather than assuming this path is confirmed.

## Swift Unity Ads runtime-name regression

The harness also registers `_TtC8UnityAds18UADSInterstitialAd` after the first
install passes, tests interception after retries, ordered asynchronous native
callbacks carrying the actual ad object, nil/non-conforming delegates, and checks
that `_TtC8UnityAds14UADSRewardedAd` remains unchanged.

On device, expect:

- `[INSTALL] _TtC8UnityAds18UADSInterstitialAd.show:delegate: -> OK`
- `[BLOCKED] _TtC8UnityAds18UADSInterstitialAd show:delegate:` at game over
- The supplied delegate responds to `showDidStart:` / `showDidComplete:with:`;
  the game returns to normal play with no playable. Test multiple game overs.

The old unmangled-class NG is not the new hook's result. If no new BLOCKED entry
appears, the actual call path remains unconfirmed; attach the full updated log.
