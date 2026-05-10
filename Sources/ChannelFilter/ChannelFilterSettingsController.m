//
//  ChannelFilterSettingsController.m
//  uYouEnhanced - ChannelFilter
//
//  設定UIの役割：ホワイトリストの同期状態確認のみ。
//  制限のON/OFFスイッチは一切持たない。
//

#import "ChannelFilterSettingsController.h"
#import "ChannelWhitelist.h"

typedef NS_ENUM(NSInteger, CFSection) {
    CFSectionStatus = 0,    // 同期状態の説明
    CFSectionWhitelist,     // チャンネルID一覧
    CFSectionCount
};

@interface ChannelFilterSettingsController ()
@property (nonatomic, strong) NSArray<NSString *> *channelIDs;
@end

@implementation ChannelFilterSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"チャンネルフィルタ（常時ON）";
    [self reload];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self reload];
}

- (void)reload {
    self.channelIDs = [[CFWhitelistManager sharedManager] allowedChannelIDs];
    [self.tableView reloadData];
}

// ─── DataSource ───────────────────────────────────────────────────────────────

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return CFSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == CFSectionStatus)    return 1;
    if (section == CFSectionWhitelist) return MAX(1, (NSInteger)self.channelIDs.count);
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == CFSectionStatus)    return @"フィルタ状態";
    if (section == CFSectionWhitelist) return @"許可チャンネル一覧";
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == CFSectionStatus) {
        if ([[CFWhitelistManager sharedManager] isEmpty]) {
            return @"⚠️ ホワイトリストが空のため制限は一時停止中です。\nYouTube公式アプリでチャンネルを登録し、このアプリの「登録チャンネル」タブを開いてください。自動でリストが更新されます。";
        } else {
            return @"✅ 制限が有効です。登録チャンネル以外の動画・タブへのアクセスはブロックされます。";
        }
    }
    if (section == CFSectionWhitelist) {
        return @"チャンネルIDはYouTube公式アプリで登録後、「登録チャンネル」タブを開くと自動的に追加されます。";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    if (indexPath.section == CFSectionStatus) {
        BOOL empty = [[CFWhitelistManager sharedManager] isEmpty];
        cell.textLabel.text = empty ? @"一時停止中（リスト未同期）" : @"制限中";
        cell.textLabel.textColor = empty ? [UIColor systemOrangeColor] : [UIColor systemGreenColor];
        cell.imageView.image = [UIImage systemImageNamed:empty ? @"exclamationmark.triangle.fill" : @"lock.shield.fill"];
        cell.imageView.tintColor = cell.textLabel.textColor;
    }

    if (indexPath.section == CFSectionWhitelist) {
        if (self.channelIDs.count == 0) {
            cell.textLabel.text = @"（まだ同期されていません）";
            cell.textLabel.textColor = [UIColor secondaryLabelColor];
        } else {
            cell.textLabel.text = self.channelIDs[indexPath.row];
            cell.imageView.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
            cell.imageView.tintColor = [UIColor systemGreenColor];
        }
    }

    return cell;
}

@end
