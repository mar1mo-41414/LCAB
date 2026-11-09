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
2. Check installation results for the relevant SDK show and banner hooks.
   An INSTALL OK alone does not prove interception.
3. Play until game over; verify a matching show `[BLOCKED]` entry and completion
   callbacks on the path actually used. Alternative hooks need not all fire.
4. Confirm no playable appears, the restart screen is reached, and the bottom
   banner is hidden. Repeat game overs and test refresh/rotation for wider coverage.
5. Check voluntary rewarded ads separately; game-over success does not verify them.
6. If a playable still appears, collect the new log; do not hide generic WKWebViews
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

When specifically testing the Swift-class entry, expect:

- `[INSTALL] _TtC8UnityAds18UADSInterstitialAd.show:delegate: -> OK`
- `[BLOCKED] _TtC8UnityAds18UADSInterstitialAd show:delegate:` at game over
- The supplied delegate responds to `showDidStart:` / `showDidComplete:with:`;
  the game returns to normal play with no playable. Test multiple game overs.

The old unmangled-class NG is not the new hook's result. If this BLOCKED entry
does not appear, this specific path remains unconfirmed. Another show hook may
block the ad first, as in the successful final device run below.


## Completed device acceptance: 2048 v4.0.8

The user confirmed no game-over ad, direct progression to the restart screen, and
no persistent bottom banner. The supplied `lcadblocker-4.log` records:

- `ISUnityAdsAdapter showInterstitialWithViewController:adapterConfig:delegate:`
  blocked at 10:09:47.011.
- Open/show/close callbacks to `ISInterstitialAdapterBridge` at 10:09:47.030.
- `LPMBannerAdView` remaining hidden=1, alpha=0 after re-show requests.
- Swift interstitial installation OK, without that hook firing in this run.

This is a completed user/device check for the reported flows, not an executed
Simulator harness test. Repeated game overs, refresh/rotation coverage, other
mediation/rewarded flows and native Swift callbacks are not established by this log.
The earlier sections describe mock coverage and checks for individual paths; they
are not requirements for every hook to fire in one device run.

## AdMob rewarded lifecycle regression

Build `Tests/GADRewardedTests.m` instead of `Tests/UnityAdsShowTests.m` in the
Simulator command above (use a separate output name). It mocks `GADRewardedAd`
and verifies blocked presentation, idempotent installation, asynchronous main-queue
will-present → reward → will-dismiss → did-dismiss order, ad identity, one reward
per invocation, nil handler/delegate and missing optional methods. Click and
impression callbacks must not be synthesized.

On device, first confirm the failing reward action works with all Tweaks disabled.
Then reproduce with LCAB enabled. Look for the AdMob BLOCKED entry, the actual
`fullScreenContentDelegate` class, reward-handler and dismissal notifications.
Verify both reward delivery and return to normal UI, including a second reward
request. If the failure persists, collect the log immediately after the same action;
mock lifecycle success is not proof that every mediation adapter accepts it.
