export ARCHS = arm64
export TARGET = iphone:clang:latest:15.0

INSTALL_TARGET_PROCESSES = Preferences SpringBoard

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += Tweak
SUBPROJECTS += Relay
SUBPROJECTS += Prefs
SUBPROJECTS += CLI

include $(THEOS_MAKE_PATH)/aggregate.mk
