# LCAdBlocker

[English README →](README-EN.md)

LiveContainer上で動くiOSアプリに注入し、アプリ内広告のうち以下を無効化するdylibです。

- Apple純正のStoreKit広告表示機構(`SKStoreProductViewController` / `SKOverlay`)
- 主要サードパーティ広告SDKの「表示」トリガー(存在する場合のみ)

特定アプリ専用ではなく、iOS/主要広告SDKの共通クラスを対象にした汎用実装です。
仕組みの詳細は[docs/TECHNICAL.md](docs/TECHNICAL.md)を参照してください。

## 重要な制約

- **アプリ本体のネットワーク通信は一切妨げません。** フック対象は「広告を画面に表示する」トリガーメソッドのみで、
  通信層(URLSession等)や広告SDKの初期化・ロード処理には触れていません。
- YouTubeなど、広告表示がアプリ独自実装(SDK共通クラスを使わない埋め込み広告)のものは対象外です。
- 脱獄不要。LiveContainerのin-process dylib注入で動作します(CydiaSubstrateには依存しません)。

## 対応環境

- iOS 15.0以降 (arm64)
- LiveContainer

## 対応している広告SDK

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
| AdSurgeSDK(AppLovin MAXのカスタムメディエーション、Tencent GDTベース) | `AdSurgeInterstitialAd` / `AdSurgeRewardedAd` / `AdSurgeAppOpenAd` / `AdSurgeBannerAdView` | show系をno-op化、バナーは非表示化 |
| Moloco | `PublisherFullscreenAd`(Interstitial/Rewarded共用実体) / `MolocoBannerAdView` | show系をno-op化、バナーは非表示化 |
| Unity Ads本体(SDK 4.x系) | `UADSInterstitialAd` / `UADSRewardedAd` / `UADSBannerView` / `UADSBannerWrapperView` / `UADSBannerAd` | show/displayBanner系をno-op化、バナーは非表示化 |
| Unity Ads本体(レガシー静的API) | `UnityAds`クラスメソッド `show:placementId:options:` / `show:placementId:options:showDelegate:` | show系をno-op化 |
| Smaato(Appodealのメディエーション先) | `SMAInterstitial` / `SMARewardedInterstitial` / `SMABannerView` | show系をno-op化、バナーは非表示化 |

サードパーティSDKはアプリ・ビルドによって実装が含まれていないことがあるため、
起動時に`NSClassFromString`でクラスの存在を確認してから動的にフックします。
存在しないクラスへの静的フックはクラッシュの原因になるため避けています。

## インストール

[Releases](../../releases)から最新の`LCAdBlocker.dylib`をダウンロードし、
LiveContainerの対象アプリのTweak設定で注入対象に追加してください。タグをpushすると
GitHub Actionsが自動でビルドし、Releasesページに`LCAdBlocker.dylib`が公開されます。

### ソースからビルドする場合

[Theos](https://theos.dev/)の開発環境が必要です。

```bash
export THEOS=~/.theos
make
```

`.theos/obj/debug/LCAdBlocker.dylib`が生成されます。

## 既知の制約

- 広告SDKがSwift実装で、表示APIがprotocol existential経由でユーザーコードに渡され、かつ
  具象実装クラスがNSObjectを継承しない(=Objective-Cランタイムに一切登録されない)場合は対象外です。
- リワード広告は、showそのものは無効化しつつ、広告を見た体でSDK側に成功コールバックを返すことで
  報酬を付与します。これは第三者へ不正な利益を与えるためではなく、このdylib自身の利用者が
  広告を見ずに機能を使えるようにする(=広告ブロッカーとしての本来の目的)ためのものです。

その他、個々のSDKでの実装上の工夫や未解決の制約については
[docs/TECHNICAL.md](docs/TECHNICAL.md)を参照してください。

## 協力のお願い

対応しているはずの広告SDKでも、SDKバージョンや個々のアプリの実装差異によって広告が
消えないケースがあります。dylibを導入しても広告がブロックできないアプリや、逆に
dylibを入れることでアプリが正常に動作しなくなる(フリーズ・クラッシュ等)場合を見つけたら、
以下の情報とあわせてIssueで報告してもらえると助かります。

- アプリのバンドルID(例: `com.example.app`)
- 消えない/おかしくなる広告の種類(バナー・インタースティシャル・リワード・オープン広告など)と、
  可能であれば広告SDK名(AdMob、AppLovin MAXなど、わかれば)
- 具体的な症状(広告が表示され続ける、アプリが起動しない、操作不能になる、など)
