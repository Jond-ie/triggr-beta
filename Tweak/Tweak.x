// Triggr: assign actions to buttons, switches and gestures (SpringBoard).
//
// Every trigger hook asks the dispatcher for an action in the current mode
// (lock screen / home screen / app, falling back to "Anywhere"). Only actions
// Triggr can actually perform count as assigned, so an unfinished action can
// never take a button away. With "Replace Button Actions" on (the default), an
// assigned home, Touch ID double tap, volume, lock or mute switch trigger skips
// the system behaviour; with it off they run alongside. Touch ID finger events
// and volume holds always run alongside.
//
// This library loads into SpringBoard only. Apps get the tiny Relay library,
// which just reports their status bar taps and shakes (see Shared/TGRelay.h).

#import <UIKit/UIKit.h>
#import <UIKit/UIGestureRecognizerSubclass.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <spawn.h>
#import <sys/wait.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <AudioToolbox/AudioToolbox.h>
#import "../Shared/TGCatalog.h"
#import "../Shared/TGHardware.h"
#import "../Shared/TGRelay.h"

@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isUILocked;
@end
@interface SpringBoard : UIApplication
- (id)_accessibilityFrontMostApplication;
@end
@interface SBIconView : UIView
@end

#pragma mark - Assignments

static NSDictionary *tgAssignments;
// Triggers with at least one assignment (any mode). Hooks check this first, so
// an unassigned trigger costs one set lookup and nothing else.
static NSSet<NSString *> *tgAssignedTriggers;

// Every "<mode>/<trigger>" key in the domain with a non-empty action id.
static void TGUpdateOtherEvents(void);
static void TGUpdateAPI(void);
static BOOL tgRequireUnlock = YES;
static BOOL tgAllowAPI;
static BOOL tgReplaces = YES; // assigned button triggers replace iOS's action; off = they run alongside
static NSSet<NSString *> *tgBlockedApps;
static BOOL tgShowBanners;
static NSDictionary<NSString *, NSString *> *tgMenuNames; // id -> name

static void TGReadAssignments(void) {
    CFStringRef domain = (__bridge CFStringRef)TGDomain;
    CFPreferencesAppSynchronize(domain);
    id requireUnlock = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)TGRequireUnlockKey, domain));
    tgRequireUnlock = ![requireUnlock respondsToSelector:@selector(boolValue)] || [requireUnlock boolValue];
    id blocked = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)TGBlockedAppsKey, domain));
    tgBlockedApps = [blocked isKindOfClass:NSArray.class] && [blocked count] ? [NSSet setWithArray:blocked] : nil;
    id allowAPI = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)TGAllowAPIKey, domain));
    tgAllowAPI = [allowAPI respondsToSelector:@selector(boolValue)] && [allowAPI boolValue];
    id lockReplaces = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)TGLockReplacesKey, domain));
    tgReplaces = ![lockReplaces respondsToSelector:@selector(boolValue)] || [lockReplaces boolValue]; // on unless turned off
    id banners = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)TGShowBannersKey, domain));
    tgShowBanners = [banners respondsToSelector:@selector(boolValue)] && [banners boolValue];
    id menus = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)TGMenusKey, domain));
    NSMutableDictionary *menuNames = [NSMutableDictionary dictionary];
    for (id menu in [menus isKindOfClass:NSArray.class] ? menus : @[])
        if ([menu isKindOfClass:NSDictionary.class] && [menu[@"id"] isKindOfClass:NSString.class]) menuNames[menu[@"id"]] = [menu[@"name"] description] ?: @"Menu";
    tgMenuNames = menuNames;
    id enabled = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)TGEnabledKey, domain));
    if ([enabled respondsToSelector:@selector(boolValue)] && ![enabled boolValue]) {
        tgAssignments = @{};
        tgAssignedTriggers = [NSSet set];
        TGUpdateOtherEvents();
        TGUpdateAPI();
        return;
    }
    NSArray *keys = CFBridgingRelease(CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
    NSDictionary *values = keys.count ? CFBridgingRelease(CFPreferencesCopyMultiple((__bridge CFArrayRef)keys, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)) : @{};
    NSMutableDictionary *assignments = [NSMutableDictionary dictionary];
    [values enumerateKeysAndObjectsUsingBlock:^(NSString *key, id action, BOOL *stop) {
        if (![key containsString:@"/"]) return;
        // One action (string) or several, run in order (array of strings).
        NSMutableArray *actions = [NSMutableArray array];
        for (id item in [action isKindOfClass:NSArray.class] ? action : @[action])
            if ([item isKindOfClass:NSString.class] && [item length]) [actions addObject:item];
        if (actions.count) assignments[key] = actions;
    }];
    tgAssignments = assignments;
    // Without a Home button (Face ID) its triggers and Touch ID's, e.g. from an imported setup, never count.
    NSMutableSet *triggers = [NSMutableSet set];
    for (NSString *key in assignments) {
        NSRange slash = [key rangeOfString:@"/"];
        NSString *trigger = slash.location == NSNotFound ? nil : [key substringFromIndex:slash.location + 1];
        if (TGIsKnownTrigger(trigger) && TGTriggerFitsHardware(trigger, TGHasHomeButton())) [triggers addObject:trigger];
    }
    tgAssignedTriggers = triggers;
    TGUpdateOtherEvents();
    TGUpdateAPI();
}

#pragma mark - Mode

// Private SpringBoard API (widely used, guarded): lock screen, then front app.
static NSString *TGCurrentMode(void) {
    Class lockManager = objc_getClass("SBLockScreenManager");
    if ([lockManager respondsToSelector:@selector(sharedInstance)]) {
        SBLockScreenManager *manager = [lockManager sharedInstance];
        if ([manager respondsToSelector:@selector(isUILocked)] && [manager isUILocked]) return @"lock";
    }
    SpringBoard *springBoard = (SpringBoard *)UIApplication.sharedApplication;
    if ([springBoard respondsToSelector:@selector(_accessibilityFrontMostApplication)] && [springBoard _accessibilityFrontMostApplication]) return @"app";
    return @"home";
}

#pragma mark - Actions

static BOOL TGCanPerform(NSString *action);
static void TGShowMenu(NSString *menuID);

// The action assigned to `trigger` in the current mode, or nil.
static NSArray<NSString *> *TGPerformable(NSArray<NSString *> *actions) {
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *action in actions) if (TGCanPerform(action)) [result addObject:action];
    return result.count ? result : nil;
}

// The actions assigned to `trigger` in the current mode (else Anywhere), or nil.
static NSArray<NSString *> *TGActionFor(NSString *trigger) {
    if (![tgAssignedTriggers containsObject:trigger]) return nil; // fast path: nothing assigned
    NSString *mode = TGCurrentMode();
    if (tgBlockedApps && [mode isEqualToString:@"app"]) {
        // Block List: ignore triggers inside these apps.
        id front = [UIApplication.sharedApplication respondsToSelector:@selector(_accessibilityFrontMostApplication)] ? [(SpringBoard *)UIApplication.sharedApplication _accessibilityFrontMostApplication] : nil;
        id identifier = [front respondsToSelector:@selector(bundleIdentifier)] ? [front performSelector:@selector(bundleIdentifier)] : nil;
        if ([identifier isKindOfClass:NSString.class] && [tgBlockedApps containsObject:identifier]) return nil;
    }
    NSArray *actions = TGPerformable(tgAssignments[TGAssignmentKey(mode, trigger)]) ?: TGPerformable(tgAssignments[TGAssignmentKey(@"anywhere", trigger)]);
    return actions;
}

// CoreFoundation exports this on iOS but the SDK doesn't declare it.
extern SInt32 CFUserNotificationDisplayNotice(CFTimeInterval timeout, CFOptionFlags flags, CFURLRef iconURL, CFURLRef soundURL, CFURLRef localizationURL,
    CFStringRef alertHeader, CFStringRef alertMessage, CFStringRef defaultButtonTitle);

static id TGShared(const char *className);
static BOOL TGAirPlayTo(NSString *name, BOOL dry);

static double TGPercent(NSString *action, NSString *prefix) {
    return MIN(MAX([[action substringFromIndex:prefix.length] doubleValue], 0), 100) / 100.0;
}

// Private AVSystemController (verified on iOS 16.7: SBVolumeControl has no shared
// instance, AVSystemController does), guarded.
static BOOL TGSetVolume(double volume, NSString *category, BOOL dryRun) {
    Class cls = objc_getClass("AVSystemController");
    id controller = [cls respondsToSelector:@selector(sharedAVSystemController)] ? [cls performSelector:@selector(sharedAVSystemController)] : nil;
    SEL sel = @selector(setVolumeTo:forCategory:);
    if (![controller respondsToSelector:sel]) return NO;
    if (!dryRun) {
        BOOL ok = ((BOOL (*)(id, SEL, float, id))objc_msgSend)(controller, sel, (float)volume, category);
        (void)ok;
    }
    return YES;
}

// Private CoreBrightness BrightnessSystemClient; SpringBoard ignores UIScreen.brightness
// (verified), guarded.
static BOOL TGSetBrightness(double level, BOOL dryRun) {
    static id client;
    if (!client) {
        Class cls = objc_getClass("BrightnessSystemClient");
        client = [cls instancesRespondToSelector:@selector(setProperty:forKey:)] ? [cls new] : nil;
    }
    if (!client) return NO;
    if (!dryRun) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(client, @selector(setProperty:forKey:), @(level), @"DisplayBrightness");
    }
    return YES;
}

static void TGSpeak(NSString *text) {
    static AVSpeechSynthesizer *synthesizer;
    if (!synthesizer) synthesizer = [AVSpeechSynthesizer new];
    [synthesizer speakUtterance:[AVSpeechUtterance speechUtteranceWithString:text]];
}

static void TGOpenURL(NSString *string);

// Actions with a value; YES when `action` is one of them (and available).
static BOOL TGValueAction(NSString *action, BOOL dryRun) {
    if ([action hasPrefix:TGBrightnessPrefix]) return TGSetBrightness(TGPercent(action, TGBrightnessPrefix), dryRun);
    if ([action hasPrefix:TGMediaVolumePrefix]) return TGSetVolume(TGPercent(action, TGMediaVolumePrefix), @"Audio/Video", dryRun);
    if ([action hasPrefix:TGRingerVolumePrefix]) return TGSetVolume(TGPercent(action, TGRingerVolumePrefix), @"Ringtone", dryRun);
    if ([action hasPrefix:TGMessagePrefix]) {
        if (!dryRun) CFUserNotificationDisplayNotice(0, 0, NULL, NULL, NULL, CFSTR("Triggr"), (__bridge CFStringRef)[action substringFromIndex:TGMessagePrefix.length], CFSTR("OK"));
        return YES;
    }
    if ([action hasPrefix:TGSpeakPrefix]) {
        if (!dryRun) TGSpeak([action substringFromIndex:TGSpeakPrefix.length]);
        return YES;
    }
    if ([action hasPrefix:TGAirPlayPrefix]) {
        NSString *name = [action substringFromIndex:TGAirPlayPrefix.length];
        return name.length && TGAirPlayTo(name, dryRun);
    }
    if ([action hasPrefix:TGSettingsPrefix]) {
        // "prefs:" no longer opens from SpringBoard on iOS 16; "App-prefs:" does (verified).
        if (!dryRun) TGOpenURL([@"App-prefs:" stringByAppendingString:[action substringFromIndex:TGSettingsPrefix.length]]);
        return YES;
    }
    return NO;
}

static void TGOpenURL(NSString *string) {
    NSURL *url = [NSURL URLWithString:string];
    if (!url) {
        return;
    }
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL ok) {
    }];
}

// Runs as mobile (SpringBoard's user), detached, output discarded.
static void TGRunShell(NSString *command) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        const char *argv[] = {"sh", "-c", command.UTF8String, NULL};
        posix_spawn_file_actions_t actions;
        posix_spawn_file_actions_init(&actions);
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
        // SpringBoard's environment has no rootless PATH; give commands one.
        const char *envp[] = {"PATH=/var/jb/usr/local/bin:/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/usr/bin:/bin:/usr/sbin:/sbin",
                              "HOME=/var/mobile", "USER=mobile", "LANG=en_US.UTF-8", NULL};
        pid_t pid = 0;
        int error = posix_spawn(&pid, "/var/jb/bin/sh", &actions, NULL, (char *const *)argv, (char *const *)envp);
        posix_spawn_file_actions_destroy(&actions);
        if (error) {
            return;
        }
        int status = 0;
        waitpid(pid, &status, 0);
    });
}

// Built-in actions. Each checks at runtime that the SpringBoard method it
// needs exists (found by class dump on iOS 16.7); an action whose method is
// missing counts as unassigned, so it can never take a button away.
typedef BOOL (^TGActionBlock)(BOOL dryRun); // dryRun: only report availability

static id TGShared(const char *className) {
    Class cls = objc_getClass(className);
    return [cls respondsToSelector:@selector(sharedInstance)] ? [cls performSelector:@selector(sharedInstance)] : nil;
}

// SpringBoard's volume and ringer controls: the app object has them on iOS 16
// (verified on 16.7); on iOS 15 (verified on 15.8) SBMainWorkspace owns them.
static id TGSpringBoardControl(SEL accessor) {
    id springBoard = UIApplication.sharedApplication;
    if ([springBoard respondsToSelector:accessor]) return ((id (*)(id, SEL))objc_msgSend)(springBoard, accessor);
    id workspace = TGShared("SBMainWorkspace");
    return [workspace respondsToSelector:accessor] ? ((id (*)(id, SEL))objc_msgSend)(workspace, accessor) : nil;
}

