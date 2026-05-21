//
//  ChannelFilter.xm
//  uYouEnhanced - ChannelFilter
//
//  実装済み機能（全て常時ON）:
//    1. チャンネルフィルター  - ホーム・検索・探索フィードからホワイトリスト外を除去
//                             - 登録チャンネルタブを開くとホワイトリスト自動同期
//    2. アカウント追加ブロック
//    3. 登録ボタン非表示
//    4. STARDYロゴ置き換え
//
//  フィルター実装方針（CF Logで全て動作確認済み）:
//    - 登録タブ判定: YTBrowseViewController.setNavigationEndpoint: で
//                   browseId="FEsubscriptions" を検知してフラグを立てる
//    - channelId取得: YTIElementRenderer.elementData (_NSInlineData) を
//                     ISO Latin-1 でテキスト化し UC[A-Za-z0-9_-]{22} で抽出
//    - 登録ボタン判定: accessibilityIdentifier = "id.ui.title.tab.button"
//                     parentVC = YTHeaderViewController
//
//  注意:
//    - %ctor は uYouPlus.xm の %init; で自動初期化されるため書かない
//    - ASCollectionView は uYouPlus.xm でフック済みのため使わない
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "ChannelWhitelist.h"

// ─────────────────────────────────────────────────────────────────────────────
// 前方宣言
// ─────────────────────────────────────────────────────────────────────────────
@interface YTInlineSignInViewController : UIViewController
- (void)didTapShowAddAccount;
@end

@interface YTQTMButton : UIButton
@end

@interface YTBrowseViewController : UIViewController
@end

@interface YTAppCollectionViewController : UIViewController
@end

// ─────────────────────────────────────────────────────────────────────────────
// ヘルパー: アラート表示
// ─────────────────────────────────────────────────────────────────────────────
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

// ─────────────────────────────────────────────────────────────────────────────
// ヘルパー: Protobufバイナリから channelId を抽出
// ─────────────────────────────────────────────────────────────────────────────
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

// ─────────────────────────────────────────────────────────────────────────────
// 機能1-A: 登録チャンネルタブ判定
//
// YTBrowseViewController.setNavigationEndpoint: をフックし、
// browseId = "FEsubscriptions" のとき NSUserDefaults にフラグを立てる。
// browseId が別の値（チャンネルIDや FEwhat_to_watch 等）のときはフラグを下ろす。
// ─────────────────────────────────────────────────────────────────────────────
static NSString *const kCFSubTabKey = @"cf_is_subscription_tab";

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
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kCFSubTabKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
    } else if ([browseId hasPrefix:@"FE"]) {
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kCFSubTabKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    // UC...チャンネルページはフラグを変更しない
}
- (void)setBrowseEndpoint:(id)endpoint {
    %orig;
    if (!endpoint) return;
    NSString *browseId = nil;
    if ([endpoint respondsToSelector:@selector(browseId)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        browseId = [endpoint performSelector:@selector(browseId)];
        #pragma clang diagnostic pop
    }
    if (!browseId.length) return;
    if ([browseId isEqualToString:@"FEsubscriptions"]) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kCFSubTabKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
    } else if ([browseId hasPrefix:@"FE"]) {
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kCFSubTabKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}
%end

// ─────────────────────────────────────────────────────────────────────────────
// 機能1-B: フィードフィルター + ホワイトリスト同期
// ─────────────────────────────────────────────────────────────────────────────
@interface YTInnerTubeCollectionViewController : UIViewController
@end

%hook YTInnerTubeCollectionViewController
- (void)addSectionsFromArray:(NSArray *)array {
    CFWhitelistManager *wl = [CFWhitelistManager sharedManager];
    BOOL isSubscriptionFeed = [[NSUserDefaults standardUserDefaults]
        boolForKey:kCFSubTabKey];
    BOOL shouldFilter = !isSubscriptionFeed && ![wl isEmpty];

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

            // ショート動画の判定: elementDataが1337バイト固定 = ショート
            // CF Logで確認済み: ショートはUCパターンがバイナリに存在しない
            BOOL isShort = ([(NSData *)elemData length] == 1337);

            if (isShort) {
                // ショートはchannelIdが取れないのでdataLenで判定して除去
                if (shouldFilter) {
                    [itemsToRemove addIndex:ii];
                } else if (isSubscriptionFeed) {
                    // 登録タブのショートは同期不要（channelId取得不可）
                }
                continue;
            }

            // ショート判定: dataLen==1337 または KEN_BURNSを含む
            NSUInteger dataLen = [(NSData *)elemData length];
            if (dataLen == 1337) {
                if (shouldFilter) [itemsToRemove addIndex:ii];
                continue;
            }
            NSString *rawStr = [[NSString alloc] initWithData:(NSData *)elemData
                                                     encoding:NSISOLatin1StringEncoding];
            if (rawStr && [rawStr containsString:@"KEN_BURNS"]) {
                if (shouldFilter) [itemsToRemove addIndex:ii];
                continue;
            }

            NSString *channelId = cf_extractChannelId((NSData *)elemData);
            if (!channelId.length) continue;

            if (isSubscriptionFeed) {
                [channelIdsForSync addObject:channelId];
            } else if (shouldFilter && ![wl isChannelAllowed:channelId]) {
                [itemsToRemove addIndex:ii];
            }
        }

        if (itemsToRemove.count > 0) {
            NSMutableArray *mut = [items mutableCopy];
            [mut removeObjectsAtIndexes:itemsToRemove];
            if ([section respondsToSelector:@selector(setContentsArray:)]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [section performSelector:@selector(setContentsArray:)
                             withObject:mut];
                #pragma clang diagnostic pop
            }
            if (mut.count == 0) [sectionsToRemove addIndex:si];
        }
    }

    if (sectionsToRemove.count > 0) {
        NSMutableArray *mut = [array mutableCopy];
        [mut removeObjectsAtIndexes:sectionsToRemove];
        %orig(mut);
    } else {
        %orig;
    }

    // ホワイトリスト同期（登録チャンネルタブのみ）
    if (isSubscriptionFeed && channelIdsForSync.count > 0) {
        [wl syncSubscribedChannelIDs:channelIdsForSync];
    }
}
%end

