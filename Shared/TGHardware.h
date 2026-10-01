// Which buttons this device has, shared by Settings and the tweak (not the CLI).
// Needs LocalAuthentication and <dlfcn.h>.

// MobileGestalt's HomeButtonType (2 = no Home button, the Face ID layout) is
// read from the hardware, so it doesn't depend on a passcode or enrolment the
// way LAContext.biometryType can. If it can't be read, Face ID stands in.
// Every iOS 15-16 device with a Home button has Touch ID in it, so this also
// says whether the Touch ID triggers apply.
static inline BOOL TGHasHomeButton(void) {
    static BOOL hasHome;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *gestalt = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
        CFTypeRef (*copyAnswer)(CFStringRef) = gestalt ? (CFTypeRef (*)(CFStringRef))dlsym(gestalt, "MGCopyAnswer") : NULL;
        id answer = copyAnswer ? CFBridgingRelease(copyAnswer(CFSTR("HomeButtonType"))) : nil;
        if ([answer isKindOfClass:NSNumber.class]) {
            hasHome = [answer intValue] != 2;
        } else {
            // Public LocalAuthentication. biometryType is only filled in after
            // canEvaluatePolicy:, whose result (e.g. not enrolled) doesn't matter.
            LAContext *context = [LAContext new];
            [context canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics error:nil];
            hasHome = context.biometryType != LABiometryTypeFaceID;
        }
    });
    return hasHome;
}

// Apple's name for the lock button where there's no Home button.
static inline NSString *TGLockButtonName(void) {
    if (TGHasHomeButton()) return @"Lock Button";
    return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? @"Top Button" : @"Side Button";
}
