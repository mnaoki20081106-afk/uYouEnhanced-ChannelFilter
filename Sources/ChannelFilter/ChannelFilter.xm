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
//    5. [NEW] 汎用UIフィルター (Gonerino流用) - 検索結果など全フィードをUIレベルで一網打尽
//    6. [NEW] ショート動画フィルター - スワイプ時のホワイトリスト外動画を自動スキップ
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
static void cf_scheduleLogSave(void) {
    static BOOL _pending = NO;
    if (_pending) return;
    _pending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        _pending = NO;
        [[NSUserDefaults standardUserDefaults]
            setObject:[_cfLogs copy] forKey:@"cf_debug_logs"];
    });
}
static void CFLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[CF] %@", msg);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!_cfLogs) {
            NSArray *saved = [[NSUserDefaults standardUserDefaults]
                arrayForKey:@"cf_debug_logs"];
            _cfLogs = saved ? [saved mutableCopy] : [NSMutableArray array];
        }
        [_cfLogs addObject:msg];
        if (_cfLogs.count > 300) [_cfLogs removeObjectAtIndex:0];
        cf_scheduleLogSave();
    });
}

// ─── ログビューア ─────────────────────────────────────────────────────────────
@interface CFLogViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, strong) UITableView  *tableView;
@property (nonatomic, strong) UISearchBar  *searchBar;
@property (nonatomic, strong) NSArray      *allLogs;
@property (nonatomic, strong) NSArray      *logs;
@property (nonatomic, copy)   NSString     *filterText;
@end

@implementation CFLogViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"CF Debug Log";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    UIBarButtonItem *closeBtn = [[UIBarButtonItem alloc] initWithTitle:@"閉じる" style:UIBarButtonItemStylePlain target:self action:@selector(cf_dismiss)];
    UIBarButtonItem *copyBtn = [[UIBarButtonItem alloc] initWithTitle:@"全コピー" style:UIBarButtonItemStylePlain target:self action:@selector(cf_copyAll)];
    self.navigationItem.rightBarButtonItems = @[closeBtn, copyBtn];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"クリア" style:UIBarButtonItemStylePlain target:self action:@selector(cf_clear)];
    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.placeholder = @"フィルタ (例: ClassScan, SearchVC, AppVC...)";
    self.searchBar.delegate = self;
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    [self.searchBar sizeToFit];
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.tableHeaderView = self.searchBar;
    self.tableView.dataSource = self;
    self.tableView.delegate   = self;
    self.tableView.rowHeight  = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 40;
    [self.view addSubview:self.tableView];
    [self cf_reload];
}
- (void)cf_reload {
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:@"cf_debug_logs"];
    self.allLogs = saved ? [[saved reverseObjectEnumerator] allObjects] : @[];
    [self cf_applyFilter];
}
- (void)cf_applyFilter {
    NSString *q = [self.filterText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!q.length) { self.logs = self.allLogs; }
    else {
        NSMutableArray *filtered = [NSMutableArray array];
        for (NSString *line in self.allLogs) {
            if ([line rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound) [filtered addObject:line];
        }
        self.logs = filtered;
    }
    [self.tableView reloadData];
    if (q.length) self.title = [NSString stringWithFormat:@"CF Log (%lu/%lu件)", (unsigned long)self.logs.count, (unsigned long)self.allLogs.count];
    else self.title = [NSString stringWithFormat:@"CF Debug Log (%lu件)", (unsigned long)self.allLogs.count];
}
- (void)cf_dismiss { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)cf_clear {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"cf_debug_logs"];
    _cfLogs = [NSMutableArray array];
    self.filterText = nil;
    self.searchBar.text = nil;
    [self cf_reload];
}
- (void)cf_copyAll {
    if (!self.logs.count) return;
    [UIPasteboard generalPasteboard].string = [self.logs componentsJoinedByString:@"\n"];
    UIBarButtonItem *btn = self.navigationItem.rightBarButtonItems[1];
    btn.title = @"✓ 済"; btn.enabled = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ btn.title = @"全コピー"; btn.enabled = YES; });
}
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)text { self.filterText = text; [self cf_applyFilter]; }
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar { [searchBar resignFirstResponder]; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return (NSInteger)self.logs.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"c"];
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    NSString *line = self.logs[(NSUInteger)ip.row];
    NSString *q = [self.filterText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (q.length) {
        NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:line];
        NSRange searchRange = NSMakeRange(0, line.length);
        NSRange found;
        while ((found = [line rangeOfString:q options:NSCaseInsensitiveSearch range:searchRange]).location != NSNotFound) {
            [attr addAttribute:NSBackgroundColorAttributeName value:[UIColor colorWithRed:1 green:0.85 blue:0 alpha:1] range:found];
            searchRange = NSMakeRange(NSMaxRange(found), line.length - NSMaxRange(found));
        }
        cell.textLabel.attributedText = attr;
    } else {
        cell.textLabel.attributedText = nil;
        cell.textLabel.text = line;
    }
    return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip { [UIPasteboard generalPasteboard].string = self.logs[(NSUInteger)ip.row]; }
