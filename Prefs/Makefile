include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = Triggr
Triggr_FILES = TGSettings.m
Triggr_INSTALL_PATH = /Library/PreferenceBundles
Triggr_FRAMEWORKS = UIKit LocalAuthentication UniformTypeIdentifiers
Triggr_PRIVATE_FRAMEWORKS = Preferences
# AltList is vendored only to compile/link against; the device gets it from com.opa334.altlist.
Triggr_EXTRA_FRAMEWORKS = AltList
# The version shown at the bottom of the main page comes from the control file.
TG_VERSION := $(shell sed -n 's/^Version: //p' $(THEOS_PROJECT_DIR)/control)
Triggr_CFLAGS = -fobjc-arc -F$(THEOS_PROJECT_DIR)/vendor -DTG_VERSION='@"$(TG_VERSION)"'
Triggr_LDFLAGS = -F$(THEOS_PROJECT_DIR)/vendor

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/Triggr.plist"$(ECHO_END)