// ─────────────────────────────────────────────────────────────────────────────
// 機能2: アカウント追加ブロック
// ─────────────────────────────────────────────────────────────────────────────
%hook YTInlineSignInViewController
- (void)didTapShowAddAccount {
    cf_showAlert(@"アカウント追加不可",
                 @"このビルドでは複数アカウントの追加は許可されていません。");
}
%end

// ─────────────────────────────────────────────────────────────────────────────
// 機能3: 登録ボタン非表示
//
// CF Logで確認済み:
//   accessibilityIdentifier = "id.ui.title.tab.button"
//   parentVC = YTHeaderViewController
// ─────────────────────────────────────────────────────────────────────────────
%hook YTQTMButton
- (void)setTitle:(NSString *)title forState:(UIControlState)state {
    %orig;
    if ([self.accessibilityIdentifier isEqualToString:@"id.ui.title.tab.button"]) {
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

// ─────────────────────────────────────────────────────────────────────────────
// 機能4: STARDYロゴ置き換え
// ─────────────────────────────────────────────────────────────────────────────
static UIImage *cf_stardyLogo(BOOL dark) {
    static NSString *darkPath;
    static NSString *litePath;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bPath = [[NSBundle mainBundle]
            pathForResource:@"uYouPlus" ofType:@"bundle"];
        NSBundle *b = bPath ? [NSBundle bundleWithPath:bPath] : nil;
        darkPath = [b pathForResource:@"PremiumLogo_dark" ofType:@"png"];
        litePath = [b pathForResource:@"PremiumLogo_lite" ofType:@"png"];
    });
    NSString *path = dark ? darkPath : litePath;
    if (!path) return nil;
    return [UIImage imageWithContentsOfFile:path];
}

%hook UIImage
+ (UIImage *)imageNamed:(NSString *)name
               inBundle:(NSBundle *)bundle
compatibleWithTraitCollection:(UITraitCollection *)tc {
    if ([name isEqualToString:@"youtube_logo_dark_cairo"] ||
        [name isEqualToString:@"youtube_premium_logo_dark_cairo"]) {
        UIImage *logo = cf_stardyLogo(YES);
        if (logo) return logo;
    } else if ([name isEqualToString:@"youtube_premium_badge_light"] ||
               [name isEqualToString:@"youtube_premium_standalone_cairo"]) {
        UIImage *logo = cf_stardyLogo(NO);
        if (logo) return logo;
    }
    return %orig;
}

+ (UIImage *)imageNamed:(NSString *)name {
    if ([name isEqualToString:@"youtube_logo_dark_cairo"] ||
        [name isEqualToString:@"youtube_premium_logo_dark_cairo"]) {
        UIImage *logo = cf_stardyLogo(YES);
        if (logo) return logo;
    } else if ([name isEqualToString:@"youtube_premium_badge_light"] ||
               [name isEqualToString:@"youtube_premium_standalone_cairo"]) {
        UIImage *logo = cf_stardyLogo(NO);
        if (logo) return logo;
    }
    return %orig;
}
%end