@end

static UIWindow *cf_appMainWindow(void) {
    NSArray<UIWindow *> *wins = [UIApplication sharedApplication].windows;
    for (UIWindow *w in wins) {
        NSString *cls = NSStringFromClass([w class]);
        if ([cls containsString:@"Keyboard"] || [cls containsString:@"TextEffects"] || [cls containsString:@"Accessibility"]) continue;
        return w;
    }
    return wins.firstObject;
}

static void cf_scanSearchVCClasses(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSMutableArray *hits = [NSMutableArray array];
    SEL sel1 = NSSelectorFromString(@"addSectionsFromArray:");
    SEL sel2 = NSSelectorFromString(@"addSection:");
    SEL sel3 = NSSelectorFromString(@"setSections:");
    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        if (![cls isSubclassOfClass:[UIViewController class]]) continue;
        BOOL has1 = class_getInstanceMethod(cls, sel1) != NULL;
        BOOL has2 = class_getInstanceMethod(cls, sel2) != NULL;
        BOOL has3 = class_getInstanceMethod(cls, sel3) != NULL;
        if (has1 || has2 || has3) [hits addObject:[NSString stringWithFormat:@"%@ [array=%d single=%d set=%d]", NSStringFromClass(cls), has1, has2, has3]];
    }
    free(classes);
    CFLog(@"[ClassScan] ===== START (scanned %u classes) =====", count);
    for (NSString *h in hits) CFLog(@"[ClassScan] %@", h);
    CFLog(@"[ClassScan] ===== END (%lu hits) =====", (unsigned long)hits.count);
}

static void cf_openLogViewer(void) {
    UIWindow *window = cf_appMainWindow();
    if (!window) window = [UIApplication sharedApplication].keyWindow;
    UIViewController *root = window.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    CFLogViewController *vc = [[CFLogViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [root presentViewController:nav animated:YES completion:nil];
}

static const char kCFBtnKey = 0;
static void cf_injectBtn(UIWindow *w) {
    if (!w || objc_getAssociatedObject(w, &kCFBtnKey)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        static dispatch_once_t scanOnce;
        dispatch_once(&scanOnce, ^{ cf_scanSearchVCClasses(); });
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
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:btn action:@selector(cf_handlePan:)];
        [btn addGestureRecognizer:pan];
        [w addSubview:btn];
        [w bringSubviewToFront:btn];
        objc_setAssociatedObject(w, &kCFBtnKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

static void cf_ensureBtn(void) {
    UIWindow *w = cf_appMainWindow();
    if (!w) return;
    UIButton *btn = (UIButton *)objc_getAssociatedObject(w, &kCFBtnKey);
    if (btn) { [w bringSubviewToFront:btn]; } else { cf_injectBtn(w); }
}

%hook UIButton
%new - (void)cf_handleTap:(UIButton *)sender { if (sender.tag == 0xCF10) cf_openLogViewer(); }
%new - (void)cf_handlePan:(UIPanGestureRecognizer *)pan {
    UIView *v = pan.view;
    CGPoint t = [pan translationInView:v.superview];
    CGRect b = v.superview.bounds;
    CGFloat hw = v.frame.size.width/2, hh = v.frame.size.height/2;
    v.center = CGPointMake(MAX(hw, MIN(b.size.width-hw, v.center.x+t.x)), MAX(hh+20, MIN(b.size.height-hh-20, v.center.y+t.y)));
    [pan setTranslation:CGPointZero inView:v.superview];
}
%end

%hook UIWindow
- (void)becomeKeyWindow { %orig; dispatch_async(dispatch_get_main_queue(), ^{ cf_ensureBtn(); }); }
%end

static BOOL _cf_globalDumped = NO;

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

static void cf_showAlert(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
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

static NSRegularExpression *cf_channelIdRegex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"UC[A-Za-z0-9_-]{22}" options:0 error:nil];
    });
    return regex;
}

static void cf_dumpObject(id obj, NSUInteger depth, NSUInteger si) {
    if (!obj || depth > 4) return;
    NSString *indent = [@"" stringByPaddingToLength:depth * 2 withString:@"  " startingAtIndex:0];
    NSString *cls = NSStringFromClass([obj class]);
    CFLog(@"[Dump] si=%lu %@cls=%@", (unsigned long)si, indent, cls);

    NSArray *shelfKeys = @[@"reelShelfRenderer", @"shortsShelfRenderer", @"richShelfRenderer", @"horizontalListRenderer", @"reelItemRenderer", @"shortsLockupViewModel"];
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

    if ([obj respondsToSelector:@selector(contentsArray)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        NSArray *children = [obj performSelector:@selector(contentsArray)];
        #pragma clang diagnostic pop
        if (children.count > 0) {
            CFLog(@"[Dump] si=%lu %@  contentsArray count=%lu", (unsigned long)si, indent, (unsigned long)children.count);
            for (NSUInteger i = 0; i < MIN(children.count, 3); i++) cf_dumpObject(children[i], depth + 1, si);
        }
    }

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
    NSString *raw = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (!raw) return nil;
    NSTextCheckingResult *match = [cf_channelIdRegex() firstMatchInString:raw options:0 range:NSMakeRange(0, raw.length)];
    return match ? [raw substringWithRange:match.range] : nil;
}

static UIImage *cf_stardyLogo(BOOL dark) {
    static NSString *darkPath;
    static NSString *litePath;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bPath = [[NSBundle mainBundle] pathForResource:@"uYouPlus" ofType:@"bundle"];
        NSBundle *b = bPath ? [NSBundle bundleWithPath:bPath] : nil;
        darkPath = [b pathForResource:@"PremiumLogo_dark" ofType:@"png"];
        litePath = [b pathForResource:@"PremiumLogo_lite" ofType:@"png"];
    });
    NSString *path = dark ? darkPath : litePath;
    if (!path) return nil;
    UIImage *raw = [UIImage imageWithContentsOfFile:path];
    if (!raw) return nil;
    return [UIImage imageWithCGImage:raw.CGImage scale:2.0f orientation:UIImageOrientationUp];
}

