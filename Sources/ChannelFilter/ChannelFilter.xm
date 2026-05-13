//
//  ChannelFilter.xm — デバッグビルド v3
//
//  目的: 以下を確認する
//    [CF-Logo]  ロゴ画像フックが実際に呼ばれているか / 画像ファイルが見つかるか
//    [CF-Feed]  フィードフックが呼ばれているか / browseId が何か
//    [CF-Node]  ASCollectionView.nodeForItemAtIndexPath: が呼ばれているか（既存コード）
//    [CF-Sync]  ホワイトリスト同期が動いているか
//
//  使い方:
//    1. ビルド・インストール
//    2. アプリ起動 → CF Logsボタン → ログ確認
//    3. 登録チャンネルタブを開く → ログ確認
//    4. 検索タブで何か検索 → ログ確認
//    5. ホームタブに戻る → ログ確認
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

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
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
    NSArray *ordered = [[self.logs reverseObjectEnumerator] allObjects];
    [UIPasteboard generalPasteboard].string = [ordered componentsJoinedByString:@"\n"];
    UIBarButtonItem *btn = self.navigationItem.rightBarButtonItems[1];
    btn.title = @"✓ 済";
    btn.enabled = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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

// ─── ログビューアを開く ───────────────────────────────────────────────────────
static void cf_openLogViewer(void) {
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
    CFLogViewController *vc = [[CFLogViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [root presentViewController:nav animated:YES completion:nil];
}

// ─── フローティングボタン ─────────────────────────────────────────────────────
static const char kCFBtnKey = 0;

static void cf_injectBtn(UIWindow *w) {
    if (!w || objc_getAssociatedObject(w, &kCFBtnKey)) return;
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = CGRectMake(20, 120, 90, 36);
    btn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    [btn setTitle:@"CF Logs" forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor cyanColor] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    btn.layer.cornerRadius = 18;
    btn.clipsToBounds = YES;
    [btn addTarget:btn action:@selector(cf_tap) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:btn action:@selector(cf_pan:)];
    [btn addGestureRecognizer:pan];
    [w addSubview:btn];
    objc_setAssociatedObject(w, &kCFBtnKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// ─── フローティングボタンのアクション (%hook で追加) ─────────────────────────
%hook UIButton
%new
- (void)cf_tap { cf_openLogViewer(); }
%new
- (void)cf_pan:(UIPanGestureRecognizer *)pan {
    UIView *v = pan.view;
    CGPoint t = [pan translationInView:v.superview];
    CGRect b = v.superview.bounds;
    CGFloat hw = v.frame.size.width/2, hh = v.frame.size.height/2;
    CGPoint c = CGPointMake(
        MAX(hw, MIN(b.size.width - hw, v.center.x + t.x)),
        MAX(hh + 20, MIN(b.size.height - hh - 20, v.center.y + t.y)));
    v.center = c;
    [pan setTranslation:CGPointZero inView:v.superview];
}
%end

// ─── UIWindow フック: ウィンドウ切り替えに追従 ───────────────────────────────
%hook UIWindow
- (void)becomeKeyWindow {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ cf_injectBtn(self); });
}
%end

// ─── YTAppDelegate: 起動時に注入 ─────────────────────────────────────────────
%hook YTAppDelegate
- (void)applicationDidBecomeActive:(UIApplication *)app {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *w = nil;
        if (@available(iOS 15, *)) {
            for (UIScene *sc in app.connectedScenes)
                if ([sc isKindOfClass:[UIWindowScene class]])
                    for (UIWindow *win in ((UIWindowScene *)sc).windows)
                        if (win.isKeyWindow) { w = win; break; }
        }
        if (!w) w = app.keyWindow;
        cf_injectBtn(w);
        CFLog(@"[System] App active. WL empty=%d", (int)[[CFWhitelistManager sharedManager] isEmpty]);
    });
}
%end

// ─────────────────────────────────────────────────────────────────────────────
// 調査①: YTInnerTubeCollectionViewController
//   - loadWithModel: が呼ばれているか
//   - browseId は何か
//   - model.contentsArray の件数
// ─────────────────────────────────────────────────────────────────────────────
%hook YTInnerTubeCollectionViewController
- (void)loadWithModel:(id)model {
    id s = (id)self;
    NSString *browseId = [s respondsToSelector:@selector(browseId)]
        ? [s performSelector:@selector(browseId)] : @"(none)";
    NSUInteger count = 0;
    if ([model respondsToSelector:@selector(contentsArray)])
        count = [[model performSelector:@selector(contentsArray)] count];
    CFLog(@"[CF-Feed] loadWithModel: browseId=%@ items=%lu class=%@",
          browseId, (unsigned long)count, NSStringFromClass([s class]));
    %orig;
}

- (void)displaySectionsWithReloadingSectionControllerByRenderer:(id)renderer {
    id s = (id)self;
    NSMutableArray *secs = [s valueForKey:@"_sectionRenderers"];
    CFLog(@"[CF-Feed] displaySections: _sectionRenderers count=%lu", (unsigned long)secs.count);
    %orig;
}

