//
//  ChannelFilter.xm
//  uYouEnhanced - ChannelFilter
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "../uYouPlus.h"
#import "ChannelWhitelist.h"

// ─── ユーティリティ ───────────────────────────────────────────────────────────

static BOOL CFShouldFilter() {
    return ![[CFWhitelistManager sharedManager] isEmpty];
}

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
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [topVC presentViewController:alert animated:YES completion:nil];
    });
}

// ─── ① アカウント追加をブロック ──────────────────────────────────────────────

%hook YTAccountSwitcherController
- (void)addAccount {
    CFShowBlockAlert(@"制限", @"アカウント追加は無効化されています。");
}
%end

// ─── ② チャンネル登録ボタンを常に非表示 ──────────────────────────────────────

%hook YTSubscribeButton
- (void)layoutSubviews {
    %orig;
    // 前方宣言対策：UIViewとしてキャストしてプロパティにアクセスする
    ((UIView *)self).hidden = YES;
    ((UIView *)self).alpha = 0;
}
%end

// ─── ③-a 登録済みチャンネルの同期 ───────────────────────────────────────────

%hook YTSubscriptionsFeedController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // id型にキャストして respondsToSelector や performSelector のコンパイルエラーを回避
        if ([(id)self respondsToSelector:@selector(cf_syncWhitelist)]) {
            [(id)self performSelector:@selector(cf_syncWhitelist)];
        }
    });
}

%new
- (void)cf_syncWhitelist {
    if (![(id)self respondsToSelector:@selector(subscriptions)]) return;
    
    NSArray *subs = [(id)self performSelector:@selector(subscriptions)];
    if (!subs || ![subs isKindOfClass:[NSArray class]]) return;

    NSMutableArray<NSString *> *channelIDs = [NSMutableArray array];
    for (id renderer in subs) {
        if ([renderer respondsToSelector:@selector(channelId)]) {
            NSString *cid = [renderer performSelector:@selector(channelId)];
            if (cid && cid.length > 0) [channelIDs addObject:cid];
        }
    }
    
    if (channelIDs.count > 0) {
        [[CFWhitelistManager sharedManager] syncSubscribedChannelIDs:channelIDs];
    }
}
%end

// ─── ③-b 視聴制限（登録外チャンネルの再生を阻止） ────────────────────────────

%hook YTWatchViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!weakSelf || !CFShouldFilter()) return;
        
        NSString *channelID = nil;
        if ([(id)weakSelf respondsToSelector:@selector(channelId)]) {
            channelID = [(id)weakSelf performSelector:@selector(channelId)];
        }
        
        if (channelID && channelID.length > 0) {
            if (![[CFWhitelistManager sharedManager] isChannelAllowed:channelID]) {
                UIAlertController *alert = [UIAlertController
                    alertControllerWithTitle:@"制限"
                    message:@"登録外のチャンネルです。"
                    preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"戻る" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                    // 前方宣言対策：UIViewControllerとしてキャスト
                    UIViewController *vc = (UIViewController *)weakSelf;
                    if (vc.navigationController) [vc.navigationController popViewControllerAnimated:YES];
                    else [vc dismissViewControllerAnimated:YES completion:nil];
                }]];
                [(UIViewController *)weakSelf presentViewController:alert animated:YES completion:nil];
            }
        }
    });
}
%end

// ─── ④ タブ制限（%origを先に呼び、不整合を防止） ──────────────────────────────

%hook YTPivotBarViewController
- (void)pivotBar:(id)pivotBar didSelectItem:(id)item {
    %orig;

    if ([item respondsToSelector:@selector(pivotIdentifier)]) {
        NSString *itemID = [item performSelector:@selector(pivotIdentifier)];
        if ([itemID isEqualToString:@"FEsearch"] || [itemID isEqualToString:@"FEexplore"] || [itemID isEqualToString:@"FEShorts"]) {
            CFShowBlockAlert(@"アクセス制限", @"登録チャンネルのみ利用可能です。");
        }
    }
}
%end