// ─── ヘルパー: YTReelModelからchannelIdを取得 ────────────────────────────────
static NSString *cf_channelIdFromReelEP(id reelEP) {
    if (!reelEP) return nil;
    SEL paramsSel = NSSelectorFromString(@"params");
    if (![reelEP respondsToSelector:paramsSel]) return nil;
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id paramsVal = [reelEP performSelector:paramsSel];
    #pragma clang diagnostic pop
    if (!paramsVal || ![paramsVal isKindOfClass:[NSString class]]) return nil;
    NSString *b64 = [(NSString *)paramsVal stringByReplacingOccurrencesOfString:@"-" withString:@"+"];
    b64 = [b64 stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    NSInteger pad = 4 - (b64.length % 4);
    if (pad < 4) for (NSInteger i = 0; i < pad; i++) b64 = [b64 stringByAppendingString:@"="];
    NSData *decoded = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
    if (!decoded) return nil;
    NSString *str = [[NSString alloc] initWithData:decoded encoding:NSISOLatin1StringEncoding];
    if (!str) return nil;
    NSTextCheckingResult *match = [cf_channelIdRegex() firstMatchInString:str options:0 range:NSMakeRange(0, str.length)];
    if (!match) return nil;
    return [str substringWithRange:match.range];
}

static id cf_reelEPFromModel(id model) {
    if (!model) return nil;
    SEL epSel = NSSelectorFromString(@"endpoint");
    if (![model respondsToSelector:epSel]) return nil;
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id ep = [model performSelector:epSel];
    #pragma clang diagnostic pop
    if (!ep) return nil;
    SEL reelSel = NSSelectorFromString(@"reelWatchEndpoint");
    if (![ep respondsToSelector:reelSel]) return nil;
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id reelEP = [ep performSelector:reelSel];
    #pragma clang diagnostic pop
    return reelEP;
}

static NSString *cf_channelIdFromShortsModel(id model) {
    return cf_channelIdFromReelEP(cf_reelEPFromModel(model));
}

static NSArray *cf_filterReelModels(NSArray *models, CFWhitelistManager *wl) {
    if (!models.count) return models;
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:models.count];
    for (id model in models) {
        NSString *channelId = cf_channelIdFromShortsModel(model);
        if (!channelId) {
            CFLog(@"[ShortsFilter] no channelId, skip model=%@", NSStringFromClass([model class]));
            continue;
        }
        if ([wl isChannelAllowed:channelId]) {
            [filtered addObject:model];
        } else {
            CFLog(@"[ShortsFilter] excluded ch=%@", channelId);
        }
    }
    return [filtered copy];
}

@interface YTReelWatchRootViewController : UIViewController
@end
@interface YTAppReelWatchRootViewController : UIViewController
@end

