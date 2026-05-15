//
//  ChannelFilter.xm
//  uYouEnhanced - ChannelFilter
//
//  実装済み機能（全て常時ON・ユーザー解除不可）:
//    1. チャンネルフィルター  - ホーム・検索・探索フィードからホワイトリスト外チャンネルを除去
//                             - 登録チャンネルタブ(YTBrowseViewController/browseId=FEsubscriptions)
//                               を開くとホワイトリストを自動同期
//    2. アカウント追加ブロック - YTInlineSignInViewController.didTapShowAddAccount をブロック
//    3. 登録ボタン非表示      - YTQTMButton を hidden
//    4. STARDYロゴ置き換え   - UIImage +imageNamed:inBundle: をフックして差し替え
//
//  フィルター実装方針:
//    YTIElementRenderer.elementData (_NSInlineData = Protobufバイナリ) を
//    ISO Latin-1 で文字列化し、正規表現 UC[A-Za-z0-9_-]{22} で channelId を抽出。
//    (Gemini提案によるバイナリ検索アプローチ - CF Logで動作確認済み)
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
// ヘルパー: elementData (Protobufバイナリ) から channelId を抽出
//
// Geminiの提案:
//   channelId は "UC" + 22文字の形式でバイナリ内に平文格納されている。
//   NSData を ISO Latin-1 で文字列化し正規表現で抽出する。
//   CF Logで UC... 形式のchannelIdが取れることを確認済み。
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
    if (!match) return nil;
    return [raw substringWithRange:match.range];
}

// ─────────────────────────────────────────────────────────────────────────────
// 機能1: チャンネルフィルター + ホワイトリスト同期
//
// フックポイント: YTInnerTubeCollectionViewController.addSectionsFromArray:
//
// 動作:
//   - 登録チャンネルタブ (YTBrowseViewController / FEsubscriptions) のとき:
//     セクション内の全 channelId を収集してホワイトリストに同期
//   - それ以外のフィード (ホーム・検索・探索):
//     ホワイトリスト外の channelId を持つアイテムをデータモデルから除去
//
// CF Logで確認した登録チャンネルタブのVC:
//   YTBrowseViewController / YTBrowseResponseViewController
// ─────────────────────────────────────────────────────────────────────────────

// browseId を持つ VC かどうかを判定するための前方宣言
@interface YTInnerTubeCollectionViewController : UIViewController
@end

%hook YTInnerTubeCollectionViewController

- (void)addSectionsFromArray:(NSArray *)array {
    CFWhitelistManager *wl = [CFWhitelistManager sharedManager];

    // このVCが登録チャンネルタブかどうかを判定
    // browseId プロパティは存在しないため、クラス名で判定
    id s = (id)self;
    NSString *vcClass = NSStringFromClass([s class]);
    BOOL isSubscriptionFeed =
        [vcClass isEqualToString:@"YTBrowseViewController"] ||
        [vcClass isEqualToString:@"YTBrowseResponseViewController"];

    BOOL shouldFilter = !isSubscriptionFeed && ![wl isEmpty];

    NSMutableArray *channelIdsForSync = isSubscriptionFeed
        ? [NSMutableArray array] : nil;
    NSMutableIndexSet *sectionsToRemove = [NSMutableIndexSet indexSet];

    for (NSUInteger si = 0; si < array.count; si++) {
        id section = array[si];

        // フィルターチップバーはスキップ
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

            // elementRenderer を取得
            if (![item respondsToSelector:@selector(elementRenderer)]) continue;
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id elemRenderer = [item performSelector:@selector(elementRenderer)];
            #pragma clang diagnostic pop
            if (!elemRenderer) continue;

            // elementData を取得
            if (![elemRenderer respondsToSelector:@selector(elementData)]) continue;
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id elemData = [elemRenderer performSelector:@selector(elementData)];
            #pragma clang diagnostic pop
            if (!elemData || ![elemData isKindOfClass:[NSData class]]) continue;

            // バイナリから channelId を抽出
            NSString *channelId = cf_extractChannelId((NSData *)elemData);
            if (!channelId.length) continue;

            if (isSubscriptionFeed) {
                // 登録チャンネルタブ: channelId を収集してホワイトリストに同期
                [channelIdsForSync addObject:channelId];
            } else if (shouldFilter && ![wl isChannelAllowed:channelId]) {
                // フィルター対象: 除去リストに追加
                [itemsToRemove addIndex:ii];
            }
        }

        // アイテムを除去
        if (itemsToRemove.count > 0) {
            NSMutableArray *mutableItems = [items mutableCopy];
            [mutableItems removeObjectsAtIndexes:itemsToRemove];
            if ([section respondsToSelector:@selector(setContentsArray:)]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [section performSelector:@selector(setContentsArray:)
                             withObject:mutableItems];
                #pragma clang diagnostic pop
            }
            if (mutableItems.count == 0) [sectionsToRemove addIndex:si];
        }
    }

    // 空になったセクションを除去して %orig を呼ぶ
    if (sectionsToRemove.count > 0) {
        NSMutableArray *mutableArray = [array mutableCopy];
        [mutableArray removeObjectsAtIndexes:sectionsToRemove];
        %orig(mutableArray);
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
// ─────────────────────────────────────────────────────────────────────────────
%hook YTQTMButton
- (void)setTitle:(NSString *)title forState:(UIControlState)state {
    %orig;
    NSString *t = [(UIButton *)self titleForState:UIControlStateNormal];
    if (t && ([t containsString:@"登録"] || [t isEqualToString:@"Subscribe"])) {
        self.hidden = YES;
        self.alpha  = 0;
    }
}
- (void)willMoveToWindow:(UIWindow *)newWindow {
    %orig;
    if (!newWindow) return;
    NSString *t = [self titleForState:UIControlStateNormal];
    if (t && ([t containsString:@"登録"] || [t isEqualToString:@"Subscribe"])) {
        self.hidden = YES;
        self.alpha  = 0;
    }
}
%end

// ─────────────────────────────────────────────────────────────────────────────
// 機能4: STARDYロゴ置き換え
//
// CF Logで確認した画像名:
//   ダーク: youtube_logo_dark_cairo / youtube_premium_logo_dark_cairo
//   ライト: youtube_premium_badge_light / youtube_premium_standalone_cairo
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

static BOOL cf_isDarkLogoName(NSString *name) {
    return [name isEqualToString:@"youtube_logo_dark_cairo"] ||
           [name isEqualToString:@"youtube_premium_logo_dark_cairo"];
}

static BOOL cf_isLiteLogoName(NSString *name) {
    return [name isEqualToString:@"youtube_premium_badge_light"] ||
           [name isEqualToString:@"youtube_premium_standalone_cairo"];
}

%hook UIImage
+ (UIImage *)imageNamed:(NSString *)name
               inBundle:(NSBundle *)bundle
compatibleWithTraitCollection:(UITraitCollection *)tc {
    if (name.length > 0) {
        if (cf_isDarkLogoName(name)) {
            UIImage *logo = cf_stardyLogo(YES);
            if (logo) return logo;
        } else if (cf_isLiteLogoName(name)) {
            UIImage *logo = cf_stardyLogo(NO);
            if (logo) return logo;
        }
    }
    return %orig;
}

+ (UIImage *)imageNamed:(NSString *)name {
    if (name.length > 0) {
        if (cf_isDarkLogoName(name)) {
            UIImage *logo = cf_stardyLogo(YES);
            if (logo) return logo;
        } else if (cf_isLiteLogoName(name)) {
            UIImage *logo = cf_stardyLogo(NO);
            if (logo) return logo;
        }
    }
    return %orig;
}
%end
