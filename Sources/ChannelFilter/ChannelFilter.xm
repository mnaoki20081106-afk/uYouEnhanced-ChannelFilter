//
//  ChannelFilter.xm
//  uYouEnhanced - ChannelFilter
//
//  機能:
//    ① アカウントは1つまで（2件目以降の追加をブロック）
//    ② チャンネル登録ボタンを常に非表示
//    ③ 「登録チャンネル」タブ表示時にホワイトリストを自動同期
//
//  フィード・検索結果のフィルタリングは uYouPlus.xm の ASCollectionView フックで行う。
//  詰み防止: ホワイトリストが空の間はフィルタを一切かけない。
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

// ─── ① アカウントは1つまで ──────────────────────────────────────────────────

%hook YTAccountSwitcherController
- (void)addAccount {
    NSArray *currentAccounts = nil;
    if ([(id)self respondsToSelector:@selector(accounts)]) {
        currentAccounts = [(id)self performSelector:@selector(accounts)];
    }
    if (currentAccounts && currentAccounts.count >= 1) {
        CFShowBlockAlert(@"アカウント追加の制限",
                         @"このアプリでは複数のアカウントを使用できません。");
        return;
    }
    %orig;
}
%end

// ─── ② チャンネル登録ボタンを常に非表示 ──────────────────────────────────────

%hook YTSubscribeButton
- (void)didMoveToWindow {
    %orig;
    ((UIView *)self).hidden = YES;
    ((UIView *)self).alpha = 0;
}
- (void)layoutSubviews {
    %orig;
    ((UIView *)self).hidden = YES;
    ((UIView *)self).alpha = 0;
}
%end

// ─── ③ 「登録チャンネル」タブでホワイトリストを自動同期 ──────────────────────

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
                if (cid && cid.length > 0) [channelIDs addObject:cid];
            }
        }
        if (channelIDs.count > 0) {
            [[CFWhitelistManager sharedManager] syncSubscribedChannelIDs:channelIDs];
            NSLog(@"[ChannelFilter] Whitelist synced: %lu channels", (unsigned long)channelIDs.count);
        }
    });
}
%end
