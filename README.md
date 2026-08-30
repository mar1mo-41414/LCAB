# LCAdBlocker

[English README →](README-EN.md)

LiveContainer上で動くiOSアプリに注入し、アプリ内広告のうち以下を無効化するdylibです。

- Apple純正のStoreKit広告表示機構(`SKStoreProductViewController` / `SKOverlay`)
- 主要サードパーティ広告SDKの「表示」トリガー(存在する場合のみ)

特定アプリ専用ではなく、iOS/主要広告SDKの共通クラスを対象にした汎用実装です。

## 重要な制約

- **アプリ本体のネットワーク通信は一切妨げません。** フック対象は「広告を画面に表示する」トリガーメソッドのみで、
  通信層(URLSession等)や広告SDKの初期化・ロード処理には触れていません。
- YouTubeなど、広告表示がアプリ独自実装(SDK共通クラスを使わない埋め込み広告)のものは対象外です。
- 脱獄不要。LiveContainerのin-process dylib注入で動作します(CydiaSubstrateには依存しません)。

## 対応環境

- iOS 15.0以降 (arm64)
- LiveContainer

## 対応している広告機構

| 種別 | 対象クラス | 挙動 |
|---|---|---|
| Apple StoreKit | `SKStoreProductViewController` | 商品情報ロードを失敗扱いにし、presentもブロック |
| Apple StoreKit | `SKOverlay` | 表示要求を無視 |
| Google AdMob | `GADInterstitialAd` / `GADRewardedAd` / `GADBannerView` | show系をno-op化、バナーは非表示化 |
| Meta Audience Network | `FBInterstitialAd` / `FBRewardedVideoAd` / `FBAdView` | show系をno-op化、バナーは非表示化 |
| ironSource | `ISBannerView` | 非表示化 |
| AppLovin MAX | `MAInterstitialAd` / `MARewardedAd` / `MAAppOpenAd` / `MAAdView` | show系をno-op化、バナーは非表示化 |
| Chartboost | `CHBInterstitial` | show系をno-op化 |
| InMobi | `IMInterstitial` / `IMBanner` | show系をno-op化、バナーは非表示化 |

サードパーティSDKはアプリ・ビルドによって実装が含まれていないことがあるため、
起動時に`NSClassFromString`でクラスの存在を確認してから動的にフックします。
存在しないクラスへの静的フックはクラッシュの原因になるため避けています。

## 仕組み

CydiaSubstrateの`%hook`(Logos)ではなく、素のObjective-Cランタイムでの
method swizzling(`method_setImplementation`)を使っています。LiveContainerの
in-process注入環境ではCydiaSubstrateが前提にできないため、姉妹プロジェクトの
[LCME (iOS_LC_MemEditor)](https://github.com/mar1mo-41414/LCME)と同じ方式です。

`__attribute__((constructor))`でdylibロード時に自動的にフックをインストールします。

- `Sources/ABSwizzle.{h,m}`: クラス・セレクタの実行時存在確認付きでIMPを差し替える共通ヘルパー
- `Sources/ABStoreKitHooks.{h,m}`: Apple純正StoreKit機構のフック
- `Sources/ABThirdPartyAdHooks.{h,m}`: サードパーティ広告SDKのフック
- `Sources/ABConstructor.m`: エントリポイント

## ビルド

```bash
export THEOS=~/.theos
make
```

`.theos/obj/debug/LCAdBlocker.dylib` が生成されます。

## インストール

LiveContainerの対象アプリのTweak設定で、ビルドした`LCAdBlocker.dylib`を注入対象に追加してください。

## 既知の制約

- 広告SDK本体(Unity Ads、MolocoSDKなど)がSwift実装で、かつ表示APIがprotocol経由・非`@objc`の場合、
  Objective-Cランタイムから直接フックできないため対象外です。mediationアダプタとして
  静的リンクされるObjective-C実装のSDK(AdMob/Meta/AppLovin/ironSource/Chartboost/InMobiなど)が対象になります。
  - InMobiはSwift実装ですが、対象クラス(`IMInterstitial`/`IMBanner`)自体はNSObjectを継承した
    Objective-Cブリッジ済みクラスのため、クラス名サフィックス一致でフックしています
    (ランタイム上のクラス名はSDKバージョンによって`_TtC9InMobiSDK14IMInterstitial`のようにマングルされます)。
- リワード広告(`GADRewardedAd` / `FBRewardedVideoAd` / `MARewardedAd`)はshowそのものを無効化するため、
  報酬コールバックも呼ばれません(広告を見ずに報酬だけ得る不正な状態を作らないため)。
