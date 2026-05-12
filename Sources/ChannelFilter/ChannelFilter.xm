//
//  ChannelFilter.xm
//  デバッグビルド: アプリ内ログビューアでクラス名・メソッド名を確認する
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "ChannelWhitelist.h"

// ─── インメモリログバッファ ────────────────────────────────────────────────────
static NSMutableArray *CFLogs;
static void CFLog(NSString *format, ...) {
    if (!CFLogs) CFLogs = [NSMutableArray array];
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[CF] %@", msg);
    dispatch_async(dispatch_get_main_queue(), ^{
        [CFLogs addObject:msg];
        if (CFLogs.count > 500) [CFLogs removeObjectAtIndex:0];
        // NSUserDefaultsにも保存（アプリ再起動後も確認できる）
        [[NSUserDefaults standardUserDefaults] setObject:CFLogs forKey:@"cf_debug_logs"];
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
    self.title = @"ChannelFilter Debug Log";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // 閉じるボタン
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"閉じる" style:UIBarButtonItemStylePlain
        target:self action:@selector(dismiss)];

    // クリアボタン
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"クリア" style:UIBarButtonItemStylePlain
        target:self action:@selector(clearLogs)];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                                  style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 44;
    [self.view addSubview:self.tableView];
    [self reloadLogs];
}
- (void)reloadLogs {
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:@"cf_debug_logs"];
    self.logs = saved ? [saved reverseObjectEnumerator].allObjects : @[];
    [self.tableView reloadData];
}
- (void)dismiss { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)clearLogs {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"cf_debug_logs"];
    CFLogs = [NSMutableArray array];
    [self reloadLogs];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.logs.count;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"log"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"log"];
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.textLabel.text = self.logs[ip.row];
    return cell;
}
// タップでコピー
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [UIPasteboard generalPasteboard].string = self.logs[ip.row];
}
@end

// ─── 設定画面からログビューアを開く ──────────────────────────────────────────
%hook YTSettingsViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 設定画面右上にデバッグボタンを追加
        UIBarButtonItem *debugBtn = [[UIBarButtonItem alloc]
            initWithTitle:@"CF Debug"
            style:UIBarButtonItemStylePlain
            target:self
            action:@selector(cf_showDebugLog)];
        self.navigationItem.rightBarButtonItem = debugBtn;
    });
}
%new
- (void)cf_showDebugLog {
    CFLogViewController *vc = [[CFLogViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}
%end

// ─── 調査①: タブ・ナビゲーション系のクラス名 ────────────────────────────────
%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSString *name = NSStringFromClass([self class]);
    if ([name containsString:@"Pivot"] || [name containsString:@"TabBar"]) {
        CFLog(@"TabVC: %@", name);
    }
    if ([name containsString:@"Subscript"] || [name containsString:@"Channel"] ||
        [name containsString:@"Feed"]) {
        CFLog(@"FeedVC: %@", name);
        // メソッドの中でsubscription/channelId系を探す
        unsigned int count = 0;
        Method *methods = class_copyMethodList([self class], &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString *sel = NSStringFromSelector(method_getName(methods[i]));
            if ([sel containsString:@"ubscri"] || [sel containsString:@"channel"] ||
                [sel containsString:@"Channel"]) {
                CFLog(@"  method: %@", sel);
            }
        }
        free(methods);
    }
    if ([name containsString:@"Watch"] || [name containsString:@"Player"]) {
        static NSMutableSet *logged;
        if (!logged) logged = [NSMutableSet set];
        if (![logged containsObject:name]) {
            [logged addObject:name];
            CFLog(@"WatchVC: %@", name);
            unsigned int count = 0;
            Method *methods = class_copyMethodList([self class], &count);
            for (unsigned int i = 0; i < count; i++) {
                NSString *sel = NSStringFromSelector(method_getName(methods[i]));
                if ([sel containsString:@"channel"] || [sel containsString:@"Channel"]) {
                    CFLog(@"  channel method: %@", sel);
                }
            }
            free(methods);
        }
    }
    if ([name containsString:@"AccountSwitch"] || [name containsString:@"AddAccount"] ||
        [name containsString:@"SignIn"]) {
        CFLog(@"AccountVC: %@", name);
        CFLog(@"  dumping methods...");
        unsigned int count = 0;
        Method *methods = class_copyMethodList([self class], &count);
        for (unsigned int i = 0; i < count; i++) {
            CFLog(@"  %@", NSStringFromSelector(method_getName(methods[i])));
        }
        free(methods);
    }
}
%end

// ─── 調査②: ロゴ画像名 ────────────────────────────────────────────────────────
%hook UIImage
+ (UIImage *)imageNamed:(NSString *)name {
    if ([name containsString:@"logo"] || [name containsString:@"Logo"] ||
        [name containsString:@"brand"] || [name containsString:@"Brand"] ||
        [name containsString:@"premium"] || [name containsString:@"Premium"] ||
        [name containsString:@"yt_"] || [name containsString:@"youtube"]) {
        CFLog(@"imageNamed: %@", name);
    }
    return %orig;
}
+ (UIImage *)imageNamed:(NSString *)name inBundle:(NSBundle *)bundle
    compatibleWithTraitCollection:(UITraitCollection *)traitCollection {
    if ([name containsString:@"logo"] || [name containsString:@"Logo"] ||
        [name containsString:@"brand"] || [name containsString:@"Brand"] ||
        [name containsString:@"premium"] || [name containsString:@"Premium"] ||
        [name containsString:@"yt_"] || [name containsString:@"youtube"]) {
        CFLog(@"imageNamed:bundle: %@", name);
    }
    return %orig;
}
%end

// ─── 調査③: 登録ボタンのクラス名 ─────────────────────────────────────────────
%hook UIButton
- (void)setTitle:(NSString *)title forState:(UIControlState)state {
    %orig;
    if ([title containsString:@"ubscri"] || [title containsString:@"登録"]) {
        CFLog(@"SubscribeBtn class: %@, title: %@",
              NSStringFromClass([self class]), title);
    }
}
%end
