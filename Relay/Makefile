include $(THEOS)/makefiles/common.mk

# Loaded into every app, so it stays tiny: UIKit only, no settings, no actions.
TWEAK_NAME = TriggrRelay
TriggrRelay_FILES = Relay.x
TriggrRelay_CFLAGS = -fobjc-arc
TriggrRelay_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
