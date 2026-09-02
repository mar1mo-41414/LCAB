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

## バナーコンテナの親ラッパーが空白のまま残る問題(未解決)

`ABForceHiddenRecursive`でバナーコンテナ自身とその子孫を`hidden=YES`にできても、
そのバナーを画面幅いっぱいの帯として包む**専用ラッパーView**(SDKが用意する無名の`UIView`、
クラス自体はフックできない汎用クラス)が高さ分のレイアウトスペースを確保したまま残り、
白い帯として見え続けるケースを実機で確認しました(Snow: `GFPNativeAd`を独自レイアウトで
描画する`FADAdViewCustomLayout`の親、素の`UIView`)。

対策として「祖先を辿り、その祖先が唯一の子(このバナー)しか持たない限り再帰的に`hidden`を
強制する」ヒューリスティックを実装して試しましたが、実際のアプリのUI階層では中間コンテナが
一時的に子1つだけの状態になっているケースが多数あり、想定よりはるかに高い階層まで条件を
満たし続けて隠す処理が伝播し、広告と無関係な正当なUI(画面下部のツールバー全体など)まで
消してしまう副作用が実機で確認されたため撤回しました。「唯一の子を持つ」という条件は、
広告専用ラッパーの特徴として直感的には妥当に思えますが、単なるレイアウト都合でも頻繁に
成立してしまい、階層を遡れば遡るほど誤検出のリスクが増します。

現状、この帯は既知の制約として受け入れています。広告のコンテンツ自体(画像・テキスト・
タップ誘導)は消えるため、実用上の影響はある程度軽減されます。

## delegate引数が計測・中継レイヤーを経由するケース

リワード報酬の通知先として渡ってくる`delegate`引数が、ゲーム自身の実装ではなく、
メディエーションSDKが用意する**計測・中継用のラッパーオブジェクト**であることがあります
(Godus: Unity Ads本体のレガシー静的API`show:placementId:options:showDelegate:`の
`showDelegate`引数が、実際にはironSourceのAdQuality計測レイヤー`SMLDelegate`
(`ISAdQualityAdDelegate`のサブクラス)だった)。このラッパーは`respondsToSelector:`に
YESと答え、呼び出し自体も成功しますが、内部で追加の状態検証(広告のライフサイクル管理、
在庫の実在性チェック等)を行っていることがあり、単純にプロトコルメソッドを呼ぶだけでは
効果が出ないことがあります。

このケースでは、`respondsToSelector:`の結果だけで判断せず、delegateの実クラス名・
クラス階層(`class_getSuperclass`を辿る)・ivar一覧(`class_copyIvarList`+
`ivar_getTypeEncoding`+`object_getIvar`)を診断ログに出して、本物のdelegateを別のivarとして
保持していないか確認するのが有効でした。Godusでは`SMLDelegate`のivar`_strongDelegate`が
実際のメディエーションアダプタ本体(`ISUnityAdsRewardedVideoDelegate`)への参照を保持して
おり、そちらに直接`unityAdsAdLoaded:`(ロード完了)→`unityAdsShowStart:`(表示開始)→
`unityAdsShowComplete:withFinishState:`(表示完了)の順で通知することで報酬付与に成功しました。
また、報酬付与系のコールバックはSDKによっては「ロード完了→表示開始→表示完了」という
ライフサイクル順序を内部で検証していることがあるため、表示完了だけでなくロード完了の通知も
先に送っておくと通りやすいです。enumの正確な値(`finishState`等)に確証が持てない場合は、
候補値を複数(0/1/2等)順に送ってしまうのも実用上有効です。

## `removeFromSuperview`の遅延クラッシュ

バナー非表示化フックの最終手段として`removeFromSuperview`でView階層から切り離す実装
(前述)が、Snowの実機で新種のクラッシュを引き起こしました。GFPネイティブ広告の
`FADCustomLayoutBaseView`と、兄弟でも祖先関係でもない別View(`FADAdViewCustomLayout`)の
`centerX`を結ぶAuto Layout制約が外部で張られており、`removeFromSuperview`でView階層から
切り離すと、その制約が「共通の祖先を持たない」不正な状態のまま残りました。

クラッシュ(`NSInternalInconsistencyException`: "because they have no common ancestor")は
`removeFromSuperview`を呼んだその場では起きず、**次のUIKitレイアウトサイクル**
(`UpdateCycle`→`QuartzCore`→`UIKitCore`、コールスタック上は完全に別の非同期タイミング)で、
その残存制約が再評価された際に発生しました。そのため、`removeFromSuperview`の呼び出し自体を
`@try`/`@catch`で囲んでも(実際に試しました)クラッシュを防げませんでした
(例外の発生元が呼び出し元のスタックの外にあるため)。

