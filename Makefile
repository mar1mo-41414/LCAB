ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = LCAdBlocker

LCAdBlocker_FILES = $(wildcard Sources/*.m)
LCAdBlocker_CFLAGS = -fobjc-arc -Wall -ISources
LCAdBlocker_FRAMEWORKS = UIKit Foundation StoreKit
LCAdBlocker_LIBRARY_EXTENSION = .dylib
LCAdBlocker_INSTALL_PATH = /usr/lib

include $(THEOS_MAKE_PATH)/library.mk
