//
//  ChannelFilter.xm
//  uYouEnhanced - ChannelFilter
//
//  機能（常時ON、ユーザーが解除する手段なし）:
//    ① アカウント追加を常にブロック
//    ② チャンネル登録ボタンを常に非表示
//    ③ ホームフィード・検索結果・おすすめ動画を登録チャンネルのみに制限（データレベルで除外）
//       動画再生画面での視聴ブロック
//    ④ 探索・ショートタブ等を常にブロック（検索は許可）
//
//  詰み防止:
//    CFWhitelistManager.isEmpty == YES のとき（ホワイトリスト未同期）は
//    フィルタを一切かけない。「登録チャンネル」タブを開くと自動同期される。
//

#import "../uYouPlus.h"
#import "ChannelWhitelist.h"

// ─── 前方宣言 ─────────────────────────────────────────────────────────────────

@interface YTAccountSwitcherController : UIViewController
- (void)addAccount;
@end

@interface YTSubscribeButton : UIButton
@end

@interface YTSubscriptionsFeedController : UIViewController
- (NSArray *)subscriptions;
@end

// ─── ユーティリティ ───────────────────────────────────────────────────────────

/// フィルタを適用すべきか。ホワイトリストが空のときは詰み防止のため無効にする。
static BOOL CFShouldFilter() {
    return ![[CFWhitelistManager sharedManager] isEmpty];
}

static void CFShowBlockAlert(NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:title
        message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    UIViewController *topVC = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (topVC.presentedViewController) topVC = topVC.presentedViewController;
    [topVC presentViewController:alert animated:YES completion:nil];
}

// ─── ① アカウント追加を常にブロック ──────────────────────────────────────────

%hook YTAccountSwitcherController

- (void)addAccount {
    CFShowBlockAlert(
        @"アカウント追加は無効です",
        @"このアプリでは複数アカウントへの切り替えはできません。"
    );
    // %orig を呼ばない
}

%end

// ─── ② チャンネル登録ボタンを常に非表示 ──────────────────────────────────────

%hook YTSubscribeButton

- (void)setHidden:(BOOL)hidden {
    %orig(YES); // 常に非表示
}

- (void)willMoveToSuperview:(UIView *)superview {
    %orig;
    self.hidden = YES;
}

%end

// ─── ③-a 登録チャンネルタブからホワイトリストを自動同期 ──────────────────────

%hook YTSubscriptionsFeedController

- (void)viewDidLoad {
    %orig;
    [self performSelector:@selector(cf_syncWhitelist)];
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [self performSelector:@selector(cf_syncWhitelist)];
}

%new
- (void)cf_syncWhitelist {
    if (![self respondsToSelector:@selector(subscriptions)]) return;
    NSArray *subs = [self subscriptions];
    if (!subs || subs.count == 0) return;

    NSMutableArray<NSString *> *channelIDs = [NSMutableArray array];
    for (id renderer in subs) {
        if ([renderer respondsToSelector:@selector(channelId)]) {
            NSString *cid = [renderer performSelector:@selector(channelId)];
            if (cid.length > 0) [channelIDs addObject:cid];
        }
    }
    if (channelIDs.count > 0) {
        [[CFWhitelistManager sharedManager] syncSubscribedChannelIDs:channelIDs];
    }
}

%end

// ─── ③-b データ通信レベルのフィルタ（おすすめ・検索結果から完全に除外） ────────────