これは`removeFromSuperview`がView階層からの切り離しのみを行い、そのViewを参照する
「外部から明示的に保持されたNSLayoutConstraintインスタンス」までは自動的に非アクティブ化
しないために起こります。対策として、クラッシュリスクのあるクラス向けに`removeFromSuperview`
自体をスキップする専用バリアント(`AB_DEFINE_HIDE_BANNER_HOOK_SET_NO_REMOVE`)を用意し、
`hidden`化のみに留めるようにしました。

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
静的解析だけで手探りするよりも問題の切り分けが速くなります。ログはプロセス起動のたびに
上書きされるため、常に直近1回分の起動ログのみが残ります(以前は追記方式で複数起動分の
ログが混ざり、調査を混乱させていました)。

実装上の注意点として、`ABDebugLog`は当初「1行出力するたびにファイルをopen/seek/write/close
する」実装になっており、診断用のクラスダンプ機能(後述、600個超のクラス名を1行ずつ出力)と
組み合わさると、メインスレッドを長時間ブロックして起動ウォッチドッグにkillされる重大な
クラッシュを引き起こしました(Godus)。プロセス起動時に一度だけファイルハンドルを作成して
使い回す方式に変更して解決しています。ログ出力のような一見軽い処理でも、大量出力する
経路がある場合はI/Oコストを見積もる必要があります。

View階層ダンプ機能(`ABDumpVisibleBottomViews`)は、画面下部のView階層を`hidden`状態を
無視して出力するデバッグ用の仕組みです。「Objective-Cランタイム上は完全に非表示・切り離し
済みなのに画面には見え続ける」という症状の切り分けに使います。アプリによっては広告が
出るタイミングが起動直後ではなく、特定の画面遷移後(数十秒〜数分後)になることがあるため、
監視期間は決め打ちせず、症状に応じて調整が必要です(実際に30秒→2分に延長したケースがあります)。

## 未知の広告SDKの発見方法

対応済みのSDKを全てフックしても広告が消えない場合、`ABInstallThirdPartyAdHooks`内の
`ABLogSuspiciousAdClasses`が使う診断用キーワードリスト(`Interstitial`/`Rewarded`/`GFP`等)に
一致するクラス名を実行時に列挙してログへ出力する仕組みが有効です。ただし、キーワードに
含まれない命名のSDKは最初は見えません。実際にSnowでは"FAD"という未知のプレフィックスの
クラスが最初は一切見えておらず、VIEWDUMPで偶然「iマーク本体」に対応するクラス名
(`FADInformationIconView`)を発見してから、キーワードリストに`FAD`を追加して初めて
全容(`FADCustomLayoutBaseView`等の階層)が判明しました。

有力な手がかりとしては次のようなものがあります。

- 広告に表示される「なぜこの広告が出るか」を説明するアイコン(いわゆるAdChoices/iマーク)の
  リンク先URL。SnowではこれがLINEの広告最適化規約ページ(`terms.line.me`)だったことから、
  正体がNAVER/LINE系列の自社広告プラットフォーム「GFP」だと判明しました。
- View階層ダンプで見えるクラス名のプレフィックス・命名パターン。アプリ自身が実装した薄い
  ラッパークラス(Snowの`YRInterstitialPopupGFPAd`のような命名)は、内部で本命のSDKクラスへの
  参照を持っていることが多く、そのプロパティ型(`class_copyPropertyList`+
  `property_getAttributes`)を調べると正しいクラス名が分かります。
- クラスが見つかっても正しいメソッド名が分からない場合、`class_copyMethodList`で
  インスタンスメソッド・クラスメソッドの全一覧を診断ログにダンプするのが確実です
  (推測を重ねるより、実機で確認したメソッド名を直接使う方が速く正確でした)。

## 未解決の既知の制約

### StoneGrassのMAAdViewバナー

StoneGrass(Unity統合アプリ)の`MAAdView`バナー1件は、上記の再帰的hiddenを
`view.layer.hidden`/`view.layer.opacity=0`というCALayerレベルの直接操作にまで広げても、
さらに`didMoveToWindow`時に対象View自体を`removeFromSuperview`でView階層から完全に
切り離しても、なお画面にバナーが表示され続けました。View階層ダンプ上は完全に非表示・
切り離し済みであることを確認しているため、これはコード上のバグではなく、LiveContainerの
描画パイプライン(Unity統合特有の可能性が高い)に起因する、Objective-Cランタイム層の対策では
手が届かない制約と判断しています。同様の症状に遭遇した場合は、まずView階層ダンプで
`hidden`状態を確認し、「View階層上は正しく非表示なのに画面に見える」場合はこの既知の
制約に該当する可能性があります。

### Snowのバナー枠(帯)が残る問題

前述の「バナーコンテナの親ラッパーが空白のまま残る問題」を参照してください。

## ソースからのビルド

```bash
export THEOS=~/.theos
make
```

成果物は`.theos/obj/debug/LCAdBlocker.dylib`。リリースビルドは`make FINALPACKAGE=1`。