%hook YTReelWatchRootViewController
- (void)dataSource:(id)dataSource didUpdateWithPrevItems:(NSArray *)prevItems nextItems:(NSArray *)nextItems refreshItems:(NSArray *)refreshItems {
    CFWhitelistManager *wl = [CFWhitelistManager sharedManager];
    if ([wl isEmpty]) { %orig; return; }
    NSArray *filteredPrev    = cf_filterReelModels(prevItems,    wl);
    NSArray *filteredNext    = cf_filterReelModels(nextItems,    wl);
    NSArray *filteredRefresh = cf_filterReelModels(refreshItems, wl);
    CFLog(@"[ShortsFilter] dataSource:didUpdate prev=%lu->%lu next=%lu->%lu refresh=%lu->%lu",
          (unsigned long)prevItems.count,    (unsigned long)filteredPrev.count,
          (unsigned long)nextItems.count,    (unsigned long)filteredNext.count,
          (unsigned long)refreshItems.count, (unsigned long)filteredRefresh.count);
    %orig(dataSource, filteredPrev, filteredNext, filteredRefresh);
}

- (void)addReelContentModels:(NSArray *)models toPlayerSequencerItems:(NSMutableArray *)sequencerItems {
    CFWhitelistManager *wl = [CFWhitelistManager sharedManager];
    if ([wl isEmpty]) { %orig; return; }
    NSArray *filtered = cf_filterReelModels(models, wl);
    CFLog(@"[ShortsFilter] addReelContentModels: %lu -> %lu", (unsigned long)models.count, (unsigned long)filtered.count);
    %orig(filtered, sequencerItems);
}
%end


// ─── [NEW] ショート動画 (YTShortsPlayerViewController) 自動スキップ機能 ───────
%hook YTShortsPlayerViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    CFWhitelistManager *wl = [CFWhitelistManager sharedManager];
    if ([wl isEmpty]) return;

    id s = (id)self;
    id model = [s performSelector:NSSelectorFromString(@"model")];
    if (!model) return;

    NSString *channelId = cf_channelIdFromShortsModel(model);

    if (channelId) {
        if (![wl isChannelAllowed:channelId]) {
            CFLog(@"[ShortsFilter] 🚫 ホワイトリスト外のショートです: %@", channelId);
            if ([s respondsToSelector:NSSelectorFromString(@"nextVideo")]) {
                [s performSelector:NSSelectorFromString(@"nextVideo")];
            } else {
                CFLog(@"[ShortsFilter] ⚠️ nextVideoメソッドが見つかりません");
            }
        } else {
            CFLog(@"[ShortsFilter] ✅ 許可されたショートです: %@", channelId);
        }
    } else {
        CFLog(@"[ShortsFilter] ⚠️ channelIdが取得できませんでした（広告などの可能性）");
    }
}

%end


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

