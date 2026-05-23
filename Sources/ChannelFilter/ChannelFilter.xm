//
//  ChannelFilter.xm
//  uYouEnhanced - ChannelFilter
//
//  実装済み機能（全て常時ON）:
//    1. チャンネルフィルター  - ホーム・検索・探索フィードから登録チャンネル以外を非表示
//                             - 登録チャンネルタブを開くとホワイトリスト自動同期
//    2. アカウント追加ブロック
//    3. 登録ボタン非表示
//    4. STARDYロゴ置き換え
//
//  重要な知見:
//    - addSectionsFromArray: はバッファ管理のみで描画に影響しない
//    - YTAppCollectionViewController を直接フックすることで画面反映できる
//    - KEN_BURNS は通常動画にも含まれるためショート判定には使わない
//    - channelIdが抽出できないアイテム = ショートまたは広告（スキップ）
//
//  制約:
//    - %ctor を書かない（uYouPlus.xm の %init; で自動初期化）
//    - ASCollectionView をフックしない（二重フックでクラッシュ）
//    - YTAppDelegate をフックしない（二重フックでクラッシュ）
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "ChannelWhitelist.h"

// ─── 前方宣言 ─────────────────────────────────────────────────────────────────
@interface YTInlineSignInViewController : UIViewController
- (void)didTapShowAddAccount;
@end

@interface YTQTMButton : UIButton
@end

@interface YTBrowseViewController : UIViewController
@end

@interface YTAppCollectionViewController : UIViewController
@end

@interface YTHeaderViewController : UIViewController
@end

// ─── ヘルパー: アラート表示 ───────────────────────────────────────────────────
static void cf_showAlert(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:title
                             message:message
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                 style:UIAlertActionStyleDefault
                                               handler:nil]];
        UIWindow *window = nil;
        if (@available(iOS 15, *)) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]])
                    for (UIWindow *w in ((UIWindowScene *)scene).windows)
                        if (w.isKeyWindow) { window = w; break; }
            }
        }
        if (!window) window = [UIApplication sharedApplication].keyWindow;
        UIViewController *root = window.rootViewController;
        while (root.presentedViewController) root = root.presentedViewController;
        [root presentViewController:alert animated:YES completion:nil];
    });
}

// ─── ヘルパー: Protobufバイナリから channelId を抽出 ──────────────────────────
static NSRegularExpression *cf_channelIdRegex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = [NSRegularExpression
            regularExpressionWithPattern:@"UC[A-Za-z0-9_-]{22}"
                                 options:0 error:nil];
    });
    return regex;
}

static NSString *cf_extractChannelId(NSData *data) {
    if (!data) return nil;
    NSString *raw = [[NSString alloc] initWithData:data
                                          encoding:NSISOLatin1StringEncoding];
    if (!raw) return nil;
    NSTextCheckingResult *match = [cf_channelIdRegex()
        firstMatchInString:raw options:0 range:NSMakeRange(0, raw.length)];
    return match ? [raw substringWithRange:match.range] : nil;
}

// ─── ヘルパー: STARDYロゴ ─────────────────────────────────────────────────────
static UIImage *cf_stardyLogo(BOOL dark) {
    static NSString *darkPath;
    static NSString *litePath;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bPath = [[NSBundle mainBundle]
            pathForResource:@"uYouPlus" ofType:@"bundle"];
        NSBundle *b = bPath ? [NSBundle bundleWithPath:bPath] : nil;
        // ユーザー提供PNG: 1000x294px
        // scale=4.5455 を指定 → 画面上で220x64.7ptとして表示（ぼやけなし）
        darkPath = [b pathForResource:@"PremiumLogo_dark" ofType:@"png"];
        litePath = [b pathForResource:@"PremiumLogo_lite" ofType:@"png"];
    });
    NSString *path = dark ? darkPath : litePath;
    if (!path) return nil;
    UIImage *raw = [UIImage imageWithContentsOfFile:path];
    if (!raw) return nil;
    // 1000px / 220pt = 4.5455
    return [UIImage imageWithCGImage:raw.CGImage scale:4.5455f
                         orientation:UIImageOrientationUp];
}

