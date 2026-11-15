# ChannelFilter（学習モード）

登録チャンネル以外のコンテンツへのアクセスを制限する機能です。  
`Sources/ChannelFilter/` 以下のファイル群として実装されています。

## ファイル構成

```
Sources/ChannelFilter/
├── ChannelWhitelist.h          # ホワイトリスト管理クラスのヘッダ
├── ChannelWhitelist.m          # ホワイトリスト管理クラスの実装（永続化含む）
├── ChannelFilter.m             # メインのTweak（Logos hooks）
└── ChannelFilterSettingsController.h / .m  # 設定画面UI
```

`Sources/RootOptionsController.m` に「学習モード」へのエントリポイントを追加済みです。

---

## 機能と対応するhook

### ① アカウントロック（`kChannelFilterLockAccounts`）

- `YTAccountSwitcherController -addAccount` をフック
- 「アカウントを追加」が押されるとアラートを表示してブロック
- `kChannelFilterEnabled` と `kChannelFilterLockAccounts` の両方がONの場合のみ動作

### ② チャンネル登録ボタン非表示（`kChannelFilterDisableSubs`）

- `YTSubscribeButton -setHidden:` と `-willMoveToSuperview:` をフック
- 登録ボタンを強制的に非表示にする
- ホワイトリストへの追加は **YouTube公式アプリ** から行う

### ③ フィードフィルタ / 視聴制限

#### ホワイトリストの自動同期
- `YTSubscriptionsFeedController` の `viewDidLoad` / `viewDidAppear:` をフック
- 登録チャンネルタブが表示されるたびに、チャンネルIDを `CFWhitelistManager` に保存

#### ホームフィード・セルのフィルタ（`kChannelFilterHideHome`）
- `ASCollectionView -collectionView:cellForItemAtIndexPath:` をフック
- セルのrendererからchannelIDを取得し、ホワイトリスト外はセルを不可視・サイズ0にする

#### 動画ウォッチページのブロック
- `YTWatchViewController -viewDidLoad` をフック
- 再生開始後0.5秒でチャンネルIDを確認し、ホワイトリスト外ならアラートを出して戻る

### ④ 検索タブ・探索タブの無効化

- `kChannelFilterDisableSearch`：検索タブ（`FEsearch`）をブロック
- `kChannelFilterHideExplore`：探索タブ（`FEexplore`）をブロック
- `YTPivotBarViewController -pivotBar:didSelectItem:` をフックし、`%orig` を呼ばずにアラートを表示

---

## 設定画面の開き方

1. YouTubeアプリ → プロフィールアイコン → **uYouEnhanced Settings**
2. 一番下の **「uYouEnhanced Extras Menu」** を開く
3. **「学習モード（チャンネルフィルタ）」** をタップ

---

## ホワイトリストの更新手順

1. **YouTube公式アプリ** でチャンネルを登録する
2. uYouEnhancedの **「登録チャンネル」タブ** を開く
3. `CFWhitelistManager` が自動でチャンネルIDを同期する

> 設定画面の「許可チャンネル一覧」で同期済みのチャンネルIDを確認できます。

---

## ビルド手順（Theos）

```bash
# 依存関係のセットアップ（初回のみ）
export THEOS=~/theos
export THEOS_DEVICE_IP=<デバイスIP>

# IPAのビルド
make package JAILBROKEN=0 YOUTUBE_VERSION=20.44.2 UYOU_VERSION=3.0.4

# または GitHub Actions でビルド（.github/workflows/buildapp.yml）
# Actions の Inputs に YouTube IPA をアップロードして実行
```

---

## 注意事項

- **YouTube内部クラス名はバージョンで変わる**可能性があります。  
  `YTPivotBarViewController`・`YTAccountSwitcherController` 等が見つからない場合は  
  `%hook` を実際のクラス名に更新してください。
- `YTSubscriptionsFeedController -subscriptions` はリバースエンジニアリングによる推定です。  
  実際のメソッド名は `class-dump` や `Frida` で確認することを推奨します。
- `ASCollectionView` のフックはパフォーマンスに影響する可能性があります。  
  重い場合は `kChannelFilterHideHome` をOFFにしてください。

---

## パフォーマンスとデバッグビルド

通常ビルドでは、フィード読み込みを遅くしていたデバッグ機能（`CFLog` のログ保存、
画面上の「CF Logs」ボタン、起動時の全クラススキャン）は無効です。

調査が必要なときだけ、以下のように `CF_DEBUG=1` を付けてビルドしてください。

```bash
make package CF_DEBUG=1 JAILBROKEN=0 YOUTUBE_VERSION=20.44.2 UYOU_VERSION=3.0.4
```

UI層フィルタ（`YTAsyncCollectionView -layoutSubviews`）はセルごとの判定結果を
キャッシュしており、許可判定のセルは 0.5 秒に1回だけ再判定されます。

---

## 登録チャンネルフィードを最初から開く（ホーム非表示）

おすすめ（ホーム, `FEwhat_to_watch`）を読み込んでから登録外を捨てる方式は、
登録チャンネルの動画が揃うまで何ページも読むため遅くなります。
そこで以下を行い、最初から登録チャンネルのフィード（`FEsubscriptions`）を開きます。
サーバー側で既に登録チャンネルの動画だけになっているため、待ち時間がほぼありません。

- `YTPivotBarView -setRenderer:` でタブバーからホームタブを外す（登録チャンネルタブがある場合のみ）
- `YTPivotBarViewController -viewDidAppear:` で起動時に登録チャンネルタブを選択
- `YTPivotBarViewController -selectItemWithPivotIdentifier:` でホームへの切り替えを登録チャンネルに振り替え

手法は YTLite（dayanch96/YTLite の Startup Tab / Remove Tabs）と uYouEnhanced の Hide Home Tab と同じです。
検索・関連動画などのフィルタはこれまで通り残っています。
