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
| AdSurgeSDK(AppLovin MAXのカスタムメディエーション、Tencent GDTベース) | `AdSurgeInterstitialAd` / `AdSurgeRewardedAd` / `AdSurgeAppOpenAd` / `AdSurgeBannerAdView` | show系をno-op化、バナーは非表示化 |
| Moloco | `PublisherFullscreenAd`(Interstitial/Rewarded共用実体) / `MolocoBannerAdView` | show系をno-op化、バナーは非表示化 |
| Unity Ads本体(SDK 4.x系) | `UADSInterstitialAd` / `UADSRewardedAd` / `UADSBannerView` / `UADSBannerWrapperView` / `UADSBannerAd` | show/displayBanner系をno-op化、バナーは非表示化 |
| Unity Ads本体(レガシー静的API) | `UnityAds`クラスメソッド `show:placementId:options:` / `show:placementId:options:showDelegate:` | show系をno-op化 |
| Smaato(Appodealのメディエーション先) | `SMAInterstitial` / `SMARewardedInterstitial` / `SMABannerView` | show系をno-op化、バナーは非表示化 |

サードパーティSDKはアプリ・ビルドによって実装が含まれていないことがあるため、
起動時に`NSClassFromString`でクラスの存在を確認してから動的にフックします。
存在しないクラスへの静的フックはクラッシュの原因になるため避けています。

## 仕組み

