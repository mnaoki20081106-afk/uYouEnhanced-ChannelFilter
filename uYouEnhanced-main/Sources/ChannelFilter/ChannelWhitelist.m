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
    [self.channelIDSet removeAllObjects];
    [self.channelIDSet addObjectsFromArray:channelIDs];
    [[NSUserDefaults standardUserDefaults] setObject:channelIDs forKey:kWhitelistStorageKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSLog(@"[ChannelFilter] Whitelist synced: %lu channels", (unsigned long)self.channelIDSet.count);
}

- (BOOL)isChannelAllowed:(NSString *)channelID {
    if (!channelID || channelID.length == 0) return NO;
    NSString *normalized = [channelID stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return [self.channelIDSet containsObject:normalized];
}

- (BOOL)isEmpty {
    return self.channelIDSet.count == 0;
}

- (NSArray<NSString *> *)allowedChannelIDs {
    return [self.channelIDSet allObjects];
}

@end