- (void)addSectionsFromArray:(NSArray *)array {
    CFLog(@"[CF-Feed] addSectionsFromArray: count=%lu", (unsigned long)array.count);

    // 最初の呼び出しだけ要素の詳細を調べる
    static BOOL _inspected = NO;
    if (!_inspected && array.count > 0) {
        _inspected = YES;
        id first = array[0];
        CFLog(@"[CF-Feed2] sectionClass=%@", NSStringFromClass([first class]));

        // セクション内のアイテム配列を探す
        NSArray *itemPaths = @[@"contentsArray", @"itemsArray", @"items", @"renderers"];
        for (NSString *path in itemPaths) {
            SEL s = NSSelectorFromString(path);
            if ([first respondsToSelector:s]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id val = [first performSelector:s];
                #pragma clang diagnostic pop
                CFLog(@"[CF-Feed2]   section.%@ count=%lu class=%@",
                      path, (unsigned long)[val count], NSStringFromClass([val class]));
                if ([val count] > 0) {
                    id item = val[0];
                    CFLog(@"[CF-Feed2]   item[0] class=%@", NSStringFromClass([item class]));
                    // item のメソッドからchannelId関連を探す
                    unsigned int cnt = 0;
                    Method *methods = class_copyMethodList([item class], &cnt);
                    for (unsigned int i = 0; i < cnt; i++) {
                        NSString *sel = NSStringFromSelector(method_getName(methods[i]));
                        if ([sel containsString:@"hannel"] || [sel containsString:@"ideo"] ||
                            [sel containsString:@"ender"] || [sel containsString:@"ontent"]) {
                            CFLog(@"[CF-Feed2]     item.method: %@", sel);
                        }
                    }
                    free(methods);
                }
            }
        }
    }
    %orig;
}
%end

// ─────────────────────────────────────────────────────────────────────────────
// 調査②: ASCollectionView.nodeForItemAtIndexPath:
//   - 呼ばれているか / renderer に channelId があるか
//   ※ 既存フックが uYouPlus.xm にあるが、そちらは %hook で追加なので
//     ここでも同じクラスを %hook できる（Logosは同クラスの複数フックを許容）
// ─────────────────────────────────────────────────────────────────────────────
%hook ASCollectionView
- (id)nodeForItemAtIndexPath:(NSIndexPath *)ip {
    id node = %orig;
    static NSUInteger callCount = 0;
    callCount++;

    // 最初の3回だけ node の詳細を掘り下げる
    if (callCount <= 3) {
        CFLog(@"[CF-Node2] #%lu nodeClass=%@", (unsigned long)callCount, NSStringFromClass([node class]));

        // node 自身のメソッド一覧からchannelId・renderer関連を探す
        unsigned int cnt = 0;
        Method *methods = class_copyMethodList([node class], &cnt);
        for (unsigned int i = 0; i < cnt; i++) {
            NSString *sel = NSStringFromSelector(method_getName(methods[i]));
            if ([sel containsString:@"hannel"] || [sel containsString:@" renderer"] ||
                [sel containsString:@"Renderer"] || [sel containsString:@"video"] ||
                [sel containsString:@"Video"] || [sel containsString:@"model"] ||
                [sel containsString:@"Model"]) {
                CFLog(@"[CF-Node2]   method: %@", sel);
            }
        }
        free(methods);

        // よくある経路を全部試す
        NSArray *paths = @[
            @"renderer", @"videoRenderer", @"compactVideoRenderer",
            @"model", @"viewModel", @"contentRenderer",
            @"itemRenderer", @"richItemRenderer"
        ];
        for (NSString *path in paths) {
            SEL s = NSSelectorFromString(path);
            if ([node respondsToSelector:s]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id val = [node performSelector:s];
                #pragma clang diagnostic pop
                CFLog(@"[CF-Node2]   node.%@ = %@", path, NSStringFromClass([val class]));
                // そこからさらにchannelIdを試す
                if ([val respondsToSelector:@selector(channelId)]) {
                    CFLog(@"[CF-Node2]   node.%@.channelId = %@", path, [val performSelector:@selector(channelId)]);
                }
            }
        }
    }
    return node;
}
%end

// ─────────────────────────────────────────────────────────────────────────────
// 調査③: UIImage imageNamed:inBundle:
//   - ロゴ系の画像名でフックが呼ばれているか
//   - バンドルファイルが存在するか
// ─────────────────────────────────────────────────────────────────────────────
%hook UIImage
+ (UIImage *)imageNamed:(NSString *)name
               inBundle:(NSBundle *)bundle
