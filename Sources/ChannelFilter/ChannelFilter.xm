//
//  ChannelFilter.xm
//  uYouEnhanced - ChannelFilter
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "ChannelWhitelist.h"
#import "../uYouPlus.h"

// ─── クラス定義（ここが重要：@class ではなく @interface で継承元を明示する） ───

@interface YTAccountSwitcherController : UIViewController
- (void)addAccount;
@end

@interface YTSubscribeButton : UIButton
@end

@interface YTSubscriptionsFeedController : UIViewController
- (NSArray *)subscriptions;
@end

@interface YTWatchViewController : UIViewController
- (NSString *)channelId;
@end

@interface YTPivotBarViewController : UIViewController
@end

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

// ─── ② チャンネル登録ボタンを隠す ───────────────────────────────────────────

%hook YTSubscribeButton
- (void)layoutSubviews {
    %orig;
    // @interface で UIButton 継承と定義したので self.hidden が使えるようになります
    self.hidden = YES;
    self.alpha = 0;
}
%end

// ─── ③-a 登録済みチャンネルの同期 ───────────────────────────────────────────

%hook YTSubscriptionsFeedController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if ([self respondsToSelector:@selector(cf_syncWhitelist)]) {
        [self performSelector:@selector(cf_syncWhitelist)];
    }
}

%new
- (void)cf_syncWhitelist {
    if (![self respondsToSelector:@selector(subscriptions)]) return;
    
    // NSArray として取得し、安全に ID を抽出
    NSArray *subs = [self performSelector:@selector(subscriptions)];
    if (!subs || ![subs isKindOfClass:[NSArray class]]) return;

    NSMutableArray<NSString *> *channelIDs = [NSMutableArray array];
    for (id renderer in subs) {
        // renderer が channelId メソッドを持っているか確認
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

// ─── ③-b 視聴制限 ──────────────────────────────────────────────────────────

%hook YTWatchViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    
    // 0.8秒待ってから判定（読み込み待ち）
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!weakSelf) return;
        
        NSString *channelID = nil;
        if ([weakSelf respondsToSelector:@selector(channelId)]) {
            channelID = [weakSelf performSelector:@selector(channelId)];
        }
        
        if (channelID && channelID.length > 0) {
            if (![[CFWhitelistManager sharedManager] isChannelAllowed:channelID]) {
                UIAlertController *alert = [UIAlertController
                    alertControllerWithTitle:@"制限"
                    message:@"登録外のチャンネルです。"
                    preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"戻る" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                    if (weakSelf.navigationController) [weakSelf.navigationController popViewControllerAnimated:YES];
                    else [weakSelf dismissViewControllerAnimated:YES completion:nil];
                }]];
                [weakSelf presentViewController:alert animated:YES completion:nil];
            }
        }
    });
}
%end

// ─── ④ タブ制限（クラッシュ防止のため %orig を必ず呼ぶ） ─────────────────────

%hook YTPivotBarViewController
- (void)pivotBar:(id)pivotBar didSelectItem:(id)item {
    // 内部状態を壊さないよう、先に元の処理を呼ぶ
    %orig;

    if ([item respondsToSelector:@selector(pivotIdentifier)]) {
        NSString *itemID = [item performSelector:@selector(pivotIdentifier)];
        if ([itemID isEqualToString:@"FEsearch"] || [itemID isEqualToString:@"FEexplore"] || [itemID isEqualToString:@"FEShorts"]) {
            CFShowBlockAlert(@"アクセス制限", @"登録チャンネルのみ利用可能です。");
        }
    }
}
%end
