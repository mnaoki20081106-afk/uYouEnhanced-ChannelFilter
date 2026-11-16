#import <Foundation/Foundation.h>

@interface ChannelManager : NSObject

+ (instancetype)sharedInstance;
- (NSArray<NSString *> *)blockedChannels;
- (void)addBlockedChannel:(NSString *)channelName;
- (void)removeBlockedChannel:(NSString *)channelName;
- (BOOL)isChannelBlocked:(NSString *)channelName;
- (void)setBlockedChannels:(NSArray<NSString *> *)channels;

// [uYouEnhanced-ChannelFilter] 登録チャンネル名（許可リスト）
- (void)addSubscribedChannel:(NSString *)channelName;
- (BOOL)isChannelSubscribed:(NSString *)channelName;
- (BOOL)hasSubscribedChannels;
- (NSArray<NSString *> *)subscribedChannels;

@end
