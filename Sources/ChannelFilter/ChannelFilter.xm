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
    // 最初の5回だけ詳細ログ、以降は10件に1回サマリ
    if (callCount <= 5 || callCount % 50 == 0) {
        id renderer = [node respondsToSelector:@selector(renderer)]
            ? [node performSelector:@selector(renderer)] : nil;
        NSString *cid = ([renderer respondsToSelector:@selector(channelId)])
            ? [renderer performSelector:@selector(channelId)] : nil;
        CFLog(@"[CF-Node] #%lu nodeForItem ip=%ld/%ld rendererClass=%@ channelId=%@",
              (unsigned long)callCount,
              (long)ip.section, (long)ip.row,
              NSStringFromClass([renderer class]),
              cid ?: @"(nil)");
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
    // ロゴ系の名前だけログ（全呼び出しだと多すぎる）
    if ([name containsString:@"logo"] || [name containsString:@"Logo"] ||
        [name containsString:@"premium"] || [name containsString:@"Premium"] ||
        [name containsString:@"brand"] || [name hasPrefix:@"youtube_logo"] ||
        [name hasPrefix:@"youtube_premium"]) {

        static NSMutableSet *_seen;
        if (!_seen) _seen = [NSMutableSet set];
        if (![_seen containsObject:name]) {
            [_seen addObject:name];

            // バンドル内のファイル存在確認
            NSString *bPath = [[NSBundle mainBundle] pathForResource:@"uYouPlus" ofType:@"bundle"];
            NSBundle *ypBundle = bPath ? [NSBundle bundleWithPath:bPath] : nil;
            NSString *darkPath  = [ypBundle pathForResource:@"PremiumLogo_dark" ofType:@"png"];
            NSString *litePath  = [ypBundle pathForResource:@"PremiumLogo_lite" ofType:@"png"];

            CFLog(@"[CF-Logo] imageNamed: '%@' bundle=%@", name, [bundle.bundlePath lastPathComponent]);
            // バンドルファイル存在確認（初回のみ）
            static BOOL _bundleChecked = NO;
            if (!_bundleChecked) {
                _bundleChecked = YES;
                CFLog(@"[CF-Logo] uYouPlus.bundle path=%@", bPath ?: @"NOT FOUND");
                CFLog(@"[CF-Logo] PremiumLogo_dark.png = %@", darkPath ? @"EXISTS" : @"NOT FOUND");
                CFLog(@"[CF-Logo] PremiumLogo_lite.png = %@", litePath ? @"EXISTS" : @"NOT FOUND");
            }
        }
    }
    return %orig;
}

+ (UIImage *)imageNamed:(NSString *)name {
    if ([name containsString:@"logo"] || [name containsString:@"Logo"] ||
        [name containsString:@"premium"] || [name containsString:@"Premium"] ||
        [name hasPrefix:@"youtube_logo"] || [name hasPrefix:@"youtube_premium"]) {
        static NSMutableSet *_seen2;
        if (!_seen2) _seen2 = [NSMutableSet set];
        if (![_seen2 containsObject:name]) {
            [_seen2 addObject:name];
            CFLog(@"[CF-Logo] imageNamed(no-bundle): '%@'", name);
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
