//
//  ChannelFilter.xm  — デバッグビルド（修正版）
//
//  修正点:
//  1. dispatch_once を削除 → 再描画後もボタンが復活するよう viewWillAppear でチェック＆追加
//  2. YTSettingsViewController に加え YTAppSettingsViewController / YTSettingsSectionViewController も同時フック
//  3. dispatch_once に頼らないフローティングボタンを導入
//     - YTAppDelegate の applicationDidBecomeActive: でウィンドウが切り替わっても再注入
//     - UIWindow の becomeKeyWindow をフックしてウィンドウ交代を検知する二段構え
//  4. UIImage フックは「yt_」「logo」「brand」「premium」に絞り、過剰呼び出しを抑制
//  5. UIViewController フックはクラス名を NSSet で重複ログをまとめる（無限ループ防止）
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "ChannelWhitelist.h"

// ─── インメモリ + NSUserDefaults ログバッファ ──────────────────────────────────
static NSMutableArray *CFLogs;
static void CFLog(NSString *format, ...) {
    if (!CFLogs) {
        // アプリ起動直後はまだ NSUserDefaults から復元する
        NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:@"cf_debug_logs"];
        CFLogs = saved ? [saved mutableCopy] : [NSMutableArray array];
    }
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[CF] %@", msg);

    // メインスレッドでないと NSUserDefaults の同期はスレッドアンセーフ
    dispatch_async(dispatch_get_main_queue(), ^{
        [CFLogs addObject:msg];
        if (CFLogs.count > 600) [CFLogs removeObjectAtIndex:0];
        [[NSUserDefaults standardUserDefaults] setObject:[CFLogs copy] forKey:@"cf_debug_logs"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    });
}

// ─── ログビューア ──────────────────────────────────────────────────────────────
@interface CFLogViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray *logs;
@end

@implementation CFLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"ChannelFilter Debug Log";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // 右側：閉じる
    UIBarButtonItem *closeBtn = [[UIBarButtonItem alloc]
        initWithTitle:@"閉じる"
               style:UIBarButtonItemStylePlain
              target:self
              action:@selector(cf_dismiss)];

    // 右側：全コピー
    UIBarButtonItem *copyAllBtn = [[UIBarButtonItem alloc]
        initWithTitle:@"全コピー"
               style:UIBarButtonItemStylePlain
              target:self
              action:@selector(cf_copyAll)];

    self.navigationItem.rightBarButtonItems = @[closeBtn, copyAllBtn];

    // 左側：クリア
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"クリア"
               style:UIBarButtonItemStylePlain
              target:self
              action:@selector(cf_clearLogs)];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                                  style:UITableViewStylePlain];
    self.tableView.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate   = self;
    self.tableView.rowHeight  = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 44;
    [self.view addSubview:self.tableView];

    [self cf_reloadLogs];
}

- (void)cf_reloadLogs {
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:@"cf_debug_logs"];
    // 新しいログを上に表示する
    self.logs = saved ? [[saved reverseObjectEnumerator] allObjects] : @[];
    [self.tableView reloadData];
}

- (void)cf_dismiss { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)cf_copyAll {
    if (self.logs.count == 0) return;
    // 古い順（正順）でまとめてコピー
    NSArray *inOrder = [[self.logs reverseObjectEnumerator] allObjects];
    NSString *all = [inOrder componentsJoinedByString:@"\n"];
    [UIPasteboard generalPasteboard].string = all;

    // ボタンを一瞬「✓ コピー済」に変えてフィードバック
    UIBarButtonItem *btn = self.navigationItem.rightBarButtonItems[1];
    NSString *original = btn.title;
    btn.title = @"✓ コピー済";
    btn.enabled = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        btn.title = original;
        btn.enabled = YES;
    });
}

- (void)cf_clearLogs {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"cf_debug_logs"];
    CFLogs = [NSMutableArray array];
    [self cf_reloadLogs];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return (NSInteger)self.logs.count;
}
- (UITableViewCell *)tableView:(UITableView *)tv
         cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"cf_log"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"cf_log"];
        cell.textLabel.numberOfLines  = 0;
        cell.textLabel.font = [UIFont monospacedSystemFontOfSize:11
                                                          weight:UIFontWeightRegular];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.textLabel.text = self.logs[(NSUInteger)ip.row];
    return cell;
}
// タップ → クリップボードにコピー
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [UIPasteboard generalPasteboard].string = self.logs[(NSUInteger)ip.row];
}

