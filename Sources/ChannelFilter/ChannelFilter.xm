//
//  ChannelFilter.xm
//  uYouEnhanced - ChannelFilter
//
//  注意: %ctor は uYouPlus.xm の %init で初期化されるため不要。
//        %orig の前にブロック処理を行いタブ移動を防ぐ。
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import "ChannelWhitelist.h"

static void CFShowBlockAlert(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        UIViewController *topVC = window.rootViewController;
        if (!topVC) return;
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

// ① アカウント追加をブロック
%hook YTAccountSwitcherController
- (void)addAccount {
    CFShowBlockAlert(@"アカウント追加は無効です",
                     @"このアプリでは複数アカウントへの切り替えはできません。");
    // %orig を呼ばない
}
%end

// ② チャンネル登録ボタンを非表示
%hook YTSubscribeButton
- (void)didMoveToWindow {
    %orig;
    ((UIView *)self).hidden = YES;
    ((UIView *)self).alpha = 0;
}
%end

// ③-a 登録チャンネルからホワイトリストを自動同期
%hook YTSubscriptionsFeedController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    id controller = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![controller respondsToSelector:@selector(subscriptions)]) return;
        NSArray *subs = [controller performSelector:@selector(subscriptions)];
        if (!subs || subs.count == 0) return;
        NSMutableArray *channelIDs = [NSMutableArray array];
        for (id renderer in subs) {
            if ([renderer respondsToSelector:@selector(channelId)]) {
                NSString *cid = [renderer performSelector:@selector(channelId)];
                if (cid.length > 0) [channelIDs addObject:cid];
            }
        }
        if (channelIDs.count > 0) {
            [[CFWhitelistManager sharedManager] syncSubscribedChannelIDs:channelIDs];
        }
    });
}
%end

// ③-b 動画再生ページのブロック
%hook YTWatchViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if ([[CFWhitelistManager sharedManager] isEmpty]) return;
    id controller = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
        if (![controller respondsToSelector:@selector(channelId)]) return;
        NSString *channelID = [controller performSelector:@selector(channelId)];
        if (!channelID || channelID.length == 0) return;
        if ([[CFWhitelistManager sharedManager] isChannelAllowed:channelID]) return;
        UIViewController *vc = (UIViewController *)controller;
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"視聴できません"
            message:@"このチャンネルは登録チャンネルではないため視聴できません。"
            preferredStyle:UIAlertControllerStyleAlert];
        UINavigationController *nav = vc.navigationController;
        [alert addAction:[UIAlertAction actionWithTitle:@"戻る"
            style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a) {
                if (nav) [nav popViewControllerAnimated:YES];
                else [vc dismissViewControllerAnimated:YES completion:nil];
            }]];
        [vc presentViewController:alert animated:YES completion:nil];
    });
}
%end

// ④ 検索・探索タブをブロック（%orig より先にチェック）
%hook YTPivotBarViewController
- (void)pivotBar:(id)pivotBar didSelectItem:(id)item {
    if ([item respondsToSelector:@selector(pivotIdentifier)]) {
        NSString *itemID = [item performSelector:@selector(pivotIdentifier)];
        if ([itemID isEqualToString:@"FEsearch"] ||
            [itemID isEqualToString:@"FEexplore"]) {
            CFShowBlockAlert(@"アクセスできません",
                             @"登録チャンネルタブのみ利用できます。");
            return; // %orig を呼ばない
        }
    }
    %orig;
}
%end
