//
//  ChannelWhitelist.m
//  uYouEnhanced - ChannelFilter
//

#import "ChannelWhitelist.h"

static NSString *const kWhitelistStorageKey = @"channelFilter_whitelistChannelIDs";

@interface CFWhitelistManager ()
@property (nonatomic, strong) NSMutableSet<NSString *> *channelIDSet;
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
        _channelIDSet = saved ? [NSMutableSet setWithArray:saved] : [NSMutableSet set];
    }
    return self;
}

- (void)syncSubscribedChannelIDs:(NSArray<NSString *> *)channelIDs {
    if (!channelIDs || channelIDs.count == 0) return;
    // 登録チャンネルフィードはページ単位（continuation）で届くため、
    // 置き換えると直近ページのチャンネルだけが残ってしまう。追加マージにする。
    @synchronized (self) {
        NSUInteger before = self.channelIDSet.count;
        [self.channelIDSet addObjectsFromArray:channelIDs];
        if (self.channelIDSet.count == before) return;
        [[NSUserDefaults standardUserDefaults] setObject:[self.channelIDSet allObjects]
                                                  forKey:kWhitelistStorageKey];
    }
    NSLog(@"[ChannelFilter] Whitelist synced: %lu channels", (unsigned long)self.channelIDSet.count);
}

- (BOOL)isChannelAllowed:(NSString *)channelID {
    if (!channelID || channelID.length == 0) return NO;
    NSString *normalized = [channelID stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    @synchronized (self) { return [self.channelIDSet containsObject:normalized]; }
}

- (BOOL)isEmpty {
    @synchronized (self) { return self.channelIDSet.count == 0; }
}

- (NSArray<NSString *> *)allowedChannelIDs {
    @synchronized (self) { return [self.channelIDSet allObjects]; }
}

@end
