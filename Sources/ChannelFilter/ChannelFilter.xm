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

// ─── ログシステム ─────────────────────────────────────────────────────────────
static NSMutableArray *_cfLogs;
static void CFLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[CF] %@", msg);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!_cfLogs) {
            NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:@"cf_debug_logs"];
            _cfLogs = saved ? [saved mutableCopy] : [NSMutableArray array];
        }
        [_cfLogs addObject:msg];
        if (_cfLogs.count > 800) [_cfLogs removeObjectAtIndex:0];
        [[NSUserDefaults standardUserDefaults] setObject:[_cfLogs copy] forKey:@"cf_debug_logs"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    });
}

// ─── ログビューア ─────────────────────────────────────────────────────────────
@interface CFLogViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray *logs;
@end
@implementation CFLogViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"CF Debug Log";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    UIBarButtonItem *closeBtn = [[UIBarButtonItem alloc] initWithTitle:@"閉じる" style:UIBarButtonItemStylePlain target:self action:@selector(cf_dismiss)];
    UIBarButtonItem *copyBtn  = [[UIBarButtonItem alloc] initWithTitle:@"全コピー" style:UIBarButtonItemStylePlain target:self action:@selector(cf_copyAll)];
    self.navigationItem.rightBarButtonItems = @[closeBtn, copyBtn];
    self.navigationItem.leftBarButtonItem  = [[UIBarButtonItem alloc] initWithTitle:@"クリア" style:UIBarButtonItemStylePlain target:self action:@selector(cf_clear)];
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self; self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 40;
    [self.view addSubview:self.tableView];
    [self cf_reload];
}
- (void)cf_reload {
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:@"cf_debug_logs"];
    self.logs = saved ? [[saved reverseObjectEnumerator] allObjects] : @[];
    [self.tableView reloadData];
}
- (void)cf_dismiss { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)cf_clear {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"cf_debug_logs"];
    _cfLogs = [NSMutableArray array];
    [self cf_reload];
}
- (void)cf_copyAll {
    if (!self.logs.count) return;
    [UIPasteboard generalPasteboard].string = [[[self.logs reverseObjectEnumerator] allObjects] componentsJoinedByString:@"\n"];
    UIBarButtonItem *btn = self.navigationItem.rightBarButtonItems[1];
    btn.title = @"✓ 済"; btn.enabled = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        btn.title = @"全コピー"; btn.enabled = YES;
    });
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return (NSInteger)self.logs.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"c"];
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.textLabel.text = self.logs[(NSUInteger)ip.row];
    return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [UIPasteboard generalPasteboard].string = self.logs[(NSUInteger)ip.row];
}
@end