static BOOL TGCall(id target, SEL sel, BOOL dryRun) {
    if (![target respondsToSelector:sel]) return NO;
    if (!dryRun) ((void (*)(id, SEL))objc_msgSend)(target, sel);
    return YES;
}

static BOOL TGVolumeStep(id springBoard, BOOL up, BOOL dryRun) {
    id volume = TGSpringBoardControl(@selector(volumeControl));
    SEL step = up ? @selector(volumeStepUp) : @selector(volumeStepDown);
    if (@available(iOS 16, *)) {
    } else if ([volume respondsToSelector:step] && [volume respondsToSelector:@selector(changeVolumeByDelta:)]) {
        // iOS 15: volumeStepUp/Down only return the step size (verified on 15.8),
        // so the step is applied with changeVolumeByDelta:.
        if (!dryRun) {
            float delta = fabsf(((float (*)(id, SEL))objc_msgSend)(volume, step));
            if (delta <= 0 || delta > 0.5f) delta = 1.0f / 16;
            ((void (*)(id, SEL, float))objc_msgSend)(volume, @selector(changeVolumeByDelta:), up ? delta : -delta);
        }
        return YES;
    }
    if ([volume respondsToSelector:step]) {
        if (!dryRun) ((void (*)(id, SEL))objc_msgSend)(volume, step);
        return YES;
    }
    SEL start = up ? @selector(increaseVolume) : @selector(decreaseVolume);
    if (![volume respondsToSelector:start] || ![volume respondsToSelector:@selector(cancelVolumeEvent)]) return NO;
    if (!dryRun) {
        ((void (*)(id, SEL))objc_msgSend)(volume, start);
        ((void (*)(id, SEL))objc_msgSend)(volume, @selector(cancelVolumeEvent));
    }
    return YES;
}

#pragma mark Switches (Toggle / On / Off)

// A switch reads its state and sets it; nil when unavailable on this device.
typedef struct { BOOL (^get)(void); void (^set)(BOOL on); } TGSwitch;

// CBBlueLightClient's status, as its getBlueLightStatus: fills it in (type
// encoding {?=BBBi{?={?=ii}{?=ii}}QB}, read from the device).
typedef struct {
    BOOL active, enabled, sunSchedulePermitted;
    int mode;
    struct { struct { int hour, minute; } from, to; } schedule;
    unsigned long long disableFlags;
    BOOL available;
} TGBlueLightStatus;

static BOOL TGSwitchFor(NSString *name, TGSwitch *out) {
    if ([name isEqualToString:@"flashlight"]) {
        AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        if (!device.hasTorch) return NO;
        out->get = ^BOOL { return device.torchMode == AVCaptureTorchModeOn; };
        out->set = ^(BOOL on) {
            NSError *error = nil;
            if (![device lockForConfiguration:&error]) { return; }
            device.torchMode = on ? AVCaptureTorchModeOn : AVCaptureTorchModeOff;
            [device unlockForConfiguration];
        };
        return YES;
    }
    if ([name isEqualToString:@"wifi"]) {
        id wifi = TGShared("SBWiFiManager");
        if (![wifi respondsToSelector:@selector(setWiFiEnabled:)] || ![wifi respondsToSelector:@selector(wiFiEnabled)]) return NO;
        out->get = ^BOOL { return ((BOOL (*)(id, SEL))objc_msgSend)(wifi, @selector(wiFiEnabled)); };
        out->set = ^(BOOL on) { ((void (*)(id, SEL, BOOL))objc_msgSend)(wifi, @selector(setWiFiEnabled:), on); };
        return YES;
    }
    if ([name isEqualToString:@"bluetooth"]) {
        id bt = TGShared("BluetoothManager");
        if (![bt respondsToSelector:@selector(setEnabled:)] || ![bt respondsToSelector:@selector(enabled)]) return NO;
        out->get = ^BOOL { return ((BOOL (*)(id, SEL))objc_msgSend)(bt, @selector(enabled)); };
        out->set = ^(BOOL on) { ((void (*)(id, SEL, BOOL))objc_msgSend)(bt, @selector(setEnabled:), on); };
        return YES;
    }
    if ([name isEqualToString:@"rotation"]) {
        id lock = TGShared("SBOrientationLockManager");
        if (![lock respondsToSelector:@selector(isUserLocked)] || ![lock respondsToSelector:@selector(lock)] || ![lock respondsToSelector:@selector(unlock)]) return NO;
        out->get = ^BOOL { return ((BOOL (*)(id, SEL))objc_msgSend)(lock, @selector(isUserLocked)); };
        out->set = ^(BOOL on) { ((void (*)(id, SEL))objc_msgSend)(lock, on ? @selector(lock) : @selector(unlock)); };
        return YES;
    }
    if ([name isEqualToString:@"lowpower"]) {
        // Private LowPowerMode.framework (iOS 15+, the call behind SpringBoard's own
        // 20 % alert), guarded. The state is read with the public NSProcessInfo.
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            if (!objc_getClass("_PMLowPowerMode")) dlopen("/System/Library/PrivateFrameworks/LowPowerMode.framework/LowPowerMode", RTLD_LAZY);
        });
        id lowPower = TGShared("_PMLowPowerMode");
        SEL sel = @selector(setPowerMode:fromSource:withCompletion:);
        if (![lowPower respondsToSelector:sel]) return NO;
        out->get = ^BOOL { return NSProcessInfo.processInfo.isLowPowerModeEnabled; };
        out->set = ^(BOOL on) {
            // As Settings: from Control Center, iOS shows a one-time "Low Power Mode"
            // explanation alert that then sits on screen (seen on iOS 15.8).
            void *symbol = dlsym(RTLD_DEFAULT, "kPMLPMSourceSettings");
            if (!symbol) symbol = dlsym(RTLD_DEFAULT, "kPMLPMSourceControlCenter");
            NSString *source = symbol ? (__bridge NSString *)*(void **)symbol : @"ControlCenter";
            ((void (*)(id, SEL, long long, id, id))objc_msgSend)(lowPower, sel, on ? 1 : 0, source, ^(BOOL ok, NSError *error) {
            });
        };
        return YES;
    }
    if ([name isEqualToString:@"airplane"]) {
        id airplane = TGShared("SBAirplaneModeController");
        if (![airplane respondsToSelector:@selector(isInAirplaneMode)] || ![airplane respondsToSelector:@selector(setInAirplaneMode:)]) return NO;
        out->get = ^BOOL { return ((BOOL (*)(id, SEL))objc_msgSend)(airplane, @selector(isInAirplaneMode)); };
        out->set = ^(BOOL on) { ((void (*)(id, SEL, BOOL))objc_msgSend)(airplane, @selector(setInAirplaneMode:), on); };
        return YES;
    }
    if ([name isEqualToString:@"cellular"]) {
        // CoreTelephony's C calls (private, exported; SpringBoard already links it).
        Boolean (*get)(void) = dlsym(RTLD_DEFAULT, "CTCellularDataPlanGetIsEnabled");
        void (*set)(Boolean) = dlsym(RTLD_DEFAULT, "CTCellularDataPlanSetIsEnabled");
        if (!get || !set) return NO;
        out->get = ^BOOL { return get(); };
        out->set = ^(BOOL on) { set(on); };
        return YES;
    }
    if ([name isEqualToString:@"dnd"]) {
        // The same manual Do Not Disturb that Control Center's Focus button takes
        // (DoNotDisturb.framework, private, guarded).
        static id service;
        Class serviceClass = objc_getClass("DNDModeAssertionService"), detailsClass = objc_getClass("DNDModeAssertionDetails");
        SEL make = @selector(userRequestedAssertionDetailsWithIdentifier:modeIdentifier:lifetime:);
        if (!service && [serviceClass respondsToSelector:@selector(serviceForClientIdentifier:)])
            service = [serviceClass performSelector:@selector(serviceForClientIdentifier:) withObject:@"com.apple.donotdisturb.control-center.module"];
        if (![service respondsToSelector:@selector(activeModeAssertionWithError:)] || ![service respondsToSelector:@selector(takeModeAssertionWithDetails:error:)]
            || ![service respondsToSelector:@selector(invalidateAllActiveModeAssertionsWithError:)] || ![detailsClass respondsToSelector:make]) return NO;
        id dnd = service;
        out->get = ^BOOL { return ((id (*)(id, SEL, NSError **))objc_msgSend)(dnd, @selector(activeModeAssertionWithError:), NULL) != nil; };
        out->set = ^(BOOL on) {
            NSError *error = nil;
            if (on) {
                id details = ((id (*)(id, SEL, id, id, id))objc_msgSend)(detailsClass, make, @"com.apple.control-center.manual-toggle", @"com.apple.donotdisturb.mode.default", nil);
                ((id (*)(id, SEL, id, NSError **))objc_msgSend)(dnd, @selector(takeModeAssertionWithDetails:error:), details, &error);
            } else {
                ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(dnd, @selector(invalidateAllActiveModeAssertionsWithError:), &error);
            }
        };
        return YES;
    }
    if ([name isEqualToString:@"darkmode"]) {
        // UIKitServices (private): 1 = light, 2 = dark. Setting it ends an automatic schedule.
        static id style;
        Class cls = objc_getClass("UISUserInterfaceStyleMode");
        if (!style && [cls instancesRespondToSelector:@selector(initWithDelegate:)]) style = ((id (*)(id, SEL, id))objc_msgSend)([cls alloc], @selector(initWithDelegate:), nil);
        if (![style respondsToSelector:@selector(modeValue)] || ![style respondsToSelector:@selector(setModeValue:)]) return NO;
        id mode = style;
        out->get = ^BOOL { return UIScreen.mainScreen.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark; };
        out->set = ^(BOOL on) { ((void (*)(id, SEL, long long))objc_msgSend)(mode, @selector(setModeValue:), on ? 2 : 1); };
        return YES;
    }
    if ([name isEqualToString:@"nightshift"]) {
        // CoreBrightness (private), guarded; the status struct's second field is "enabled".
        static id client;
        Class cls = objc_getClass("CBBlueLightClient");
        if (![cls respondsToSelector:@selector(supportsBlueLightReduction)] || !((BOOL (*)(id, SEL))objc_msgSend)(cls, @selector(supportsBlueLightReduction))) return NO;
        if (!client) client = [cls new];
        if (![client respondsToSelector:@selector(getBlueLightStatus:)] || ![client respondsToSelector:@selector(setEnabled:)]) return NO;
        id blueLight = client;
        out->get = ^BOOL {
            TGBlueLightStatus status = {0};
            ((BOOL (*)(id, SEL, TGBlueLightStatus *))objc_msgSend)(blueLight, @selector(getBlueLightStatus:), &status);
            return status.enabled;
        };
        out->set = ^(BOOL on) { ((BOOL (*)(id, SEL, BOOL))objc_msgSend)(blueLight, @selector(setEnabled:), on); };
        return YES;
    }
    if ([name isEqualToString:@"autobrightness"]) {
        // BackBoardServices' setter (private, exported); the state is backboardd's own setting.
        void (*set)(BOOL) = dlsym(RTLD_DEFAULT, "BKSDisplayBrightnessSetAutoBrightnessEnabled");
        if (!set) return NO;
        out->get = ^BOOL {
            CFPreferencesSynchronize(CFSTR("com.apple.backboardd"), CFSTR("mobile"), kCFPreferencesAnyHost);
            id enabled = CFBridgingRelease(CFPreferencesCopyValue(CFSTR("BKEnableALS"), CFSTR("com.apple.backboardd"), CFSTR("mobile"), kCFPreferencesAnyHost));
            return ![enabled respondsToSelector:@selector(boolValue)] || [enabled boolValue]; // on unless turned off
        };
        out->set = ^(BOOL on) { set(on); };
        return YES;
    }
    if ([name isEqualToString:@"keepawake"]) {
        // SpringBoard's own idle-timer assertion (private, guarded). Held in memory
        // only, so a respring always goes back to normal auto-lock.
        static id assertion;
        id coordinator = TGShared("SBIdleTimerGlobalCoordinator");
        SEL acquire = @selector(acquireIdleTimerDisableAssertionForReason:);
        if (![coordinator respondsToSelector:acquire]) return NO;
        out->get = ^BOOL { return assertion != nil; };
        out->set = ^(BOOL on) {
            if (on && !assertion) {
                assertion = ((id (*)(id, SEL, id))objc_msgSend)(coordinator, acquire, @"Triggr: Keep Screen Awake");
            } else if (!on && assertion) {
                if ([assertion respondsToSelector:@selector(invalidate)]) ((void (*)(id, SEL))objc_msgSend)(assertion, @selector(invalidate));
                assertion = nil;
            }
        };
        return YES;
    }
    if ([name isEqualToString:@"location"]) {
        // CoreLocation's private class setter (the one Settings uses), guarded.
        Class cls = objc_getClass("CLLocationManager");
        if (![cls respondsToSelector:@selector(setLocationServicesEnabled:)] || ![cls respondsToSelector:@selector(locationServicesEnabled)]) return NO;
        out->get = ^BOOL { return ((BOOL (*)(id, SEL))objc_msgSend)(cls, @selector(locationServicesEnabled)); };
        out->set = ^(BOOL on) { ((void (*)(id, SEL, BOOL))objc_msgSend)(cls, @selector(setLocationServicesEnabled:), on); };
        return YES;
    }
    if ([name isEqualToString:@"mute"]) {
        // setRingerMuted: (verified); toggleRingerMute does nothing on a phone with a mute switch.
        id ringer = TGSpringBoardControl(@selector(ringerControl));
        if (![ringer respondsToSelector:@selector(isRingerMuted)] || ![ringer respondsToSelector:@selector(setRingerMuted:)]) return NO;
        out->get = ^BOOL { return ((BOOL (*)(id, SEL))objc_msgSend)(ringer, @selector(isRingerMuted)); };
        out->set = ^(BOOL on) { ((void (*)(id, SEL, BOOL))objc_msgSend)(ringer, @selector(setRingerMuted:), on); };
        return YES;
    }
    return NO;
}