compatibleWithTraitCollection:(UITraitCollection *)tc {

    if ([name isEqualToString:@"youtube_logo_dark_cairo"] ||
        [name isEqualToString:@"youtube_premium_logo_dark_cairo"]) {

        // バンドルパスを取得
        static NSString *darkPath;
        static NSString *litePath;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            NSString *bPath = [[NSBundle mainBundle] pathForResource:@"uYouPlus" ofType:@"bundle"];
            NSBundle *b = bPath ? [NSBundle bundleWithPath:bPath] : nil;
            darkPath = [b pathForResource:@"PremiumLogo_dark" ofType:@"png"];
            litePath = [b pathForResource:@"PremiumLogo_lite" ofType:@"png"];
        });

        // ダークモード判定
        BOOL isDark = (tc.userInterfaceStyle == UIUserInterfaceStyleDark)
            || ([name containsString:@"dark"]);
        NSString *path = isDark ? darkPath : litePath;
        if (path) {
            UIImage *logo = [UIImage imageWithContentsOfFile:path];
            if (logo) {
                CFLog(@"[CF-Logo] ✅ replaced '%@' -> %@", name, isDark ? @"dark" : @"lite");
                return logo;
            } else {
                CFLog(@"[CF-Logo] ❌ imageWithContentsOfFile failed: %@", path);
            }
        } else {
            CFLog(@"[CF-Logo] ❌ path not found for %@", name);
        }
    }

    // ログ（未置き換えのロゴ系）
    if ([name containsString:@"logo"] || [name containsString:@"Logo"] ||
        [name containsString:@"premium"] || [name containsString:@"Premium"]) {
        static NSMutableSet *_seen;
        if (!_seen) _seen = [NSMutableSet set];
        if (![_seen containsObject:name]) {
            [_seen addObject:name];
            CFLog(@"[CF-Logo] imageNamed: '%@' bundle=%@", name, [bundle.bundlePath lastPathComponent]);
        }
    }
    return %orig;
}

+ (UIImage *)imageNamed:(NSString *)name {
    if ([name isEqualToString:@"youtube_logo_dark_cairo"] ||
        [name isEqualToString:@"youtube_premium_logo_dark_cairo"]) {
        static NSString *darkPath2;
        static NSString *litePath2;
        static dispatch_once_t once2;
        dispatch_once(&once2, ^{
            NSString *bPath = [[NSBundle mainBundle] pathForResource:@"uYouPlus" ofType:@"bundle"];
            NSBundle *b = bPath ? [NSBundle bundleWithPath:bPath] : nil;
            darkPath2 = [b pathForResource:@"PremiumLogo_dark" ofType:@"png"];
            litePath2 = [b pathForResource:@"PremiumLogo_lite" ofType:@"png"];
        });
        NSString *path = darkPath2; // バンドルなし版はダーク固定
        if (path) {
            UIImage *logo = [UIImage imageWithContentsOfFile:path];
            if (logo) {
                CFLog(@"[CF-Logo] ✅ replaced(no-bundle) '%@'", name);
                return logo;
            }
        }
    }
    return %orig;
}
%end

// ─────────────────────────────────────────────────────────────────────────────
// 調査④: YTHeaderLogoControllerImpl
//   - setTopbarLogoRenderer: が呼ばれているか（uYouPlus.xm の gSTARDYLogo と同じクラス）
// ─────────────────────────────────────────────────────────────────────────────
%hook YTHeaderLogoControllerImpl
- (void)setTopbarLogoRenderer:(id)renderer {
    CFLog(@"[CF-Logo] setTopbarLogoRenderer: called. renderer=%@", NSStringFromClass([renderer class]));
    %orig;
}
%end

// ─────────────────────────────────────────────────────────────────────────────
// 既存機能: アカウント追加ブロック（変更なし）
// ─────────────────────────────────────────────────────────────────────────────
static void cf_showAlert(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:title message:message
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
            style:UIAlertActionStyleDefault handler:nil]];
        UIWindow *w = nil;
        if (@available(iOS 15, *))
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes)
                if ([sc isKindOfClass:[UIWindowScene class]])
                    for (UIWindow *win in ((UIWindowScene *)sc).windows)
                        if (win.isKeyWindow) { w = win; break; }
        if (!w) w = [UIApplication sharedApplication].keyWindow;
        UIViewController *root = w.rootViewController;
        while (root.presentedViewController) root = root.presentedViewController;
        [root presentViewController:alert animated:YES completion:nil];
    });
}

@interface YTInlineSignInViewController : UIViewController
@end
%hook YTInlineSignInViewController
- (void)didTapShowAddAccount {
    cf_showAlert(@"アカウント追加不可", @"このビルドでは複数アカウントの追加は許可されていません。");
}
%end

// ─────────────────────────────────────────────────────────────────────────────
// 既存機能: 登録ボタン非表示（変更なし）
// ─────────────────────────────────────────────────────────────────────────────
@interface YTQTMButton : UIButton
@end
%hook YTQTMButton
- (void)setTitle:(NSString *)title forState:(UIControlState)state {
    %orig;
    NSString *t = [(UIButton *)self titleForState:UIControlStateNormal];
    if (t && ([t containsString:@"登録"] || [t isEqualToString:@"Subscribe"])) {
        self.hidden = YES; self.alpha = 0;
    }
}
- (void)willMoveToWindow:(UIWindow *)newWindow {
    %orig;
    if (!newWindow) return;
    NSString *t = [self titleForState:UIControlStateNormal];
    if (t && ([t containsString:@"登録"] || [t isEqualToString:@"Subscribe"])) {
        self.hidden = YES; self.alpha = 0;
    }
}
%end
