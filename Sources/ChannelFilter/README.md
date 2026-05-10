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
