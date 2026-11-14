//
//  ChannelWhitelist.m
//  uYouEnhanced - ChannelFilter
//

#import "ChannelWhitelist.h"

static NSString *const kWhitelistStorageKey = @"channelFilter_whitelistChannelIDs";

// channelIDSet は不変の NSSet を丸ごと差し替える方式にしている。
// 判定（isChannelAllowed:）はフィード描画のたびに大量に呼ばれるため、
// ロックなしでどのスレッドからでも安全に読めるようにするため。
@interface CFWhitelistManager ()
@property (atomic, copy) NSSet<NSString *> *channelIDSet;
@property (atomic, readwrite) NSUInteger generation;
@end

@implementation CFWhitelistManager

+ (instancetype)sharedManager {
    static CFWhitelistManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[CFWhitelistManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kWhitelistStorageKey];
        _channelIDSet = saved ? [NSSet setWithArray:saved] : [NSSet set];
    }
    return self;
}

- (void)syncSubscribedChannelIDs:(NSArray<NSString *> *)channelIDs {
    if (!channelIDs || channelIDs.count == 0) return;
    NSSet<NSString *> *newSet = [NSSet setWithArray:channelIDs];
    // 中身が同じなら何もしない（ディスク書き込みとキャッシュ無効化を避ける）
    if ([newSet isEqualToSet:self.channelIDSet]) return;
    self.channelIDSet = newSet;
    self.generation = self.generation + 1;
    // synchronize は呼ばない（メインスレッドを止める同期書き込みになるため。
    // NSUserDefaults は自動で保存される）
    [[NSUserDefaults standardUserDefaults] setObject:[newSet allObjects]
                                              forKey:kWhitelistStorageKey];
    NSLog(@"[ChannelFilter] Whitelist synced: %lu channels", (unsigned long)newSet.count);
}

- (BOOL)isChannelAllowed:(NSString *)channelID {
    if (!channelID || channelID.length == 0) return NO;
    NSSet<NSString *> *set = self.channelIDSet;
    if ([set containsObject:channelID]) return YES;
    // 前後に空白が付いている場合だけ、取り除いて再確認する
    NSString *normalized = [channelID stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (normalized.length == channelID.length) return NO;
    return [set containsObject:normalized];
}

- (BOOL)isEmpty {
    return self.channelIDSet.count == 0;
}

- (NSArray<NSString *> *)allowedChannelIDs {
    return [self.channelIDSet allObjects];
}

@end