%hook YTBrowseViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    id s = (id)self;
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
    if (!browseEP) {
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"cf_is_subscription_tab"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        CFLog(@"[Endpoint] no browseEP -> FLAG OFF (search/other)");
        return;
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
}
%end

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
    if (!browseEP) {
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"cf_is_subscription_tab"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        return;
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

    NSString *resolvedBrowseId = nil;
    {
        id s = (id)self;
        if ([s respondsToSelector:@selector(navigationEndpoint)]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id ep = [s performSelector:@selector(navigationEndpoint)];
            #pragma clang diagnostic pop
            if (ep && [ep respondsToSelector:@selector(browseEndpoint)]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id bep = [ep performSelector:@selector(browseEndpoint)];
                #pragma clang diagnostic pop
                if (bep && [bep respondsToSelector:@selector(browseId)]) {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    NSString *bid = [bep performSelector:@selector(browseId)];
                    #pragma clang diagnostic pop
                    if (bid.length) resolvedBrowseId = bid;
                }
            }
        }
        if (!resolvedBrowseId) {
            UIViewController *cur = (UIViewController *)s;
            for (int depth = 0; depth < 10 && cur && !resolvedBrowseId; depth++) {
                cur = cur.parentViewController;
                if (!cur) break;
                id vc = cur;
                if ([vc respondsToSelector:@selector(navigationEndpoint)]) {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    id ep = [vc performSelector:@selector(navigationEndpoint)];
                    #pragma clang diagnostic pop
                    if (ep && [ep respondsToSelector:@selector(browseEndpoint)]) {
                        #pragma clang diagnostic push
                        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        id bep = [ep performSelector:@selector(browseEndpoint)];
                        #pragma clang diagnostic pop
                        if (bep && [bep respondsToSelector:@selector(browseId)]) {
                            #pragma clang diagnostic push
                            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                            NSString *bid = [bep performSelector:@selector(browseId)];
                            #pragma clang diagnostic pop
                            if (bid.length) resolvedBrowseId = bid;
                        }
                    }
                }
            }
        }
    }

    BOOL isSubscriptionFeed;
    if (resolvedBrowseId.length) {
        isSubscriptionFeed = [resolvedBrowseId isEqualToString:@"FEsubscriptions"];
        [[NSUserDefaults standardUserDefaults] setBool:isSubscriptionFeed forKey:@"cf_is_subscription_tab"];
        CFLog(@"[AppVC] resolvedBrowseId=%@ isSub=%d", resolvedBrowseId, (int)isSubscriptionFeed);
    } else {
        isSubscriptionFeed = [[NSUserDefaults standardUserDefaults] boolForKey:@"cf_is_subscription_tab"];
        CFLog(@"[AppVC] no resolvedBrowseId, fallback flag isSub=%d", (int)isSubscriptionFeed);
    }

    BOOL shouldFilter = !isSubscriptionFeed && ![wl isEmpty];

    CFLog(@"[AppVC] count=%lu isSub=%d shouldFilter=%d wlEmpty=%d",
          (unsigned long)array.count, (int)isSubscriptionFeed,
          (int)shouldFilter, (int)[wl isEmpty]);

    if (!_cf_globalDumped && shouldFilter && array.count > 5) {
        _cf_globalDumped = YES;
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

    NSMutableArray *channelIdsForSync = isSubscriptionFeed ? [NSMutableArray array] : nil;
    NSMutableIndexSet *sectionsToRemove = [NSMutableIndexSet indexSet];

    for (NSUInteger si = 0; si < array.count; si++) {
        id section = array[si];
        NSString *secClass = NSStringFromClass([section class]);
        if ([secClass containsString:@"FilterChip"] || [secClass containsString:@"ChipBar"]) continue;

        if (shouldFilter) {
            if ([secClass isEqualToString:@"YTIShelfRenderer"] || [secClass containsString:@"ShelfRenderer"]) {
                CFLog(@"[ShortShelf] si=%lu cls=%@ -> removed", (unsigned long)si, secClass);
                [sectionsToRemove addIndex:si];
                continue;
            }
        }

        if (![section respondsToSelector:@selector(contentsArray)]) continue;
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        NSArray *items = [section performSelector:@selector(contentsArray)];
        #pragma clang diagnostic pop
        if (!items.count) continue;

        NSMutableIndexSet *itemsToRemove = [NSMutableIndexSet indexSet];
        for (NSUInteger ii = 0; ii < items.count; ii++) {
            id item = items[ii];
            if (shouldFilter && items.count > 1) {
                NSString *itemCls = NSStringFromClass([item class]);
                CFLog(@"[ShelfItem] si=%lu ii=%lu itemCls=%@", (unsigned long)si, (unsigned long)ii, itemCls);
                NSArray *shelfSelectors = @[@"reelShelfRenderer", @"shortsShelfRenderer", @"richShelfRenderer", @"horizontalListRenderer"];
                for (NSString *sel in shelfSelectors) {
                    SEL s2 = NSSelectorFromString(sel);
                    if ([item respondsToSelector:s2]) CFLog(@"[ShelfItem]   has %@", sel);
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

            if (!channelId.length) {
                NSString *raw = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
                BOOL hasReel = raw && ([raw containsString:@"reel"] || [raw containsString:@"Reel"] || [raw containsString:@"short"] || [raw containsString:@"Short"] || [raw containsString:@"SHORTS"]);
                CFLog(@"[NoId] si=%lu ii=%lu dataLen=%lu hasReel=%d", (unsigned long)si, (unsigned long)ii, (unsigned long)[data length], (int)hasReel);
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
        if (shouldFilter) {
            NSString *secCls = NSStringFromClass([section class]);
            if ([secCls containsString:@"Shelf"] || [secCls containsString:@"Reel"] || [secCls containsString:@"Short"]) {
                CFLog(@"[ShelfSection] si=%lu secCls=%@ -> removing entire section", (unsigned long)si, secCls);
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
                [section performSelector:@selector(setContentsArray:) withObject:filteredItems];
                #pragma clang diagnostic pop
            }
            if (filteredItems.count == 0) [sectionsToRemove addIndex:si];
        }
    }

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
        CFLog(@"[AppVC] ✅ removed=%lu remaining=%lu", (unsigned long)sectionsToRemove.count, (unsigned long)filteredArray.count);
    }
    %orig(filteredArray);

    if (isSubscriptionFeed && channelIdsForSync.count > 0) {
        [wl syncSubscribedChannelIDs:channelIdsForSync];
        CFLog(@"[Sync] ✅ synced %lu ids", (unsigned long)channelIdsForSync.count);
    }
}
%end


// ─── [NEW] Gonerino流用: 汎用UIフィルター (YTAsyncCollectionViewハック) ────────
static NSString *cf_getChannelIdFromNode(id node) {
    if (!node) return nil;
    NSArray *modelSelectors = @[@"model", @"renderer", @"entry"];
    for (NSString *selName in modelSelectors) {
        SEL sel = NSSelectorFromString(selName);
        if ([node respondsToSelector:sel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id model = [node performSelector:sel];
            #pragma clang diagnostic pop
            
            if ([model respondsToSelector:@selector(data)]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                NSData *data = [model performSelector:@selector(data)];
                #pragma clang diagnostic pop
                
                NSString *cid = cf_extractChannelId(data);
                if (cid.length) return cid;
            }
        }
    }
    
    if ([node respondsToSelector:@selector(subnodes)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        NSArray *subnodes = [node performSelector:@selector(subnodes)];
        #pragma clang diagnostic pop
        
        for (id subnode in subnodes) {
            NSString *cid = cf_getChannelIdFromNode(subnode);
            if (cid.length) return cid;
        }
    }
    return nil;
}

@interface YTAsyncCollectionView : UICollectionView
- (void)cf_removeOffendingCells;
@end

%hook YTAsyncCollectionView

- (void)layoutSubviews {
    %orig;
    [self cf_removeOffendingCells];
}

%new
- (void)cf_removeOffendingCells {
    BOOL isSubscriptionFeed = [[NSUserDefaults standardUserDefaults] boolForKey:@"cf_is_subscription_tab"];
    if (isSubscriptionFeed) return;

    CFWhitelistManager *wl = [CFWhitelistManager sharedManager];
    if ([wl isEmpty]) return;

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        @try {
            NSArray *visibleCells = [strongSelf visibleCells];
            NSMutableArray *indexPathsToRemove = [NSMutableArray array];

            for (UICollectionViewCell *cell in visibleCells) {
                if (![cell isKindOfClass:NSClassFromString(@"_ASCollectionViewCell")]) continue;
                
                id asCell = cell;
                if (![asCell respondsToSelector:@selector(node)]) continue;
                
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id node = [asCell performSelector:@selector(node)];
                #pragma clang diagnostic pop
                
                if (!node) continue;
                NSString *channelId = cf_getChannelIdFromNode(node);
                
                if (channelId.length > 0) {
                    if (![wl isChannelAllowed:channelId]) {
                        NSIndexPath *indexPath = [strongSelf indexPathForCell:cell];
                        if (indexPath) {
                            [indexPathsToRemove addObject:indexPath];
                            CFLog(@"[GonerinoHack] 🚫 セルをUIから直接削除: %@", channelId);
                        }
                    }
                }
            }

            if (indexPathsToRemove.count > 0) {
                [strongSelf performBatchUpdates:^{
                    [strongSelf deleteItemsAtIndexPaths:indexPathsToRemove];
                } completion:nil];
            }
        } @catch (NSException *e) {
            CFLog(@"[GonerinoHack] Exception: %@", e);
        }
    });
}

%end
// ──────────────────────────────────────────────────────────────────────────


%hook YTInlineSignInViewController
- (void)didTapShowAddAccount {
    cf_showAlert(@"アカウント追加不可",
                 @"このビルドでは複数アカウントの追加は許可されていません。");
}
%end

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

    if (![vcClass isEqualToString:@"YTAppCollectionViewController"]) {
        CFLog(@"[InnerTube] vcClass=%@ count=%lu isSub=%d shouldFilter=%d",
              vcClass, (unsigned long)array.count,
              (int)isSubscriptionFeed, (int)shouldFilter);
    }

    BOOL isSearchVC = ([vcClass containsString:@"Search"] ||
                       [vcClass containsString:@"search"]);
    if (isSearchVC && ![wl isEmpty]) {
        shouldFilter = YES;
        isSubscriptionFeed = NO;
        CFLog(@"[InnerTube] detected SearchVC -> shouldFilter=YES");
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

- (void)addSection:(id)section {
    CFWhitelistManager *wl = [CFWhitelistManager sharedManager];
    BOOL isSubscriptionFeed = [[NSUserDefaults standardUserDefaults]
        boolForKey:@"cf_is_subscription_tab"];
    BOOL shouldFilter = !isSubscriptionFeed && ![wl isEmpty];

    id s = (id)self;
    NSString *vcClass = NSStringFromClass([s class]);
    CFLog(@"[Search-single] vcClass=%@ shouldFilter=%d", vcClass, (int)shouldFilter);

    BOOL isSearchVC = ([vcClass containsString:@"Search"] ||
                       [vcClass containsString:@"search"]);
    if (isSearchVC && ![wl isEmpty]) {
        shouldFilter = YES;
        isSubscriptionFeed = NO;
    }

    if (!shouldFilter) { %orig; return; }

    NSString *secClass = NSStringFromClass([section class]);

    if ([secClass containsString:@"FilterChip"] ||
        [secClass containsString:@"ChipBar"])    { %orig; return; }

    if ([secClass isEqualToString:@"YTIShelfRenderer"] ||
        [secClass containsString:@"ShelfRenderer"]) {
        CFLog(@"[Search-single] Shelf removed cls=%@", secClass);
        return;
    }

    if (![section respondsToSelector:@selector(contentsArray)]) { %orig; return; }
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    NSArray *items = [section performSelector:@selector(contentsArray)];
    #pragma clang diagnostic pop
    if (!items.count) { %orig; return; }

    NSMutableIndexSet *toRemove = [NSMutableIndexSet indexSet];
    for (NSUInteger ii = 0; ii < items.count; ii++) {
        id item = items[ii];
        if (![item respondsToSelector:@selector(elementRenderer)]) continue;
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id elemRenderer = [item performSelector:@selector(elementRenderer)];
        #pragma clang diagnostic pop
        if (!elemRenderer || ![elemRenderer respondsToSelector:@selector(elementData)]) continue;
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id elemData = [elemRenderer performSelector:@selector(elementData)];
        #pragma clang diagnostic pop
        if (!elemData || ![elemData isKindOfClass:[NSData class]]) continue;

        NSString *channelId = cf_extractChannelId((NSData *)elemData);
        if (!channelId.length || ![wl isChannelAllowed:channelId]) {
            [toRemove addIndex:ii];
            if (channelId.length) CFLog(@"[Search-single] excluded ch=%@", channelId);
        }
    }

    if (toRemove.count == items.count) {
        CFLog(@"[Search-single] all %lu items excluded, skip addSection",
              (unsigned long)items.count);
        return;
    }

    if (toRemove.count > 0) {
        NSMutableArray *filtered = [items mutableCopy];
        [filtered removeObjectsAtIndexes:toRemove];
        if ([section respondsToSelector:@selector(setContentsArray:)]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [section performSelector:@selector(setContentsArray:) withObject:filtered];
            #pragma clang diagnostic pop
        }
        CFLog(@"[Search-single] %lu -> %lu items",
              (unsigned long)items.count, (unsigned long)filtered.count);
    }
    %orig;
}
%end


static BOOL cf_filterOneSectionInPlace(id section, CFWhitelistManager *wl) {
    NSString *secCls = NSStringFromClass([section class]);
    if ([secCls containsString:@"FilterChip"] ||
        [secCls containsString:@"ChipBar"])   return YES; 

    if ([secCls isEqualToString:@"YTIShelfRenderer"] ||
        [secCls containsString:@"ShelfRenderer"]) {
        CFLog(@"[SearchVC] Shelf removed cls=%@", secCls);
        return NO;
    }

    if (![section respondsToSelector:@selector(contentsArray)]) return YES;
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    NSArray *items = [section performSelector:@selector(contentsArray)];
    #pragma clang diagnostic pop
    if (!items.count) return YES;

    NSMutableIndexSet *toRemove = [NSMutableIndexSet indexSet];
    for (NSUInteger ii = 0; ii < items.count; ii++) {
        id item = items[ii];
        if (![item respondsToSelector:@selector(elementRenderer)]) continue;
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id er = [item performSelector:@selector(elementRenderer)];
        #pragma clang diagnostic pop
        if (!er || ![er respondsToSelector:@selector(elementData)]) continue;
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id ed = [er performSelector:@selector(elementData)];
        #pragma clang diagnostic pop
        if (!ed || ![ed isKindOfClass:[NSData class]]) continue;
        NSString *ch = cf_extractChannelId((NSData *)ed);
        if (!ch.length || ![wl isChannelAllowed:ch]) {
            [toRemove addIndex:ii];
            if (ch.length) CFLog(@"[SearchVC] excluded ch=%@", ch);
        }
    }

    if (toRemove.count == items.count) return NO;

    if (toRemove.count > 0) {
        NSMutableArray *f = [items mutableCopy];
        [f removeObjectsAtIndexes:toRemove];
        if ([section respondsToSelector:@selector(setContentsArray:)]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [section performSelector:@selector(setContentsArray:) withObject:f];
            #pragma clang diagnostic pop
        }
        CFLog(@"[SearchVC] section %lu->%lu items", (unsigned long)items.count, (unsigned long)f.count);
    }
    return YES;
}

@interface YTSearchResultsViewController : UIViewController
@end

%hook YTSearchResultsViewController
- (void)addSectionsFromArray:(NSArray *)array {
    id s = (id)self;
    CFLog(@"[SearchVC] addSectionsFromArray vcClass=%@ count=%lu",
          NSStringFromClass([s class]), (unsigned long)array.count);
    CFWhitelistManager *wl = [CFWhitelistManager sharedManager];
    if ([wl isEmpty]) { %orig; return; }

    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:array.count];
    for (id sec in array) {
        if (cf_filterOneSectionInPlace(sec, wl)) [filtered addObject:sec];
    }
    CFLog(@"[SearchVC] addSectionsFromArray: %lu -> %lu",
          (unsigned long)array.count, (unsigned long)filtered.count);
    %orig(filtered);
}

- (void)addSection:(id)section {
    id s = (id)self;
    CFLog(@"[SearchVC] addSection vcClass=%@", NSStringFromClass([s class]));
    CFWhitelistManager *wl = [CFWhitelistManager sharedManager];
    if ([wl isEmpty]) { %orig; return; }
    if (cf_filterOneSectionInPlace(section, wl)) %orig;
}

- (void)setSections:(NSArray *)sections {
    CFLog(@"[SearchVC] setSections count=%lu", (unsigned long)sections.count);
    CFWhitelistManager *wl = [CFWhitelistManager sharedManager];
    if ([wl isEmpty]) { %orig; return; }
    NSMutableArray *f = [NSMutableArray arrayWithCapacity:sections.count];
    for (id sec in sections) {
        if (cf_filterOneSectionInPlace(sec, wl)) [f addObject:sec];
    }
    %orig(f);
}
%end

@interface YTSearchResultsCollectionViewController : UIViewController
@end

%hook YTSearchResultsCollectionViewController
- (void)addSectionsFromArray:(NSArray *)array {
    id s = (id)self;
    CFLog(@"[SearchVC2] addSectionsFromArray vcClass=%@ count=%lu",
          NSStringFromClass([s class]), (unsigned long)array.count);
    CFWhitelistManager *wl = [CFWhitelistManager sharedManager];
    if ([wl isEmpty]) { %orig; return; }
    NSMutableArray *f = [NSMutableArray arrayWithCapacity:array.count];
    for (id sec in array) {
        if (cf_filterOneSectionInPlace(sec, wl)) [f addObject:sec];
    }
    %orig(f);
}
- (void)addSection:(id)section {
    id s = (id)self;
    CFLog(@"[SearchVC2] addSection vcClass=%@", NSStringFromClass([s class]));
    CFWhitelistManager *wl = [CFWhitelistManager sharedManager];
    if ([wl isEmpty]) { %orig; return; }
    if (cf_filterOneSectionInPlace(section, wl)) %orig;
}
- (void)setSections:(NSArray *)sections {
    CFLog(@"[SearchVC2] setSections count=%lu", (unsigned long)sections.count);
    CFWhitelistManager *wl = [CFWhitelistManager sharedManager];
    if ([wl isEmpty]) { %orig; return; }
    NSMutableArray *f = [NSMutableArray arrayWithCapacity:sections.count];
    for (id sec in sections) {
        if (cf_filterOneSectionInPlace(sec, wl)) [f addObject:sec];
    }
    %orig(f);
}
%end
static UIImage *cf_shortsLogo(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bPath = [[NSBundle mainBundle]
            pathForResource:@"uYouPlus" ofType:@"bundle"];
        NSBundle *b = bPath ? [NSBundle bundleWithPath:bPath] : nil;
        path = [b pathForResource:@"ShortsLogo" ofType:@"png"];
    });
    if (!path) return nil;
    UIImage *raw = [UIImage imageWithContentsOfFile:path];
    if (!raw) return nil;
    return [UIImage imageWithCGImage:raw.CGImage scale:10.0f
                         orientation:UIImageOrientationUp];
}

%hook UIImage
+ (UIImage *)imageNamed:(NSString *)name
               inBundle:(NSBundle *)bundle
compatibleWithTraitCollection:(UITraitCollection *)tc {
    if ([name isEqualToString:@"youtube_logo_dark_cairo"] ||
        [name isEqualToString:@"youtube_premium_logo_dark_cairo"]) {
        UIImage *i = cf_stardyLogo(YES); if (i) return i;
    }
    if ([name isEqualToString:@"youtube_premium_badge_light"] ||
        [name isEqualToString:@"youtube_premium_standalone_cairo"]) {
        UIImage *i = cf_stardyLogo(NO); if (i) return i;
    }
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
+ (UIImage *)imageNamed:(NSString *)name
                inBundle:(NSBundle *)bundle {
    if ([name isEqualToString:@"youtube_logo_dark_cairo"] ||
        [name isEqualToString:@"youtube_premium_logo_dark_cairo"]) {
        UIImage *i = cf_stardyLogo(YES); if (i) return i;
    }
    if ([name isEqualToString:@"youtube_premium_badge_light"] ||
        [name isEqualToString:@"youtube_premium_standalone_cairo"]) {
        UIImage *i = cf_stardyLogo(NO); if (i) return i;
    }
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
    if ([name isEqualToString:@"youtube_logo_dark_cairo"] ||
        [name isEqualToString:@"youtube_premium_logo_dark_cairo"]) {
        UIImage *i = cf_stardyLogo(YES); if (i) return i;
    }
    if ([name isEqualToString:@"youtube_premium_badge_light"] ||
        [name isEqualToString:@"youtube_premium_standalone_cairo"]) {
        UIImage *i = cf_stardyLogo(NO); if (i) return i;
    }
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
