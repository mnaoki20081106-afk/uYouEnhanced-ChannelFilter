//
//  ChannelWhitelist.h
//  uYouEnhanced - ChannelFilter
//
//  登録チャンネル以外を常時制限する。ユーザーが解除できるトグルは持たない。
//
//  「詰み」防止ルール:
//    ホワイトリストが空（0件）のときはフィルタを一切かけない。
//    → 初回起動時や同期前でも「登録チャンネル」タブが必ず開けるため
//      ホワイトリストを埋めることができる。
//

#pragma once
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// ホワイトリスト（登録チャンネルIDのセット）を管理するシングルトン
@interface CFWhitelistManager : NSObject

+ (instancetype)sharedManager;

/// 登録済みチャンネルIDを同期する（YTSubscriptionsFeedController から取得したものを渡す）
- (void)syncSubscribedChannelIDs:(NSArray<NSString *> *)channelIDs;

/// チャンネルIDがホワイトリストに含まれるか
- (BOOL)isChannelAllowed:(NSString *)channelID;

/// ホワイトリストが空かどうか（空のときはフィルタをかけない＝詰み防止）
- (BOOL)isEmpty;

/// 現在のホワイトリスト（チャンネルIDの配列、デバッグ表示用）
- (NSArray<NSString *> *)allowedChannelIDs;

@end
