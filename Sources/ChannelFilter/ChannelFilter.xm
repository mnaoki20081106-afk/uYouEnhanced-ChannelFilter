//
//  ChannelFilter.xm — デバッグビルド（フィルター動作確認用）
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ btn.title=@"全コピー"; btn.enabled=YES; });
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return (NSInteger)self.logs.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) { cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"c"]; cell.textLabel.numberOfLines=0; cell.textLabel.font=[UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular]; cell.selectionStyle=UITableViewCellSelectionStyleNone; }
    cell.textLabel.text = self.logs[(NSUInteger)ip.row];
    return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip { [UIPasteboard generalPasteboard].string=self.logs[(NSUInteger)ip.row]; }
@end

// ─── ログビューアを開く ───────────────────────────────────────────────────────
static void cf_openLogViewer(void) {
    UIWindow *window = nil;
    if (@available(iOS 15, *))
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes)
            if ([sc isKindOfClass:[UIWindowScene class]])
                for (UIWindow *w in ((UIWindowScene *)sc).windows)
                    if (w.isKeyWindow) { window=w; break; }
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
    btn.layer.cornerRadius = 18; btn.clipsToBounds = YES;
    [btn addTarget:btn action:@selector(cf_tap) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:btn action:@selector(cf_pan:)];
    [btn addGestureRecognizer:pan];
    [w addSubview:btn];
    objc_setAssociatedObject(w, &kCFBtnKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
%hook UIButton
%new - (void)cf_tap { cf_openLogViewer(); }
%new - (void)cf_pan:(UIPanGestureRecognizer *)pan {
    UIView *v=pan.view; CGPoint t=[pan translationInView:v.superview]; CGRect b=v.superview.bounds;
    CGFloat hw=v.frame.size.width/2, hh=v.frame.size.height/2;
    v.center=CGPointMake(MAX(hw,MIN(b.size.width-hw,v.center.x+t.x)),MAX(hh+20,MIN(b.size.height-hh-20,v.center.y+t.y)));
    [pan setTranslation:CGPointZero inView:v.superview];
}
%end
%hook UIWindow
- (void)becomeKeyWindow { %orig; dispatch_async(dispatch_get_main_queue(),^{ cf_injectBtn(self); }); }
%end

// ─── 正規表現 ─────────────────────────────────────────────────────────────────
static NSRegularExpression *cf_regex(void) {
    static NSRegularExpression *r; static dispatch_once_t t;
    dispatch_once(&t,^{ r=[NSRegularExpression regularExpressionWithPattern:@"UC[A-Za-z0-9_-]{22}" options:0 error:nil]; });
    return r;
}
static NSString *cf_extractChannelId(NSData *data) {
    if (!data) return nil;
    NSString *raw=[[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (!raw) return nil;
    NSTextCheckingResult *m=[cf_regex() firstMatchInString:raw options:0 range:NSMakeRange(0,raw.length)];
    return m ? [raw substringWithRange:m.range] : nil;
}


// ─── addSectionsFromArray: ──────────────────────────────────────────────────
@interface YTInnerTubeCollectionViewController : UIViewController
@end

%hook YTInnerTubeCollectionViewController

// ── 呼び出し順調査 ──────────────────────────────────────────────────────────
- (void)setInitialSections:(id)sections {
    id s = (id)self;
    CFLog(@"[Hook] setInitialSections: vcClass=%@ type=%@",
          NSStringFromClass([s class]), NSStringFromClass([sections class]));
    %orig;
}
- (void)reloadSections:(id)sections {
    id s = (id)self;
    CFLog(@"[Hook] reloadSections: vcClass=%@ type=%@",
          NSStringFromClass([s class]), NSStringFromClass([sections class]));
    %orig;
}
- (void)updateSections:(id)sections {
    id s = (id)self;
    CFLog(@"[Hook] updateSections: vcClass=%@ type=%@",
          NSStringFromClass([s class]), NSStringFromClass([sections class]));
    %orig;
}
- (void)replaceSections:(id)sections {
    id s = (id)self;
    CFLog(@"[Hook] replaceSections: vcClass=%@ type=%@",
          NSStringFromClass([s class]), NSStringFromClass([sections class]));
    %orig;
}
- (void)setSectionsFromArray:(NSArray *)array {
    id s = (id)self;
    CFLog(@"[Hook] setSectionsFromArray: vcClass=%@ count=%lu",
          NSStringFromClass([s class]), (unsigned long)array.count);
    %orig;
}
- (void)reloadData {
    id s = (id)self;
    CFLog(@"[Hook] reloadData vcClass=%@", NSStringFromClass([s class]));
    %orig;
}

- (void)addSectionsFromArray:(NSArray *)array {
    id s = (id)self;
    NSString *vcClass = NSStringFromClass([s class]);
    CFWhitelistManager *wl = [CFWhitelistManager sharedManager];

    // 登録チャンネルタブの判定:
    // NSUserDefaultsにYTBrowseResponseViewControllerのviewDidAppearでフラグを立てる方式
    BOOL isSubscriptionFeed = [[NSUserDefaults standardUserDefaults]
        boolForKey:@"cf_is_subscription_tab"];

    BOOL shouldFilter = !isSubscriptionFeed && ![wl isEmpty];

    CFLog(@"[Feed] vcClass=%@ count=%lu isSub=%d shouldFilter=%d wlEmpty=%d",
          vcClass, (unsigned long)array.count, (int)isSubscriptionFeed,
          (int)shouldFilter, (int)[wl isEmpty]);

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
            NSString *channelId = cf_extractChannelId((NSData *)elemData);
            if (!channelId.length) {
                // channelIdが取れないアイテム（ショート等）の調査
                static NSMutableSet *_shortLog; if (!_shortLog) _shortLog=[NSMutableSet set];
                NSString *key = [NSString stringWithFormat:@"%lu-%lu", (unsigned long)si, (unsigned long)ii];
                if (![_shortLog containsObject:key]) {
                    [_shortLog addObject:key];
                    // elementDataのサイズとtitleを確認
                    NSUInteger dataLen = [(NSData *)elemData length];
                    NSString *rawStr = [[NSString alloc] initWithData:(NSData *)elemData
                                                             encoding:NSISOLatin1StringEncoding];
                    // "Reel"や"Short"や"reels"が含まれるか確認
                    BOOL isShort = rawStr && ([rawStr containsString:@"Reel"] ||
                                              [rawStr containsString:@"reel"] ||
                                              [rawStr containsString:@"Short"] ||
                                              [rawStr containsString:@"short"]);
                    // KEN_BURNSが含まれるかどうかも確認
                    NSString *rawCheck2 = [[NSString alloc] initWithData:(NSData *)elemData
                                                                encoding:NSISOLatin1StringEncoding];
                    BOOL hasKenBurns = rawCheck2 && [rawCheck2 containsString:@"KEN_BURNS"];
                    CFLog(@"[Short?] si=%lu ii=%lu dataLen=%lu isShort=%d kenBurns=%d",
                          (unsigned long)si, (unsigned long)ii,
                          (unsigned long)dataLen, (int)isShort, (int)hasKenBurns);
                }
                continue;
            }

            if (isSubscriptionFeed) {
                [channelIdsForSync addObject:channelId];
                CFLog(@"[Sync] collected %@", channelId);
            } else if (shouldFilter) {
                BOOL allowed = [wl isChannelAllowed:channelId];
                CFLog(@"[Filter] %@ allowed=%d", channelId, (int)allowed);
                if (!allowed) [itemsToRemove addIndex:ii];
            }
        }
        if (itemsToRemove.count > 0) {
            NSMutableArray *filteredItems = [items mutableCopy];
            [filteredItems removeObjectsAtIndexes:itemsToRemove];
            CFLog(@"[Remove] si=%lu removed=%lu remaining=%lu",
                  (unsigned long)si,
                  (unsigned long)itemsToRemove.count,
                  (unsigned long)filteredItems.count);
            // setContentsArray: でセクション内を書き換える
            if ([section respondsToSelector:@selector(setContentsArray:)]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [section performSelector:@selector(setContentsArray:) withObject:filteredItems];
                #pragma clang diagnostic pop
            }
            if (filteredItems.count == 0) [sectionsToRemove addIndex:si];
        }
    }

    NSMutableArray *filteredArray = [array mutableCopy];
    if (sectionsToRemove.count > 0) {
        [filteredArray removeObjectsAtIndexes:sectionsToRemove];
        CFLog(@"[Remove] sections removed=%lu remaining=%lu",
              (unsigned long)sectionsToRemove.count,
              (unsigned long)filteredArray.count);
    }

    BOOL didFilter = (sectionsToRemove.count > 0);

    if (!didFilter) {
        // フィルタリングなし: 元のまま渡す
        %orig;
    } else {
        // フィルタリングあり: 編集済み配列で %orig を呼んだ後、
        // setSections: で再セットしてDiffingをトリガーする
        %orig(filteredArray);

        id s = (id)self;
        if ([s respondsToSelector:@selector(sections)]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id currentSections = [s performSelector:@selector(sections)];
            #pragma clang diagnostic pop
            if (currentSections && [s respondsToSelector:@selector(setSections:)]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [s performSelector:@selector(setSections:) withObject:currentSections];
                #pragma clang diagnostic pop
                CFLog(@"[Render] setSections: triggered type=%@",
                      NSStringFromClass([currentSections class]));
            } else {
                CFLog(@"[Render] setSections: not available on %@",
                      NSStringFromClass([s class]));
            }
        }
    }

    if (isSubscriptionFeed && channelIdsForSync.count > 0) {
        [wl syncSubscribedChannelIDs:channelIdsForSync];
        CFLog(@"[Sync] ✅ synced %lu channelIds to whitelist", (unsigned long)channelIdsForSync.count);
    }
}

// setSections: をフックしてフィルタリングする（addSectionsFromArray: が効かない場合の代替）
// YouTubeはaddSectionsFromArray: でバッファに追加した後、
// setSections: で全量をUIに反映している可能性がある
- (void)setSections:(id)sections {
    CFWhitelistManager *wl = [CFWhitelistManager sharedManager];
    BOOL isSubscriptionFeed = [[NSUserDefaults standardUserDefaults] boolForKey:@"cf_is_subscription_tab"];
    BOOL shouldFilter = !isSubscriptionFeed && ![wl isEmpty];

    if (!shouldFilter || !sections) {
        %orig;
        return;
    }

    // sections が NSArray かどうか確認
    if (![sections isKindOfClass:[NSArray class]]) {
        CFLog(@"[setSections] unknown type=%@, passing through", NSStringFromClass([sections class]));
        %orig;
        return;
    }

    NSArray *sectionsArray = (NSArray *)sections;
    NSMutableIndexSet *sectionsToRemove = [NSMutableIndexSet indexSet];

    for (NSUInteger si = 0; si < sectionsArray.count; si++) {
        id section = sectionsArray[si];
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
            if (!channelId.length) continue;

            BOOL allowed = [wl isChannelAllowed:channelId];
            if (!allowed) [itemsToRemove addIndex:ii];
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

    if (sectionsToRemove.count > 0) {
        NSMutableArray *filteredSections = [sectionsArray mutableCopy];
        [filteredSections removeObjectsAtIndexes:sectionsToRemove];
        CFLog(@"[setSections] ✅ removed %lu sections, passing %lu",
              (unsigned long)sectionsToRemove.count,
              (unsigned long)filteredSections.count);
        %orig(filteredSections);
    } else {
        %orig;
    }
}
%end

// ─── アカウント追加ブロック ───────────────────────────────────────────────────
@interface YTInlineSignInViewController : UIViewController
@end
static void cf_showAlert(NSString *title, NSString *msg) {
    dispatch_async(dispatch_get_main_queue(),^{
        UIAlertController *a=[UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        UIWindow *w=nil;
        if (@available(iOS 15,*))
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes)
                if ([sc isKindOfClass:[UIWindowScene class]])
                    for (UIWindow *win in ((UIWindowScene *)sc).windows)
                        if (win.isKeyWindow){w=win;break;}
        if (!w) w=[UIApplication sharedApplication].keyWindow;
        UIViewController *root=w.rootViewController;
        while (root.presentedViewController) root=root.presentedViewController;
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
// ─── Gemini提案: setNavigationEndpoint / setBrowseEndpoint をフック ──────────
// YTBrowseViewController / YTAppCollectionViewController に渡される
// NavigationEndpoint から browseId を取得して FEsubscriptions を判定
%hook YTBrowseViewController
- (void)setNavigationEndpoint:(id)endpoint {
    %orig;
    if (!endpoint) return;
    // browseEndpoint から browseId を取得
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
    CFLog(@"[Endpoint] YTBrowseVC setNavigationEndpoint browseId=%@", browseId ?: @"nil");
    if (browseId.length > 0) {
        if ([browseId isEqualToString:@"FEsubscriptions"]) {
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"cf_is_subscription_tab"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            CFLog(@"[Endpoint] -> FLAG ON (FEsubscriptions)");
        } else if ([browseId hasPrefix:@"FE"]) {
            // 他のタブ(ホーム・探索等)ではフラグをOFF
            [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"cf_is_subscription_tab"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            CFLog(@"[Endpoint] -> FLAG OFF (%@)", browseId);
        }
        // UC...等のチャンネルページではフラグを変更しない
    }
}
// setBrowseEndpoint: も試す
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
    CFLog(@"[Endpoint] YTBrowseVC setBrowseEndpoint browseId=%@", browseId ?: @"nil");
    if ([browseId isEqualToString:@"FEsubscriptions"]) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"cf_is_subscription_tab"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        CFLog(@"[Endpoint] ✅ FEsubscriptions detected");
    }
}
%end

// YTAppCollectionViewControllerにも同じフックを適用
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
    CFLog(@"[Endpoint] YTAppCollectionVC setNavigationEndpoint browseId=%@", browseId ?: @"nil");
    if (browseId.length > 0) {
        if ([browseId isEqualToString:@"FEsubscriptions"]) {
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"cf_is_subscription_tab"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            CFLog(@"[Endpoint] -> FLAG ON (FEsubscriptions)");
        } else if ([browseId hasPrefix:@"FE"]) {
            [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"cf_is_subscription_tab"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            CFLog(@"[Endpoint] -> FLAG OFF (%@)", browseId);
        }
    }
}
%end

// ─── 登録ボタン非表示 ────────────────────────────────────────────────────────
// Gemini提案: レスポンダチェーン探索は重いので
// setAccessibilityIdentifier: をフックして accId だけで判定する軽量方式
// + YTHeaderViewController から直接ボタンを隠す方式の二本立て

%hook YTQTMButton
// accId がセットされた瞬間に判定 → レスポンダチェーン探索ゼロ
- (void)setAccessibilityIdentifier:(NSString *)identifier {
    %orig;
    if ([identifier isEqualToString:@"id.ui.title.tab.button"]) {
        self.hidden = YES;
        self.alpha = 0;
        CFLog(@"[SubBtn] ✅ hidden by accId=%@", identifier);
    }
}
// ウィンドウ移動時も念のため
- (void)willMoveToWindow:(UIWindow *)newWindow {
    %orig;
    if (!newWindow) return;
    if ([self.accessibilityIdentifier isEqualToString:@"id.ui.title.tab.button"]) {
        self.hidden = YES;
        self.alpha = 0;
    }
}
%end

// YTHeaderViewController をフックして子ボタンを隠す（二重対策）
@interface YTHeaderViewController : UIViewController
@end
%hook YTHeaderViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    id s = (id)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        // view階層からYTQTMButtonを探して accId で判定
        NSMutableArray *stack = [NSMutableArray arrayWithObject:[(UIViewController *)s view]];
        while (stack.count > 0) {
            UIView *v = stack.lastObject;
            [stack removeLastObject];
            if ([NSStringFromClass([v class]) isEqualToString:@"YTQTMButton"]) {
                if ([v.accessibilityIdentifier isEqualToString:@"id.ui.title.tab.button"]) {
                    v.hidden = YES;
                    v.alpha = 0;
                    CFLog(@"[SubBtn] ✅ hidden via YTHeaderViewController scan");
                }
            }
            for (UIView *sub in v.subviews) [stack addObject:sub];
        }
    });
}
%end

// ─── STARDYロゴ ──────────────────────────────────────────────────────────────
static UIImage *cf_stardyLogo(BOOL dark) {
    static NSString *dp, *lp; static dispatch_once_t t;
    dispatch_once(&t,^{
        NSString *bp=[[NSBundle mainBundle] pathForResource:@"uYouPlus" ofType:@"bundle"];
        NSBundle *b=bp?[NSBundle bundleWithPath:bp]:nil;
        dp=[b pathForResource:@"PremiumLogo_dark" ofType:@"png"];
        lp=[b pathForResource:@"PremiumLogo_lite" ofType:@"png"];
    });
    NSString *p=dark?dp:lp; return p?[UIImage imageWithContentsOfFile:p]:nil;
}
%hook UIImage
+ (UIImage *)imageNamed:(NSString *)name inBundle:(NSBundle *)bundle compatibleWithTraitCollection:(UITraitCollection *)tc {
    if ([name isEqualToString:@"youtube_logo_dark_cairo"]||[name isEqualToString:@"youtube_premium_logo_dark_cairo"]) { UIImage *i=cf_stardyLogo(YES); if(i) return i; }
    if ([name isEqualToString:@"youtube_premium_badge_light"]||[name isEqualToString:@"youtube_premium_standalone_cairo"]) { UIImage *i=cf_stardyLogo(NO); if(i) return i; }
    return %orig;
}
+ (UIImage *)imageNamed:(NSString *)name {
    if ([name isEqualToString:@"youtube_logo_dark_cairo"]||[name isEqualToString:@"youtube_premium_logo_dark_cairo"]) { UIImage *i=cf_stardyLogo(YES); if(i) return i; }
    if ([name isEqualToString:@"youtube_premium_badge_light"]||[name isEqualToString:@"youtube_premium_standalone_cairo"]) { UIImage *i=cf_stardyLogo(NO); if(i) return i; }
    return %orig;
}
%end