// "toggle.<switch>", "on.<switch>", "off.<switch>".
static TGActionBlock TGSwitchAction(NSString *action) {
    NSRange dot = [action rangeOfString:@"."];
    if (dot.location == NSNotFound) return nil;
    NSString *verb = [action substringToIndex:dot.location], *name = [action substringFromIndex:dot.location + 1];
    int mode = [verb isEqualToString:@"toggle"] ? -1 : [verb isEqualToString:@"on"] ? 1 : [verb isEqualToString:@"off"] ? 0 : -2;
    if (mode == -2) return nil;
    return ^BOOL(BOOL dry) {
        TGSwitch sw;
        if (!TGSwitchFor(name, &sw)) return NO;
        if (!dry) {
            BOOL target = mode == -1 ? !sw.get() : mode;
            sw.set(target);
        }
        return YES;
    };
}

// The app in front now (or last in front) and the one before it, for Last App.
static NSString *tgCurrentApp, *tgPreviousApp;
static BOOL TGOpenApp(NSString *identifier, BOOL dryRun);

static NSString *TGFrontAppIdentifier(void) {
    SpringBoard *springBoard = (SpringBoard *)UIApplication.sharedApplication;
    id front = [springBoard respondsToSelector:@selector(_accessibilityFrontMostApplication)] ? [springBoard _accessibilityFrontMostApplication] : nil;
    id identifier = [front respondsToSelector:@selector(bundleIdentifier)] ? [front performSelector:@selector(bundleIdentifier)] : nil;
    return [identifier isKindOfClass:NSString.class] ? identifier : nil;
}

// Siri: SiriActivation's own entry point (private, guarded). Verified on iOS
// 16.7: a source ignores an activation sent before it has connected (a fraction
// of a second) and doesn't answer a second one, so each activation makes its own
// source and gives it a moment. Nothing is sent while the screen is off.
static BOOL TGScreenIsOn(void);

static void TGActivateSiri(void) {
    static id source; // kept until the next activation replaces it
    Class cls = objc_getClass("SiriSimpleActivationSource");
    if (!TGScreenIsOn() || ![cls instancesRespondToSelector:@selector(activateFromSource:)]) return;
    id fresh = source = [cls new];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, long long))objc_msgSend)(fresh, @selector(activateFromSource:), 1);
    });
}

static BOOL TGShutdown(BOOL restart, BOOL dryRun) {
    id service = TGShared("FBSystemService");
    SEL sel = @selector(shutdownAndReboot:);
    if (![service respondsToSelector:sel]) return NO;
    if (!dryRun) ((void (*)(id, SEL, BOOL))objc_msgSend)(service, sel, restart);
    return YES;
}

// Sleep: lock and turn the screen off, as a lock button press does
// (SpringBoard's simulated lock press).
// iOS 15 keeps the SOS gesture "active" for about a second after quick lock
// presses and won't sleep meanwhile, so Triple Press -> Sleep did nothing
// (verified on iOS 15.8). There, an active SOS gesture is ended first and the
// lock button's own sleep runs. Real SOS isn't affected: Triggr never acts on
// four or more presses, so those stay iOS's. iOS 16 is unchanged (verified on 16.7).
// The lock button's sleep/wake handler (SBSleepWakeHardwareButtonInteraction), or nil.
static id TGSleepWakeInteraction(void) {
    id springBoard = UIApplication.sharedApplication;
    id button = [springBoard respondsToSelector:@selector(lockHardwareButton)] ? [springBoard performSelector:@selector(lockHardwareButton)] : nil;
    id actions = [button respondsToSelector:@selector(buttonActions)] ? [button performSelector:@selector(buttonActions)] : nil;
    return [actions respondsToSelector:@selector(sleepWakeButtonInteraction)] ? [actions performSelector:@selector(sleepWakeButtonInteraction)] : nil;
}

static BOOL TGSleep(BOOL dry) {
    id springBoard = UIApplication.sharedApplication;
    if (dry) return [springBoard respondsToSelector:@selector(_simulateLockButtonPress)];
    // Right after quick lock presses (a triple press running Sleep) iOS is still
    // counting them towards Emergency SOS and ignores sleep requests. Seen on
    // iOS 15 and iOS 16: end that gesture first.
    id interaction = TGSleepWakeInteraction();
    if ([interaction respondsToSelector:@selector(isSOSGestureActive)] && [interaction respondsToSelector:@selector(setSOSGestureActive:)]
        && ((BOOL (*)(id, SEL))objc_msgSend)(interaction, @selector(isSOSGestureActive))) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(interaction, @selector(setSOSGestureActive:), NO);
    }
    // The button's own sleep step (what a press ends up calling). A simulated press
    // instead takes a darkened screen (Triple → Sleep's early dim) as already asleep.
    if ([interaction respondsToSelector:@selector(_performSleep)]) {
        ((void (*)(id, SEL))objc_msgSend)(interaction, @selector(_performSleep));
        return YES;
    }
    return TGCall(springBoard, @selector(_simulateLockButtonPress), NO);
}

// Screen Recording: ReplayKit's system recording, as Control Center's button
// (no microphone). Private methods, checked at runtime (seen on iOS 15.8).
static BOOL TGScreenRecord(BOOL dry) {
    Class cls = objc_getClass("RPScreenRecorder");
    if (!cls) { dlopen("/System/Library/Frameworks/ReplayKit.framework/ReplayKit", RTLD_NOW); cls = objc_getClass("RPScreenRecorder"); }
    id recorder = [cls respondsToSelector:@selector(sharedRecorder)] ? [cls performSelector:@selector(sharedRecorder)] : nil;
    SEL start = @selector(startSystemRecordingWithMicrophoneEnabled:handler:), stop = @selector(stopSystemRecording:);
    if (![recorder respondsToSelector:start] || ![recorder respondsToSelector:stop] || ![recorder respondsToSelector:@selector(systemRecording)]) return NO;
    if (dry) return YES;
    BOOL recording = ((BOOL (*)(id, SEL))objc_msgSend)(recorder, @selector(systemRecording));
    if (recording) ((void (*)(id, SEL, id))objc_msgSend)(recorder, stop, ^(id error) { });
    else ((void (*)(id, SEL, BOOL, id))objc_msgSend)(recorder, start, NO, ^(id error) { });
    return YES;
}

// Close Background Apps: every app in the App Switcher except the one in use
// and the one playing audio, removed the way swiping its card up does.
static BOOL TGCloseBackgroundApps(BOOL dry) {
    id switcher = TGShared("SBMainSwitcherViewController");
    SEL remove = @selector(_deleteAppLayoutsMatchingBundleIdentifier:);
    if (![switcher respondsToSelector:remove] || ![switcher respondsToSelector:@selector(recentAppLayouts)]) return NO;
    if (dry) return YES;
    NSMutableSet *keep = [NSMutableSet set];
    NSString *front = TGFrontAppIdentifier();
    if (front) [keep addObject:front];
    id media = TGShared("SBMediaController");
    id playing = [media respondsToSelector:@selector(nowPlayingApplication)] ? [media performSelector:@selector(nowPlayingApplication)] : nil;
    NSString *playingID = [playing respondsToSelector:@selector(bundleIdentifier)] ? [playing performSelector:@selector(bundleIdentifier)] : nil;
    if (playingID) [keep addObject:playingID];
    NSMutableOrderedSet *apps = [NSMutableOrderedSet orderedSet];
    for (id layout in [switcher performSelector:@selector(recentAppLayouts)]) {
        id items = [layout respondsToSelector:@selector(allItems)] ? [layout performSelector:@selector(allItems)] : nil;
        for (id item in items) {
            NSString *bundle = [item respondsToSelector:@selector(bundleIdentifier)] ? [item performSelector:@selector(bundleIdentifier)] : nil;
            if (bundle && ![keep containsObject:bundle]) [apps addObject:bundle];
        }
    }
    for (NSString *bundle in apps) ((void (*)(id, SEL, id))objc_msgSend)(switcher, remove, bundle);
    return YES;
}

// AirPlay: the system's own output picker (what AVRoutePickerView shows), and
// MediaPlayer's routing controller to send audio to a named device or back to
// the iPhone. Private, checked at runtime (seen on iOS 15.8).
static BOOL TGAirPlayPicker(BOOL dry) {
    static id controls; // kept while it's on screen
    Class cls = objc_getClass("MPMediaControls");
    if (![cls instancesRespondToSelector:@selector(present)]) return NO;
    if (dry) return YES;
    controls = [cls new];
    ((void (*)(id, SEL))objc_msgSend)(controls, @selector(present));
    return YES;
}

static id TGRoutingController(void) {
    Class cls = objc_getClass("MPAVRoutingController");
    if (![cls instancesRespondToSelector:@selector(fetchAvailableRoutesWithCompletionHandler:)] || ![cls instancesRespondToSelector:@selector(pickRoute:)]) return nil;
    id controller = [cls new];
    if ([controller respondsToSelector:@selector(setDiscoveryMode:)]) ((void (*)(id, SEL, long long))objc_msgSend)(controller, @selector(setDiscoveryMode:), 3); // detailed
    return controller;
}

// Looks for a matching route for a few seconds (speakers take a moment to be
// discovered), then picks it. name nil = this iPhone (or its headphones).
static BOOL TGAirPlayTo(NSString *name, BOOL dry) {
    if (!objc_getClass("MPAVRoutingController")) return NO;
    if (dry) return YES;
    id controller = TGRoutingController();
    if (!controller) return NO;
    __block int attempts = 0;
    __block void (^attempt)(void);
    void (^tryOnce)(void) = ^{
        ((void (*)(id, SEL, id))objc_msgSend)(controller, @selector(fetchAvailableRoutesWithCompletionHandler:), ^(NSArray *routes) {
            dispatch_async(dispatch_get_main_queue(), ^{
                id match = nil;
                for (id route in routes) {
                    NSString *routeName = [route respondsToSelector:@selector(routeName)] ? [route performSelector:@selector(routeName)] : nil;
                    BOOL device = [route respondsToSelector:@selector(isDeviceRoute)] && ((BOOL (*)(id, SEL))objc_msgSend)(route, @selector(isDeviceRoute));
                    if (name ? [routeName localizedCaseInsensitiveContainsString:name] : device) { match = route; break; }
                }
                if (match) {
                    BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(controller, @selector(pickRoute:), match);
                    (void)ok;
                    attempt = nil;
                } else if (++attempts < 10) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (attempt) attempt(); });
                } else {
                    attempt = nil;
                }
            });
        });
    };
    attempt = tryOnce;
    attempt();
    return YES;
}

// For Settings' AirPlay To list: the speaker and TV names SpringBoard can see
// (network devices take a moment to be discovered: up to ~3 s).
static void TGWriteAirPlayList(void) {
    id controller = TGRoutingController();
    if (!controller) { notify_post(TGAirPlayListReady); return; }
    __block int attempts = 0;
    __block void (^fetch)(void);
    fetch = ^{
        ((void (*)(id, SEL, id))objc_msgSend)(controller, @selector(fetchAvailableRoutesWithCompletionHandler:), ^(NSArray *routes) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSMutableOrderedSet *names = [NSMutableOrderedSet orderedSet];
                for (id route in routes) {
                    BOOL device = [route respondsToSelector:@selector(isDeviceRoute)] && ((BOOL (*)(id, SEL))objc_msgSend)(route, @selector(isDeviceRoute));
                    NSString *name = [route respondsToSelector:@selector(routeName)] ? [route performSelector:@selector(routeName)] : nil;
                    if (!device && name.length) [names addObject:name];
                }
                if (!names.count && ++attempts < 6) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (fetch) fetch(); });
                    return;
                }
                fetch = nil;
                (void)controller;
                [names.array writeToFile:TGAirPlayListPath atomically:YES];
                notify_post(TGAirPlayListReady);
            });
        });
    };
    fetch();
}

