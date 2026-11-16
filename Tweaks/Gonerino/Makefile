# Gonerino (https://github.com/castdrian/Gonerino) v1.8.10, GPL-3.0
# uYouEnhanced-ChannelFilter 用に改変: 登録チャンネル名の許可リスト方式に変更。
# 変更点は各ソースの "[uYouEnhanced-ChannelFilter]" コメントを参照。
# UpdateChecker / Sideloading / ReelSequenceFilter はビルドしない。
TARGET := iphone:clang:latest:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Gonerino

$(TWEAK_NAME)_FILES = $(wildcard sources/*.x) $(wildcard sources/*.m)
$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation UserNotifications UniformTypeIdentifiers MobileCoreServices
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -DPACKAGE_VERSION='@"1.8.10"' -Iheaders

include $(THEOS_MAKE_PATH)/tweak.mk
