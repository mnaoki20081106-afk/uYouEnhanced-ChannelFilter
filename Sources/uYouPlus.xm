#import "uYouPlus.h"
#import "uYouPlusPatches.h"
#import "ChannelFilter/ChannelWhitelist.h"

// Tweak's bundle for Localizations support
NSBundle *uYouPlusBundle() {
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *tweakBundlePath = [[NSBundle mainBundle] pathForResource:@"uYouPlus" ofType:@"bundle"];
        if (tweakBundlePath)
            bundle = [NSBundle bundleWithPath:tweakBundlePath];
        else
            bundle = [NSBundle bundleWithPath:ROOT_PATH_NS(@"/Library/Application Support/uYouPlus.bundle")];
    });
    return bundle;
}
NSBundle *tweakBundle = uYouPlusBundle();

// ─── ChannelFilter 連携用 ──────────────────────────────────────────────

static BOOL CFShouldFilter() {
    return ![[CFWhitelistManager sharedManager] isEmpty];
}

static NSString *CFExtractChannelID(id renderer) {
    if (!renderer) return nil;
    if ([renderer respondsToSelector:@selector(channelId)]) {
        return [renderer performSelector:@selector(channelId)];
    }
    return nil;
}

// ─────────────────────────────────────────────────────────────────────────────

// ★ STARDY ロゴの置き換え ★
%hook YTHeaderLogoController
- (void)setPremiumLogo:(BOOL)isPremium {
    // まずYouTube公式のPremiumロゴを強制的に表示させる
    %orig(YES);
    
    // 表示された直後に画像をSTARDYロゴに差し替える
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([(id)self respondsToSelector:@selector(view)]) {
            UIView *logoView = [(id)self performSelector:@selector(view)];
            if (!logoView) return;
            
            for (UIView *subview in logoView.subviews) {
                if ([subview isKindOfClass:[UIImageView class]]) {
                    UIImageView *imageView = (UIImageView *)subview;
                    
                    // BundleからSTARDY.pngを読み込む (拡張子が異なる場合は適宜変更してください)
                    NSString *imagePath = [[NSBundle mainBundle] pathForResource:@"uYouPlus.bundle/STARDY" ofType:@"png"];
                    if (imagePath) {
                        imageView.image = [UIImage imageWithContentsOfFile:imagePath];
                        imageView.contentMode = UIViewContentModeScaleAspectFit;
                    }
                }
            }
        }
    });
}
%end

// Fake Premium
%hook YTUserSubstitutionData
- (BOOL)isPremium { return YES; }
%end

// ─── リスト表示のフィルタリング（非表示処理のクラッシュ対策） ─────────────────

%hook ASCollectionView
- (id)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    id cell = %orig;
    if (!CFShouldFilter()) return cell;

    if ([cell respondsToSelector:@selector(node)]) {
        id node = [cell performSelector:@selector(node)];
        NSString *cid = CFExtractChannelID(node);

        if (cid && ![[CFWhitelistManager sharedManager] isChannelAllowed:cid]) {
            if ([node isKindOfClass:[UIView class]]) {
                ((UIView *)node).hidden = YES;
            } else if ([node respondsToSelector:@selector(setHidden:)]) {
                [(UIView *)node setHidden:YES];
            }
        }
    }
    return cell;
}
%end

// ─── 設定の初期化 ──────────────────────────────────────────────────────────

%ctor {
    %init(_ungrouped);

    NSArray *allKeys = [[[NSUserDefaults standardUserDefaults] dictionaryRepresentation] allKeys];

    if (![allKeys containsObject:kAdBlockWorkaroundLite]) { 
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kAdBlockWorkaroundLite];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kAdBlockWorkaround];
    }
    
    if (![allKeys containsObject:@"noSuggestedVideoAtEnd"]) { 
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"noSuggestedVideoAtEnd"]; 
    }
    
    if (![allKeys containsObject:@"fixCasting_enabled"]) { 
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kFixCasting]; 
    }

    if (![allKeys containsObject:@"newSettingsUI_enabled"]) { 
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kNewSettingsUI]; 
    }
}