static NSDictionary<NSString *, TGActionBlock> *TGActionTable(void) {
    static NSDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id springBoard = UIApplication.sharedApplication;
        table = @{
            @"system.screenshot": ^BOOL(BOOL dry) { return TGCall(springBoard, @selector(takeScreenshot), dry); },
            @"system.respring": ^BOOL(BOOL dry) {
                id service = TGShared("FBSystemService");
                if (![service respondsToSelector:@selector(exitAndRelaunch:)]) return NO;
                if (!dry) ((void (*)(id, SEL, BOOL))objc_msgSend)(service, @selector(exitAndRelaunch:), YES);
                return YES;
            },
            @"system.nothing": ^BOOL(BOOL dry) { return YES; }, // only takes the trigger away from iOS
            @"system.vibrate": ^BOOL(BOOL dry) {
                if (!dry) AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
                return YES;
            },
            @"system.home": ^BOOL(BOOL dry) {
                SEL sel = @selector(_simulateHomeButtonPressWithCompletion:);
                if (![springBoard respondsToSelector:sel]) return NO;
                if (!dry) ((void (*)(id, SEL, id))objc_msgSend)(springBoard, sel, nil);
                return YES;
            },
            // In an app: the app used before it. On the Home Screen: the app last used.
            @"system.lastapp": ^BOOL(BOOL dry) {
                if (!TGOpenApp(nil, YES)) return NO;
                if (!dry) {
                    NSString *target = TGFrontAppIdentifier() ? tgPreviousApp : tgCurrentApp;
                    if (target) TGOpenApp(target, NO);
                }
                return YES;
            },
            // FrontBoard's own termination call (private, guarded); reason 1 = the user asked.
            @"system.quitapp": ^BOOL(BOOL dry) {
                id service = TGShared("FBSystemService");
                SEL sel = @selector(terminateApplication:forReason:andReport:withDescription:completion:);
                if (![service respondsToSelector:sel]) return NO;
                if (!dry) {
                    NSString *app = TGFrontAppIdentifier();
                    if (app) ((void (*)(id, SEL, id, long long, BOOL, id, id))objc_msgSend)(service, sel, app, 1, NO, @"Triggr: Quit Current App", nil);
                }
                return YES;
            },
            @"system.siri": ^BOOL(BOOL dry) {
                // As if Siri's button was held.
                if (![objc_getClass("SiriSimpleActivationSource") instancesRespondToSelector:@selector(activateFromSource:)]) return NO;
                if (!dry) TGActivateSiri();
                return YES;
            },
            // A press of the lock button as iOS handles it (screen off and locked, with
            // the lock sound and haptic), which Lock Device alone doesn't do. SpringBoard's
            // own simulated press (private, guarded); verified on iOS 16.7 that it skips
            // -[SBLockHardwareButton singlePress:], so a replaced lock button can't loop.
            @"system.sleep": ^BOOL(BOOL dry) { return TGSleep(dry); },
            // The slide-to-power-off screen (private, guarded).
            @"system.powerdown": ^BOOL(BOOL dry) { return TGCall(TGShared("SBMainWorkspace"), @selector(presentPowerDownTransientOverlay), dry); },
            // FrontBoard's shutdown (private, guarded): YES restarts, NO powers off.
            @"system.restart": ^BOOL(BOOL dry) { return TGShutdown(YES, dry); },
            // ElleKit (Dopamine's tweak loader) starts SpringBoard without tweaks while
            // this file exists; its Safe Mode screen offers Dismiss, which removes it.
            @"system.safemode": ^BOOL(BOOL dry) {
                BOOL ellekit = NO;
                for (NSString *path in @[@"/var/jb/usr/lib/ellekit/libinjector.dylib", @"/usr/lib/ellekit/libinjector.dylib"])
                    if ([NSFileManager.defaultManager fileExistsAtPath:path]) ellekit = YES;
                id service = TGShared("FBSystemService");
                if (!ellekit || ![service respondsToSelector:@selector(exitAndRelaunch:)]) return NO;
                if (!dry) {
                    BOOL flagged = [NSData.data writeToFile:@"/var/mobile/.eksafemode" atomically:NO];
                    if (flagged) ((void (*)(id, SEL, BOOL))objc_msgSend)(service, @selector(exitAndRelaunch:), YES);
                }
                return YES;
            },
            @"system.poweroff": ^BOOL(BOOL dry) { return TGShutdown(NO, dry); },
            @"system.switcher": ^BOOL(BOOL dry) { return TGCall(TGShared("SBUIController"), @selector(handleHomeButtonDoublePressDown), dry); },
            @"system.reachability": ^BOOL(BOOL dry) { return TGCall(TGShared("SBReachabilityManager"), @selector(toggleReachability), dry); },
            @"system.lock": ^BOOL(BOOL dry) {
                id manager = TGShared("SBLockScreenManager");
                SEL sel = @selector(lockUIFromSource:withOptions:);
                if (![manager respondsToSelector:sel]) return NO;
                if (!dry) ((void (*)(id, SEL, int, id))objc_msgSend)(manager, sel, 1, nil);
                return YES;
            },
            @"system.cc": ^BOOL(BOOL dry) {
                id cc = TGShared("SBControlCenterController");
                SEL sel = @selector(presentAnimated:);
                if (![cc respondsToSelector:sel]) return NO;
                if (!dry) ((void (*)(id, SEL, BOOL))objc_msgSend)(cc, sel, YES);
                return YES;
            },
            @"system.nc": ^BOOL(BOOL dry) {
                id sheet = TGShared("SBCoverSheetPresentationManager");
                SEL sel = @selector(setCoverSheetPresented:animated:withCompletion:);
                if (![sheet respondsToSelector:sel]) return NO;
                if (!dry) ((void (*)(id, SEL, BOOL, BOOL, id))objc_msgSend)(sheet, sel, YES, YES, nil);
                return YES;
            },
            @"system.spotlight": ^BOOL(BOOL dry) {
                SEL sel = @selector(toggleSearchFromBreadcrumbSource:withWillBeginHandler:completionHandler:);
                if (![springBoard respondsToSelector:sel]) return NO;
                if (!dry) ((void (*)(id, SEL, long long, id, id))objc_msgSend)(springBoard, sel, 0, nil, nil);
                return YES;
            },
            @"media.playpause": ^BOOL(BOOL dry) {
                id media = TGShared("SBMediaController");
                SEL sel = @selector(togglePlayPauseForEventSource:);
                if (![media respondsToSelector:sel]) return NO;
                if (!dry) ((BOOL (*)(id, SEL, long long))objc_msgSend)(media, sel, 0);
                return YES;
            },
            @"media.next": ^BOOL(BOOL dry) {
                id media = TGShared("SBMediaController");
                SEL sel = @selector(changeTrack:eventSource:);
                if (![media respondsToSelector:sel]) return NO;
                if (!dry) ((BOOL (*)(id, SEL, int, long long))objc_msgSend)(media, sel, 1, 0);
                return YES;
            },
            @"media.previous": ^BOOL(BOOL dry) {
                id media = TGShared("SBMediaController");
                SEL sel = @selector(changeTrack:eventSource:);
                if (![media respondsToSelector:sel]) return NO;
                if (!dry) ((BOOL (*)(id, SEL, int, long long))objc_msgSend)(media, sel, -1, 0);
                return YES;
            },
            // One notch per action. increaseVolume/decreaseVolume are press-and-hold
            // calls that keep repeating until cancelVolumeEvent (verified the hard way),
            // so prefer the single-step methods and always cancel after the fallback.
            @"media.airplay": ^BOOL(BOOL dry) { return TGAirPlayPicker(dry); },
            @"media.airplayiphone": ^BOOL(BOOL dry) { return TGAirPlayTo(nil, dry); },
            @"system.screenrecord": ^BOOL(BOOL dry) { return TGScreenRecord(dry); },
            @"system.closeapps": ^BOOL(BOOL dry) { return TGCloseBackgroundApps(dry); },
            @"media.volup": ^BOOL(BOOL dry) { return TGVolumeStep(springBoard, YES, dry); },
            @"media.voldown": ^BOOL(BOOL dry) { return TGVolumeStep(springBoard, NO, dry); },
        };
    });
    return table;
}

// Private launch APIs, both checked at runtime.
@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
@end

// Never block SpringBoard's main thread on a launch: LaunchServices calls back
// into SpringBoard, so a synchronous call from here stalls it (the hitch seen
// on-device). Prefer SpringBoard's own in-process launch; otherwise call
// LaunchServices off the main thread.
static BOOL TGOpenApp(NSString *identifier, BOOL dryRun) {
    id springBoard = UIApplication.sharedApplication;
    SEL launch = @selector(launchApplicationWithIdentifier:suspended:);
    if ([springBoard respondsToSelector:launch]) {
        if (!dryRun) ((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(springBoard, launch, identifier, NO);
        return YES;
    }
    Class workspaceClass = objc_getClass("LSApplicationWorkspace");
    LSApplicationWorkspace *workspace = [workspaceClass respondsToSelector:@selector(defaultWorkspace)] ? [workspaceClass defaultWorkspace] : nil;
    if (![workspace respondsToSelector:@selector(openApplicationWithBundleID:)]) return NO;
    if (!dryRun) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            BOOL opened = [workspace openApplicationWithBundleID:identifier];
            (void)opened;
        });
    }
    return YES;
}

static BOOL TGCanPerform(NSString *action) {
    if (action.length == 0) return NO;
    if ([action hasPrefix:TGPausePrefix]) return YES;
    if ([action hasPrefix:TGMenuPrefix]) return tgMenuNames[[action substringFromIndex:TGMenuPrefix.length]] != nil;
    if (TGValueAction(action, YES)) return YES;
    if ([action hasPrefix:TGShortcutPrefix] || [action hasPrefix:TGURLPrefix] || [action hasPrefix:TGShellPrefix]) return YES;
    if ([action hasPrefix:TGAppPrefix]) return action.length > TGAppPrefix.length && TGOpenApp(nil, YES);
    TGActionBlock block = TGActionTable()[action] ?: TGSwitchAction(action);
    return block && block(YES);
}

static void TGPerform(NSString *action) {
    dispatch_async(dispatch_get_main_queue(), ^{
        TGActionBlock block = TGActionTable()[action] ?: TGSwitchAction(action);
        if (block) {
            block(NO);
        } else if ([action hasPrefix:TGShortcutPrefix]) {
            NSString *name = [[action substringFromIndex:TGShortcutPrefix.length] stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
            TGOpenURL([@"shortcuts://run-shortcut?name=" stringByAppendingString:name]);
        } else if ([action hasPrefix:TGURLPrefix]) {
            TGOpenURL([action substringFromIndex:TGURLPrefix.length]);
        } else if ([action hasPrefix:TGShellPrefix]) {
            TGRunShell([action substringFromIndex:TGShellPrefix.length]);
        } else if ([action hasPrefix:TGAppPrefix]) {
            TGOpenApp([action substringFromIndex:TGAppPrefix.length], NO);
        } else if ([action hasPrefix:TGMenuPrefix]) {
            TGShowMenu([action substringFromIndex:TGMenuPrefix.length]);
        } else {
            TGValueAction(action, NO);
        }
    });
}

// State changes an action can cause, so its own effects don't fire triggers
// (no loops) while unrelated changes still do. Families: "wifi", "bluetooth",
// "lowpower", "lock" (device locked/unlocked) and "display" (screen on/off).
static CFTimeInterval tgCausedAt[5];
static int TGStateFamily(NSString *trigger) {
    if ([trigger hasPrefix:@"wifi."]) return 0;
    if ([trigger hasPrefix:@"bluetooth."]) return 1;
    if ([trigger hasPrefix:@"lowpower."]) return 2;
    if ([trigger hasPrefix:@"device."]) return 3;
    if ([trigger hasPrefix:@"display."]) return 4;
    return -1;
}

static void TGNoteCausedStates(NSString *action) {
    CFTimeInterval now = CACurrentMediaTime();
    NSArray<NSNumber *> *families = nil;
    NSRange dot = [action rangeOfString:@"."];
    NSString *verb = dot.location == NSNotFound ? nil : [action substringToIndex:dot.location];
    NSString *name = dot.location == NSNotFound ? nil : [action substringFromIndex:dot.location + 1];
    if ([verb isEqualToString:@"toggle"] || [verb isEqualToString:@"on"] || [verb isEqualToString:@"off"]) {
        if ([name isEqualToString:@"wifi"]) families = @[@0];
        else if ([name isEqualToString:@"bluetooth"]) families = @[@1];
        else if ([name isEqualToString:@"airplane"]) families = @[@0, @1];
        else if ([name isEqualToString:@"lowpower"]) families = @[@2];
    } else if ([action isEqualToString:@"system.lock"] || [action isEqualToString:@"system.home"]) {
        families = @[@3];
    } else if ([action isEqualToString:@"system.sleep"] || [action isEqualToString:@"system.respring"] || [action isEqualToString:@"system.safemode"]) {
        families = @[@3, @4];
    } else if ([action hasPrefix:TGShellPrefix] || [action hasPrefix:TGShortcutPrefix]) {
        families = @[@0, @1, @2, @3, @4]; // can change anything
    }
    for (NSNumber *family in families) tgCausedAt[family.intValue] = now;
}

// Runs a list in order; "pause:<s>" waits before the next action.
static void TGRunList(NSArray<NSString *> *actions, NSUInteger index) {
    for (; index < actions.count; index++) {
        NSString *action = actions[index];
        if ([action hasPrefix:TGPausePrefix]) {
            double seconds = MIN(MAX([[action substringFromIndex:TGPausePrefix.length] doubleValue], 0.1), TGPauseMax);
            NSUInteger next = index + 1;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ TGRunList(actions, next); });
            return;
        }
        TGNoteCausedStates(action);
        TGPerform(action); // queued in order on the main queue
    }
}

// On the Lock Screen, lists that open an app (which iOS can't show there) always
// wait for unlock, and shell commands do too when "Commands Need Passcode" is on
// and a passcode is set. iOS's own unlock action block (SBLockScreenManager,
// private, guarded) runs them once the user unlocks; if that API is missing,
// they don't run at all.
static BOOL TGNeedsUnlock(NSArray<NSString *> *actions) {
    if (![TGCurrentMode() isEqualToString:@"lock"]) return NO;
    BOOL command = NO;
    for (NSString *action in actions) {
        if (TGActionOpensApp(action)) return YES;
        if ([action hasPrefix:TGShellPrefix]) command = YES;
    }
    // Public: YES when a passcode is set.
    return command && tgRequireUnlock && [[LAContext new] canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:nil];
}

