//
//  ChannelFilter.xm
//  uYouEnhanced - ChannelFilter
//
//  アーキテクチャ: ハイブリッド二重フィルタ
//    Layer 1 (Model層): addSectionsFromArray: でデータがVCに渡る前に除外
//    Layer 2 (UI層):    YTAsyncCollectionView.layoutSubviews で描画後に残ったセルを削除
//                       → 検索・関連動画・エンドカード・キャッシュ動画を全てカバー
//
//  制約:
//    - %ctor を書かない（uYouPlus.xm の %init; で自動初期化）
//    - ASCollectionView をフックしない（二重フックでクラッシュ）
//    - YTAppDelegate をフックしない（二重フックでクラッシュ）
//    - self 直接使用不可 → id s = (id)self;
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
@interface YTInnerTubeCollectionViewController : UIViewController
@end
@interface YTReelWatchRootViewController : UIViewController
@end
@interface YTPivotBarViewController : UIViewController
@end
@interface YTSearchResultsViewController : UIViewController
@end
@interface YTAsyncCollectionView : UICollectionView
- (void)removeOffendingCells;
@end

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
        if (_cfLogs.count > 500) [_cfLogs removeObjectAtIndex:0];
        cf_scheduleLogSave();
    });
}

// ─── ログビューア（検索バー付き）─────────────────────────────────────────────
@interface CFLogViewController : UIViewController
    <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
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

    UIBarButtonItem *closeBtn = [[UIBarButtonItem alloc]
        initWithTitle:@"閉じる" style:UIBarButtonItemStylePlain
               target:self action:@selector(cf_dismiss)];
    UIBarButtonItem *copyBtn = [[UIBarButtonItem alloc]
        initWithTitle:@"全コピー" style:UIBarButtonItemStylePlain
               target:self action:@selector(cf_copyAll)];
    self.navigationItem.rightBarButtonItems = @[closeBtn, copyBtn];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"クリア" style:UIBarButtonItemStylePlain
               target:self action:@selector(cf_clear)];

    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.placeholder = @"フィルタ (例: ClassScan, UI-Layer, AppVC...)";
    self.searchBar.delegate = self;
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    [self.searchBar sizeToFit];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                                  style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                      UIViewAutoresizingFlexibleHeight;
    self.tableView.tableHeaderView = self.searchBar;
    self.tableView.dataSource = self;
    self.tableView.delegate   = self;
    self.tableView.rowHeight  = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 40;
    [self.view addSubview:self.tableView];
    [self cf_reload];
}

- (void)cf_reload {
    NSArray *saved = [[NSUserDefaults standardUserDefaults]
        arrayForKey:@"cf_debug_logs"];
    self.allLogs = saved ? [[saved reverseObjectEnumerator] allObjects] : @[];
    [self cf_applyFilter];
}

- (void)cf_applyFilter {
    NSString *q = [self.filterText stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceCharacterSet]];
    if (!q.length) {
        self.logs = self.allLogs;
    } else {
        NSMutableArray *filtered = [NSMutableArray array];
        for (NSString *line in self.allLogs) {
            if ([line rangeOfString:q options:NSCaseInsensitiveSearch].location
                != NSNotFound) {
                [filtered addObject:line];
            }
        }
        self.logs = filtered;
    }
    [self.tableView reloadData];
    self.title = q.length
        ? [NSString stringWithFormat:@"CF Log (%lu/%lu件)",
           (unsigned long)self.logs.count, (unsigned long)self.allLogs.count]
        : [NSString stringWithFormat:@"CF Debug Log (%lu件)",
           (unsigned long)self.allLogs.count];
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
    [UIPasteboard generalPasteboard].string =
        [self.logs componentsJoinedByString:@"\\n"];
    UIBarButtonItem *btn = self.navigationItem.rightBarButtonItems[1];
    btn.title = @"✓ 済"; btn.enabled = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        btn.title = @"全コピー"; btn.enabled = YES;
    });
}

- (void)searchBar:(UISearchBar *)sb textDidChange:(NSString *)text {
    self.filterText = text;
    [self cf_applyFilter];
}
- (void)searchBarSearchButtonClicked:(UISearchBar *)sb {
    [sb resignFirstResponder];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return (NSInteger)self.logs.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv
         cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"c"];
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.font = [UIFont monospacedSystemFontOfSize:11
                                                          weight:UIFontWeightRegular];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    NSString *line = self.logs[(NSUInteger)ip.row];
    NSString *q = [self.filterText stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceCharacterSet]];
    if (q.length) {
        NSMutableAttributedString *attr =
            [[NSMutableAttributedString alloc] initWithString:line];
        NSRange sr = NSMakeRange(0, line.length);
        NSRange found;
        while ((found = [line rangeOfString:q options:NSCaseInsensitiveSearch
                                      range:sr]).location != NSNotFound) {
            [attr addAttribute:NSBackgroundColorAttributeName
                         value:[UIColor colorWithRed:1 green:0.85 blue:0 alpha:1]
                         range:found];
            sr = NSMakeRange(NSMaxRange(found), line.length - NSMaxRange(found));
        }
        cell.textLabel.attributedText = attr;
    } else {
        cell.textLabel.attributedText = nil;
        cell.textLabel.text = line;
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [UIPasteboard generalPasteboard].string = self.logs[(NSUInteger)ip.row];
}
@end

