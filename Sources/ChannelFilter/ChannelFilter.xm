//
//  ChannelFilter.m
//  uYouEnhanced - ChannelFilter
//
//  機能（常時ON、ユーザーが解除する手段なし）:
//    ① アカウント追加を常にブロック
//    ② チャンネル登録ボタンを常に非表示
//    ③ ホームフィード・動画再生を登録チャンネルのみに制限
//    ④ 検索タブ・探索タブを常にブロック
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
- (void)cf_syncWhitelist;
@end

// YTWatchViewController は YouTubeHeader に定義済みのためカテゴリで拡張
@interface YTWatchViewController (ChannelFilter)
- (void)cf_checkAndBlockIfNeeded;
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
    // ホワイトリスト未同期でも常にブロック（アカウント追加は同期状態に関係ない）
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
    [self cf_syncWhitelist];
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [self cf_syncWhitelist];
}

%new
- (void)cf_syncWhitelist {
    if (![self respondsToSelector:@selector(subscriptions)]) return;
    NSArray *subs = [self subscriptions];
    if (!subs || subs.count == 0) return;

    NSMutableArray<NSString *> *channelIDs = [NSMutableArray array];
    for (id renderer in subs) {
        if ([renderer respondsToSelector:@selector(channelId)]) {
            NSString *cid = [renderer channelId];
            if (cid.length > 0) [channelIDs addObject:cid];
        }
    }
    if (channelIDs.count > 0) {
        [[CFWhitelistManager sharedManager] syncSubscribedChannelIDs:channelIDs];
    }
}

%end

// ─── ③-b ホームフィードのセルフィルタ ────────────────────────────────────────

%hook ASCollectionView

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewCell *cell = %orig;
    if (!CFShouldFilter()) return cell;

    if ([cell respondsToSelector:@selector(node)]) {
        id node = [cell performSelector:@selector(node)];
        if ([node respondsToSelector:@selector(renderer)]) {
            id renderer = [node performSelector:@selector(renderer)];
            if ([renderer respondsToSelector:@selector(channelId)]) {
                NSString *channelID = [renderer performSelector:@selector(channelId)];
                if (channelID.length > 0 && ![[CFWhitelistManager sharedManager] isChannelAllowed:channelID]) {
                    cell.hidden = YES;
                    cell.frame = CGRectMake(cell.frame.origin.x, cell.frame.origin.y, 0, 0);
                }
            }
        }
    }
    return cell;
}

%end

// ─── ③-c 動画再生ページのブロック ────────────────────────────────────────────

%hook YTWatchViewController

- (void)viewDidLoad {
    %orig;
    if (!CFShouldFilter()) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self cf_checkAndBlockIfNeeded];
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

// ─── ④ 検索・探索タブを常にブロック ──────────────────────────────────────────

%hook YTPivotBarViewController

- (void)pivotBar:(id)pivotBar didSelectItem:(id)item {
    NSString *itemID = nil;
    if ([item respondsToSelector:@selector(pivotIdentifier)]) {
        itemID = [item performSelector:@selector(pivotIdentifier)];
    }

    if ([itemID isEqualToString:@"FEsearch"] || [itemID isEqualToString:@"FEexplore"]) {
        CFShowBlockAlert(
            @"アクセスできません",
            @"登録チャンネルタブのみ利用できます。"
        );
        return; // %orig を呼ばない
    }

    %orig;
}

%end

// ─── フック登録 ──────────────────────────────────────────────────────────────
// %constructor はアプリ起動時に自動で呼ばれる。
// ChannelFilter は常時ONのため条件なしで %init する。
%ctor {
    %init;
}