static void TGRunAfterUnlock(NSArray<NSString *> *actions) {
    id manager = TGShared("SBLockScreenManager");
    SEL setBlock = @selector(setUnlockActionBlock:), showPasscode = @selector(_setPasscodeVisible:animated:);
    if (![manager respondsToSelector:setBlock] || ![manager respondsToSelector:showPasscode]) {
        return;
    }
    void (^run)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{ TGRunList(actions, 0); });
    };
    ((void (*)(id, SEL, id))objc_msgSend)(manager, setBlock, run);
    ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(manager, showPasscode, YES, YES);
}

static void TGRunActions(NSArray<NSString *> *actions) {
    if (TGNeedsUnlock(actions)) TGRunAfterUnlock(actions);
    else TGRunList(actions, 0);
}

#pragma mark - Banners and menus (SpringBoard overlay windows)

// A title for any action, with app and menu names looked up in SpringBoard.
static NSString *TGSpringBoardTitle(NSString *action) {
    if ([action hasPrefix:TGMenuPrefix]) return tgMenuNames[[action substringFromIndex:TGMenuPrefix.length]] ?: @"Menu";
    if ([action hasPrefix:TGAppPrefix]) {
        id controller = TGShared("SBApplicationController");
        NSString *identifier = [action substringFromIndex:TGAppPrefix.length];
        id app = [controller respondsToSelector:@selector(applicationWithBundleIdentifier:)] ? [controller performSelector:@selector(applicationWithBundleIdentifier:) withObject:identifier] : nil;
        id name = [app respondsToSelector:@selector(displayName)] ? [app performSelector:@selector(displayName)] : nil;
        return [@"Open " stringByAppendingString:[name isKindOfClass:NSString.class] ? name : identifier];
    }
    return TGActionTitle(action);
}

static UIWindowScene *TGWindowScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)scene;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)scene;
    return nil;
}

static UIWindow *TGOverlayWindow(BOOL interactive) {
    UIWindowScene *scene = TGWindowScene();
    if (!scene) return nil;
    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.windowLevel = UIWindowLevelAlert + 1;
    window.backgroundColor = UIColor.clearColor;
    window.userInteractionEnabled = interactive;
    window.rootViewController = [UIViewController new];
    window.rootViewController.view.backgroundColor = UIColor.clearColor;
    return window;
}

static UIWindow *tgBannerWindow;
static NSUInteger tgBannerGeneration;

// A small pill at the top naming what ran; fades after ~1.3 s.
static void TGShowBanner(NSString *text) {
    [tgBannerWindow setHidden:YES];
    tgBannerWindow = TGOverlayWindow(NO);
    if (!tgBannerWindow) return;
    UIView *root = tgBannerWindow.rootViewController.view;
    UILabel *label = [UILabel new];
    label.text = [@"  " stringByAppendingString:[text stringByAppendingString:@"  "]];
    label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    label.textColor = UIColor.labelColor;
    label.backgroundColor = UIColor.secondarySystemBackgroundColor;
    label.layer.cornerRadius = 15;
    label.layer.masksToBounds = YES;
    label.textAlignment = NSTextAlignmentCenter;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor constant:6],
        [label.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [label.heightAnchor constraintEqualToConstant:30],
        [label.widthAnchor constraintLessThanOrEqualToAnchor:root.widthAnchor constant:-32],
    ]];
    tgBannerWindow.alpha = 0;
    tgBannerWindow.hidden = NO;
    [UIView animateWithDuration:0.2 animations:^{ tgBannerWindow.alpha = 1; }];
    NSUInteger generation = ++tgBannerGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != tgBannerGeneration) return;
        [UIView animateWithDuration:0.3 animations:^{ tgBannerWindow.alpha = 0; } completion:^(BOOL done) {
            if (generation != tgBannerGeneration) return;
            tgBannerWindow.hidden = YES;
            tgBannerWindow = nil;
        }];
    });
}

static UIWindow *tgMenuWindow;

static void TGCloseMenu(void) {
    tgMenuWindow.hidden = YES;
    tgMenuWindow = nil;
}

// A pop-up list of the menu's actions; the picked one runs (unlock rules apply).
static void TGShowMenu(NSString *menuID) {
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *item in tgAssignments[[TGMenuKeyPrefix stringByAppendingString:menuID]])
        if (![item hasPrefix:TGPausePrefix] && ![item hasPrefix:TGMenuPrefix] && TGCanPerform(item)) [items addObject:item];
    if (!items.count) return;
    TGCloseMenu();
    tgMenuWindow = TGOverlayWindow(YES);
    if (!tgMenuWindow) return;
    tgMenuWindow.hidden = NO;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:tgMenuNames[menuID] message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *item in items) {
        [sheet addAction:[UIAlertAction actionWithTitle:TGSpringBoardTitle(item) style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            TGCloseMenu();
            TGRunActions(@[item]);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) { TGCloseMenu(); }]];
    UIView *root = tgMenuWindow.rootViewController.view;
    sheet.popoverPresentationController.sourceView = root;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(root.bounds), CGRectGetMidY(root.bounds), 1, 1);
    [tgMenuWindow.rootViewController presentViewController:sheet animated:YES completion:nil];
}

static BOOL TGCallBool(id target, SEL selector);

static BOOL TGFire(NSString *trigger) {
    NSArray *actions = TGActionFor(trigger);
    if (!actions) return NO;
    if (tgShowBanners) {
        NSMutableArray *titles = [NSMutableArray array];
        for (NSString *action in actions)
            if (![action hasPrefix:TGPausePrefix] && ![action hasPrefix:TGMenuPrefix] && ![action isEqualToString:@"system.nothing"]) [titles addObject:TGSpringBoardTitle(action)];
        if (titles.count) TGShowBanner([titles componentsJoinedByString:@" + "]);
    }
    TGRunActions(actions);
    return YES;
}

#pragma mark - API (other tweaks and the triggr tool)

// Darwin notifications carry no payload, so SpringBoard listens for one name per
// thing that may be run: built-in actions, assigned triggers and menus. Never
// shell commands, URLs or apps. Only while "Allow API" is on.
static NSMutableArray<NSNumber *> *tgAPITokens;

static void TGListenAPI(NSString *name, void (^handler)(void)) {
    int token;
    if (notify_register_dispatch([@TGAPIPrefix stringByAppendingString:name].UTF8String, &token, dispatch_get_main_queue(), ^(int t) {
        handler();
    }) == NOTIFY_STATUS_OK) [tgAPITokens addObject:@(token)];
}

static void TGUpdateAPI(void) {
    for (NSNumber *token in tgAPITokens) notify_cancel(token.intValue);
    tgAPITokens = [NSMutableArray array];
    if (!tgAllowAPI) return;
    for (int g = 0; g < TG_COUNT(TGActionGroups); g++) {
        for (int i = 0; i < TGActionGroups[g].count; i++) {
            NSString *action = @(TGActionGroups[g].items[i].identifier);
            TGListenAPI([@"run/" stringByAppendingString:action], ^{
                if (TGCanPerform(action)) TGRunActions(@[action]);
            });
        }
    }
    for (NSString *trigger in tgAssignedTriggers) TGListenAPI([@"trigger/" stringByAppendingString:trigger], ^{ TGFire(trigger); });
    for (NSString *menuID in tgMenuNames) TGListenAPI([@"menu/" stringByAppendingString:menuID], ^{ TGRunActions(@[[TGMenuPrefix stringByAppendingString:menuID]]); });
}

#pragma mark - Home button
// With Replace Button Actions on (the default) an assigned press replaces iOS's
// action; with it off, iOS acts first and Triggr runs alongside.

static const CFTimeInterval TGMultiPressWindow = 0.35;
// Status bar double tap window (0.3 split some real double taps).
static const CFTimeInterval TGTapWindow = 0.35;
static const CFTimeInterval TGShortHoldMinimum = 0.35;

static CFTimeInterval tgHomeDownAt;
static BOOL tgHomeLongFired;
static BOOL tgHomeSwallowSingle;  // after a short hold or a triple press
static BOOL tgHomeAwaitingTriple; // a double press is waiting to see if a third follows
static NSUInteger tgHomeGeneration;

%hook SBHomeHardwareButton
- (void)initialButtonDown:(id)recognizer {
    if (tgHomeAwaitingTriple) {
        // Third press inside the window: it's a triple.
        tgHomeAwaitingTriple = NO;
        tgHomeGeneration++;
        tgHomeSwallowSingle = tgReplaces;
        TGFire(@"home.triple");
    }
    tgHomeDownAt = CACurrentMediaTime();
    tgHomeLongFired = NO;
    %orig;
}
- (void)initialButtonUp:(id)recognizer {
    CFTimeInterval held = CACurrentMediaTime() - tgHomeDownAt;
    if (!tgHomeLongFired && held >= TGShortHoldMinimum && TGFire(@"home.shorthold")) tgHomeSwallowSingle = tgReplaces;
    %orig;
}
%end

%hook SBHomeHardwareButtonActions
- (void)performSinglePressUpActions {
    if (tgHomeSwallowSingle) {
        tgHomeSwallowSingle = NO;
        return;
    }
    if (!tgReplaces) {
        %orig;
        TGFire(@"home.single");
        return;
    }
    if (TGFire(@"home.single")) return;
    %orig;
}
- (void)performDoublePressDownActions {
    if (!tgReplaces) {
        %orig;
        if (!TGActionFor(@"home.triple")) {
            TGFire(@"home.double");
            return;
        }
        // iOS has had its double press; Triggr still waits to tell double from triple.
        tgHomeAwaitingTriple = YES;
        NSUInteger generation = ++tgHomeGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(TGMultiPressWindow * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!tgHomeAwaitingTriple || generation != tgHomeGeneration) return;
            tgHomeAwaitingTriple = NO;
            TGFire(@"home.double");
        });
        return;
    }
    if (TGActionFor(@"home.triple")) {
        // iOS never reports a triple here: wait briefly for a third press.
        tgHomeAwaitingTriple = YES;
        NSUInteger generation = ++tgHomeGeneration;
        void (^systemDouble)(void) = ^{
            %orig;
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(TGMultiPressWindow * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!tgHomeAwaitingTriple || generation != tgHomeGeneration) return;
            tgHomeAwaitingTriple = NO;
            if (!TGFire(@"home.double")) systemDouble();
        });
        return;
    }
    if (TGFire(@"home.double")) return;
    %orig;
}
- (void)performLongPressActions {
    tgHomeLongFired = YES;
    if (!tgReplaces) {
        %orig;
        TGFire(@"home.longhold");
        return;
    }
    if (TGFire(@"home.longhold")) return;
    %orig;
}
// A light double tap on the Touch ID sensor (no click), which normally toggles
// Reachability (verified on iOS 16.7). Single taps and holds aren't reported.
- (void)performDoubleTapUpActions {
    if (!tgReplaces) {
        %orig;
        TGFire(@"touchid.doubletap");
        return;
    }
    if (TGFire(@"touchid.doubletap")) return;
    %orig;
}
%end

#pragma mark - Volume buttons (an assigned press replaces the volume change, or runs alongside with Replace off)

static const CFTimeInterval TGHoldDelay = 0.5; // iOS's own long press

typedef struct {
    BOOL down;
    CFTimeInterval downAt;
    BOOL calledSystemOnDown; // the system saw the press, so it must see the release
    BOOL holdFired;
    BOOL partOfBoth; // the other button went down while this one was held
    NSUInteger generation;
} TGVolumeState;

static TGVolumeState tgVolume[2]; // 0 = up, 1 = down

#pragma mark Both volume buttons

// SpringBoard's volume handling lets only one button count: when the second goes
// down it reports the first as released (verified on iOS 16.7), so the button
// hooks never see both. The raw button events do: each lists every press still
// down (type 102 = up, 103 = down; verified). Checked only while a both-buttons
// trigger is assigned.
static BOOL tgBothDown, tgBothHoldFired;
static NSUInteger tgBothGeneration;

static void TGCheckBothVolume(UIPressesEvent *event) {
    BOOL up = NO, down = NO;
    for (UIPress *press in event.allPresses) {
        if (press.phase > UIPressPhaseStationary) continue; // ended or cancelled
        if (press.type == 102) up = YES;
        else if (press.type == 103) down = YES;
    }
    BOOL both = up && down;
    if (both == tgBothDown) return;
    tgBothDown = both;
    BOOL holdAssigned = TGActionFor(@"volume.bothhold") != nil;
    if (both) {
        tgVolume[0].partOfBoth = tgVolume[1].partOfBoth = YES;
        tgBothHoldFired = NO;
        NSUInteger generation = ++tgBothGeneration;
        if (!holdAssigned) {
            TGFire(@"volume.both");
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(TGHoldDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!tgBothDown || generation != tgBothGeneration) return;
            tgBothHoldFired = YES;
            TGFire(@"volume.bothhold");
        });
    } else if (holdAssigned && !tgBothHoldFired) {
        TGFire(@"volume.both"); // released before the hold: a press
    }
}

