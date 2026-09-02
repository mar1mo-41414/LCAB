# LCAdBlocker 技術詳細

[English version →](TECHNICAL-EN.md)

このドキュメントは実装の仕組みを説明する開発者向け資料です。導入・使い方は
[README.md](../README.md) を参照してください。

## ソース構成

| ファイル | 役割 |
|---|---|
| `Sources/ABSwizzle.{h,m}` | クラス・セレクタの実行時存在確認付きでIMPを差し替える共通ヘルパー |
| `Sources/ABStoreKitHooks.{h,m}` | Apple純正StoreKit機構のフック |
| `Sources/ABThirdPartyAdHooks.{h,m}` | サードパーティ広告SDKのフック |
| `Sources/ABDebugLog.{h,m}` | 診断用の簡易ロガー(`Documents/lcadblocker.log`) |
| `Sources/ABConstructor.m` | エントリポイント(`__attribute__((constructor))`) |

## なぜCydiaSubstrateを使わないのか

LiveContainerのin-process注入環境ではCydiaSubstrateの存在が前提にできないため、
Logos(`%hook`)ではなく素のObjective-Cランタイムでmethod swizzlingを行っています。
姉妹プロジェクトの[LCME (iOS_LC_MemEditor)](https://github.com/mar1mo-41414/LCME)
と同じ方式です。

## フックインストールのタイミング

`__attribute__((constructor))`でdylibロード時に自動的にフックをインストールし、
`UIApplicationDidFinishLaunchingNotification`後にもう一度同じインストール処理を実行します
(UnityFrameworkのような追加dylibが、constructor実行時点ではまだロード・クラス登録されていない
ことがあるため)。さらに`_dyld_register_func_for_add_image`で、以後にロードされる
全ての共有ライブラリ/フレームワークに対しても再インストールを試みます。

Appodealのようなメディエーションプラットフォームでは、個々の広告ネットワークSDK
(`AppLovinSDK.framework`など)がアプリ起動時ではなくメディエーション側の初期化タイミング
(Unity C#コード実行後など、`didFinishLaunching`よりずっと後)まで実際にロードされないことが
あり、前述の2点キャプチャだけでは取りこぼします。

ただし、アプリ起動時には数百の共有ライブラリ(システムライブラリ含む)がロードされることが
あるため、素朴に「毎回全フックを最初から試し直す」実装にすると、そのタスクの山でメイン
スレッドが埋め尽くされ、アプリが実質フリーズしたまま起動できなくなる不具合を実際に踏みました。
これを避けるため2段構えの対策を入れています。

1. `ABSwizzle`側で「一度成功したフックは二度と試みない」成功キャッシュを持ち、
   `NSClassFromString`の再実行やクラス一覧の再スキャンを省略する
2. dyldコールバック自体も「既にメインキューに再インストールタスクが積まれている間は
   新たに積まない」コアレッシングを行う

この2つを組み合わせることで、イメージロードのたびに実行される処理は時間とともに軽くなります。

## `class_addMethod`優先の安全策

`class_getInstanceMethod`+`method_setImplementation`をそのまま使うと、対象クラス自身が
そのセレクタを独自実装していない場合(継承しているだけの場合)に継承元(`UIView`など多数の
クラスが継承する共通基底クラス)のメソッドテーブルごと書き換えてしまいます(実際に発生し、
アプリ全体のUI描画が壊れる重大な不具合を起こしました)。

これを避けるため、まず`class_addMethod`で対象クラス自身への新規追加を試み、追加できた場合は
それで完了、既にそのクラス自身がオーバーライド済みで追加できない場合のみ
`method_setImplementation`で直接差し替えます。

## バナー広告の非表示化

バナー広告Viewは表示トリガーとなるメソッド呼び出しがなく、window階層に追加された時点で
自動的に画面に見えるようになります。`didMoveToWindow`だけをフックしても、SDK側が自動リフレッシュ
のタイミングなどで非同期に`hidden`を書き戻してくることがある(AppLovin MAXの`MAAdView`で実際に
発生)ため、`setHidden:`も乗っ取って渡された値に関わらず常に`YES`を強制します。

`frame`を`CGRectZero`に直接書き換える案も試しましたが、Auto Layout制約下のView(InMobiの
`IMBanner`で実際に発生)では「frame変更→制約違反→再レイアウト要求→`layoutSubviews`再呼び出し→
SDK側がframeを書き戻す→……」という循環でメインスレッドがフリーズしたため撤廃しました。
`hidden`の強制だけで画面上には表示されなくなるので、`frame`はSDK/Auto Layoutの管理に委ねています。

`didMoveToWindow`+`setHidden:`の2点でもまだ不十分なケースがありました。`MAAdView`は
`setAlpha:`を独自オーバーライドしており、自動リフレッシュ時に`alpha`を明示的に1.0へ
書き戻すコードが副作用として`hidden`も`NO`に戻していると見て`setAlpha:`も乗っ取りましたが、
それでもバナーが消えないケースが残りました(後述の既知の制約を参照)。画面下部のViewツリーを
実際にダンプして特定したところ、`MAAdView`自身は正しく`hidden=1`になっているのに、
その**子ビュー**(SDKが追加する無名の`UIView`インスタンス)が`hidden=0`のまま残っており、
Unity統合特有の描画パス(推測)でUIKitの`hidden`を無視して表示され続けていました。`UIView`
クラス自体をフックするのは危険(継承元=`UIView`全体を壊す上記の既知のバグと同種)なので、
代わりに対象バナーコンテナの子孫を**特定インスタンス単位**で再帰的に`hidden=YES`にする
(`ABForceHiddenRecursive`)ようにしました。バナー系フックは全SDK共通で
`didMoveToWindow`/`setHidden:`/`layoutSubviews`/`setAlpha:`の4点セットにし、いずれも
自身だけでなく子孫全体に再帰的に`hidden`を強制します。

## リワード広告の報酬付与とMAAdのキャプチャ

リワード広告のshowをブロックした後、広告を見た体でSDK側のdelegateに成功を通知することで
ゲーム側の処理を続行させています。AppLovin MAXについては、delegateの実装(公式Unity Pluginの
`MAUnityAdManager`、ソースはGitHubで公開)が`ad.adUnitIdentifier`等をNSDictionaryリテラルに
直接詰めるため、`ad`引数にnilや偽装オブジェクトを渡すとクラッシュしうることが判明しました。
そのため`didLoadAd:`を横取りして実際にロードされた本物の`MAAd`インスタンスをフォーマット別
(interstitial/rewarded/appOpen)にキャプチャしておき、show断念時にそれを使い回しています。

## 診断ログとView階層ダンプ

`ABDebugLog`がフックのインストール成否・実際に発火したフック・リワード付与時のdelegate通知
結果をファイルログに記録します。未知の広告SDKやSDKバージョン差異による対応漏れを調査する際に、
静的解析だけで手探りするよりも問題の切り分けが速くなります。

View階層ダンプ機能(`ABDumpVisibleBottomViews`)は、画面下部のView階層を`hidden`状態を
無視して出力するデバッグ用の仕組みです。「Objective-Cランタイム上は完全に非表示・切り離し
済みなのに画面には見え続ける」という症状の切り分けに使います。

## 未解決の既知の制約: StoneGrassのMAAdViewバナー

StoneGrass(Unity統合アプリ)の`MAAdView`バナー1件は、上記の再帰的hiddenを
`view.layer.hidden`/`view.layer.opacity=0`というCALayerレベルの直接操作にまで広げても、
さらに`didMoveToWindow`時に対象View自体を`removeFromSuperview`でView階層から完全に
切り離しても、なお画面にバナーが表示され続けました。View階層ダンプ上は完全に非表示・
切り離し済みであることを確認しているため、これはコード上のバグではなく、LiveContainerの
描画パイプライン(Unity統合特有の可能性が高い)に起因する、Objective-Cランタイム層の対策では
手が届かない制約と判断しています。同様の症状に遭遇した場合は、まずView階層ダンプで
`hidden`状態を確認し、「View階層上は正しく非表示なのに画面に見える」場合はこの既知の
制約に該当する可能性があります。

## ソースからのビルド

```bash
export THEOS=~/.theos
make
```

成果物は`.theos/obj/debug/LCAdBlocker.dylib`。リリースビルドは`make FINALPACKAGE=1`。