@end

// ─── フローティングボタンを注入するユーティリティ ─────────────────────────────
// 同一 window に二重注入しないよう associated object でフラグを立てる
static const char kCFFloatBtnKey = 0;

static UIButton *cf_makeFloatingButton(void);

static void cf_injectFloatingButton(UIWindow *window) {
    if (!window) return;
    // 既に注入済みなら何もしない
    if (objc_getAssociatedObject(window, &kCFFloatBtnKey)) return;

    UIButton *btn = cf_makeFloatingButton();
    if (!btn) return;
    [window addSubview:btn];
    objc_setAssociatedObject(window, &kCFFloatBtnKey,
                             btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CFLog(@"[System] Floating button injected into: %@", NSStringFromClass([window class]));
}

// ─── ログビューアを開く ────────────────────────────────────────────────────────
// C関数として定義（%hook 外から呼べる）
static void cf_openLogViewer(void) {
    UIWindow *window = nil;
    // iOS 15+ シーン対応
    if (@available(iOS 15, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.isKeyWindow) { window = w; break; }
                }
            }
            if (window) break;
        }
    }
    if (!window) window = [UIApplication sharedApplication].keyWindow;
    if (!window) return;

    UIViewController *root = window.rootViewController;
    // モーダルが積まれている場合は一番上のVCを探す
    while (root.presentedViewController)
        root = root.presentedViewController;

    CFLogViewController *logVC = [[CFLogViewController alloc] init];
    UINavigationController *nav =
        [[UINavigationController alloc] initWithRootViewController:logVC];
    nav.modalPresentationStyle = UIModalPresentationFormSheet; // iPad 対応
    [root presentViewController:nav animated:YES completion:nil];
}

// ─── フローティングボタン本体の生成 ──────────────────────────────────────────
//
// ドラッグ可能 / タップでログビューア / iPad でも視認しやすいデザイン
//
@interface CFFloatingButton : UIButton
@end
@implementation CFFloatingButton
- (void)handleCFPan:(UIPanGestureRecognizer *)pan {
    UIView *v = pan.view;
    CGPoint t = [pan translationInView:v.superview];
    CGPoint c = v.center;
    c.x += t.x;
    c.y += t.y;
    // 画面外に出ないようにクランプ
    CGRect bounds = v.superview.bounds;
    CGFloat hw = v.frame.size.width  / 2;
    CGFloat hh = v.frame.size.height / 2;
    c.x = MAX(hw, MIN(bounds.size.width  - hw, c.x));
    c.y = MAX(hh + 20, MIN(bounds.size.height - hh - 20, c.y)); // ステータスバー回避
    v.center = c;
    [pan setTranslation:CGPointZero inView:v.superview];
}
@end

static UIButton *cf_makeFloatingButton(void) {
    CFFloatingButton *btn = [CFFloatingButton buttonWithType:UIButtonTypeSystem];
    btn.frame = CGRectMake(20, 120, 88, 40);
    btn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    [btn setTitle:@"CF Logs" forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor cyanColor] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    btn.layer.cornerRadius = 20;
    btn.clipsToBounds = YES;
    btn.layer.borderWidth = 1;
    btn.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.3].CGColor;
    // タップ
    [btn addTarget:btn action:@selector(cf_tap) forControlEvents:UIControlEventTouchUpInside];
    // ドラッグ
    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:btn
                                                action:@selector(handleCFPan:)];
    [btn addGestureRecognizer:pan];
    return btn;
}

// CFFloatingButton のタップアクション
%hook CFFloatingButton
%new
- (void)cf_tap {
    cf_openLogViewer();
}
%end

// ─── フック① YTAppDelegate — アプリがアクティブになるたびに注入試行 ────────────
//
// %hook YTAppDelegate が uYouPlus.xm でも使われているため競合しないよう
// applicationDidBecomeActive: だけを追加でフックする
//
%hook YTAppDelegate
- (void)applicationDidBecomeActive:(UIApplication *)application {
    %orig;
    // 少し待ってウィンドウが確定してから注入
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            UIWindow *target = nil;
            if (@available(iOS 15, *)) {
                for (UIScene *scene in application.connectedScenes) {
                    if ([scene isKindOfClass:[UIWindowScene class]]) {
                        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                            if (w.isKeyWindow) { target = w; break; }
                        }
                    }
                    if (target) break;
                }
            }
            if (!target) target = application.keyWindow;
            cf_injectFloatingButton(target);
        });
}
%end