static BOOL TGVolumeBegan(int which) {
    NSString *press = which == 0 ? @"volume.up" : @"volume.down";
    NSString *hold = which == 0 ? @"volume.uphold" : @"volume.downhold";
    TGVolumeState *state = &tgVolume[which];
    *state = (TGVolumeState){ .down = YES, .downAt = CACurrentMediaTime(), .generation = state->generation + 1 };
    if (tgBothDown) {
        // Second button of a both-buttons press: keep it away from the system when replacing.
        state->partOfBoth = YES;
        state->calledSystemOnDown = !tgReplaces;
        return state->calledSystemOnDown;
    }

    if (TGActionFor(hold)) {
        NSUInteger generation = state->generation;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(TGHoldDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            TGVolumeState *s = &tgVolume[which];
            if (!s->down || s->generation != generation || s->partOfBoth) return;
            s->holdFired = YES;
            TGFire(hold);
        });
    }
    state->calledSystemOnDown = !tgReplaces || TGActionFor(press) == nil;
    return state->calledSystemOnDown;
}

// Up, then Down (or the reverse): two short presses, the second released within
// TGSequenceWindow of the first. Observed only; the presses themselves are untouched.
static const CFTimeInterval TGSequenceWindow = 0.6;
static int tgVolumeLastTap = -1;
static CFTimeInterval tgVolumeLastTapAt;

static void TGVolumeTapped(int which) {
    CFTimeInterval now = CACurrentMediaTime();
    if (tgVolumeLastTap == 1 - which && now - tgVolumeLastTapAt < TGSequenceWindow && TGFire(which == 1 ? @"volume.updown" : @"volume.downup")) {
        tgVolumeLastTap = -1;
        return;
    }
    tgVolumeLastTap = which;
    tgVolumeLastTapAt = now;
}

static BOOL TGVolumeEnded(int which) {
    NSString *press = which == 0 ? @"volume.up" : @"volume.down";
    TGVolumeState *state = &tgVolume[which];
    state->down = NO;
    if (state->holdFired || state->partOfBoth) tgVolumeLastTap = -1;
    else if ([tgAssignedTriggers containsObject:@"volume.updown"] || [tgAssignedTriggers containsObject:@"volume.downup"]) TGVolumeTapped(which);
    if ((!state->calledSystemOnDown || !tgReplaces) && !state->holdFired && !state->partOfBoth) TGFire(press);
    return state->calledSystemOnDown;
}

%hook SBVolumeHardwareButton
- (void)volumeIncreasePress:(UIGestureRecognizer *)recognizer {
    BOOL passToSystem = YES;
    if (recognizer.state == UIGestureRecognizerStateBegan) passToSystem = TGVolumeBegan(0);
    else if (recognizer.state == UIGestureRecognizerStateEnded || recognizer.state == UIGestureRecognizerStateCancelled) passToSystem = TGVolumeEnded(0);
    if (passToSystem) {
        %orig;
    }
}
- (void)volumeDecreasePress:(UIGestureRecognizer *)recognizer {
    BOOL passToSystem = YES;
    if (recognizer.state == UIGestureRecognizerStateBegan) passToSystem = TGVolumeBegan(1);
    else if (recognizer.state == UIGestureRecognizerStateEnded || recognizer.state == UIGestureRecognizerStateCancelled) passToSystem = TGVolumeEnded(1);
    if (passToSystem) {
        %orig;
    }
}
%end

#pragma mark - Lock button
// With Replace Button Actions on (the default), an assigned press or hold runs
// instead of iOS's, like Activator. With it off, every press goes to iOS
// untouched and Triggr's actions run alongside, after the presses stop.
//
// Replacing only skips iOS's reaction to a press: the button-down events that
// Emergency SOS counts, the hold with a volume button and the force restart
// never pass through these methods. A press that starts on a dark screen is
// never replaced, so the button always wakes the phone, and four or more
// presses are left to iOS.
//
// Verified on iOS 16.7: a press is performInitialButtonDownActions (which wakes
// a dark screen) and then singlePress:, whose own work is what locks.

// How long after a lock press another one still counts towards a double /
// triple, and so how long a press waits when Double or Triple is assigned.
// Real quick presses on an iPhone 7 came 216-313 ms apart.
static const CFTimeInterval TGLockPressWindow = 0.4;
static NSUInteger tgLockPresses;
static CFTimeInterval tgLockLastPress;
static NSUInteger tgLockGeneration;
static BOOL tgLockHoldReplaced;
static BOOL tgLockScreenWasOn = YES; // when the button went down
static BOOL tgLockDimmed;             // Triple → Sleep went dark early, the real Sleep is pending

// Triple → Sleep can't run until the wait rules out a 4th press (Emergency SOS),
// and Sleep has to end the SOS press count iOS keeps. So the third press only
// turns the backlight off, which leaves SOS alone; the wait then sleeps for real,
// or a 4th press turns the backlight straight back on.
static BOOL TGSetBacklight(float factor) {
    id backlight = TGShared("SBBacklightController");
    SEL animate = @selector(_animateBacklightToFactor:duration:source:silently:completion:);
    if (![backlight respondsToSelector:animate]) return NO;
    ((void (*)(id, SEL, float, double, long long, BOOL, id))objc_msgSend)(backlight, animate, factor, 0.18, 3, NO, nil);
    return YES;
}

static BOOL TGScreenIsOn(void) {
    id backlight = TGShared("SBBacklightController");
    return ![backlight respondsToSelector:@selector(screenIsOn)] || ((BOOL (*)(id, SEL))objc_msgSend)(backlight, @selector(screenIsOn));
}

static BOOL TGLockPressInUse(void) {
    return [tgAssignedTriggers containsObject:@"lock.single"] || [tgAssignedTriggers containsObject:@"lock.double"] || [tgAssignedTriggers containsObject:@"lock.triple"];
}

%hook SBLockHardwareButtonActions
- (void)performInitialButtonDownActions {
    if (tgLockDimmed) {
        // A 4th press: no Sleep after all. Light the screen and drop the pending triple.
        tgLockDimmed = NO;
        tgLockGeneration++;
        TGSetBacklight(1);
    }
    tgLockScreenWasOn = TGScreenIsOn(); // read before iOS wakes the screen for this press
    %orig;
}
%end

%hook SBLockHardwareButton
- (void)singlePress:(id)recognizer {
    BOOL woke = !tgLockScreenWasOn; // this press only woke the phone; it isn't a trigger
    if (!TGLockPressInUse() || (woke && tgReplaces)) {
        %orig;
        return;
    }
    BOOL replace = tgReplaces && (TGActionFor(@"lock.single") || TGActionFor(@"lock.double") || TGActionFor(@"lock.triple"));
    BOOL multiple = TGActionFor(@"lock.double") || TGActionFor(@"lock.triple");
    if (replace && !multiple) {
        // Only Single Press is assigned: nothing to wait for.
        TGFire(@"lock.single");
        return;
    }
    if (!replace) %orig;
    void (^system)(void) = ^{
        %orig;
    };
    CFTimeInterval now = CACurrentMediaTime();
    tgLockPresses = (now - tgLockLastPress < TGLockPressWindow) ? tgLockPresses + 1 : 1;
    tgLockLastPress = now;
    NSUInteger generation = ++tgLockGeneration;
    if (replace && tgLockPresses == 3 && [TGActionFor(@"lock.triple").firstObject isEqualToString:@"system.sleep"]
        && [TGSleepWakeInteraction() respondsToSelector:@selector(_performSleep)] && TGSetBacklight(0)) {
        tgLockDimmed = YES;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(TGLockPressWindow * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != tgLockGeneration) return;
        NSUInteger count = tgLockPresses;
        tgLockPresses = 0;
        BOOL dimmed = tgLockDimmed;
        tgLockDimmed = NO;
        if (count > 3) return; // Emergency SOS territory; never act on it
        if (count == 1 && woke) return;
        BOOL ran = TGFire(count == 1 ? @"lock.single" : count == 2 ? @"lock.double" : @"lock.triple");
        if (dimmed && !ran) TGSetBacklight(1); // the Sleep didn't happen after all
        // Replacing, but this many presses has nothing assigned: iOS gets its press after all.
        if (!ran && replace) {
            system();
        }
    });
}
- (void)longPress:(UIGestureRecognizer *)recognizer {
    // Called when the hold begins and again when it ends: act once.
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        tgLockHoldReplaced = tgReplaces && tgLockScreenWasOn && TGFire(@"lock.longhold");
        if (tgLockHoldReplaced) return;
        %orig;
        if (!tgReplaces) TGFire(@"lock.longhold");
        return;
    }
    if (tgLockHoldReplaced) {
        if (recognizer.state != UIGestureRecognizerStateChanged) tgLockHoldReplaced = NO;
        return; // iOS never saw this hold begin
    }
    %orig;
}
%end

#pragma mark - Mute switch
// A flip arrives as -[SpringBoard _ringerChanged:] (the hardware event), which
// applies it through _updateRingerState:withVisuals:updatePreferenceRegister:
// (state 1 = Ring, 0 = Silent; verified on iOS 15.8 against isRingerMuted).
// With Replace Button Actions on, an assigned flip skips that, so the ringer
// keeps its state; the Mute switch action changes it in software. With it off,
// iOS mutes first and Triggr runs alongside (from the ringer HUD, as before).

static BOOL tgRingerFromSwitch;
static BOOL tgRingerReplaced;

static BOOL TGMuteSwitchFire(long long state) {
    return TGFire(state ? @"mute.ring" : @"mute.silent") || TGFire(@"mute.toggle");
}

%hook SpringBoard
- (void)_ringerChanged:(void *)event {
    tgRingerFromSwitch = YES;
    tgRingerReplaced = NO;
    %orig;
    tgRingerFromSwitch = NO;
}
- (void)_updateRingerState:(int)state withVisuals:(BOOL)visuals updatePreferenceRegister:(BOOL)update {
    if (tgRingerFromSwitch && tgReplaces && TGMuteSwitchFire(state)) {
        tgRingerReplaced = YES;
        return;
    }
    %orig;
}
%end

%hook SBRingerControl
- (void)activateRingerHUDFromMuteSwitch:(long long)state {
    %orig;
    if (tgRingerReplaced) return; // already ran instead of the switch
    TGMuteSwitchFire(state);
}
%end

#pragma mark - Touch ID (runs alongside: unlocking is untouched)

static CFTimeInterval tgLastFingerRest;

%hook SBUIBiometricResource
- (void)_notifyObserversOfEvent:(unsigned long long)event {
    %orig;
    if (![tgAssignedTriggers containsObject:@"touchid.rest"] && ![tgAssignedTriggers containsObject:@"touchid.match"]) return;
    // Verified on-device: 1 / 6 = finger down, 4 = match, 2 / 10 = no match.
    if (event == 1 || event == 6) {
        CFTimeInterval now = CACurrentMediaTime();
        if (now - tgLastFingerRest > 1.0) {
            tgLastFingerRest = now;
            TGFire(@"touchid.rest");
        }
    } else if (event == 4) {
        TGFire(@"touchid.match");
    }
}
%end

#pragma mark - Status bar
// Taps arrive from SpringBoard's own status bar (home / lock screen) and, via a
// Darwin notification, from apps (each app handles its own status bar). Single
// vs double is decided here by timing, so both sources behave the same.

static NSUInteger tgStatusBarGeneration;
static CFTimeInterval tgStatusBarLastTap;
static BOOL tgStatusBarPendingSingle;

static BOOL TGStatusBarInUse(void) {
    return [tgAssignedTriggers containsObject:@"statusbar.tap"] || [tgAssignedTriggers containsObject:@"statusbar.doubletap"];
}

// Hold: iOS reports a held status bar as a plain tap when it's let go (in apps
// too: the action's type is the same), so SpringBoard times the touch itself.
// After a hold has run, the tap that follows is the same touch and is dropped.
static const CFTimeInterval TGStatusBarHoldTime = 0.5;
static BOOL tgStatusBarHeld;
static CFTimeInterval tgStatusBarHoldEndedAt;

static void TGStatusBarHoldBegan(void) {
    if (![tgAssignedTriggers containsObject:@"statusbar.hold"]) return;
    tgStatusBarHeld = YES;
    TGFire(@"statusbar.hold");
}

static void TGStatusBarHoldEnded(void) {
    if (!tgStatusBarHeld) return;
    tgStatusBarHeld = NO;
    tgStatusBarHoldEndedAt = CACurrentMediaTime();
}

static void TGStatusBarTapped(void) {
    CFTimeInterval now = CACurrentMediaTime();
    // The release of a hold that already ran (the app's report comes a moment later).
    if (tgStatusBarHeld || now - tgStatusBarHoldEndedAt < 0.6) { tgStatusBarHoldEndedAt = 0; tgStatusBarHeld = NO; return; }
    if (!TGStatusBarInUse()) return;
    if (tgStatusBarPendingSingle && now - tgStatusBarLastTap < TGTapWindow) {
        tgStatusBarPendingSingle = NO;
        tgStatusBarGeneration++; // cancel the pending single tap
        TGFire(@"statusbar.doubletap");
        return;
    }
    tgStatusBarLastTap = now;
    if (!TGActionFor(@"statusbar.doubletap")) {
        TGFire(@"statusbar.tap");
        return;
    }
    tgStatusBarPendingSingle = YES;
    NSUInteger generation = ++tgStatusBarGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(TGTapWindow * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != tgStatusBarGeneration || !tgStatusBarPendingSingle) return;
        tgStatusBarPendingSingle = NO;
        TGFire(@"statusbar.tap");
    });
}

