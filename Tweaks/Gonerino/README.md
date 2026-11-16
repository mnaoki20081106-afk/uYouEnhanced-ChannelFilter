# Gonerino（uYouEnhanced-ChannelFilter 改変版）

元: https://github.com/castdrian/Gonerino （v1.8.10, GPL-3.0 / LICENSE 参照）

チャンネル名でフィードの動画を判定する Gonerino の仕組みを、
「登録チャンネル以外を除外する」許可リスト方式に改変したもの。

- 登録チャンネルタブ(FEsubscriptions)のフィードでは除外せず、出てきたチャンネル名を
  `CFSubscribedChannelNames`（NSUserDefaults）に追加する（`ChannelManager -addSubscribedChannel:`）
- それ以外のフィードでは、チャンネル名が許可リストに無い動画を除外する
  （`Util +nodeContainsBlockedVideo:metadata:`）。許可リストが空の間は除外しない
- フィルタは常にオン（設定・トップバーのボタンで切れない）。ボタンは非表示
- アップデート確認（外部通信）、Sideloading.x、ReelSequenceFilter はビルドしない

改変箇所には `[uYouEnhanced-ChannelFilter]` のコメントを付けている。
