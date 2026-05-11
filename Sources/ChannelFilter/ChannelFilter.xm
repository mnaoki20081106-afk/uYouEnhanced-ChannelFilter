//
//  ChannelFilter.xm
//  uYouEnhanced - ChannelFilter
//
//  ASCollectionView は uYouPlus.xm で既にフック済みのため除外。
//  YTPivotBarViewController も uYouPlus.xm と競合しないよう確認済み。
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "ChannelWhitelist.h"

// ─── ユーティリティ ───────────────────────────────────────────────────────────

static BOOL CFShouldFilter() {
    return ![[CFWhitelistManager sharedManager] isEmpty];
}

static void CFShowBlockAlert(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        UIViewController *topVC = window.rootViewController;
        while (topVC.presentedViewController) topVC = topVC.presentedViewController;
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:title
            message:message
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
            style:UIAlertActionStyleDefault handler:nil]];
        [topVC presentViewController:alert animated:YES completion:nil];
    });
}

// ─── ① アカウント追加をブロック ──────────────────────────────────────────────

%hook YTAccountSwitcherController

- (void)addAccount {
    CFShowBlockAlert(
        @"アカウント追加は無効です",
        @"このアプリでは複数アカウントへの切り替えはできません。"
    );
}

%end

// ─── ② チャンネル登録ボタンを常に非表示 ──────────────────────────────────────

%hook YTSubscribeButton

- (void)didMoveToWindow {
    %orig;
    self.hidden = YES;
    self.alpha = 0;
}

%end

// ─── ③-a 登録チャンネルからホワイトリストを自動同期 ──────────────────────────

%hook YTSubscriptionsFeedController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self respondsToSelector:@selector(subscriptions)]) return;
        NSArray *subs = [self subscriptions];
        if (!subs || subs.count == 0) return;
        NSMutableArray *channelIDs = [NSMutableArray array];
        for (id renderer in subs) {
            if ([renderer respondsToSelector:@selector(channelId)]) {
                NSString *cid = [renderer channelId];
                if (cid.length > 0) [channelIDs addObject:cid];
            }
        }
        if (channelIDs.count > 0) {
            [[CFWhitelistManager sharedManager] syncSubscribedChannelIDs:channelIDs];
        }
    });
}

%end

// ─── ③-b 動画再生ページのブロック ────────────────────────────────────────────

%hook YTWatchViewController

- (void)viewDidLoad {
    %orig;
    if (!CFShouldFilter()) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
        if (![self respondsToSelector:@selector(channelId)]) return;
        NSString *channelID = [self performSelector:@selector(channelId)];
        if (!channelID || channelID.length == 0) return;
        if ([[CFWhitelistManager sharedManager] isChannelAllowed:channelID]) return;
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"視聴できません"
            message:@"このチャンネルは登録チャンネルではないため視聴できません。"
            preferredStyle:UIAlertControllerStyleAlert];
        UINavigationController *nav = self.navigationController;
        [alert addAction:[UIAlertAction actionWithTitle:@"戻る"
            style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a) {
                [nav popViewControllerAnimated:YES];
            }]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

%end

// ─── ④ 検索・探索タブをブロック ──────────────────────────────────────────────

%hook YTPivotBarViewController

- (void)pivotBar:(id)pivotBar didSelectItem:(id)item {
    if ([item respondsToSelector:@selector(pivotIdentifier)]) {
        NSString *itemID = [item performSelector:@selector(pivotIdentifier)];
        if ([itemID isEqualToString:@"FEsearch"] ||
            [itemID isEqualToString:@"FEexplore"]) {
            CFShowBlockAlert(
                @"アクセスできません",
                @"登録チャンネルタブのみ利用できます。"
            );
            return;
        }
    }
    %orig;
}

%end
