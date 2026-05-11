#import "uYouPlus.h"
#import "uYouPlusPatches.h"
#import "ChannelFilter/ChannelWhitelist.h"

// Tweak's bundle for Localizations support - @PoomSmart - https://github.com/PoomSmart/YouPiP/commit/aea2473f64c75d73cab713e1e2d5d0a77675024f
NSBundle *uYouPlusBundle() {
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;
 	dispatch_once(&onceToken, ^{
        NSString *tweakBundlePath = [[NSBundle mainBundle] pathForResource:@"uYouPlus" ofType:@"bundle"];
        if (tweakBundlePath)
            bundle = [NSBundle bundleWithPath:tweakBundlePath];
        else
            bundle = [NSBundle bundleWithPath:ROOT_PATH_NS(@"/Library/Application Support/uYouPlus.bundle")]; // ROOT_PATH_NS = JBROOT_PATH_NSSTRING
    });
    return bundle;
}
NSBundle *tweakBundle = uYouPlusBundle();

// Notifications Tab appearance
UIImage *resizeImage(UIImage *image, CGSize newSize) {
    UIGraphicsBeginImageContextWithOptions(newSize, NO, 0.0);
    [image drawInRect:CGRectMake(0, 0, newSize.width, newSize.height)];
    UIImage *resizedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return resizedImage;
}

static int getNotificationIconStyle() {
    return [[NSUserDefaults standardUserDefaults] integerForKey:@"notificationIconStyle_enabled"];
}

// ─── ChannelFilter 連携用 ──────────────────────────────────────────────

static BOOL CFShouldFilter() {
    return ![[CFWhitelistManager sharedManager] isEmpty];
}

// データからチャンネルIDを抽出する補助関数
static NSString *CFExtractChannelID(id renderer) {
    if (!renderer) return nil;
    if ([renderer respondsToSelector:@selector(channelId)]) {
        return [renderer performSelector:@selector(channelId)];
    }
    return nil;
}

// ─────────────────────────────────────────────────────────────────────────────

// Premium Logo
%hook YTHeaderLogoController
- (void)setDelegate:(id)delegate {
    %orig;
    if (IS_ENABLED(@"isPremiumLogo_enabled")) {
        [self setPremiumLogo:YES];
    }
}
%end

// Fake Premium
%hook YTUserSubstitutionData
- (BOOL)isPremium { return YES; }
%end

// ─── チャンネルフィルタ：リスト表示の制御 ──────────────────────────────────────

%hook ASCollectionView
- (id)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    id cell = %orig;
    if (!CFShouldFilter()) return cell;

    // セルに対応するデータ（node）からチャンネルIDを確認
    if ([cell respondsToSelector:@selector(node)]) {
        id node = [cell performSelector:@selector(node)];
        NSString *cid = CFExtractChannelID(node);

        if (cid && ![[CFWhitelistManager sharedManager] isChannelAllowed:cid]) {
            // クラッシュ対策：BOOL引数に@YES(オブジェクト)を渡さない
            if ([node respondsToSelector:@selector(setHidden:)]) {
                // nodeは通常UIViewを継承したクラスなのでキャストして安全にセット
                ((UIView *)node).hidden = YES;
            }
        }
    }
    return cell;
}
%end

// ─── uYouPlus Settings ＆ Defaults ───────────────────────────────────────────

%ctor {
    // ロゴやPremium機能のために偽装を有効化
    %init(_ungrouped);

    // デフォルト設定の読み込み
    NSArray *allKeys = [[[NSUserDefaults standardUserDefaults] dictionaryRepresentation] allKeys];

    if (![allKeys containsObject:kAdBlockWorkaroundLite]) { 
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kAdBlockWorkaroundLite];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kAdBlockWorkaround];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"removeYouTubeAds"];
    }
    if (![allKeys containsObject:kAdBlockWorkaround]) { 
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kAdBlockWorkaroundLite];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kAdBlockWorkaround];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"removeYouTubeAds"];
    }
    
    // その他の初期化設定...
    if (![allKeys containsObject:@"noSuggestedVideoAtEnd"]) { 
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"noSuggestedVideoAtEnd"]; 
    }
    
    if (![allKeys containsObject:@"showPlaybackRate"]) {
        if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone) {
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"showPlaybackRate"]; 
        } else {
            [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"showPlaybackRate"]; 
        }
    }

    if (![allKeys containsObject:@"fixCasting_enabled"]) { 
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kFixCasting]; 
    }

    if (![allKeys containsObject:@"newSettingsUI_enabled"]) { 
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kNewSettingsUI]; 
    }
}