@interface TGStatusBarHoldTarget : NSObject
@end
@implementation TGStatusBarHoldTarget
+ (void)held:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan) TGStatusBarHoldBegan();
    else if (recognizer.state == UIGestureRecognizerStateEnded || recognizer.state == UIGestureRecognizerStateCancelled) TGStatusBarHoldEnded();
}
@end

// Every status bar SpringBoard draws (Home Screen, Lock Screen, and the ones
// over apps, which live in the switcher's window) gets one hold recognizer.
static const void *TGHoldRecognizerKey = &TGHoldRecognizerKey;
%hook UIStatusBar_Modern
- (void)didMoveToWindow {
    %orig;
    UIView *bar = (UIView *)self;
    if (!bar.window || objc_getAssociatedObject(bar, TGHoldRecognizerKey)) return;
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:TGStatusBarHoldTarget.class action:@selector(held:)];
    hold.minimumPressDuration = TGStatusBarHoldTime;
    hold.cancelsTouchesInView = NO; // taps go on to iOS as before
    [bar addGestureRecognizer:hold];
    objc_setAssociatedObject(bar, TGHoldRecognizerKey, hold, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
%end
%hook UIStatusBarWindow
- (void)sendEvent:(UIEvent *)event {
    if (event.type == UIEventTypeTouches && TGStatusBarInUse() && event.allTouches.anyObject.phase == UITouchPhaseEnded) {
        TGStatusBarTapped();
    }
    %orig;
}
%end

#pragma mark - Shake
// The Relay library reports iOS's own shake events from whichever app (or
// SpringBoard) is in front; nothing here touches the motion sensors.

static CFTimeInterval tgLastShake;

static void TGShaken(void) {
    CFTimeInterval now = CACurrentMediaTime();
    if (now - tgLastShake < 1.0) return; // one shake can be reported more than once
    tgLastShake = now;
    TGFire(@"motion.shake");
}

#pragma mark - Home Screen icon flicks
// One small recognizer per icon view, added only while a flick is assigned. It
// decides within the first few points of movement: an assigned direction runs
// its action (and the touch goes no further), anything else fails at once, so
// taps, long presses, page swipes and Search behave as before.

static BOOL tgWantIconFlicks;
static const CGFloat TGFlickDistance = 9;        // just under a scroll view's own threshold
static const CFTimeInterval TGFlickTime = 0.3;   // slower than this is a drag, not a flick

// Apps and folders on the Home Screen, in folders and in the Dock; not widgets,
// the App Library or icons being rearranged.
static BOOL TGIconFlickAllowed(UIView *iconView) {
    if (TGCallBool(iconView, @selector(isEditing))) return NO;
    id icon = [iconView respondsToSelector:@selector(icon)] ? [iconView performSelector:@selector(icon)] : nil;
    if (TGCallBool(icon, @selector(isWidgetIcon))) return NO;
    id location = [iconView respondsToSelector:@selector(location)] ? [iconView performSelector:@selector(location)] : nil;
    if (![location isKindOfClass:NSString.class]) return NO;
    for (NSString *allowed in @[@"SBIconLocationRoot", @"SBIconLocationDock", @"SBIconLocationFloatingDock", @"SBIconLocationFolder"])
        if ([location hasPrefix:allowed]) return YES;
    return NO;
}

// A flick assigned to this app's icon comes first, then the plain flick.
static BOOL TGFireFlick(UIView *iconView, NSString *trigger) {
    id icon = [iconView respondsToSelector:@selector(icon)] ? [iconView performSelector:@selector(icon)] : nil;
    id app = [icon respondsToSelector:@selector(applicationBundleID)] ? [icon performSelector:@selector(applicationBundleID)] : nil;
    return ([app isKindOfClass:NSString.class] && TGFire([NSString stringWithFormat:@"%@:%@", trigger, app])) || TGFire(trigger);
}

@interface TGFlickRecognizer : UIGestureRecognizer
@end

@implementation TGFlickRecognizer {
    CGPoint _start;
    CFTimeInterval _startedAt;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!tgWantIconFlicks || self.numberOfTouches != 1) {
        self.state = UIGestureRecognizerStateFailed;
        return;
    }
    _start = [touches.anyObject locationInView:self.view];
    _startedAt = CACurrentMediaTime();
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    CGPoint point = [touches.anyObject locationInView:self.view];
    CGFloat dx = point.x - _start.x, dy = point.y - _start.y;
    if (dx * dx + dy * dy < TGFlickDistance * TGFlickDistance) return;
    NSString *trigger = fabs(dx) > fabs(dy) ? (dx < 0 ? @"icon.flickleft" : @"icon.flickright") : (dy < 0 ? @"icon.flickup" : @"icon.flickdown");
    BOOL flick = CACurrentMediaTime() - _startedAt < TGFlickTime && TGIconFlickAllowed(self.view) && TGFireFlick(self.view, trigger);
    self.state = flick ? UIGestureRecognizerStateRecognized : UIGestureRecognizerStateFailed;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.state = UIGestureRecognizerStateFailed;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.state = UIGestureRecognizerStateFailed;
}

@end

static void TGAttachFlick(UIView *iconView) {
    for (UIGestureRecognizer *recognizer in iconView.gestureRecognizers) if ([recognizer isKindOfClass:TGFlickRecognizer.class]) return;
    [iconView addGestureRecognizer:[TGFlickRecognizer new]];
}

// Icon views already on screen when a flick is first assigned.
static void TGAttachFlicksIn(UIView *view, Class iconViewClass) {
    if ([view isKindOfClass:iconViewClass]) {
        TGAttachFlick(view);
        return;
    }
    for (UIView *subview in view.subviews) TGAttachFlicksIn(subview, iconViewClass);
}

static void TGUpdateIconFlicks(BOOL want) {
    if (want == tgWantIconFlicks) return;
    tgWantIconFlicks = want; // recognizers already attached stay, and fail at once while this is off
    Class iconViewClass = objc_getClass("SBIconView");
    if (!want || !iconViewClass) return;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass:UIWindowScene.class])
            for (UIWindow *window in ((UIWindowScene *)scene).windows) TGAttachFlicksIn(window, iconViewClass);
}

%hook SBIconView
- (void)addGesturesAndInteractionsIfNecessary {
    %orig;
    if (tgWantIconFlicks) TGAttachFlick(self);
}
%end

static BOOL tgWatchApps; // an "app.launched:" trigger is assigned
static NSString *tgFrontApp;
static void TGFireMatching(NSString *prefix, NSString *value);

%hook SpringBoard
// The front app changed (verified on iOS 16.7: an SBApplication, nil for the Home Screen).
- (void)frontDisplayDidChange:(id)display {
    %orig;
    id identifier = [display respondsToSelector:@selector(bundleIdentifier)] ? [display performSelector:@selector(bundleIdentifier)] : nil;
    NSString *app = [identifier isKindOfClass:NSString.class] ? identifier : nil;
    if (app && ![app isEqualToString:tgCurrentApp]) { // remembered for Last App
        tgPreviousApp = tgCurrentApp;
        tgCurrentApp = app;
    }
    if (!tgWatchApps) return;
    if (app && ![app isEqualToString:tgFrontApp]) TGFireMatching(TGAppLaunchedPrefix, app);
    tgFrontApp = app;
}
- (BOOL)_handlePhysicalButtonEvent:(UIPressesEvent *)event {
    if ((tgBothDown || [tgAssignedTriggers containsObject:@"volume.both"] || [tgAssignedTriggers containsObject:@"volume.bothhold"])
        && [event isKindOfClass:UIPressesEvent.class]) TGCheckBothVolume(event);
    return %orig;
}
%end

#pragma mark - Other Events (charger, headphones)

// Public notifications only, observed only while one of these triggers is
// assigned. Both run alongside the system.
static id tgPowerObserver, tgRouteObserver;
static BOOL tgPluggedIn, tgHeadphones;

static BOOL TGIsPluggedIn(void) {
    UIDeviceBatteryState state = UIDevice.currentDevice.batteryState;
    return state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull;
}

static BOOL TGIsHeadphonePort(AVAudioSessionPortDescription *port) {
    NSString *type = port.portType;
    return [type isEqualToString:AVAudioSessionPortHeadphones] || [type isEqualToString:AVAudioSessionPortBluetoothA2DP]
        || [type isEqualToString:AVAudioSessionPortBluetoothHFP] || [type isEqualToString:AVAudioSessionPortBluetoothLE];
}

static BOOL TGRouteHasHeadphones(AVAudioSessionRouteDescription *route) {
    for (AVAudioSessionPortDescription *port in route.outputs) if (TGIsHeadphonePort(port)) return YES;
    return NO;
}

static BOOL TGAssignedAny(NSString *a, NSString *b) {
    return [tgAssignedTriggers containsObject:a] || [tgAssignedTriggers containsObject:b];
}

#pragma mark - State Changes

// Fires only on a real change, and not right after Triggr ran an action itself,
// so e.g. Bluetooth Off -> Toggle Bluetooth can't loop.
static void TGStateChanged(BOOL *previous, BOOL now, NSString *onTrigger, NSString *offTrigger) {
    if (now == *previous) return;
    *previous = now;
    int family = TGStateFamily(onTrigger);
    if (family >= 0 && CACurrentMediaTime() - tgCausedAt[family] < 1.0) {
        return;
    }
    TGFire(now ? onTrigger : offTrigger);
}

static BOOL TGCallBool(id target, SEL selector) {
    return [target respondsToSelector:selector] && ((BOOL (*)(id, SEL))objc_msgSend)(target, selector);
}

// Wi-Fi: SBWiFiManager (private, guarded). Its link notification fires on
// connect/disconnect (verified); power changes are read at the same time.
static BOOL tgWiFiOn, tgWiFiJoined;
static NSString *tgWiFiName;
static NSString *TGReadWiFi(BOOL *on, BOOL *joined) {
    id wifi = TGShared("SBWiFiManager");
    *on = TGCallBool(wifi, @selector(wiFiEnabled));
    id name = [wifi respondsToSelector:@selector(currentNetworkName)] ? ((id (*)(id, SEL))objc_msgSend)(wifi, @selector(currentNetworkName)) : nil;
    if (![name isKindOfClass:NSString.class] || ![name length]) name = nil;
    *joined = name != nil;
    return name;
}

#pragma mark Custom events

// Any assigned trigger starting with `prefix`? (the assigned set is small)
static BOOL TGAssignedPrefix(NSString *prefix) {
    for (NSString *trigger in tgAssignedTriggers) if ([trigger hasPrefix:prefix]) return YES;
    return NO;
}

// Fire every assigned "<prefix><value>" whose value matches, ignoring case.
static void TGFireMatching(NSString *prefix, NSString *value) {
    if (!value.length) return;
    for (NSString *trigger in tgAssignedTriggers.copy)
        if ([trigger hasPrefix:prefix] && [[trigger substringFromIndex:prefix.length] caseInsensitiveCompare:value] == NSOrderedSame) TGFire(trigger);
}

static NSString *TGBluetoothDeviceName(NSNotification *n) {
    id device = n.object;
    id name = [device respondsToSelector:@selector(name)] ? [device performSelector:@selector(name)] : nil;
    return [name isKindOfClass:NSString.class] ? name : nil;
}

// IOKit's power source calls are exported on iOS but the SDK has no header for them.
extern CFTypeRef IOPSCopyPowerSourcesInfo(void);
extern CFArrayRef IOPSCopyPowerSourcesList(CFTypeRef blob);
extern CFDictionaryRef IOPSGetPowerSourceDescription(CFTypeRef blob, CFTypeRef source);
#define TGBatteryPercentNotification "com.apple.system.powersources.percent" // kIOPSNotifyPercentChange

// The battery level in whole percent, as the status bar shows it, or -1. Read
// from IOKit; UIDevice's level is only the fallback, because SpringBoard doesn't
// reliably keep it (or its change notification) up to date for itself.
static int TGBatteryPercent(void) {
    int percent = -1;
    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    NSArray *sources = blob ? CFBridgingRelease(IOPSCopyPowerSourcesList(blob)) : nil;
    for (id source in sources) {
        NSDictionary *description = (__bridge NSDictionary *)IOPSGetPowerSourceDescription(blob, (__bridge CFTypeRef)source);
        id current = description[@"Current Capacity"], max = description[@"Max Capacity"];
        if (![current respondsToSelector:@selector(doubleValue)] || ![max respondsToSelector:@selector(doubleValue)] || [max doubleValue] <= 0) continue;
        percent = (int)lround([current doubleValue] * 100.0 / [max doubleValue]);
        break;
    }
    if (blob) CFRelease(blob);
    if (percent < 0) {
        float level = UIDevice.currentDevice.batteryLevel;
        if (level >= 0) percent = (int)lroundf(level * 100);
    }
    return percent;
}

// Battery: fires when the level crosses a threshold, compared in whole percent.
static int tgBatteryPercent = -1;
static void TGBatteryLevelChanged(void) {
    int level = TGBatteryPercent();
    int previous = tgBatteryPercent;
    if (level < 0 || level == previous) return;
    tgBatteryPercent = level;
    if (previous < 0) return;
    for (NSString *trigger in tgAssignedTriggers.copy) {
        BOOL above = [trigger hasPrefix:TGBatteryAbovePrefix], below = [trigger hasPrefix:TGBatteryBelowPrefix];
        if (!above && !below) continue;
        int threshold = [[trigger substringFromIndex:(above ? TGBatteryAbovePrefix : TGBatteryBelowPrefix).length] intValue];
        // "Above 80" fires on reaching 81 and "Below 65" on reaching 64, as the
        // titles say. Above 100 can't happen, so it means reaching 100.
        int edge = above ? MIN(threshold + 1, 100) : MAX(threshold - 1, 0);
        if ((above && previous < edge && level >= edge) || (below && previous > edge && level <= edge)) TGFire(trigger);
    }
}