// ─── フック② UIWindow.becomeKeyWindow — ウィンドウが切り替わった瞬間に再注入 ──
//
// YouTube は動画再生・広告などで UIWindow を頻繁に差し替える。
// makeKeyAndVisible / becomeKeyWindow をフックしておくと確実に追従できる。
//
%hook UIWindow
- (void)becomeKeyWindow {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        cf_injectFloatingButton(self);
    });
}
%end

// ─── フック③ 設定画面 — dispatch_once なしで毎回チェック＆追加 ────────────────
//
// 問題: dispatch_once は「初回だけ」実行される。YouTubeが設定画面を
//       再描画するとナビゲーションアイテムごとリセットされるため二度と現れない。
// 修正: viewWillAppear: でボタンの有無を毎回確認し、消えていたら再追加する。
//
// クラス名候補を複数フック（YouTube バージョンによって変わるため）

// ── 共通のボタン追加ロジックをマクロで展開 ──
#define CF_ADD_DEBUG_BUTTON(vc_self) \
    do { \
        UIViewController *_vc = (UIViewController *)(vc_self); \
        if (_vc.navigationItem.rightBarButtonItem == nil || \
            _vc.navigationItem.rightBarButtonItem.action != @selector(cf_showDebugLog)) { \
            UIBarButtonItem *_btn = [[UIBarButtonItem alloc] \
                initWithTitle:@"CF Debug" \
                        style:UIBarButtonItemStylePlain \
                       target:_vc \
                       action:@selector(cf_showDebugLog)]; \
            _vc.navigationItem.rightBarButtonItem = _btn; \
            CFLog(@"[UI] CF Debug button added to %@", NSStringFromClass([_vc class])); \
        } \
    } while(0)

%hook YTSettingsViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    CF_ADD_DEBUG_BUTTON(self);
}
%new
- (void)cf_showDebugLog {
    cf_openLogViewer();
}
%end

%hook YTAppSettingsViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    CF_ADD_DEBUG_BUTTON(self);
}
%new
- (void)cf_showDebugLog {
    cf_openLogViewer();
}
%end

// YouTube 20.x で確認されているもう一つの候補
%hook YTSettingsSectionViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    CF_ADD_DEBUG_BUTTON(self);
}
%new
- (void)cf_showDebugLog {
    cf_openLogViewer();
}
%end

// ─── 調査①: タブ・ナビゲーション系のクラス名 ────────────────────────────────
// 重複ログを抑制するため NSMutableSet でキャッシュする
%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSString *name = NSStringFromClass([self class]);

    // タブバー・Pivot 系
    if ([name containsString:@"Pivot"] || [name containsString:@"TabBar"]) {
        static NSMutableSet *_s1;
        if (!_s1) _s1 = [NSMutableSet set];
        if (![_s1 containsObject:name]) {
            [_s1 addObject:name];
            CFLog(@"[TabVC] %@", name);
        }
    }

    // 登録・サブスクリプション・フィード系
    if ([name containsString:@"Subscri"] || [name containsString:@"Channel"] ||
        [name containsString:@"Feed"]) {
        static NSMutableSet *_s2;
        if (!_s2) _s2 = [NSMutableSet set];
        if (![_s2 containsObject:name]) {
            [_s2 addObject:name];
            CFLog(@"[FeedVC] %@", name);
            unsigned int cnt = 0;
            Method *methods = class_copyMethodList([self class], &cnt);
            for (unsigned int i = 0; i < cnt; i++) {
                NSString *sel = NSStringFromSelector(method_getName(methods[i]));
                if ([sel containsString:@"ubscri"] || [sel containsString:@"hannel"] ||
                    [sel containsString:@"feed"]   || [sel containsString:@"Feed"]) {
                    CFLog(@"  method: %@", sel);
                }
            }
            free(methods);
        }
    }

    // 動画再生・プレイヤー系
    if ([name containsString:@"Watch"] || [name containsString:@"Player"]) {
        static NSMutableSet *_s3;
        if (!_s3) _s3 = [NSMutableSet set];
        if (![_s3 containsObject:name]) {
            [_s3 addObject:name];
            CFLog(@"[WatchVC] %@", name);
            unsigned int cnt = 0;
            Method *methods = class_copyMethodList([self class], &cnt);
            for (unsigned int i = 0; i < cnt; i++) {
                NSString *sel = NSStringFromSelector(method_getName(methods[i]));
                if ([sel containsString:@"hannel"] || [sel containsString:@"videoId"] ||
                    [sel containsString:@"VideoId"]) {
                    CFLog(@"  channel/video method: %@", sel);
                }
            }
            free(methods);
        }
    }

    // アカウント・サインイン系
    if ([name containsString:@"AccountSwitch"] || [name containsString:@"AddAccount"] ||
        [name containsString:@"SignIn"]) {
        static NSMutableSet *_s4;
        if (!_s4) _s4 = [NSMutableSet set];
        if (![_s4 containsObject:name]) {
            [_s4 addObject:name];
            CFLog(@"[AccountVC] %@", name);
            unsigned int cnt = 0;
            Method *methods = class_copyMethodList([self class], &cnt);
            for (unsigned int i = 0; i < cnt; i++) {
                NSString *sel = NSStringFromSelector(method_getName(methods[i]));
                CFLog(@"  method: %@", sel);
            }
            free(methods);
        }
    }
}
%end