// ─── 機能1-A: 登録チャンネルタブ判定 ─────────────────────────────────────────
%hook YTBrowseViewController
- (void)setNavigationEndpoint:(id)endpoint {
    %orig;
    if (!endpoint) return;
    id browseEP = nil;
    if ([endpoint respondsToSelector:@selector(browseEndpoint)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        browseEP = [endpoint performSelector:@selector(browseEndpoint)];
        #pragma clang diagnostic pop
    }
    NSString *browseId = nil;
    if ([browseEP respondsToSelector:@selector(browseId)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        browseId = [browseEP performSelector:@selector(browseId)];
        #pragma clang diagnostic pop
    }
    if (!browseId.length) return;
    if ([browseId isEqualToString:@"FEsubscriptions"]) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"cf_is_subscription_tab"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    } else if ([browseId hasPrefix:@"FE"]) {
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"cf_is_subscription_tab"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    // UC...チャンネルページはフラグを変更しない
}
%end

// ─── 機能1-B: フィードフィルター + ホワイトリスト同期 ────────────────────────
// YTAppCollectionViewController を直接フックする（スーパークラスフックは画面に反映されない）
%hook YTAppCollectionViewController

- (void)setNavigationEndpoint:(id)endpoint {
    %orig;
    if (!endpoint) return;
    id browseEP = nil;
    if ([endpoint respondsToSelector:@selector(browseEndpoint)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        browseEP = [endpoint performSelector:@selector(browseEndpoint)];
        #pragma clang diagnostic pop
    }
    NSString *browseId = nil;
    if ([browseEP respondsToSelector:@selector(browseId)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        browseId = [browseEP performSelector:@selector(browseId)];
        #pragma clang diagnostic pop
    }
    if (!browseId.length) return;
    if ([browseId isEqualToString:@"FEsubscriptions"]) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"cf_is_subscription_tab"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    } else if ([browseId hasPrefix:@"FE"]) {
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"cf_is_subscription_tab"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}

- (void)addSectionsFromArray:(NSArray *)array {
    CFWhitelistManager *wl = [CFWhitelistManager sharedManager];
    BOOL isSubscriptionFeed = [[NSUserDefaults standardUserDefaults]
        boolForKey:@"cf_is_subscription_tab"];
    BOOL shouldFilter = !isSubscriptionFeed && ![wl isEmpty];

    // フィルター不要かつ同期不要なら即リターン
    if (!shouldFilter && !isSubscriptionFeed) {
        %orig;
        return;
    }

    NSMutableArray *channelIdsForSync = isSubscriptionFeed
        ? [NSMutableArray array] : nil;
    NSMutableIndexSet *sectionsToRemove = [NSMutableIndexSet indexSet];

    for (NSUInteger si = 0; si < array.count; si++) {
        id section = array[si];
        NSString *secClass = NSStringFromClass([section class]);
        if ([secClass containsString:@"FilterChip"] ||
            [secClass containsString:@"ChipBar"]) continue;
        if (![section respondsToSelector:@selector(contentsArray)]) continue;
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        NSArray *items = [section performSelector:@selector(contentsArray)];
        #pragma clang diagnostic pop
        if (!items.count) continue;

        NSMutableIndexSet *itemsToRemove = [NSMutableIndexSet indexSet];
        for (NSUInteger ii = 0; ii < items.count; ii++) {
            id item = items[ii];
            if (![item respondsToSelector:@selector(elementRenderer)]) continue;
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id elemRenderer = [item performSelector:@selector(elementRenderer)];
            #pragma clang diagnostic pop
            if (!elemRenderer) continue;
            if (![elemRenderer respondsToSelector:@selector(elementData)]) continue;
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id elemData = [elemRenderer performSelector:@selector(elementData)];
            #pragma clang diagnostic pop
            if (!elemData || ![elemData isKindOfClass:[NSData class]]) continue;

            NSString *channelId = cf_extractChannelId((NSData *)elemData);
            if (!channelId.length) continue; // ショート・広告はスキップ

            if (isSubscriptionFeed) {
                [channelIdsForSync addObject:channelId];
            } else if (shouldFilter) {
                if (![wl isChannelAllowed:channelId]) {
                    [itemsToRemove addIndex:ii];
                }
            }
        }

        if (itemsToRemove.count > 0) {
            NSMutableArray *filteredItems = [items mutableCopy];
            [filteredItems removeObjectsAtIndexes:itemsToRemove];
            if ([section respondsToSelector:@selector(setContentsArray:)]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [section performSelector:@selector(setContentsArray:)
                             withObject:filteredItems];
                #pragma clang diagnostic pop
            }
            if (filteredItems.count == 0) [sectionsToRemove addIndex:si];
        }
    }

    NSMutableArray *filteredArray = [array mutableCopy];
    if (sectionsToRemove.count > 0) {
        [filteredArray removeObjectsAtIndexes:sectionsToRemove];
    }
    %orig(filteredArray);

    if (isSubscriptionFeed && channelIdsForSync.count > 0) {
        [wl syncSubscribedChannelIDs:channelIdsForSync];
    }
}
%end

// ─── 機能2: アカウント追加ブロック ───────────────────────────────────────────
%hook YTInlineSignInViewController
- (void)didTapShowAddAccount {
    cf_showAlert(@"アカウント追加不可",
                 @"このビルドでは複数アカウントの追加は許可されていません。");
}
%end

// ─── 機能3: 登録ボタン非表示 ─────────────────────────────────────────────────
%hook YTQTMButton
- (void)setAccessibilityIdentifier:(NSString *)identifier {
    %orig;
    if ([identifier isEqualToString:@"id.ui.title.tab.button"]) {
        self.hidden = YES;
        self.alpha  = 0;
    }
}
- (void)willMoveToWindow:(UIWindow *)newWindow {
    %orig;
    if (!newWindow) return;
    if ([self.accessibilityIdentifier isEqualToString:@"id.ui.title.tab.button"]) {
        self.hidden = YES;
        self.alpha  = 0;
    }
}
%end

%hook YTHeaderViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    id s = (id)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableArray *stack = [NSMutableArray arrayWithObject:[(UIViewController *)s view]];
        while (stack.count > 0) {
            UIView *v = stack.lastObject;
            [stack removeLastObject];
            if ([NSStringFromClass([v class]) isEqualToString:@"YTQTMButton"]) {
                if ([v.accessibilityIdentifier
                     isEqualToString:@"id.ui.title.tab.button"]) {
                    v.hidden = YES;
                    v.alpha  = 0;
                }
            }
            for (UIView *sub in v.subviews) [stack addObject:sub];
        }
    });
}
%end

// ─── ヘルパー: ShortsロゴSVG→PNG ────────────────────────────────────────────
static UIImage *cf_shortsLogo(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bPath = [[NSBundle mainBundle]
            pathForResource:@"uYouPlus" ofType:@"bundle"];
        NSBundle *b = bPath ? [NSBundle bundleWithPath:bPath] : nil;
        // ユーザー提供PNG: 1920x2385px
        // scale=40.0 を指定 → 画面上で48x59.6ptとして表示（ぼやけなし）
        path = [b pathForResource:@"ShortsLogo" ofType:@"png"];
    });
    if (!path) return nil;
    UIImage *raw = [UIImage imageWithContentsOfFile:path];
    if (!raw) return nil;
    // 1920px / 48pt = 40.0
    return [UIImage imageWithCGImage:raw.CGImage scale:40.0f
                         orientation:UIImageOrientationUp];
}

