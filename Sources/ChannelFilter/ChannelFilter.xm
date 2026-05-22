//
//  ChannelFilter.xm — デバッグビルド v3
//
//  【根本原因と修正】
//  addSectionsFromArray: は非同期で遅れて呼ばれるため、
//  ホームに戻った後も登録タブのフィード読み込みが続いて
//  NSUserDefaults の isSub=1 フラグが残ったまま shouldFilter=0 になっていた。
//
//  修正: フラグをNSUserDefaultsではなく、VCインスタンスに
//  objc_setAssociatedObject で紐付ける。
//  setNavigationEndpoint: でそのVCインスタンスにフラグを付け、
//  addSectionsFromArray: では self（=YTAppCollectionViewController）の
//  フラグを見る。これでVCをまたいだフラグ汚染がなくなる。
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

// ─── ログビューアを開く ───────────────────────────────────────────────────────
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
    CGFloat hw = v.frame.size.width / 2, hh = v.frame.size.height / 2;
    v.center = CGPointMake(
        MAX(hw, MIN(b.size.width - hw, v.center.x + t.x)),
        MAX(hh + 20, MIN(b.size.height - hh - 20, v.center.y + t.y))
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

// ─── 正規表現 ─────────────────────────────────────────────────────────────────
static NSRegularExpression *cf_regex(void) {
    static NSRegularExpression *r; static dispatch_once_t t;
    dispatch_once(&t, ^{
        r = [NSRegularExpression regularExpressionWithPattern:@"UC[A-Za-z0-9_-]{22}"
                                                      options:0 error:nil];
    });
    return r;
}
static NSString *cf_extractChannelId(NSData *data) {
    if (!data) return nil;
    NSString *raw = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (!raw) return nil;
    NSTextCheckingResult *m = [cf_regex() firstMatchInString:raw options:0
                                                       range:NSMakeRange(0, raw.length)];
    return m ? [raw substringWithRange:m.range] : nil;
}

// ─── VCインスタンスへのフラグ紐付け用キー ────────────────────────────────────
// NSUserDefaultsではなくVCインスタンスに直接フラグを持たせる。
// これによりホームに戻った後の遅延フィード読み込みでフラグが汚染されない。
static const char kCFIsSubFeedKey = 0;

// ─── 前方宣言 ─────────────────────────────────────────────────────────────────
@interface YTAppCollectionViewController : UIViewController
@end

@interface YTInnerTubeCollectionViewController : UIViewController
@end

// ─── YTBrowseViewController: フラグをVCインスタンスに紐付け ─────────────────
// setNavigationEndpoint: が呼ばれた時、そのVCが登録タブかどうかを
// VCインスタンス自身に objc_setAssociatedObject で記録する。
// 同時に NSUserDefaults も更新（addSectionsFromArray の呼び出し元VCが
// YTInnerTubeCollectionViewController の場合の fallback 用）。

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
    CFLog(@"[Endpoint] YTBrowseVC setNavigationEndpoint browseId=%@", browseId);

    id s = (id)self;
    if ([browseId isEqualToString:@"FEsubscriptions"]) {
        objc_setAssociatedObject(s, &kCFIsSubFeedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"cf_is_subscription_tab"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        CFLog(@"[Endpoint] -> FLAG ON this=%p", s);
    } else if ([browseId hasPrefix:@"FE"]) {
        objc_setAssociatedObject(s, &kCFIsSubFeedKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"cf_is_subscription_tab"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        CFLog(@"[Endpoint] -> FLAG OFF (%@) this=%p", browseId, s);
    }
    // UC...チャンネルページはフラグ変更しない
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
    id s = (id)self;
    if ([browseId isEqualToString:@"FEsubscriptions"]) {
        objc_setAssociatedObject(s, &kCFIsSubFeedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"cf_is_subscription_tab"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        CFLog(@"[Endpoint] setBrowseEndpoint FLAG ON this=%p", s);
    } else if ([browseId hasPrefix:@"FE"]) {
        objc_setAssociatedObject(s, &kCFIsSubFeedKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"cf_is_subscription_tab"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        CFLog(@"[Endpoint] setBrowseEndpoint FLAG OFF (%@) this=%p", browseId, s);
    }
}
%end

// YTAppCollectionViewController にも同じフックを適用
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
    id s = (id)self;
    CFLog(@"[Endpoint] YTAppCollectionVC setNavigationEndpoint browseId=%@ this=%p", browseId, s);
    if ([browseId isEqualToString:@"FEsubscriptions"]) {
        objc_setAssociatedObject(s, &kCFIsSubFeedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"cf_is_subscription_tab"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        CFLog(@"[Endpoint] -> FLAG ON this=%p", s);
    } else if ([browseId hasPrefix:@"FE"]) {
        objc_setAssociatedObject(s, &kCFIsSubFeedKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"cf_is_subscription_tab"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        CFLog(@"[Endpoint] -> FLAG OFF (%@) this=%p", browseId, s);
    }
}
%end

// ─── addSectionsFromArray: ───────────────────────────────────────────────────
%hook YTInnerTubeCollectionViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UIWindow *w = self.view.window;
    if (w) cf_injectBtn(w);
}

- (void)addSectionsFromArray:(NSArray *)array {
    id s = (id)self;
    CFWhitelistManager *wl = [CFWhitelistManager sharedManager];

    // ① まず self (YTInnerTubeCollectionViewController) のフラグを確認
    // ② なければ親VCチェーンを辿って YTAppCollectionViewController or YTBrowseViewController のフラグを確認
    // ③ それもなければ NSUserDefaults にフォールバック
    BOOL isSubscriptionFeed = NO;
    NSString *flagSource = @"default(NO)";

    NSNumber *selfFlag = objc_getAssociatedObject(s, &kCFIsSubFeedKey);
    if (selfFlag) {
        isSubscriptionFeed = selfFlag.boolValue;
        flagSource = [NSString stringWithFormat:@"self(%p)", s];
    } else {
        // 親VCを辿る
        UIResponder *r = self;
        while ((r = r.nextResponder)) {
            if ([r isKindOfClass:[UIViewController class]]) {
                NSNumber *parentFlag = objc_getAssociatedObject(r, &kCFIsSubFeedKey);
                if (parentFlag) {
                    isSubscriptionFeed = parentFlag.boolValue;
                    flagSource = [NSString stringWithFormat:@"parentVC=%@(%p)",
                                  NSStringFromClass([(id)r class]), r];
                    break;
                }
            }
        }
        // 親にもなければ NSUserDefaults
        if (!selfFlag) {
            isSubscriptionFeed = [[NSUserDefaults standardUserDefaults]
                boolForKey:@"cf_is_subscription_tab"];
            flagSource = @"NSUserDefaults";
        }
    }

    BOOL shouldFilter = !isSubscriptionFeed && ![wl isEmpty];
    CFLog(@"[Feed] vcClass=%@ count=%lu isSub=%d shouldFilter=%d wlEmpty=%d src=%@",
          NSStringFromClass([s class]), (unsigned long)array.count,
          (int)isSubscriptionFeed, (int)shouldFilter, (int)[wl isEmpty], flagSource);

    NSMutableArray *channelIdsForSync = isSubscriptionFeed ? [NSMutableArray array] : nil;
    NSMutableIndexSet *sectionsToRemove = [NSMutableIndexSet indexSet];

    for (NSUInteger si = 0; si < array.count; si++) {
        id section = array[si];
        NSString *secClass = NSStringFromClass([section class]);
        if ([secClass containsString:@"FilterChip"] || [secClass containsString:@"ChipBar"]) continue;
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

            NSUInteger dataLen = [(NSData *)elemData length];

            // ショート動画判定: 1337バイト固定はchannelIdなし
            if (dataLen == 1337) {
                if (shouldFilter) [itemsToRemove addIndex:ii];
                continue;
            }

            // KEN_BURNS は通常動画にも含まれるので channelId で判断する
            NSString *channelId = cf_extractChannelId((NSData *)elemData);
            if (!channelId.length) {
                // channelIdが取れない = 本当のショートまたは広告など
                static NSMutableSet *_noIdLog;
                if (!_noIdLog) _noIdLog = [NSMutableSet set];
                NSString *key = [NSString stringWithFormat:@"%lu-%lu", (unsigned long)si, (unsigned long)ii];
                if (![_noIdLog containsObject:key]) {
                    [_noIdLog addObject:key];
                    CFLog(@"[NoId] si=%lu ii=%lu dataLen=%lu -> skip", (unsigned long)si, (unsigned long)ii, (unsigned long)dataLen);
                }
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

        if (itemsToRemove.count > 0) {
            NSMutableArray *mut = [items mutableCopy];
            [mut removeObjectsAtIndexes:itemsToRemove];
            if ([section respondsToSelector:@selector(setContentsArray:)]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [section performSelector:@selector(setContentsArray:) withObject:mut];
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

    if (isSubscriptionFeed && channelIdsForSync.count > 0) {
        [wl syncSubscribedChannelIDs:channelIdsForSync];
        CFLog(@"[Sync] ✅ synced %lu ids", (unsigned long)channelIdsForSync.count);
    }
}
%end

// ─── アカウント追加ブロック ───────────────────────────────────────────────────
@interface YTInlineSignInViewController : UIViewController
@end

static void cf_showAlert(NSString *title, NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                                    message:msg
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        UIWindow *w = nil;
        if (@available(iOS 15, *))
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes)
                if ([sc isKindOfClass:[UIWindowScene class]])
                    for (UIWindow *win in ((UIWindowScene *)sc).windows)
                        if (win.isKeyWindow) { w = win; break; }
        if (!w) w = [UIApplication sharedApplication].keyWindow;
        UIViewController *root = w.rootViewController;
        while (root.presentedViewController) root = root.presentedViewController;
        [root presentViewController:a animated:YES completion:nil];
    });
}

%hook YTInlineSignInViewController
- (void)didTapShowAddAccount {
    cf_showAlert(@"アカウント追加不可", @"このビルドでは複数アカウントの追加は許可されていません。");
}
%end

// ─── 登録ボタン非表示 ────────────────────────────────────────────────────────
@interface YTQTMButton : UIButton
@end

%hook YTQTMButton
- (void)setTitle:(NSString *)title forState:(UIControlState)state {
    %orig;
    NSString *t = [self titleForState:UIControlStateNormal];
    if (!t.length) return;
    NSArray *tabTitles = @[@"ホーム", @"ショート", @"登録チャンネル", @"マイページ", @"uYou", @"YouTube",
                           @"Home", @"Shorts", @"Subscriptions", @"You", @"Library", @"フィードバックを送信"];
    if ([tabTitles containsObject:t]) return;
    NSString *accId = self.accessibilityIdentifier ?: @"nil";
    UIViewController *vc = nil;
    UIResponder *r = self;
    while ((r = r.nextResponder))
        if ([r isKindOfClass:[UIViewController class]]) { vc = (UIViewController *)r; break; }
    NSString *vcName = NSStringFromClass([vc class]);
    CFLog(@"[SubBtn] title='%@' accId='%@' parentVC=%@", t, accId, vcName);
    if ([accId isEqualToString:@"id.ui.title.tab.button"]) {
        self.hidden = YES; self.alpha = 0;
        CFLog(@"[SubBtn] ✅ hidden by accId");
    } else if ([vcName containsString:@"Channel"] || [vcName containsString:@"Browse"] ||
               [vcName containsString:@"Profile"] || [vcName containsString:@"Watch"]) {
        self.hidden = YES; self.alpha = 0;
        CFLog(@"[SubBtn] ✅ hidden by vcName");
    }
}
- (void)willMoveToWindow:(UIWindow *)newWindow {
    %orig;
    if (!newWindow) return;
    NSString *t = [self titleForState:UIControlStateNormal];
    if (!t.length) return;
    NSArray *tabTitles = @[@"ホーム", @"ショート", @"登録チャンネル", @"マイページ", @"uYou", @"YouTube",
                           @"Home", @"Shorts", @"Subscriptions", @"You", @"Library", @"フィードバックを送信"];
    if ([tabTitles containsObject:t]) return;
    NSString *accId = self.accessibilityIdentifier ?: @"";
    if ([accId isEqualToString:@"id.ui.title.tab.button"]) {
        self.hidden = YES; self.alpha = 0;
    } else {
        UIViewController *vc = nil;
        UIResponder *r = self;
        while ((r = r.nextResponder))
            if ([r isKindOfClass:[UIViewController class]]) { vc = (UIViewController *)r; break; }
        NSString *vcName = NSStringFromClass([vc class]);
        if ([vcName containsString:@"Channel"] || [vcName containsString:@"Browse"] ||
            [vcName containsString:@"Profile"] || [vcName containsString:@"Watch"]) {
            self.hidden = YES; self.alpha = 0;
        }
    }
}
%end

// ─── STARDYロゴ ──────────────────────────────────────────────────────────────
static UIImage *cf_stardyLogo(BOOL dark) {
    static NSString *dp, *lp; static dispatch_once_t t;
    dispatch_once(&t, ^{
        NSString *bp = [[NSBundle mainBundle] pathForResource:@"uYouPlus" ofType:@"bundle"];
        NSBundle *b = bp ? [NSBundle bundleWithPath:bp] : nil;
        dp = [b pathForResource:@"PremiumLogo_dark" ofType:@"png"];
        lp = [b pathForResource:@"PremiumLogo_lite" ofType:@"png"];
    });
    NSString *p = dark ? dp : lp;
    return p ? [UIImage imageWithContentsOfFile:p] : nil;
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
    return %orig;
}
%end