// データ（Renderer）の奥深くからチャンネルIDを抽出する関数
static NSString *CFExtractChannelID(id renderer) {
    if (!renderer) return nil;

    // ホーム画面などのRichItemRendererだった場合は、中身のVideoRendererを取り出す
    if ([NSStringFromClass([renderer class]) isEqualToString:@"YTIRichItemRenderer"]) {
        if ([renderer respondsToSelector:@selector(content)]) {
            id content = [renderer performSelector:@selector(content)];
            if ([content respondsToSelector:@selector(videoRenderer)]) {
                renderer = [content performSelector:@selector(videoRenderer)];
            }
        }
    }

    // 1. 直接 channelId を持っているかチェック
    if ([renderer respondsToSelector:@selector(channelId)]) {
        NSString *cid = [renderer performSelector:@selector(channelId)];
        if ([cid isKindOfClass:[NSString class]] && cid.length > 0) return cid;
    }

    // 2. テキスト（チャンネル名）のリンク情報に埋め込まれているかチェック
    NSArray *textSelectors = @[@"ownerText", @"shortBylineText", @"longBylineText"];
    for (NSString *selName in textSelectors) {
        SEL sel = NSSelectorFromString(selName);
        if ([renderer respondsToSelector:sel]) {
            id formattedString = [renderer performSelector:sel];
            if ([formattedString respondsToSelector:@selector(runsArray)]) {
                NSArray *runs = [formattedString performSelector:@selector(runsArray)];
                for (id run in runs) {
                    if ([run respondsToSelector:@selector(navigationEndpoint)]) {
                        id endpoint = [run performSelector:@selector(navigationEndpoint)];
                        if ([endpoint respondsToSelector:@selector(browseEndpoint)]) {
                            id browseEndpoint = [endpoint performSelector:@selector(browseEndpoint)];
                            if ([browseEndpoint respondsToSelector:@selector(browseId)]) {
                                NSString *browseId = [browseEndpoint performSelector:@selector(browseId)];
                                if ([browseId isKindOfClass:[NSString class]] && [browseId hasPrefix:@"UC"]) {
                                    return browseId;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    return nil;
}

// ホーム画面（おすすめフィード）のデータ管理をフック
%hook YTIRichGridRenderer

- (NSMutableArray *)contentsArray {
    NSMutableArray *contents = %orig;
    if (!CFShouldFilter()) return contents;

    // 後ろからループして安全に削除する
    for (NSInteger i = contents.count - 1; i >= 0; i--) {
        id item = contents[i];
        NSString *className = NSStringFromClass([item class]);

        if ([className isEqualToString:@"YTIRichItemRenderer"]) {
            NSString *channelID = CFExtractChannelID(item);
            // チャンネルIDが取得できたがホワイトリストにない場合、またはチャンネルIDが判別できない（広告など）場合は削除
            if ((channelID && ![[CFWhitelistManager sharedManager] isChannelAllowed:channelID]) || !channelID) {
                // ただし、動画ではなく単なるヘッダーやボタンなら消さないためのチェック
                id content = [item respondsToSelector:@selector(content)] ? [item performSelector:@selector(content)] : nil;
                if (content && ([content respondsToSelector:@selector(videoRenderer)] || [content respondsToSelector:@selector(shortsLockupViewModel)])) {
                    [contents removeObjectAtIndex:i];
                }
            }
        }
        // ショート動画の棚（RichSection）は丸ごと削除
        else if ([className isEqualToString:@"YTIRichSectionRenderer"]) {
            [contents removeObjectAtIndex:i];
        }
    }
    return contents;
}

%end

// 検索結果や関連動画のデータ管理をフック
%hook YTIItemSectionRenderer

- (NSMutableArray *)contentsArray {
    NSMutableArray *contents = %orig;
    if (!CFShouldFilter()) return contents;

    for (NSInteger i = contents.count - 1; i >= 0; i--) {
        id item = contents[i];
        NSString *className = NSStringFromClass([item class]);

        BOOL isVideo = [className containsString:@"VideoRenderer"] || [className containsString:@"CompactVideoRenderer"];

        if (isVideo) {
            NSString *channelID = CFExtractChannelID(item);
            if ((channelID && ![[CFWhitelistManager sharedManager] isChannelAllowed:channelID]) || !channelID) {
                [contents removeObjectAtIndex:i];
            }
        } 
        // 検索結果に混ざるショート動画（ReelShelf）も丸ごと削除
        else if ([className containsString:@"ReelShelfRenderer"]) {
            [contents removeObjectAtIndex:i];
        }
    }
    return contents;
}

%end

// 追加読み込み（スクロールした時）のデータ管理をフック
%hook YTIAppendContinuationItemsAction

- (NSMutableArray *)continuationItemsArray {
    NSMutableArray *contents = %orig;
    if (!CFShouldFilter()) return contents;

    for (NSInteger i = contents.count - 1; i >= 0; i--) {
        id item = contents[i];
        NSString *className = NSStringFromClass([item class]);

        if ([className isEqualToString:@"YTIRichItemRenderer"]) {
            NSString *channelID = CFExtractChannelID(item);
            if ((channelID && ![[CFWhitelistManager sharedManager] isChannelAllowed:channelID]) || !channelID) {
                id content = [item respondsToSelector:@selector(content)] ? [item performSelector:@selector(content)] : nil;
                if (content && ([content respondsToSelector:@selector(videoRenderer)] || [content respondsToSelector:@selector(shortsLockupViewModel)])) {
                    [contents removeObjectAtIndex:i];
                }
            }
        }
    }
    return contents;
}

%end

// ─── ③-c 動画再生ページのブロック ────────────────────────────────────────────

%hook YTWatchViewController

- (void)viewDidLoad {
    %orig;
    if (!CFShouldFilter()) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self performSelector:@selector(cf_checkAndBlockIfNeeded)];
    });
}

%new
- (void)cf_checkAndBlockIfNeeded {
    if (!CFShouldFilter()) return;

    NSString *channelID = nil;
    if ([self respondsToSelector:@selector(channelId)]) {
        channelID = [self performSelector:@selector(channelId)];
    }
    if (!channelID || channelID.length == 0) return;

    if (![[CFWhitelistManager sharedManager] isChannelAllowed:channelID]) {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"視聴できません"
            message:@"このチャンネルは登録チャンネルではないため視聴できません。"
            preferredStyle:UIAlertControllerStyleAlert];
        UINavigationController *nav = self.navigationController;
        [alert addAction:[UIAlertAction actionWithTitle:@"戻る" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [nav popViewControllerAnimated:YES];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

%end

// ─── ④ 探索タブ等をブロック（検索は許可） ──────────────────────────────────────────

%hook YTPivotBarViewController

- (void)pivotBar:(id)pivotBar didSelectItem:(id)item {
    NSString *itemID = nil;
    if ([item respondsToSelector:@selector(pivotIdentifier)]) {
        itemID = [item performSelector:@selector(pivotIdentifier)];
    }

    // FEsearch (検索) は許可し、FEexplore (探索) や FEShorts などだけをブロックする
    if ([itemID isEqualToString:@"FEexplore"] || [itemID isEqualToString:@"FEShorts"]) {
        CFShowBlockAlert(
            @"アクセスできません",
            @"このタブは学習用アプリのため制限されています。"
        );
        return; // %orig を呼ばない
    }

    %orig;
}

%end