// ─── 機能4: STARDYロゴ + Shortsロゴ置き換え ──────────────────────────────────
%hook UIImage
+ (UIImage *)imageNamed:(NSString *)name
               inBundle:(NSBundle *)bundle
compatibleWithTraitCollection:(UITraitCollection *)tc {
    // メインロゴ置き換え
    if ([name isEqualToString:@"youtube_logo_dark_cairo"] ||
        [name isEqualToString:@"youtube_premium_logo_dark_cairo"]) {
        UIImage *i = cf_stardyLogo(YES); if (i) return i;
    }
    if ([name isEqualToString:@"youtube_premium_badge_light"] ||
        [name isEqualToString:@"youtube_premium_standalone_cairo"]) {
        UIImage *i = cf_stardyLogo(NO); if (i) return i;
    }
    // Shortsロゴ置き換え（候補を全て試す）
    if ([name isEqualToString:@"ic_shorts_logo"] ||
        [name isEqualToString:@"youtube_shorts_logo"] ||
        [name isEqualToString:@"shorts_logo"] ||
        [name isEqualToString:@"reel_logo"] ||
        [name isEqualToString:@"ic_shorts_logo_fill"] ||
        [name isEqualToString:@"ic_shorts_logo_outline"] ||
        [name isEqualToString:@"youtube_shorts_24"] ||
        [name isEqualToString:@"youtube_shorts_fill_24"] ||
        [name isEqualToString:@"yt_shorts_logo"]) {
        UIImage *i = cf_shortsLogo(); if (i) return i;
    }
    // 調査ログ（shortsまたはreelを含む画像名を記録）
    if ([name containsString:@"shorts"] || [name containsString:@"Shorts"] ||
        [name containsString:@"reel"] || [name containsString:@"Reel"]) {
        static NSMutableSet *_logged;
        if (!_logged) _logged = [NSMutableSet set];
        if (![_logged containsObject:name]) {
            [_logged addObject:name];
            NSLog(@"[CF][ShortsImg] inBundle: %@", name);
        }
    }
    return %orig;
}
+ (UIImage *)imageNamed:(NSString *)name {
    // メインロゴ置き換え
    if ([name isEqualToString:@"youtube_logo_dark_cairo"] ||
        [name isEqualToString:@"youtube_premium_logo_dark_cairo"]) {
        UIImage *i = cf_stardyLogo(YES); if (i) return i;
    }
    if ([name isEqualToString:@"youtube_premium_badge_light"] ||
        [name isEqualToString:@"youtube_premium_standalone_cairo"]) {
        UIImage *i = cf_stardyLogo(NO); if (i) return i;
    }
    // Shortsロゴ置き換え
    if ([name isEqualToString:@"ic_shorts_logo"] ||
        [name isEqualToString:@"youtube_shorts_logo"] ||
        [name isEqualToString:@"shorts_logo"] ||
        [name isEqualToString:@"reel_logo"] ||
        [name isEqualToString:@"ic_shorts_logo_fill"] ||
        [name isEqualToString:@"ic_shorts_logo_outline"] ||
        [name isEqualToString:@"youtube_shorts_24"] ||
        [name isEqualToString:@"youtube_shorts_fill_24"] ||
        [name isEqualToString:@"yt_shorts_logo"]) {
        UIImage *i = cf_shortsLogo(); if (i) return i;
    }
    // 調査ログ
    if ([name containsString:@"shorts"] || [name containsString:@"Shorts"] ||
        [name containsString:@"reel"] || [name containsString:@"Reel"]) {
        static NSMutableSet *_logged2;
        if (!_logged2) _logged2 = [NSMutableSet set];
        if (![_logged2 containsObject:name]) {
            [_logged2 addObject:name];
            NSLog(@"[CF][ShortsImg] imageNamed: %@", name);
        }
    }
    return %orig;
}
%end