// ─── メインウィンドウ取得 ─────────────────────────────────────────────────────
static UIWindow *cf_appMainWindow(void) {
    NSArray<UIWindow *> *wins = [UIApplication sharedApplication].windows;
    for (UIWindow *w in wins) {
        NSString *cls = NSStringFromClass([w class]);
        if ([cls containsString:@"Keyboard"]    ||
            [cls containsString:@"TextEffects"] ||
            [cls containsString:@"Accessibility"]) continue;
        return w;
    }
    return wins.firstObject;
}

static void cf_openLogViewer(void) {
    UIWindow *window = cf_appMainWindow();
    if (!window) window = [UIApplication sharedApplication].keyWindow;
    UIViewController *root = window.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    CFLogViewController *vc = [[CFLogViewController alloc] init];
    UINavigationController *nav =
        [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [root presentViewController:nav animated:YES completion:nil];
}

// ─── ClassScan: 起動時に全VCクラスをスキャン ──────────────────────────────────
// addSectionsFromArray: / addSection: / setSections: を持つVCを全てログに出す。
// CF Logsで「ClassScan」と検索すれば検索・関連動画VCのクラス名が一発で判明する。
static BOOL _cf_globalDumped = NO; // VC再生成でリセットされないグローバルフラグ

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
        BOOL h1 = class_getInstanceMethod(cls, sel1) != NULL;
        BOOL h2 = class_getInstanceMethod(cls, sel2) != NULL;
        BOOL h3 = class_getInstanceMethod(cls, sel3) != NULL;
        if (h1 || h2 || h3) {
            [hits addObject:[NSString stringWithFormat:
                @"%@ [array=%d single=%d set=%d]",
                NSStringFromClass(cls), h1, h2, h3]];
        }
    }
    free(classes);

    CFLog(@"[ClassScan] ===== START (scanned %u classes) =====", count);
    for (NSString *h in hits) CFLog(@"[ClassScan] %@", h);
    CFLog(@"[ClassScan] ===== END (%lu hits) =====", (unsigned long)hits.count);
}

// ─── フローティングボタン ─────────────────────────────────────────────────────
static const char kCFBtnKey = 0;
static void cf_injectBtn(UIWindow *w) {
    if (!w || objc_getAssociatedObject(w, &kCFBtnKey)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        // 起動時1回だけ全VCをスキャン
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
        [btn addTarget:nil action:@selector(cf_handleTap:)
            forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:btn action:@selector(cf_handlePan:)];
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
    if (btn) { [w bringSubviewToFront:btn]; }
    else     { cf_injectBtn(w); }
}

%hook UIButton
%new - (void)cf_handleTap:(UIButton *)sender {
    if (sender.tag == 0xCF10) cf_openLogViewer();
}
%new - (void)cf_handlePan:(UIPanGestureRecognizer *)pan {
    UIView *v = pan.view;
    CGPoint t = [pan translationInView:v.superview];
    CGRect  b = v.superview.bounds;
    CGFloat hw = v.frame.size.width/2, hh = v.frame.size.height/2;
    v.center = CGPointMake(
        MAX(hw, MIN(b.size.width-hw,  v.center.x+t.x)),
        MAX(hh+20, MIN(b.size.height-hh-20, v.center.y+t.y)));
    [pan setTranslation:CGPointZero inView:v.superview];
}
%end

%hook UIWindow
- (void)becomeKeyWindow {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ cf_ensureBtn(); });
}
%end

// ─── ヘルパー: アラート表示 ───────────────────────────────────────────────────
static void cf_showAlert(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:title message:message
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
            style:UIAlertActionStyleDefault handler:nil]];
        UIWindow *w = cf_appMainWindow();
        if (!w) w = [UIApplication sharedApplication].keyWindow;
        UIViewController *root = w.rootViewController;
        while (root.presentedViewController) root = root.presentedViewController;
        [root presentViewController:alert animated:YES completion:nil];
    });
}

// ─── ヘルパー: channelId 抽出 ─────────────────────────────────────────────────
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
    NSTextCheckingResult *m = [cf_channelIdRegex()
        firstMatchInString:raw options:0 range:NSMakeRange(0, raw.length)];
    return m ? [raw substringWithRange:m.range] : nil;
}

// ─── ヘルパー: UI層ノードからchannelIdを抽出（Gonerino方式 + channelIdベース）─
// YTVideoWithContextNode 系ノードの navigationEndpoint → Protobufバイナリから
// UC...channelId を抽出して isChannelAllowed: で判定する。
// isChannelNameAllowed: は使わない（ChannelWhitelist.h に存在しないため）。