// Scheduled: one timer for the nearest time; fires only within 5 minutes of it.
static NSTimer *tgTimeTimer;
static id tgTimeObserver;

static BOOL TGDayMatches(NSString *days, NSDate *date) {
    NSInteger weekday = [NSCalendar.currentCalendar component:NSCalendarUnitWeekday fromDate:date]; // 1 = Sunday
    BOOL weekend = weekday == 1 || weekday == 7;
    if ([days isEqualToString:@"weekdays"]) return !weekend;
    if ([days isEqualToString:@"weekends"]) return weekend;
    return YES;
}

// The next date (after `after`) this time trigger is due, or nil.
static NSDate *TGNextDate(NSString *trigger, NSDate *after) {
    int hour, minute;
    NSString *days;
    if (!TGParseTime(trigger, &hour, &minute, &days)) return nil;
    NSCalendar *calendar = NSCalendar.currentCalendar;
    for (int offset = 0; offset < 8; offset++) {
        NSDate *day = [calendar dateByAddingUnit:NSCalendarUnitDay value:offset toDate:after options:0];
        NSDate *candidate = [calendar dateBySettingHour:hour minute:minute second:0 ofDate:day options:0];
        if ([candidate compare:after] == NSOrderedDescending && TGDayMatches(days, candidate)) return candidate;
    }
    return nil;
}

static void TGScheduleTimes(void);

static void TGTimeTimerFired(NSDate *target) {
    NSTimeInterval late = -target.timeIntervalSinceNow;
    if (late < 300) {
        for (NSString *trigger in tgAssignedTriggers.copy) {
            NSDate *due = TGNextDate(trigger, [target dateByAddingTimeInterval:-1]);
            if (due && fabs([due timeIntervalSinceDate:target]) < 1) TGFire(trigger);
        }
    }
    TGScheduleTimes();
}

static void TGScheduleTimes(void) {
    [tgTimeTimer invalidate];
    tgTimeTimer = nil;
    NSDate *now = [NSDate date], *next = nil;
    for (NSString *trigger in tgAssignedTriggers) {
        if (![trigger hasPrefix:TGTimePrefix]) continue;
        NSDate *due = TGNextDate(trigger, now);
        if (due && (!next || [due compare:next] == NSOrderedAscending)) next = due;
    }
    if (next) {
        tgTimeTimer = [[NSTimer alloc] initWithFireDate:next interval:0 repeats:NO block:^(NSTimer *timer) { TGTimeTimerFired(next); }];
        tgTimeTimer.tolerance = 1;
        [NSRunLoop.mainRunLoop addTimer:tgTimeTimer forMode:NSRunLoopCommonModes];
    }
    // Clock or time zone changes: reschedule.
    if (next && !tgTimeObserver) {
        tgTimeObserver = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationSignificantTimeChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { TGScheduleTimes(); }];
    } else if (!next && tgTimeObserver) {
        [NSNotificationCenter.defaultCenter removeObserver:tgTimeObserver];
        tgTimeObserver = nil;
    }
}

static BOOL tgBluetoothOn, tgLowPowerOn, tgLocked;
static id tgWiFiObserver, tgBluetoothObserver, tgLowPowerObserver;
static id tgBTConnectObserver, tgBTDisconnectObserver, tgBatteryObserver;
static int tgLockToken = -1, tgBatteryToken = -1, tgScreenToken = -1;
static BOOL tgScreenOff;

static void TGObserve(BOOL want, id __strong *observer, NSString *name, void (^block)(void)) {
    if (want && !*observer) {
        *observer = [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { block(); }];
    } else if (!want && *observer) {
        [NSNotificationCenter.defaultCenter removeObserver:*observer];
        *observer = nil;
    }
}

static void TGObserveNote(BOOL want, id __strong *observer, NSString *name, void (^block)(NSNotification *)) {
    if (want && !*observer) {
        *observer = [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:block];
    } else if (!want && *observer) {
        [NSNotificationCenter.defaultCenter removeObserver:*observer];
        *observer = nil;
    }
}

static void TGUpdateStateEvents(void) {
    BOOL wantWiFi = TGAssignedAny(@"wifi.on", @"wifi.off") || TGAssignedAny(@"wifi.joined", @"wifi.left")
        || TGAssignedPrefix(TGWiFiJoinedPrefix) || TGAssignedPrefix(TGWiFiLeftPrefix);
    if (wantWiFi && !tgWiFiObserver) tgWiFiName = TGReadWiFi(&tgWiFiOn, &tgWiFiJoined);
    TGObserve(wantWiFi, &tgWiFiObserver, @"SBWifiManagerLinkDidChangeNotification", ^{
        BOOL on, joined;
        NSString *name = TGReadWiFi(&on, &joined);
        TGStateChanged(&tgWiFiOn, on, @"wifi.on", @"wifi.off");
        TGStateChanged(&tgWiFiJoined, joined, @"wifi.joined", @"wifi.left");
        if (!(name == tgWiFiName || [name isEqualToString:tgWiFiName])) {
            NSString *previous = tgWiFiName;
            tgWiFiName = name;
            TGFireMatching(TGWiFiLeftPrefix, previous);
            TGFireMatching(TGWiFiJoinedPrefix, name);
        }
    });

    // Specific Bluetooth devices (BluetoothManager notifications, verified on iOS 16.7).
    TGObserveNote(TGAssignedPrefix(TGBTConnectedPrefix), &tgBTConnectObserver, @"BluetoothDeviceConnectSuccessNotification", ^(NSNotification *n) {
        TGFireMatching(TGBTConnectedPrefix, TGBluetoothDeviceName(n));
    });
    TGObserveNote(TGAssignedPrefix(TGBTDisconnectedPrefix), &tgBTDisconnectObserver, @"BluetoothDeviceDisconnectSuccessNotification", ^(NSNotification *n) {
        TGFireMatching(TGBTDisconnectedPrefix, TGBluetoothDeviceName(n));
    });

    // Battery level: powerd's Darwin notification for a percent change, plus the
    // public UIDevice one. Both only say "look again"; the level is compared once.
    BOOL wantBattery = TGAssignedPrefix(TGBatteryAbovePrefix) || TGAssignedPrefix(TGBatteryBelowPrefix);
    if (wantBattery && !tgBatteryObserver) {
        UIDevice.currentDevice.batteryMonitoringEnabled = YES; // never turned off: SpringBoard may rely on it
        tgBatteryPercent = TGBatteryPercent();
    }
    TGObserve(wantBattery, &tgBatteryObserver, UIDeviceBatteryLevelDidChangeNotification, ^{ TGBatteryLevelChanged(); });
    if (wantBattery && tgBatteryToken == -1) {
        if (notify_register_dispatch(TGBatteryPercentNotification, &tgBatteryToken, dispatch_get_main_queue(), ^(int token) { TGBatteryLevelChanged(); }) != NOTIFY_STATUS_OK) tgBatteryToken = -1;
    } else if (!wantBattery && tgBatteryToken != -1) {
        notify_cancel(tgBatteryToken);
        tgBatteryToken = -1;
    }

    // App opened: SpringBoard's frontDisplayDidChange: hook checks this flag.
    tgWatchApps = TGAssignedPrefix(TGAppLaunchedPrefix);

    TGScheduleTimes();

    BOOL wantBluetooth = TGAssignedAny(@"bluetooth.on", @"bluetooth.off");
    if (wantBluetooth && !tgBluetoothObserver) tgBluetoothOn = TGCallBool(TGShared("BluetoothManager"), @selector(enabled));
    TGObserve(wantBluetooth, &tgBluetoothObserver, @"BluetoothStateChangedNotification", ^{
        BOOL on = TGCallBool(TGShared("BluetoothManager"), @selector(enabled));
        TGStateChanged(&tgBluetoothOn, on, @"bluetooth.on", @"bluetooth.off");
    });

    // Public API.
    BOOL wantLowPower = TGAssignedAny(@"lowpower.on", @"lowpower.off");
    if (wantLowPower && !tgLowPowerObserver) tgLowPowerOn = NSProcessInfo.processInfo.isLowPowerModeEnabled;
    TGObserve(wantLowPower, &tgLowPowerObserver, NSProcessInfoPowerStateDidChangeNotification, ^{
        TGStateChanged(&tgLowPowerOn, NSProcessInfo.processInfo.isLowPowerModeEnabled, @"lowpower.on", @"lowpower.off");
    });

    // Lock state: SpringBoard's Darwin notification; its state is 1 while locked.
    BOOL wantLock = TGAssignedAny(@"device.locked", @"device.unlocked");
    if (wantLock && tgLockToken == -1) {
        notify_register_dispatch("com.apple.springboard.lockstate", &tgLockToken, dispatch_get_main_queue(), ^(int token) {
            uint64_t state = 0;
            notify_get_state(token, &state);
            TGStateChanged(&tgLocked, state != 0, @"device.locked", @"device.unlocked");
        });
        uint64_t state = 0;
        notify_get_state(tgLockToken, &state);
        tgLocked = state != 0;
    } else if (!wantLock && tgLockToken != -1) {
        notify_cancel(tgLockToken);
        tgLockToken = -1;
    }

    // Screen: SpringBoard's Darwin notification; its state is 1 while the screen is off.
    BOOL wantScreen = TGAssignedAny(@"display.on", @"display.off");
    if (wantScreen && tgScreenToken == -1) {
        if (notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &tgScreenToken, dispatch_get_main_queue(), ^(int token) {
            uint64_t state = 0;
            notify_get_state(token, &state);
            TGStateChanged(&tgScreenOff, state != 0, @"display.off", @"display.on");
        }) != NOTIFY_STATUS_OK) {
            tgScreenToken = -1;
        } else {
            uint64_t state = 0;
            notify_get_state(tgScreenToken, &state);
            tgScreenOff = state != 0;
        }
    } else if (!wantScreen && tgScreenToken != -1) {
        notify_cancel(tgScreenToken);
        tgScreenToken = -1;
    }
}

static void TGUpdateOtherEvents(void) {
    TGUpdateStateEvents();
    TGUpdateIconFlicks(TGAssignedPrefix(@"icon.flick"));
    // Tell the in-app Relay which of its events anything is waiting for.
    static int relayToken = -1;
    if (relayToken == -1 && notify_register_check(TGRelayWanted, &relayToken) != NOTIFY_STATUS_OK) relayToken = -1;
    if (relayToken != -1) notify_set_state(relayToken, (TGStatusBarInUse() ? TGRelayWantsStatusBar : 0) | ([tgAssignedTriggers containsObject:@"motion.shake"] ? TGRelayWantsShake : 0));
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    BOOL wantPower = TGAssignedAny(@"power.connected", @"power.disconnected");
    if (wantPower && !tgPowerObserver) {
        // Turned on only; SpringBoard may rely on monitoring itself, so never turned off.
        UIDevice.currentDevice.batteryMonitoringEnabled = YES;
        tgPluggedIn = TGIsPluggedIn();
        tgPowerObserver = [center addObserverForName:UIDeviceBatteryStateDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            BOOL plugged = TGIsPluggedIn();
            if (plugged == tgPluggedIn) return; // e.g. charging -> full
            tgPluggedIn = plugged;
            TGFire(plugged ? @"power.connected" : @"power.disconnected");
        }];
    } else if (!wantPower && tgPowerObserver) {
        [center removeObserver:tgPowerObserver];
        tgPowerObserver = nil;
    }

    BOOL wantRoute = TGAssignedAny(@"headphones.in", @"headphones.out");
    if (wantRoute && !tgRouteObserver) {
        // AVAudioSession's own route-change notification doesn't reach SpringBoard;
        // SpringBoard's SBAudioRoutesChangedNotification does (verified on iOS 16.7),
        // and the public currentRoute is correct when it fires. It fires several
        // times per change, so act only when headphones appear or disappear.
        tgHeadphones = TGRouteHasHeadphones(AVAudioSession.sharedInstance.currentRoute);
        tgRouteObserver = [center addObserverForName:@"SBAudioRoutesChangedNotification" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            BOOL now = TGRouteHasHeadphones(AVAudioSession.sharedInstance.currentRoute);
            if (now == tgHeadphones) return;
            tgHeadphones = now;
            TGFire(now ? @"headphones.in" : @"headphones.out");
        }];
    } else if (!wantRoute && tgRouteObserver) {
        [center removeObserver:tgRouteObserver];
        tgRouteObserver = nil;
    }
}

%ctor {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    TGReadAssignments();
    int token;
    notify_register_dispatch(TGPrefsChangedNotification, &token, dispatch_get_main_queue(), ^(int t) { TGReadAssignments(); });
    int tapToken;
    int airPlayListToken;
    notify_register_dispatch(TGAirPlayListRequest, &airPlayListToken, dispatch_get_main_queue(), ^(int t) { TGWriteAirPlayList(); });
    notify_register_dispatch(TGRelayStatusBarTap, &tapToken, dispatch_get_main_queue(), ^(int t) {
        TGStatusBarTapped();
    });
    int shakeToken;
    notify_register_dispatch(TGRelayShake, &shakeToken, dispatch_get_main_queue(), ^(int t) { TGShaken(); });
    %init(_ungrouped);
}