CydiaSubstrateの`%hook`(Logos)ではなく、素のObjective-Cランタイムでの
method swizzlingを使っています。LiveContainerのin-process注入環境ではCydiaSubstrateが
前提にできないため、姉妹プロジェクトの[LCME (iOS_LC_MemEditor)](https://github.com/mar1mo-41414/LCME)
と同じ方式です。

`__attribute__((constructor))`でdylibロード時に自動的にフックをインストールし、
`UIApplicationDidFinishLaunchingNotification`後にもう一度同じインストール処理を実行します
(UnityFrameworkのような追加dylibが、constructor実行時点ではまだロード・クラス登録されていない
ことがあるため)。さらに`_dyld_register_func_for_add_image`で、以後にロードされる
全ての共有ライブラリ/フレームワークに対しても再インストールを試みます。Appodealのような
メディエーションプラットフォームでは、個々の広告ネットワークSDK(`AppLovinSDK.framework`など)
がアプリ起動時ではなくメディエーション側の初期化タイミング(Unity C#コード実行後など、
`didFinishLaunching`よりずっと後)まで実際にロードされないことがあり、前述の2点キャプチャ
だけでは取りこぼす。

ただし、アプリ起動時には数百の共有ライブラリ(システムライブラリ含む)がロードされることが
あるため、素朴に「毎回全フックを最初から試し直す」実装にすると、そのタスクの山でメイン
スレッドが埋め尽くされ、アプリが実質フリーズしたまま起動できなくなる不具合を実際に踏んだ。
これを避けるため2段構えの対策を入れている: (1) `ABSwizzle`側で「一度成功したフックは
二度と試みない」成功キャッシュを持ち、`NSClassFromString`の再実行やクラス一覧の
再スキャンを省略する、(2) dyldコールバック自体も「既にメインキューに再インストール
タスクが積まれている間は新たに積まない」コアレッシングを行う。この2つを組み合わせることで、
イメージロードのたびに実行される処理は時間とともに軽くなっていく。

- `Sources/ABSwizzle.{h,m}`: クラス・セレクタの実行時存在確認付きでIMPを差し替える共通ヘルパー。
  `class_getInstanceMethod`+`method_setImplementation`をそのまま使うと、対象クラス自身が
  そのセレクタを独自実装していない場合(継承しているだけの場合)に継承元(`UIView`など多数の
  クラスが継承する共通基底クラス)のメソッドテーブルごと書き換えてしまう(実際に発生し、
  アプリ全体のUI描画が壊れる重大な不具合を起こした)。これを避けるため、まず`class_addMethod`で
  対象クラス自身への新規追加を試み、追加できた場合はそれで完了、既にそのクラス自身が
  オーバーライド済みで追加できない場合のみ`method_setImplementation`で直接差し替える。
- `Sources/ABStoreKitHooks.{h,m}`: Apple純正StoreKit機構のフック
- `Sources/ABThirdPartyAdHooks.{h,m}`: サードパーティ広告SDKのフック
- `Sources/ABDebugLog.{h,m}`: 診断用の簡易ロガー。アプリのDocuments配下に`lcadblocker.log`を
  書き出し、フックのインストール成否・実際に発火したフック・リワード付与時のdelegate通知結果を
  記録する。未知の広告SDKやSDKバージョン差異による対応漏れを調査する際に使う。
- `Sources/ABConstructor.m`: エントリポイント

### バナー広告の非表示化

バナー広告Viewは表示トリガーとなるメソッド呼び出しがなく、window階層に追加された時点で
自動的に画面に見えるようになる。`didMoveToWindow`だけをフックしても、SDK側が自動リフレッシュ
のタイミングなどで非同期に`hidden`を書き戻してくることがある(AppLovin MAXの`MAAdView`で実際に
発生)ため、`setHidden:`も乗っ取って渡された値に関わらず常に`YES`を強制する。

`frame`を`CGRectZero`に直接書き換える案も試したが、Auto Layout制約下のView(InMobiの
`IMBanner`で実際に発生)では「frame変更→制約違反→再レイアウト要求→`layoutSubviews`再呼び出し→
SDK側がframeを書き戻す→……」という循環でメインスレッドがフリーズしたため撤廃した。
`hidden`の強制だけで画面上には表示されなくなるので、`frame`はSDK/Auto Layoutの管理に委ねている。

`didMoveToWindow`+`setHidden:`の2点でもまだ不十分なケースを確認した。`MAAdView`は
`setAlpha:`を独自オーバーライドしており、自動リフレッシュ時に`alpha`を明示的に1.0へ
書き戻すコードが副作用として`hidden`も`NO`に戻していると見て`setAlpha:`も乗っ取ったが、
それでもバナーが消えないケースが残った(StoneGrassの`MAAdView`)。画面下部のViewツリーを
実際にダンプして特定したところ、`MAAdView`自身は正しく`hidden=1`になっているのに、
その**子ビュー**(SDKが追加する無名の`UIView`インスタンス)が`hidden=0`のまま残っており、
Unity統合特有の描画パス(推測)でUIKitの`hidden`を無視して表示され続けていた。`UIView`
クラス自体をフックするのは危険(継承元=`UIView`全体を壊す既知のバグ、下記参照)なので、
代わりに対象バナーコンテナの子孫を**特定インスタンス単位**で再帰的に`hidden=YES`にする
(`ABForceHiddenRecursive`)ようにした。バナー系フックは全SDK共通で
`didMoveToWindow`/`setHidden:`/`layoutSubviews`/`setAlpha:`の4点セットにし、いずれも
自身だけでなく子孫全体に再帰的に`hidden`を強制する。

StoneGrassの`MAAdView`では、この再帰的hiddenを`view.layer.hidden`/`view.layer.opacity=0`
というCALayerレベルの直接操作にまで広げても、さらに`didMoveToWindow`時に対象View自体を
`removeFromSuperview`でView階層から完全に切り離しても、なお画面にバナーが表示され続けた。
View階層ダンプ上は完全に非表示・切り離し済みであることを確認しているため、これは
Objective-Cランタイム層の対策では手が届かない、LiveContainerの描画パイプライン
(Unity統合特有の可能性が高い)に起因する制約と判断し、対応を断念した。同様の症状に
遭遇した場合は、まずView階層ダンプ(`ABDumpVisibleBottomViews`)で`hidden`状態を確認し、
「View階層上は正しく非表示なのに画面に見える」場合はこの既知の制約に該当する。

### リワード広告の報酬付与とMAAdのキャプチャ

リワード広告のshowをブロックした後、広告を見た体でSDK側のdelegateに成功を通知することで
ゲーム側の処理を続行させる(詳細は下記「既知の制約」参照)。AppLovin MAXについては、
delegateの実装(公式Unity Pluginの`MAUnityAdManager`、ソースはGitHubで公開)が
`ad.adUnitIdentifier`等をNSDictionaryリテラルに直接詰めるため、`ad`引数にnilや偽装
オブジェクトを渡すとクラッシュしうることが判明した。そのため`didLoadAd:`を横取りして
実際にロードされた本物の`MAAd`インスタンスをフォーマット別(interstitial/rewarded/appOpen)に
キャプチャしておき、show断念時にそれを使い回している。

## ビルド

```bash
export THEOS=~/.theos
make
```

`.theos/obj/debug/LCAdBlocker.dylib` が生成されます。

## インストール

LiveContainerの対象アプリのTweak設定で、ビルドした`LCAdBlocker.dylib`を注入対象に追加してください。

## 既知の制約

- 広告SDKがSwift実装で、表示APIがprotocol existential経由でユーザーコードに渡され、かつ
  具象実装クラスがNSObjectを継承しない(=Objective-Cランタイムに一切登録されない)場合は対象外です。
  mediationアダプタとして静的リンクされるObjective-C実装/NSObjectブリッジ済みのSDK
  (AdMob/Meta/AppLovin/ironSource/Chartboost/InMobi/Moloco/Unity Adsなど)が対象になります。
  - InMobi・Molocoはどちらも内部実装がSwiftですが、対象クラス(`IMInterstitial`/`IMBanner`、
    `PublisherFullscreenAd`/`MolocoBannerAdView`)自体はNSObjectを継承したObjective-Cブリッジ済み
    クラスのため、クラス名サフィックス一致でフックしています(ランタイム上のクラス名はSDKバージョンに
    よって`_TtC9InMobiSDK14IMInterstitial`のようにマングルされます)。
  - Unity AdsはSDK 4.x系以降、`UADSInterstitialAd`/`UADSRewardedAd`/`UADSBannerView`という
    "UADS"プレフィックスでObjective-Cブリッジされた新APIを公開しており、これらはクラス名の
    マングルもなく通常の`NSClassFromString`でフックできます。AppLovin MAXなどのUnity Adsメディエー
    ションアダプタ経由で使われる場合も、最終的にはこの2クラスの`show:delegate:`が呼ばれます。
- リワード広告(`GADRewardedAd` / `FBRewardedVideoAd` / `MARewardedAd` / `AdSurgeRewardedAd` /
  `UADSRewardedAd` / MolocoのPublisherFullscreenAd)は、showそのものは無効化しつつ、
  広告を見た体でSDK側に成功コールバック(delegate経由の`didRewardUserForAd:withReward:`相当、
  またはブロック引数)を返すことで報酬を付与します。これは第三者へ不正な利益を与えるためではなく、
  このdylib自身の利用者が広告を見ずに機能を使えるようにする(=広告ブロッカーとしての本来の目的)ための
  ものです。delegateのメソッド名・シグネチャはSDKによって確証の強さが異なり
  (AppLovin MAX/Google AdMobは公式APIに基づき確度が高い、他はベストエフォート)、
  ad/rewardオブジェクトの引数はnilで渡します(Objective-Cのnilへのメッセージ送信は
  プロパティアクセス程度なら安全にゼロ値を返すため)。