static void cf_openLogViewer(void) {
    UIWindow *window = nil;
    if (@available(iOS 15, *))
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes)
            if ([sc isKindOfClass:[UIWindowScene class]])
                for (UIWindow *w in ((UIWindowScene *)sc).windows)
                    if (w.isKeyWindow) { window = w; break; }
    if (!window) window = [UIApplication sharedApplication].keyWindow;
    UIViewController *root = window.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    CFLogViewController *vc = [[CFLogViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [root presentViewController:nav animated:YES completion:nil];
}

// ─── フローティングボタン ─────────────────────────────────────────────────────
static const char kCFBtnKey = 0;
static void cf_injectBtn(UIWindow *w) {
    if (!w || objc_getAssociatedObject(w, &kCFBtnKey)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(20, 120, 90, 36);
        btn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
        [btn setTitle:@"CF Logs" forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor cyanColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        btn.layer.cornerRadius = 18;
        btn.clipsToBounds = YES;
        btn.tag = 0xCF10;
        [btn addTarget:nil action:@selector(cf_handleTap:) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:btn action:@selector(cf_handlePan:)];
        [btn addGestureRecognizer:pan];
        [w addSubview:btn];
        [w bringSubviewToFront:btn];
        objc_setAssociatedObject(w, &kCFBtnKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

%hook UIButton
%new - (void)cf_handleTap:(UIButton *)sender {
    if (sender.tag == 0xCF10) cf_openLogViewer();
}
%new - (void)cf_handlePan:(UIPanGestureRecognizer *)pan {
    UIView *v = pan.view;
    CGPoint t = [pan translationInView:v.superview];
    CGRect b = v.superview.bounds;
    CGFloat hw = v.frame.size.width/2, hh = v.frame.size.height/2;
    v.center = CGPointMake(
        MAX(hw, MIN(b.size.width-hw, v.center.x+t.x)),
        MAX(hh+20, MIN(b.size.height-hh-20, v.center.y+t.y))
    );
    [pan setTranslation:CGPointZero inView:v.superview];
}
%end

%hook UIWindow
- (void)becomeKeyWindow {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ cf_injectBtn(self); });
}
%end

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

// ─── デバッグ: 再帰的オブジェクトダンプ ──────────────────────────────────────
static void cf_dumpObject(id obj, NSUInteger depth, NSUInteger si) {
    if (!obj || depth > 4) return;
    NSString *indent = [@"" stringByPaddingToLength:depth * 2 withString:@"  " startingAtIndex:0];
    NSString *cls = NSStringFromClass([obj class]);
    CFLog(@"[Dump] si=%lu %@cls=%@", (unsigned long)si, indent, cls);

    // reelShelfRenderer / shortsShelfRenderer を持つか
    NSArray *shelfKeys = @[@"reelShelfRenderer", @"shortsShelfRenderer",
                           @"richShelfRenderer", @"horizontalListRenderer",
                           @"reelItemRenderer", @"shortsLockupViewModel"];
    for (NSString *key in shelfKeys) {
        SEL sel = NSSelectorFromString(key);
        if ([obj respondsToSelector:sel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id child = [obj performSelector:sel];
            #pragma clang diagnostic pop
            if (child) {
                CFLog(@"[Dump] si=%lu %@  -> HAS %@", (unsigned long)si, indent, key);
                cf_dumpObject(child, depth + 1, si);
            }
        }
    }

    // contentsArray を再帰
    if ([obj respondsToSelector:@selector(contentsArray)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        NSArray *children = [obj performSelector:@selector(contentsArray)];
        #pragma clang diagnostic pop
        if (children.count > 0) {
            CFLog(@"[Dump] si=%lu %@  contentsArray count=%lu",
                  (unsigned long)si, indent, (unsigned long)children.count);
            for (NSUInteger i = 0; i < MIN(children.count, 3); i++) {
                cf_dumpObject(children[i], depth + 1, si);
            }
        }
    }

    // elementRenderer を再帰
    if ([obj respondsToSelector:@selector(elementRenderer)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id er = [obj performSelector:@selector(elementRenderer)];
        #pragma clang diagnostic pop
        if (er) cf_dumpObject(er, depth + 1, si);
    }
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
    // scale=2.0 → 1000px / 2.0 = 500pt で表示
    // ロゴが大きすぎ/小さすぎならscaleを調整:
    //   小さく見せたい → scale値を大きくする（例: 3.0, 4.0）
    //   大きく見せたい → scale値を小さくする（例: 1.5, 2.0）
    return [UIImage imageWithCGImage:raw.CGImage scale:2.0f
                         orientation:UIImageOrientationUp];
}

// ─── タブバー判定（iPhone対応） ──────────────────────────────────────────────
@interface YTPivotBarViewController : UIViewController
@end

%hook YTPivotBarViewController
- (void)navigateToItemWithEndpoint:(id)endpoint animated:(BOOL)animated {
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
    CFLog(@"[PivotBar] navigateToItem browseId=%@", browseId);
    if ([browseId isEqualToString:@"FEsubscriptions"]) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"cf_is_subscription_tab"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        CFLog(@"[PivotBar] FLAG ON");
    } else if ([browseId hasPrefix:@"FE"]) {
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"cf_is_subscription_tab"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        CFLog(@"[PivotBar] FLAG OFF (%@)", browseId);
    }
}
- (void)setSelectedItemEndpoint:(id)endpoint {
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
    CFLog(@"[PivotBar] setSelected browseId=%@", browseId);
    if ([browseId isEqualToString:@"FEsubscriptions"]) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"cf_is_subscription_tab"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        CFLog(@"[PivotBar] FLAG ON via setSelected");
    } else if ([browseId hasPrefix:@"FE"]) {
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"cf_is_subscription_tab"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}
%end

// ─── 機能1-A: 登録チャンネルタブ判定 ─────────────────────────────────────────
%hook YTBrowseViewController
// viewWillAppear: でもタブ判定を試みる（iPhoneでsetNavigationEndpointが効かない場合の補完）
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    id s = (id)self;
    // タイトルからFEsubscriptionsかどうかを判定
    if ([s respondsToSelector:@selector(navigationEndpoint)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id ep = [s performSelector:@selector(navigationEndpoint)];
        #pragma clang diagnostic pop
        if (ep && [ep respondsToSelector:@selector(browseEndpoint)]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id browseEP = [ep performSelector:@selector(browseEndpoint)];
            #pragma clang diagnostic pop
            if (browseEP && [browseEP respondsToSelector:@selector(browseId)]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                NSString *bId = [browseEP performSelector:@selector(browseId)];
                #pragma clang diagnostic pop
                if ([bId isEqualToString:@"FEsubscriptions"]) {
                    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"cf_is_subscription_tab"];
                    [[NSUserDefaults standardUserDefaults] synchronize];
                    CFLog(@"[Endpoint] viewWillAppear FLAG ON");
                } else if (bId.length > 0 && [bId hasPrefix:@"FE"]) {
                    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"cf_is_subscription_tab"];
                    [[NSUserDefaults standardUserDefaults] synchronize];
                    CFLog(@"[Endpoint] viewWillAppear FLAG OFF (%@)", bId);
                }
            }
        }
    }
}

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
    CFLog(@"[Endpoint] browseId=%@", browseId);
    if ([browseId isEqualToString:@"FEsubscriptions"]) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"cf_is_subscription_tab"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        CFLog(@"[Endpoint] -> FLAG ON");
    } else if ([browseId hasPrefix:@"FE"]) {
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"cf_is_subscription_tab"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        CFLog(@"[Endpoint] -> FLAG OFF (%@)", browseId);
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

    // iPhoneではsetNavigationEndpointが呼ばれない場合がある
    // 親VCのナビゲーションエンドポイントを直接確認して補完
    if (!isSubscriptionFeed) {
        id s = (id)self;
        UIResponder *r = (UIResponder *)s;
        while ((r = r.nextResponder)) {
            if ([r isKindOfClass:[UIViewController class]]) {
                id vc = r;
                if ([vc respondsToSelector:@selector(navigationEndpoint)]) {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    id ep = [vc performSelector:@selector(navigationEndpoint)];
                    #pragma clang diagnostic pop
                    if (ep && [ep respondsToSelector:@selector(browseEndpoint)]) {
                        #pragma clang diagnostic push
                        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        id browseEP = [ep performSelector:@selector(browseEndpoint)];
                        #pragma clang diagnostic pop
                        if (browseEP && [browseEP respondsToSelector:@selector(browseId)]) {
                            #pragma clang diagnostic push
                            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                            NSString *bId = [browseEP performSelector:@selector(browseId)];
                            #pragma clang diagnostic pop
                            if ([bId isEqualToString:@"FEsubscriptions"]) {
                                isSubscriptionFeed = YES;
                                shouldFilter = NO;
                                [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"cf_is_subscription_tab"];
                                [[NSUserDefaults standardUserDefaults] synchronize];
                                CFLog(@"[AppVC] FEsubscriptions detected via VC chain");
                            } else if (bId.length > 0 && [bId hasPrefix:@"FE"]) {
                                [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"cf_is_subscription_tab"];
                                [[NSUserDefaults standardUserDefaults] synchronize];
                            }
                        }
                    }
                }
                break;
            }
        }
    }

    CFLog(@"[AppVC] count=%lu isSub=%d shouldFilter=%d wlEmpty=%d",
          (unsigned long)array.count, (int)isSubscriptionFeed,
          (int)shouldFilter, (int)[wl isEmpty]);

    // 最初の呼び出しのみ全セクションを再帰ダンプ（構造特定用）
    static BOOL _dumped = NO;
    if (!_dumped && shouldFilter && array.count > 5) {
        _dumped = YES;
        CFLog(@"[Dump] ===== START DUMP count=%lu =====", (unsigned long)array.count);
        for (NSUInteger di = 0; di < MIN(array.count, 8); di++) {
            cf_dumpObject(array[di], 0, di);
        }
        CFLog(@"[Dump] ===== END DUMP =====");
    }

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

        // ショートシェルフ判定（2段階）:
        // 1. セクションクラスがYTIShelfRendererなら除去
        // 2. contentsArray内にhorizontalListRenderer→reelItemRendererを持つなら除去
        // 3. dataLen=1355のアイテムが含まれるなら除去
        if (shouldFilter) {
            NSString *secCls2 = NSStringFromClass([section class]);

            // YTIShelfRenderer はショートシェルフのコンテナ
            if ([secCls2 containsString:@"ShelfRenderer"] ||
                [secCls2 containsString:@"Shelf"]) {
                CFLog(@"[ShortShelf] si=%lu -> removed (ShelfRenderer class)", (unsigned long)si);
                [sectionsToRemove addIndex:si];
                continue;
            }

            BOOL isShortShelf = NO;
            for (id chkItem in items) {
                // reelItemRenderer を持つかチェック（ダンプで確認済みの構造）
                if ([chkItem respondsToSelector:@selector(horizontalListRenderer)]) {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    id hlr = [chkItem performSelector:@selector(horizontalListRenderer)];
                    #pragma clang diagnostic pop
                    if (hlr && [hlr respondsToSelector:@selector(reelItemRenderer)]) {
                        isShortShelf = YES;
                        break;
                    }
                }
                // dataLen=1355 判定（スペーサー兼ショートマーカー）
                if (![chkItem respondsToSelector:@selector(elementRenderer)]) continue;
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id chkRenderer = [chkItem performSelector:@selector(elementRenderer)];
                id chkData = chkRenderer ? [chkRenderer performSelector:@selector(elementData)] : nil;
                #pragma clang diagnostic pop
                if (chkData && [chkData isKindOfClass:[NSData class]]) {
                    NSUInteger dlen = [(NSData *)chkData length];
                    if (dlen >= 1300 && dlen <= 1400) {
                        isShortShelf = YES;
                        break;
                    }
                }
            }
            if (isShortShelf) {
                CFLog(@"[ShortShelf] si=%lu -> section removed", (unsigned long)si);
                [sectionsToRemove addIndex:si];
                continue;
            }
        }

        NSMutableIndexSet *itemsToRemove = [NSMutableIndexSet indexSet];
        for (NSUInteger ii = 0; ii < items.count; ii++) {
            id item = items[ii];

            // ショートシェルフ判定: セクション内に複数アイテムがある場合はショートシェルフの可能性
            // ショートシェルフはアイテム1件ごとに複数のショートを含むreelShelfRenderer
            // セクション自体のクラス名でショートシェルフを識別してセクションごと除去
            if (shouldFilter && items.count > 1) {
                // 複数アイテムを持つセクション = ショートシェルフまたはリッチシェルフ
                NSString *itemCls = NSStringFromClass([item class]);
                CFLog(@"[ShelfItem] si=%lu ii=%lu itemCls=%@", (unsigned long)si, (unsigned long)ii, itemCls);

                // reelShelfRenderer / shortsShelfRenderer を持つか確認
                NSArray *shelfSelectors = @[@"reelShelfRenderer", @"shortsShelfRenderer",
                                            @"richShelfRenderer", @"horizontalListRenderer"];
                for (NSString *sel in shelfSelectors) {
                    SEL s2 = NSSelectorFromString(sel);
                    if ([item respondsToSelector:s2]) {
                        CFLog(@"[ShelfItem]   has %@", sel);
                    }
                }
            }

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

            NSData *data = (NSData *)elemData;
            NSString *channelId = cf_extractChannelId(data);

            // channelIdが取れない場合の詳細ログ
            if (!channelId.length) {
                NSString *raw = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
                BOOL hasReel = raw && ([raw containsString:@"reel"] || [raw containsString:@"Reel"] ||
                                       [raw containsString:@"short"] || [raw containsString:@"Short"] ||
                                       [raw containsString:@"SHORTS"]);
                CFLog(@"[NoId] si=%lu ii=%lu dataLen=%lu hasReel=%d",
                      (unsigned long)si, (unsigned long)ii,
                      (unsigned long)[data length], (int)hasReel);
                if (shouldFilter) [itemsToRemove addIndex:ii];
                continue;
            }

            if (isSubscriptionFeed) {
                [channelIdsForSync addObject:channelId];
                CFLog(@"[Sync] %@", channelId);
            } else if (shouldFilter) {
                BOOL allowed = [wl isChannelAllowed:channelId];
                CFLog(@"[Filter] %@ allowed=%d", channelId, (int)allowed);
                if (!allowed) [itemsToRemove addIndex:ii];
            }
        }

        // セクション全体がショートシェルフの場合を判定して除去
        // ショートシェルフはcontentsArrayの中に複数アイテムがあり、
        // セクションクラス名に"Shelf"や"Reel"が含まれる
        if (shouldFilter) {
            NSString *secCls = NSStringFromClass([section class]);
            if ([secCls containsString:@"Shelf"] || [secCls containsString:@"Reel"] ||
                [secCls containsString:@"Short"]) {
                CFLog(@"[ShelfSection] si=%lu secCls=%@ -> removing entire section",
                      (unsigned long)si, secCls);
                [sectionsToRemove addIndex:si];
                continue;
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

    // 除去対象セクションのcontentsArrayを空にする（キャッシュ対策）
    [sectionsToRemove enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx >= array.count) return;
        id sec = array[idx];
        if ([sec respondsToSelector:@selector(setContentsArray:)]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [sec performSelector:@selector(setContentsArray:) withObject:@[]];
            #pragma clang diagnostic pop
        }
    }];

    NSMutableArray *filteredArray = [array mutableCopy];
    if (sectionsToRemove.count > 0) {
        [filteredArray removeObjectsAtIndexes:sectionsToRemove];
        CFLog(@"[AppVC] ✅ removed=%lu remaining=%lu",
              (unsigned long)sectionsToRemove.count,
              (unsigned long)filteredArray.count);
    }
    %orig(filteredArray);

    if (isSubscriptionFeed && channelIdsForSync.count > 0) {
        [wl syncSubscribedChannelIDs:channelIdsForSync];
        CFLog(@"[Sync] ✅ synced %lu ids", (unsigned long)channelIdsForSync.count);
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

// ─── YTInnerTubeCollectionViewController フック ───────────────────────────────
// YTAppCollectionViewController の親クラス。
// ショートなど一部コンテンツはこちら経由で追加される場合がある。
@interface YTInnerTubeCollectionViewController : UIViewController
@end

%hook YTInnerTubeCollectionViewController
- (void)addSectionsFromArray:(NSArray *)array {
    id s = (id)self;
    NSString *vcClass = NSStringFromClass([s class]);
    CFWhitelistManager *wl = [CFWhitelistManager sharedManager];
    BOOL isSubscriptionFeed = [[NSUserDefaults standardUserDefaults]
        boolForKey:@"cf_is_subscription_tab"];
    BOOL shouldFilter = !isSubscriptionFeed && ![wl isEmpty];

    // YTAppCollectionViewController以外のVCでもフィードが来たらログ
    if (![vcClass isEqualToString:@"YTAppCollectionViewController"]) {
        CFLog(@"[InnerTube] vcClass=%@ count=%lu isSub=%d shouldFilter=%d",
              vcClass, (unsigned long)array.count,
              (int)isSubscriptionFeed, (int)shouldFilter);
    }

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
            if (!channelId.length) {
                if (shouldFilter) [itemsToRemove addIndex:ii];
                continue;
            }

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
    // scale=10.0 → 1920px / 10.0 = 192pt で表示
    // ロゴが大きすぎ/小さすぎならscaleを調整
    return [UIImage imageWithCGImage:raw.CGImage scale:10.0f
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
    // Shortsロゴ置き換え（CF Logで判明した画像名）
    if ([name isEqualToString:@"youtube_shorts_24_cairo"] ||
        [name isEqualToString:@"youtube_outline_experimental/shorts_24pt"] ||
        [name isEqualToString:@"youtube_fill_experimental/shorts_24pt"] ||
        [name isEqualToString:@"ic_shorts_logo"] ||
        [name isEqualToString:@"youtube_shorts_logo"] ||
        [name isEqualToString:@"shorts_logo"] ||
        [name isEqualToString:@"reel_logo"]) {
        UIImage *i = cf_shortsLogo(); if (i) return i;
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
    if ([name isEqualToString:@"youtube_shorts_24_cairo"] ||
        [name isEqualToString:@"youtube_outline_experimental/shorts_24pt"] ||
        [name isEqualToString:@"youtube_fill_experimental/shorts_24pt"] ||
        [name isEqualToString:@"ic_shorts_logo"] ||
        [name isEqualToString:@"youtube_shorts_logo"] ||
        [name isEqualToString:@"shorts_logo"] ||
        [name isEqualToString:@"reel_logo"]) {
        UIImage *i = cf_shortsLogo(); if (i) return i;
    }
    return %orig;
}
%end