// ─── 調査②: ロゴ・ブランド画像名 ──────────────────────────────────────────────
//
// クラッシュリスクについて:
//   imageNamed: は非常に高頻度に呼ばれる。全呼び出しをフックするのではなく
//   名前フィルタを必ず先に評価（短絡評価）して NSLog/CFLog に落とすのは最小限。
//   ただし NSUserDefaults synchronize をここで行うと重くなるので CFLog 経由で
//   バックグラウンドキューに逃がす。
//
%hook UIImage
+ (UIImage *)imageNamed:(NSString *)name {
    if (name.length > 0 &&
        ([name hasPrefix:@"yt_"] || [name hasPrefix:@"youtube"] ||
         [name containsString:@"logo"]    || [name containsString:@"Logo"]    ||
         [name containsString:@"brand"]   || [name containsString:@"Brand"]   ||
         [name containsString:@"premium"] || [name containsString:@"Premium"])) {
        static NSMutableSet *_imgLog;
        if (!_imgLog) _imgLog = [NSMutableSet set];
        if (![_imgLog containsObject:name]) {
            [_imgLog addObject:name];
            CFLog(@"[imageNamed] %@", name);
        }
    }
    return %orig;
}

+ (UIImage *)imageNamed:(NSString *)name
               inBundle:(NSBundle *)bundle
compatibleWithTraitCollection:(UITraitCollection *)tc {
    if (name.length > 0 &&
        ([name hasPrefix:@"yt_"] || [name hasPrefix:@"youtube"] ||
         [name containsString:@"logo"]    || [name containsString:@"Logo"]    ||
         [name containsString:@"brand"]   || [name containsString:@"Brand"]   ||
         [name containsString:@"premium"] || [name containsString:@"Premium"])) {
        static NSMutableSet *_imgLog2;
        if (!_imgLog2) _imgLog2 = [NSMutableSet set];
        if (![_imgLog2 containsObject:name]) {
            [_imgLog2 addObject:name];
            CFLog(@"[imageNamed:bundle] %@ (bundle: %@)",
                  name, [bundle.bundlePath lastPathComponent]);
        }
    }
    return %orig;
}
%end

// ─── 調査③: 登録ボタンのクラス名 ─────────────────────────────────────────────
%hook UIButton
- (void)setTitle:(NSString *)title forState:(UIControlState)state {
    %orig;
    if ([title containsString:@"ubscri"] || [title containsString:@"登録"]) {
        static NSMutableSet *_btnLog;
        if (!_btnLog) _btnLog = [NSMutableSet set];
        NSString *key = [NSString stringWithFormat:@"%@|%@",
                         NSStringFromClass([self class]), title];
        if (![_btnLog containsObject:key]) {
            [_btnLog addObject:key];
            CFLog(@"[SubscribeBtn] class=%@, title=%@",
                  NSStringFromClass([self class]), title);
        }
    }
}
%end