// ノードのnavigationEndpointからProtobufバイナリを取得してchannelIdを抽出
static NSString *cf_channelIdFromNode(id node) {
    if (!node) return nil;

    // 1. navigationEndpoint → browseEndpoint → Protobufバイナリ
    SEL navSel = NSSelectorFromString(@"navigationEndpoint");
    if ([node respondsToSelector:navSel]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id ep = [node performSelector:navSel];
        #pragma clang diagnostic pop
        if (ep) {
            // browseEndpoint
            SEL bepSel = NSSelectorFromString(@"browseEndpoint");
            if ([ep respondsToSelector:bepSel]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id bep = [ep performSelector:bepSel];
                #pragma clang diagnostic pop
                // browseId が UC... 形式ならそのまま使う
                if (bep) {
                    SEL bidSel = NSSelectorFromString(@"browseId");
                    if ([bep respondsToSelector:bidSel]) {
                        #pragma clang diagnostic push
                        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        NSString *bid = [bep performSelector:bidSel];
                        #pragma clang diagnostic pop
                        if ([bid hasPrefix:@"UC"] && bid.length == 24) return bid;
                    }
                    // serializedDataを試す
                    SEL dataSel = NSSelectorFromString(@"serializedData");
                    if ([bep respondsToSelector:dataSel]) {
                        #pragma clang diagnostic push
                        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        id data = [bep performSelector:dataSel];
                        #pragma clang diagnostic pop
                        if ([data isKindOfClass:[NSData class]]) {
                            NSString *ch = cf_extractChannelId((NSData *)data);
                            if (ch.length) return ch;
                        }
                    }
                }
            }
            // reelWatchEndpoint → params → Base64デコード
            SEL reelSel = NSSelectorFromString(@"reelWatchEndpoint");
            if ([ep respondsToSelector:reelSel]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id reelEP = [ep performSelector:reelSel];
                #pragma clang diagnostic pop
                if (reelEP) {
                    // cf_channelIdFromReelEP と同じロジック
                    SEL ps = NSSelectorFromString(@"params");
                    if ([reelEP respondsToSelector:ps]) {
                        #pragma clang diagnostic push
                        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        id pv = [reelEP performSelector:ps];
                        #pragma clang diagnostic pop
                        if ([pv isKindOfClass:[NSString class]]) {
                            NSString *b64 = [(NSString *)pv
                                stringByReplacingOccurrencesOfString:@"-" withString:@"+"];
                            b64 = [b64 stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
                            NSInteger pad = 4 - (b64.length % 4);
                            if (pad < 4) for (NSInteger i = 0; i < pad; i++)
                                b64 = [b64 stringByAppendingString:@"="];
                            NSData *dec = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
                            if (dec) {
                                NSString *str = [[NSString alloc] initWithData:dec
                                    encoding:NSISOLatin1StringEncoding];
                                if (str) {
                                    NSTextCheckingResult *m = [cf_channelIdRegex()
                                        firstMatchInString:str options:0
                                        range:NSMakeRange(0, str.length)];
                                    if (m) return [str substringWithRange:m.range];
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // 2. serializedData を直接持つ場合
    SEL sdSel = NSSelectorFromString(@"serializedData");
    if ([node respondsToSelector:sdSel]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id data = [node performSelector:sdSel];
        #pragma clang diagnostic pop
        if ([data isKindOfClass:[NSData class]]) {
            NSString *ch = cf_extractChannelId((NSData *)data);
            if (ch.length) return ch;
        }
    }

    return nil;
}

// ─── ヘルパー: ノードがブロック対象か判定（channelIdベース）────────────────────
// isChannelAllowed: で判定する。チャンネル名は使わない。
static BOOL cf_nodeShouldBlock(id node, CFWhitelistManager *wl) {
    if (!node || [wl isEmpty]) return NO;

    // 動画ノード系のみ対象（広告・UIパーツ等の誤検知を防ぐ）
    NSString *nodeCls = NSStringFromClass([node class]);
    BOOL isVideoNode = ([nodeCls containsString:@"VideoWithContext"] ||
                        [nodeCls containsString:@"CompactVideo"]     ||
                        [nodeCls containsString:@"GridVideo"]        ||
                        [nodeCls containsString:@"SearchResult"]     ||
                        [nodeCls containsString:@"VideoCell"]);

    if (isVideoNode) {
        NSString *channelId = cf_channelIdFromNode(node);
        if (channelId.length) {
            BOOL allowed = [wl isChannelAllowed:channelId];
            if (!allowed) CFLog(@"[UI-Layer] blocked channelId=%@", channelId);
            return !allowed;
        }
        // channelId取得不可 → 念のためブロック（広告・ショート等）
        CFLog(@"[UI-Layer] no channelId for node=%@, blocking", nodeCls);
        return YES;
    }

    // 動画ノードでない場合はサブノードを再帰チェック（最大2段）
    SEL subSel = NSSelectorFromString(@"subnodes");
    if ([node respondsToSelector:subSel]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        NSArray *subs = [node performSelector:subSel];
        #pragma clang diagnostic pop
        for (id sub in subs) {
            if (cf_nodeShouldBlock(sub, wl)) return YES;
        }
    }
    return NO;
}

// ─── ヘルパー: Model層セクション1件フィルタリング ────────────────────────────
static BOOL cf_filterOneSectionInPlace(id section, CFWhitelistManager *wl) {
    NSString *secCls = NSStringFromClass([section class]);
    if ([secCls containsString:@"FilterChip"] ||
        [secCls containsString:@"ChipBar"])   return YES;

    // ShelfRenderer はセクションごと除去（ショートシェルフ等）
    if ([secCls isEqualToString:@"YTIShelfRenderer"] ||
        [secCls containsString:@"ShelfRenderer"]     ||
        [secCls containsString:@"Shelf"]             ||
        [secCls containsString:@"Reel"]              ||
        [secCls containsString:@"Short"]) {
        CFLog(@"[Model-Layer] Shelf/Reel/Short section removed cls=%@", secCls);
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
            if (ch.length) CFLog(@"[Model-Layer] excluded ch=%@", ch);
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
        CFLog(@"[Model-Layer] %lu->%lu items", (unsigned long)items.count, (unsigned long)f.count);
    }
    return YES;
}

// ─── STARDYロゴ ──────────────────────────────────────────────────────────────
static UIImage *cf_stardyLogo(BOOL dark) {
    static NSString *darkPath, *litePath;
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
    UIImage *raw = [UIImage imageWithContentsOfFile:path];
    if (!raw) return nil;
    return [UIImage imageWithCGImage:raw.CGImage scale:2.0f
                         orientation:UIImageOrientationUp];
}

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

// ─── ショートタブ フィルター（Model層）────────────────────────────────────────
static NSString *cf_channelIdFromReelEP(id reelEP) {
    if (!reelEP) return nil;
    SEL ps = NSSelectorFromString(@"params");
    if (![reelEP respondsToSelector:ps]) return nil;
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id pv = [reelEP performSelector:ps];
    #pragma clang diagnostic pop
    if (!pv || ![pv isKindOfClass:[NSString class]]) return nil;
    NSString *b64 = [(NSString *)pv
        stringByReplacingOccurrencesOfString:@"-" withString:@"+"];
    b64 = [b64 stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    NSInteger pad = 4 - (b64.length % 4);
    if (pad < 4) for (NSInteger i = 0; i < pad; i++) b64 = [b64 stringByAppendingString:@"="];
    NSData *decoded = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
    if (!decoded) return nil;
    NSString *str = [[NSString alloc] initWithData:decoded encoding:NSISOLatin1StringEncoding];
    if (!str) return nil;
    NSTextCheckingResult *m = [cf_channelIdRegex()
        firstMatchInString:str options:0 range:NSMakeRange(0, str.length)];
    return m ? [str substringWithRange:m.range] : nil;
}

static id cf_reelEPFromModel(id model) {
    if (!model) return nil;
    SEL es = NSSelectorFromString(@"endpoint");
    if (![model respondsToSelector:es]) return nil;
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id ep = [model performSelector:es];
    #pragma clang diagnostic pop
    if (!ep) return nil;
    SEL rs = NSSelectorFromString(@"reelWatchEndpoint");
    if (![ep respondsToSelector:rs]) return nil;
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id reel = [ep performSelector:rs];
    #pragma clang diagnostic pop
    return reel;
}

static NSArray *cf_filterReelModels(NSArray *models, CFWhitelistManager *wl) {
    if (!models.count) return models;
    NSMutableArray *f = [NSMutableArray arrayWithCapacity:models.count];
    for (id model in models) {
        NSString *chId = cf_channelIdFromReelEP(cf_reelEPFromModel(model));
        if (!chId) continue; // channelId不明 = 広告等 → 除外
        if ([wl isChannelAllowed:chId]) [f addObject:model];
    }
    return [f copy];
}

// ════════════════════════════════════════════════════════════════════════════
// LAYER 2: UI層フック（Gonerino方式）
// YTAsyncCollectionView.layoutSubviews で描画済みセルを後から削除する。
// Model層をすり抜けた動画（検索・関連動画・キャッシュ・エンドカード）を全てカバー。
// ════════════════════════════════════════════════════════════════════════════
%hook YTAsyncCollectionView

- (void)layoutSubviews {
    %orig;
    CFWhitelistManager *wl = [CFWhitelistManager sharedManager];
    if ([wl isEmpty]) return;
    id s = (id)self;
    [s removeOffendingCells];
}

%new
- (void)removeOffendingCells {
    __weak id weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong id strongSelf = weakSelf;
        if (!strongSelf) return;

        CFWhitelistManager *wl = [CFWhitelistManager sharedManager];
        if ([wl isEmpty]) return;

        @try {
            UICollectionView *cv = (UICollectionView *)strongSelf;
            NSArray *visibleCells = [cv visibleCells];
            NSMutableArray *toRemove = [NSMutableArray array];

            for (UICollectionViewCell *cell in visibleCells) {
                // _ASCollectionViewCell のみ処理
                if (![NSStringFromClass([cell class])
                      containsString:@"ASCollectionViewCell"]) continue;

                SEL nodeSel = NSSelectorFromString(@"node");
                if (![cell respondsToSelector:nodeSel]) continue;
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id node = [cell performSelector:nodeSel];
                #pragma clang diagnostic pop
                if (!node) continue;

                // YTVideoWithContextNode 系のみフィルタ対象
                if (!cf_nodeShouldBlock(node, wl)) continue;

                NSIndexPath *ip = [cv indexPathForCell:cell];
                if (ip) [toRemove addObject:ip];
            }

            if (toRemove.count > 0) {
                CFLog(@"[UI-Layer] removing %lu cells", (unsigned long)toRemove.count);
                [cv performBatchUpdates:^{
                    [cv deleteItemsAtIndexPaths:toRemove];
                } completion:nil];
            }
        } @catch (NSException *e) {
            NSLog(@"[CF] UI-Layer exception: %@", e);
        }
    });
}
%end

// ════════════════════════════════════════════════════════════════════════════
// LAYER 1: Model層フック（既存ロジック）
// ════════════════════════════════════════════════════════════════════════════

// ─── ショートタブ ─────────────────────────────────────────────────────────────
%hook YTReelWatchRootViewController
- (void)dataSource:(id)ds
didUpdateWithPrevItems:(NSArray *)prev
         nextItems:(NSArray *)next
      refreshItems:(NSArray *)refresh {
    CFWhitelistManager *wl = [CFWhitelistManager sharedManager];
    if ([wl isEmpty]) { %orig; return; }
    NSArray *fp = cf_filterReelModels(prev,    wl);
    NSArray *fn = cf_filterReelModels(next,    wl);
    NSArray *fr = cf_filterReelModels(refresh, wl);
    CFLog(@"[Shorts] prev=%lu->%lu next=%lu->%lu refresh=%lu->%lu",
          (unsigned long)prev.count,    (unsigned long)fp.count,
          (unsigned long)next.count,    (unsigned long)fn.count,
          (unsigned long)refresh.count, (unsigned long)fr.count);
    %orig(ds, fp, fn, fr);
}

- (void)addReelContentModels:(NSArray *)models
       toPlayerSequencerItems:(NSMutableArray *)items {
    CFWhitelistManager *wl = [CFWhitelistManager sharedManager];
    if ([wl isEmpty]) { %orig; return; }
    NSArray *f = cf_filterReelModels(models, wl);
    CFLog(@"[Shorts] addReelContentModels: %lu->%lu",
          (unsigned long)models.count, (unsigned long)f.count);
    %orig(f, items);
}
%end

// ─── タブバー判定（iPhone）────────────────────────────────────────────────────
%hook YTPivotBarViewController
- (void)navigateToItemWithEndpoint:(id)ep animated:(BOOL)a {
    %orig;
    if (!ep) return;
    id bep = nil;
    if ([ep respondsToSelector:@selector(browseEndpoint)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        bep = [ep performSelector:@selector(browseEndpoint)];
        #pragma clang diagnostic pop
    }
    NSString *bid = nil;
    if ([bep respondsToSelector:@selector(browseId)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        bid = [bep performSelector:@selector(browseId)];
        #pragma clang diagnostic pop
    }
    if (!bid.length) return;
    CFLog(@"[PivotBar] browseId=%@", bid);
    BOOL isSub = [bid isEqualToString:@"FEsubscriptions"];
    [[NSUserDefaults standardUserDefaults] setBool:isSub forKey:@"cf_is_subscription_tab"];
}

- (void)setSelectedItemEndpoint:(id)ep {
    %orig;
    if (!ep) return;
    id bep = nil;
    if ([ep respondsToSelector:@selector(browseEndpoint)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        bep = [ep performSelector:@selector(browseEndpoint)];
        #pragma clang diagnostic pop
    }
    NSString *bid = nil;
    if ([bep respondsToSelector:@selector(browseId)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        bid = [bep performSelector:@selector(browseId)];
        #pragma clang diagnostic pop
    }
    if (!bid.length) return;
    BOOL isSub = [bid isEqualToString:@"FEsubscriptions"];
    [[NSUserDefaults standardUserDefaults] setBool:isSub forKey:@"cf_is_subscription_tab"];
}
%end

// ─── タブ判定（iPad）─────────────────────────────────────────────────────────
%hook YTBrowseViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    id s = (id)self;
    if (![s respondsToSelector:@selector(navigationEndpoint)]) return;
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id ep = [s performSelector:@selector(navigationEndpoint)];
    #pragma clang diagnostic pop
    if (!ep || ![ep respondsToSelector:@selector(browseEndpoint)]) return;
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id bep = [ep performSelector:@selector(browseEndpoint)];
    #pragma clang diagnostic pop
    if (!bep || ![bep respondsToSelector:@selector(browseId)]) return;
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    NSString *bid = [bep performSelector:@selector(browseId)];
    #pragma clang diagnostic pop
    if (!bid.length) return;
    CFLog(@"[BrowseVC] viewWillAppear browseId=%@", bid);
    BOOL isSub = [bid isEqualToString:@"FEsubscriptions"];
    [[NSUserDefaults standardUserDefaults] setBool:isSub forKey:@"cf_is_subscription_tab"];
}

- (void)setNavigationEndpoint:(id)ep {
    %orig;
    if (!ep) return;
    id bep = nil;
    if ([ep respondsToSelector:@selector(browseEndpoint)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        bep = [ep performSelector:@selector(browseEndpoint)];
        #pragma clang diagnostic pop
    }
    if (!bep) {
        // browseEndpointなし = 検索 → フラグOFF
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"cf_is_subscription_tab"];
        CFLog(@"[BrowseVC] no browseEP -> FLAG OFF");
        return;
    }
    NSString *bid = nil;
    if ([bep respondsToSelector:@selector(browseId)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        bid = [bep performSelector:@selector(browseId)];
        #pragma clang diagnostic pop
    }
    if (!bid.length) return;
    CFLog(@"[BrowseVC] setNavEP browseId=%@", bid);
    BOOL isSub = [bid isEqualToString:@"FEsubscriptions"];
    if ([bid hasPrefix:@"FE"]) {
        [[NSUserDefaults standardUserDefaults] setBool:isSub forKey:@"cf_is_subscription_tab"];
    }
    // UC...チャンネルページはフラグ変更しない
}
%end

// ─── ホームフィードフィルター + ホワイトリスト同期 ───────────────────────────
%hook YTAppCollectionViewController

- (void)setNavigationEndpoint:(id)ep {
    %orig;
    if (!ep) return;
    id bep = nil;
    if ([ep respondsToSelector:@selector(browseEndpoint)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        bep = [ep performSelector:@selector(browseEndpoint)];
        #pragma clang diagnostic pop
    }
    if (!bep) {
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"cf_is_subscription_tab"];
        return;
    }
    NSString *bid = nil;
    if ([bep respondsToSelector:@selector(browseId)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        bid = [bep performSelector:@selector(browseId)];
        #pragma clang diagnostic pop
    }
    if (!bid.length) return;
    BOOL isSub = [bid isEqualToString:@"FEsubscriptions"];
    if ([bid hasPrefix:@"FE"]) {
        [[NSUserDefaults standardUserDefaults] setBool:isSub forKey:@"cf_is_subscription_tab"];
    }
}

- (void)addSectionsFromArray:(NSArray *)array {
    CFWhitelistManager *wl = [CFWhitelistManager sharedManager];

    // ─── browseId をself→parentVCチェーンで直接確認（フラグ非依存）────────────
    NSString *resolvedBrowseId = nil;
    id s = (id)self;

    // self自身のnavigationEndpointを最優先で確認
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

    // 取得できなければparentVCチェーンを最大10段追う
    if (!resolvedBrowseId) {
        UIViewController *cur = (UIViewController *)s;
        for (int d = 0; d < 10 && cur && !resolvedBrowseId; d++) {
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

    BOOL isSubscriptionFeed;
    if (resolvedBrowseId.length) {
        isSubscriptionFeed = [resolvedBrowseId isEqualToString:@"FEsubscriptions"];
        [[NSUserDefaults standardUserDefaults]
            setBool:isSubscriptionFeed forKey:@"cf_is_subscription_tab"];
        CFLog(@"[AppVC] browseId=%@ isSub=%d", resolvedBrowseId, (int)isSubscriptionFeed);
    } else {
        isSubscriptionFeed = [[NSUserDefaults standardUserDefaults]
            boolForKey:@"cf_is_subscription_tab"];
        CFLog(@"[AppVC] no browseId, fallback flag isSub=%d", (int)isSubscriptionFeed);
    }

    BOOL shouldFilter = !isSubscriptionFeed && ![wl isEmpty];
    CFLog(@"[AppVC] count=%lu shouldFilter=%d wlEmpty=%d",
          (unsigned long)array.count, (int)shouldFilter, (int)[wl isEmpty]);

    // 最初の1回だけ構造をダンプ（フィルタリング中のみ）
    if (!_cf_globalDumped && shouldFilter && array.count > 3) {
        _cf_globalDumped = YES;
        CFLog(@"[Dump] START count=%lu", (unsigned long)array.count);
        for (NSUInteger di = 0; di < MIN(array.count, 5); di++) {
            id sec = array[di];
            CFLog(@"[Dump] si=%lu cls=%@", (unsigned long)di,
                  NSStringFromClass([sec class]));
        }
        CFLog(@"[Dump] END");
    }

    if (!shouldFilter && !isSubscriptionFeed) { %orig; return; }

    NSMutableArray *channelIdsForSync = isSubscriptionFeed
        ? [NSMutableArray array] : nil;
    NSMutableIndexSet *toRemoveSections = [NSMutableIndexSet indexSet];

    for (NSUInteger si = 0; si < array.count; si++) {
        id section = array[si];
        NSString *secCls = NSStringFromClass([section class]);

        if ([secCls containsString:@"FilterChip"] ||
            [secCls containsString:@"ChipBar"]) continue;

        // ShelfRenderer / Reel / Short 系はセクションごと除去
        if (shouldFilter) {
            if ([secCls isEqualToString:@"YTIShelfRenderer"] ||
                [secCls containsString:@"ShelfRenderer"]     ||
                [secCls containsString:@"Shelf"]             ||
                [secCls containsString:@"Reel"]              ||
                [secCls containsString:@"Short"]) {
                CFLog(@"[AppVC] Shelf/Reel removed si=%lu cls=%@",
                      (unsigned long)si, secCls);
                [toRemoveSections addIndex:si];
                continue;
            }
        }

        if (![section respondsToSelector:@selector(contentsArray)]) continue;
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        NSArray *items = [section performSelector:@selector(contentsArray)];
        #pragma clang diagnostic pop
        if (!items.count) continue;

        NSMutableIndexSet *toRemoveItems = [NSMutableIndexSet indexSet];
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

            NSString *channelId = cf_extractChannelId((NSData *)ed);
            if (!channelId.length) {
                if (shouldFilter) [toRemoveItems addIndex:ii];
                continue;
            }
            if (isSubscriptionFeed) {
                [channelIdsForSync addObject:channelId];
            } else if (shouldFilter && ![wl isChannelAllowed:channelId]) {
                CFLog(@"[AppVC] excluded ch=%@", channelId);
                [toRemoveItems addIndex:ii];
            }
        }

        if (toRemoveItems.count > 0) {
            NSMutableArray *filtered = [items mutableCopy];
            [filtered removeObjectsAtIndexes:toRemoveItems];
            if ([section respondsToSelector:@selector(setContentsArray:)]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [section performSelector:@selector(setContentsArray:)
                             withObject:filtered];
                #pragma clang diagnostic pop
            }
            if (filtered.count == 0) [toRemoveSections addIndex:si];
        }
    }

    // 除去セクションのcontentsArrayをクリア（キャッシュ対策）
    [toRemoveSections enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx >= array.count) return;
        id sec = array[idx];
        if ([sec respondsToSelector:@selector(setContentsArray:)]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [sec performSelector:@selector(setContentsArray:) withObject:@[]];
            #pragma clang diagnostic pop
        }
    }];

    NSMutableArray *filtered = [array mutableCopy];
    if (toRemoveSections.count > 0) {
        [filtered removeObjectsAtIndexes:toRemoveSections];
        CFLog(@"[AppVC] ✅ removed=%lu remaining=%lu",
              (unsigned long)toRemoveSections.count,
              (unsigned long)filtered.count);
    }
    %orig(filtered);

    if (isSubscriptionFeed && channelIdsForSync.count > 0) {
        [wl syncSubscribedChannelIDs:channelIdsForSync];
        CFLog(@"[Sync] ✅ %lu ids", (unsigned long)channelIdsForSync.count);
    }
}
%end

// ─── InnerTube VC フック（サブクラス補完 + 検索VC検出）──────────────────────
%hook YTInnerTubeCollectionViewController
- (void)addSectionsFromArray:(NSArray *)array {
    id s = (id)self;
    NSString *vcCls = NSStringFromClass([s class]);
    CFWhitelistManager *wl = [CFWhitelistManager sharedManager];
    BOOL isSub = [[NSUserDefaults standardUserDefaults] boolForKey:@"cf_is_subscription_tab"];

    // YTAppCollectionViewController以外のVCをログ
    if (![vcCls isEqualToString:@"YTAppCollectionViewController"]) {
        CFLog(@"[InnerTube] vcClass=%@ count=%lu isSub=%d",
              vcCls, (unsigned long)array.count, (int)isSub);
    }

    // 検索VCまたはSearch含むVC → 強制フィルタリングON
    BOOL forceFilter = [vcCls containsString:@"Search"] || [vcCls containsString:@"search"];
    BOOL shouldFilter = (forceFilter || !isSub) && ![wl isEmpty];

    if (!shouldFilter && !isSub) { %orig; return; }

    NSMutableArray *channelIdsForSync = isSub ? [NSMutableArray array] : nil;
    NSMutableIndexSet *toRemove = [NSMutableIndexSet indexSet];

    for (NSUInteger si = 0; si < array.count; si++) {
        id sec = array[si];
        if (!cf_filterOneSectionInPlace(sec, wl)) {
            [toRemove addIndex:si];
        }
    }

    NSMutableArray *filtered = [array mutableCopy];
    if (toRemove.count > 0) [filtered removeObjectsAtIndexes:toRemove];
    %orig(filtered);

    if (isSub && channelIdsForSync.count > 0) {
        [wl syncSubscribedChannelIDs:channelIdsForSync];
    }
}

- (void)addSection:(id)section {
    id s = (id)self;
    NSString *vcCls = NSStringFromClass([s class]);
    CFLog(@"[InnerTube-single] vcClass=%@", vcCls);
    CFWhitelistManager *wl = [CFWhitelistManager sharedManager];
    if ([wl isEmpty]) { %orig; return; }
    BOOL isSub = [[NSUserDefaults standardUserDefaults] boolForKey:@"cf_is_subscription_tab"];
    BOOL forceFilter = [vcCls containsString:@"Search"] || [vcCls containsString:@"search"];
    if (!forceFilter && isSub) { %orig; return; }
    if (cf_filterOneSectionInPlace(section, wl)) %orig;
}
%end

// ─── 検索VC フック ─────────────────────────────────────────────────────────
%hook YTSearchResultsViewController
- (void)addSectionsFromArray:(NSArray *)array {
    id s = (id)self;
    CFLog(@"[SearchVC] addSectionsFromArray vcClass=%@ count=%lu",
          NSStringFromClass([s class]), (unsigned long)array.count);
    CFWhitelistManager *wl = [CFWhitelistManager sharedManager];
    if ([wl isEmpty]) { %orig; return; }
    NSMutableArray *f = [NSMutableArray arrayWithCapacity:array.count];
    for (id sec in array) {
        if (cf_filterOneSectionInPlace(sec, wl)) [f addObject:sec];
    }
    CFLog(@"[SearchVC] %lu->%lu", (unsigned long)array.count, (unsigned long)f.count);
    %orig(f);
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

// ─── アカウント追加ブロック ───────────────────────────────────────────────────
%hook YTInlineSignInViewController
- (void)didTapShowAddAccount {
    cf_showAlert(@"アカウント追加不可",
                 @"このビルドでは複数アカウントの追加は許可されていません。");
}
%end

// ─── 登録操作の無効化 ─────────────────────────────────────────────────────────
// ボタンを非表示にするだけでなく、登録アクション自体を無効化する。
// YTQTMButton: accessibilityIdentifier が "id.ui.title.tab.button" の場合が登録ボタン。
%hook YTQTMButton
- (void)setAccessibilityIdentifier:(NSString *)identifier {
    %orig;
    if ([identifier isEqualToString:@"id.ui.title.tab.button"]) {
        self.hidden = YES;
        self.alpha  = 0;
        self.userInteractionEnabled = NO;
    }
}
- (void)willMoveToWindow:(UIWindow *)newWindow {
    %orig;
    if (!newWindow) return;
    if ([self.accessibilityIdentifier isEqualToString:@"id.ui.title.tab.button"]) {
        self.hidden = YES;
        self.alpha  = 0;
        self.userInteractionEnabled = NO;
    }
}
// タップイベント自体を無効化（accessibilityIdentifierが登録ボタンの場合のみ）
- (void)sendActionsForControlEvents:(UIControlEvents)events {
    if ([self.accessibilityIdentifier isEqualToString:@"id.ui.title.tab.button"]) return;
    %orig;
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
            if ([NSStringFromClass([v class]) isEqualToString:@"YTQTMButton"] &&
                [v.accessibilityIdentifier isEqualToString:@"id.ui.title.tab.button"]) {
                v.hidden = YES;
                v.alpha  = 0;
                v.userInteractionEnabled = NO;
            }
            for (UIView *sub in v.subviews) [stack addObject:sub];
        }
    });
}
%end

// ─── ロゴ置き換え ─────────────────────────────────────────────────────────────
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
    if ([name isEqualToString:@"youtube_shorts_24_cairo"]          ||
        [name isEqualToString:@"youtube_outline_experimental/shorts_24pt"] ||
        [name isEqualToString:@"youtube_fill_experimental/shorts_24pt"]    ||
        [name isEqualToString:@"ic_shorts_logo"]                   ||
        [name isEqualToString:@"youtube_shorts_logo"]              ||
        [name isEqualToString:@"shorts_logo"]                      ||
        [name isEqualToString:@"reel_logo"]) {
        UIImage *i = cf_shortsLogo(); if (i) return i;
    }
    return %orig;
}
+ (UIImage *)imageNamed:(NSString *)name inBundle:(NSBundle *)bundle {
    if ([name isEqualToString:@"youtube_logo_dark_cairo"] ||
        [name isEqualToString:@"youtube_premium_logo_dark_cairo"]) {
        UIImage *i = cf_stardyLogo(YES); if (i) return i;
    }
    if ([name isEqualToString:@"youtube_premium_badge_light"] ||
        [name isEqualToString:@"youtube_premium_standalone_cairo"]) {
        UIImage *i = cf_stardyLogo(NO); if (i) return i;
    }
    if ([name isEqualToString:@"youtube_shorts_24_cairo"]          ||
        [name isEqualToString:@"youtube_outline_experimental/shorts_24pt"] ||
        [name isEqualToString:@"youtube_fill_experimental/shorts_24pt"]    ||
        [name isEqualToString:@"ic_shorts_logo"]                   ||
        [name isEqualToString:@"youtube_shorts_logo"]              ||
        [name isEqualToString:@"shorts_logo"]                      ||
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
    if ([name isEqualToString:@"youtube_shorts_24_cairo"]          ||
        [name isEqualToString:@"youtube_outline_experimental/shorts_24pt"] ||
        [name isEqualToString:@"youtube_fill_experimental/shorts_24pt"]    ||
        [name isEqualToString:@"ic_shorts_logo"]                   ||
        [name isEqualToString:@"youtube_shorts_logo"]              ||
        [name isEqualToString:@"shorts_logo"]                      ||
        [name isEqualToString:@"reel_logo"]) {
        UIImage *i = cf_shortsLogo(); if (i) return i;
    }
    return %orig;
}
%end
