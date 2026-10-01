// The single catalogue of modes, triggers and actions, shared by Settings and
// the tweak so the two can never disagree about ids.
//
// Each assignment is its own key in the prefs domain:
//   "<mode>/<trigger id>" = "<action id>"   ("" = none)

#define TGDomain @"com.johndie.triggr"
#define TGPrefsChangedNotification "com.johndie.triggr/prefs-changed"
#define TGEnabledKey @"Enabled" // master switch, default on
#define TGRequireUnlockKey @"RequireUnlock" // Lock Screen: shell commands wait for unlock, default on
#define TGBlockedAppsKey @"BlockedApps"     // bundle ids where triggers are ignored
#define TGShowBannersKey @"ShowBanners"     // banner naming what ran, default off
#define TGMenusKey @"Menus"                 // [{id, name}]; items stored at "menu/<id>"
#define TGProfilesKey @"Profiles"           // {name: setup}
#define TGActiveProfileKey @"ActiveProfile"
#define TGAllowAPIKey @"AllowAPI"           // other tweaks / the triggr tool may run actions, default off
#define TGLockReplacesKey @"LockReplaces"   // assigned button presses replace iOS's own action (all buttons), default on
// API: notify_post(TGAPIPrefix "run/<action>" | "trigger/<trigger>" | "menu/<id>").
#define TGAPIPrefix "com.johndie.triggr/api/"

typedef struct { const char *identifier; const char *title; } TGItem;
typedef struct { const char *title; const TGItem *items; int count; const char *footer; } TGGroup;

#define TG_COUNT(a) ((int)(sizeof(a) / sizeof((a)[0])))

// Where an assignment applies, as in Activator.
static const TGItem TGModes[] = {
    {"anywhere", "Anywhere"},
    {"home",     "At Home Screen"},
    {"app",      "In Apps"},
    {"lock",     "At Lock Screen"},
};

static const TGItem TGHomeButton[] = {
    {"home.single", "Single Press"}, {"home.double", "Double Press"}, {"home.triple", "Triple Press"},
    {"home.shorthold", "Short Hold"}, {"home.longhold", "Long Hold"},
};
static const TGItem TGTouchID[] = {
    {"touchid.doubletap", "Light Double Tap"}, {"touchid.rest", "Finger Rest (Lock Screen)"}, {"touchid.match", "Finger Match (Lock Screen)"},
};
static const TGItem TGLockButton[] = {
    {"lock.single", "Single Press"}, {"lock.double", "Double Press"}, {"lock.triple", "Triple Press"}, {"lock.longhold", "Hold"},
};
static const TGItem TGVolume[] = {
    {"volume.up", "Up Press"}, {"volume.down", "Down Press"}, {"volume.uphold", "Up Hold"},
    {"volume.downhold", "Down Hold"}, {"volume.updown", "Up, then Down"}, {"volume.downup", "Down, then Up"},
    {"volume.both", "Press Both"}, {"volume.bothhold", "Hold Both"},
};
static const TGItem TGMuteSwitch[] = { {"mute.silent", "Switched to Silent"}, {"mute.ring", "Switched to Ring"}, {"mute.toggle", "Toggled"} };
static const TGItem TGStatusBar[] = { {"statusbar.tap", "Tap"}, {"statusbar.doubletap", "Double Tap"} };
// Shake rides on iOS's own shake detection, so no sensor runs for Triggr.
static const TGItem TGMotion[] = { {"motion.shake", "Shake Device"} };
// A quick flick that starts on a Home Screen icon (see TGFlickRecognizer).
static const TGItem TGIcons[] = {
    {"icon.flickup", "Flick Up"}, {"icon.flickdown", "Flick Down"}, {"icon.flickleft", "Flick Left"}, {"icon.flickright", "Flick Right"},
};
// Not offered: slide-in edge gestures and Home Screen pinches (they'd compete
// with system gestures), status bar swipes (apps draw their own status bar).
static const TGItem TGOther[] = {
    {"power.connected", "Charger Connected"}, {"power.disconnected", "Charger Disconnected"},
    {"headphones.in", "Headphones Connected"}, {"headphones.out", "Headphones Disconnected"},
};

static const TGItem TGStateChanges[] = {
    {"wifi.on", "Wi-Fi Turned On"}, {"wifi.off", "Wi-Fi Turned Off"},
    {"wifi.joined", "Joined Wi-Fi Network"}, {"wifi.left", "Left Wi-Fi Network"},
    {"bluetooth.on", "Bluetooth Turned On"}, {"bluetooth.off", "Bluetooth Turned Off"},
    {"lowpower.on", "Low Power Mode On"}, {"lowpower.off", "Low Power Mode Off"},
    {"device.locked", "Device Locked"}, {"device.unlocked", "Device Unlocked"},
    {"display.on", "Screen Turned On"}, {"display.off", "Screen Turned Off"},
};

static const TGGroup TGTriggerGroups[] = {
    {"Home Button", TGHomeButton, TG_COUNT(TGHomeButton), NULL},
    {"Touch ID", TGTouchID, TG_COUNT(TGTouchID), "Light Double Tap is touching the sensor twice without clicking. iOS doesn't report single taps or holds while unlocked. Finger Rest and Match only work on the Lock Screen and run alongside unlocking."},
    {"Lock Button", TGLockButton, TG_COUNT(TGLockButton), NULL},
    {"Volume Buttons", TGVolume, TG_COUNT(TGVolume), "Up, then Down (and the reverse) are two quick presses; they always run alongside, and the volume ends where it started."},
    {"Mute Switch", TGMuteSwitch, TG_COUNT(TGMuteSwitch), "With Replace on, the switch's position and the ringer can differ until you flip it back."},
    {"Status Bar", TGStatusBar, TG_COUNT(TGStatusBar), "Works on the Home Screen, Lock Screen and inside apps. A single tap still scrolls to the top."},
    {"Home Screen Icons", TGIcons, TG_COUNT(TGIcons), "A quick flick that starts on an app or folder icon on the Home Screen or in the Dock. Widgets, the App Library and jiggle mode are left alone. Flick Left and Flick Right take over page swipes that start on an icon."},
    {"Motion", TGMotion, TG_COUNT(TGMotion), "Uses iOS's own shake detection (the one behind Shake to Undo), so it costs no battery. Works while the phone is unlocked and awake; Shake to Undo still appears where an app offers it."},
    {"Charger & Headphones", TGOther, TG_COUNT(TGOther), "Taking an AirPod out can count as Headphones Disconnected, because iOS moves the sound to the speaker."},
    {"State Changes", TGStateChanges, TG_COUNT(TGStateChanges), "Runs after the change. Control Center's Wi-Fi button only disconnects from the network (Left Wi-Fi Network); Wi-Fi stays on. Changes caused by Triggr's own actions are ignored for a second, so assignments can't loop."},
};

static const TGItem TGSystemActions[] = {
    {"system.home", "Go to Home Screen"}, {"system.switcher", "App Switcher"},
    {"system.lastapp", "Last App"}, {"system.quitapp", "Quit Current App"},
    {"system.cc", "Control Center"}, {"system.nc", "Notification Center"}, {"system.spotlight", "Spotlight"},
    {"system.reachability", "Reachability"}, {"system.siri", "Siri"}, {"system.screenshot", "Take Screenshot"},
    {"system.vibrate", "Vibrate"}, {"system.nothing", "Do Nothing"},
};
static const TGItem TGPowerActions[] = {
    {"system.sleep", "Sleep"}, {"system.lock", "Lock Device"}, {"system.respring", "Respring"}, {"system.powerdown", "Power Off Slider"},
    {"system.safemode", "Safe Mode"}, {"system.restart", "Restart"}, {"system.poweroff", "Power Off"},
};
// Switches: toggle.<name>, on.<name>, off.<name> (like Activator's Flipswitch actions).
// Siri: no safe SpringBoard entry point found yet.
#define TG_SWITCHES(X) \
    X("flashlight", "Flashlight") X("wifi", "Wi-Fi") X("bluetooth", "Bluetooth") X("airplane", "Airplane Mode") \
    X("cellular", "Cellular Data") X("dnd", "Do Not Disturb") X("lowpower", "Low Power Mode") X("rotation", "Rotation Lock") \
    X("mute", "Mute") X("darkmode", "Dark Mode") X("nightshift", "Night Shift") X("autobrightness", "Auto-Brightness") \
    X("keepawake", "Keep Screen Awake") X("location", "Location Services")
#define TG_SWITCH_NAME(id, name) {id, name},
#define TG_SWITCH_TOGGLE(id, name) {"toggle." id, "Toggle " name},
#define TG_SWITCH_ON(id, name) {"on." id, name " On"},
#define TG_SWITCH_OFF(id, name) {"off." id, name " Off"},
static const TGItem TGSwitches[] = { TG_SWITCHES(TG_SWITCH_NAME) };
static const TGItem TGToggleActions[] = { TG_SWITCHES(TG_SWITCH_TOGGLE) };
static const TGItem TGOnActions[] = { TG_SWITCHES(TG_SWITCH_ON) };
static const TGItem TGOffActions[] = { TG_SWITCHES(TG_SWITCH_OFF) };
static const TGItem TGMediaActions[] = {
    {"media.playpause", "Play / Pause"}, {"media.next", "Next Track"}, {"media.previous", "Previous Track"},
    {"media.volup", "Volume Up"}, {"media.voldown", "Volume Down"},
};

static const TGGroup TGActionGroups[] = {
    {"System", TGSystemActions, TG_COUNT(TGSystemActions), NULL},
    {"Power", TGPowerActions, TG_COUNT(TGPowerActions), NULL},
    {"Toggle", TGToggleActions, TG_COUNT(TGToggleActions), NULL},
    {"Turn On", TGOnActions, TG_COUNT(TGOnActions), NULL},
    {"Turn Off", TGOffActions, TG_COUNT(TGOffActions), NULL},
    {"Media", TGMediaActions, TG_COUNT(TGMediaActions), NULL},
};

// Command actions carry their argument in the id: "<prefix><text>".
#define TGShortcutPrefix @"shortcut:"
#define TGURLPrefix @"url:"
#define TGShellPrefix @"shell:"
#define TGAppPrefix @"app:"
#define TGPausePrefix @"pause:" // "pause:<seconds>" between actions in a list
#define TGMenuPrefix @"menu:"   // "menu:<id>" shows that menu
#define TGMenuKeyPrefix @"menu/" // "menu/<id>" = the menu's items
// Custom event prefixes (see TGIsCustomTrigger).
#define TGWiFiJoinedPrefix @"wifi.joined:"
#define TGWiFiLeftPrefix @"wifi.left:"
#define TGBTConnectedPrefix @"bt.connected:"
#define TGBTDisconnectedPrefix @"bt.disconnected:"
#define TGBatteryAbovePrefix @"battery.above:"
#define TGBatteryBelowPrefix @"battery.below:"
#define TGAppLaunchedPrefix @"app.launched:"
#define TGTimePrefix @"time:"
// A flick on one app's icon: "icon.flickup:<bundle id>" (runs instead of the plain flick).
#define TGIconFlickUpPrefix @"icon.flickup:"
#define TGIconFlickDownPrefix @"icon.flickdown:"
#define TGIconFlickLeftPrefix @"icon.flickleft:"
#define TGIconFlickRightPrefix @"icon.flickright:"
// Actions with a value.
#define TGBrightnessPrefix @"brightness:"     // 0-100
#define TGMediaVolumePrefix @"volume.media:"  // 0-100
#define TGRingerVolumePrefix @"volume.ringer:" // 0-100
#define TGMessagePrefix @"message:"
#define TGSpeakPrefix @"speak:"
#define TGSettingsPrefix @"settings:" // App-prefs page id

// Settings pages for "Open Settings Page" (App-prefs:<id>, verified to open Settings on iOS 16.7).
static const TGItem TGSettingsPages[] = {
    {"WIFI", "Wi-Fi"}, {"Bluetooth", "Bluetooth"}, {"MOBILE_DATA_SETTINGS_ID", "Cellular"},
    {"NOTIFICATIONS_ID", "Notifications"}, {"Sounds", "Sounds & Haptics"}, {"General", "General"},
    {"ControlCenter", "Control Center"}, {"DISPLAY", "Display & Brightness"}, {"Wallpaper", "Wallpaper"},
    {"BATTERY_USAGE", "Battery"}, {"Privacy", "Privacy & Security"},
};
#define TGPauseMax 30.0

// Actions that open an app. iOS can't show them over the Lock Screen (verified:
// Open App does nothing there), so on the Lock Screen they wait for unlock.
static inline BOOL TGActionOpensApp(NSString *action) {
    return [action hasPrefix:TGAppPrefix] || [action hasPrefix:TGURLPrefix] || [action hasPrefix:TGShortcutPrefix] || [action hasPrefix:TGSettingsPrefix];
}

// Pauses only make sense between actions: drop leading and trailing ones and
// collapse repeats (used after an action is removed).
static inline NSMutableArray<NSString *> *TGTidyPauses(NSArray<NSString *> *actions) {
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *action in actions) {
        BOOL pause = [action hasPrefix:TGPausePrefix];
        if (pause && (result.count == 0 || [result.lastObject hasPrefix:TGPausePrefix])) continue;
        [result addObject:action];
    }
    while ([result.lastObject hasPrefix:TGPausePrefix]) [result removeLastObject];
    return result;
}

// What a button or the mute switch does by itself, which is what happens while
// nothing is assigned to it (nil: nothing, or not a button trigger).
static inline NSString *TGDefaultActionTitle(NSString *trigger) {
    return @{
        @"home.single": @"Go Home", @"home.double": @"App Switcher", @"home.triple": @"Accessibility Shortcut",
        @"home.longhold": @"Siri", @"touchid.doubletap": @"Reachability",
        @"volume.up": @"Volume Up", @"volume.down": @"Volume Down",
        @"lock.single": @"Lock", @"lock.longhold": @"Power Off Slider",
        @"mute.silent": @"Mute", @"mute.ring": @"Unmute", @"mute.toggle": @"Mute / Unmute",
    }[trigger];
}

// What assigning an action to a trigger does to the button's own action (shown in
// the action picker). Button triggers depend on Replace Button Actions.
static inline NSString *TGTriggerWarning(NSString *trigger, BOOL replaces) {
    NSDictionary *buttons = replaces ? @{
        @"home.single": @"Runs instead of going Home (or waking) wherever this assignment applies. To go Home as well, add Go to Home Screen.",
        @"home.double": @"Runs instead of the App Switcher. To open it as well, add App Switcher.",
        @"touchid.doubletap": @"Runs instead of Reachability (the light double tap). To keep it, add Reachability.",
        @"home.triple": @"Runs instead of the Accessibility Shortcut, and double presses wait a moment to see if a third follows.",
        @"home.longhold": @"Runs instead of Siri. To keep Siri, add Siri.",
        @"volume.up": @"Runs instead of turning the volume up. To change it as well, add Volume Up (Media).",
        @"volume.down": @"Runs instead of turning the volume down. To change it as well, add Volume Down (Media).",
        @"volume.both": @"Hold one volume button and press the other. The second button won't change the volume; the first may still move it one step.",
        @"volume.bothhold": @"Both volume buttons held for 0.5 s. The second button won't change the volume; the first may still move it one step.",
        @"lock.single": @"Runs instead of locking while the screen is on. To lock as well, add Sleep.",
        @"lock.double": @"Single presses wait a moment to see if another follows.",
        @"lock.triple": @"Single and double presses wait a moment to see if another follows.",
        @"lock.longhold": @"Runs instead of the power-off slider. To show it as well, add Power Off Slider.",
        @"mute.silent": @"Runs instead of muting, so the ringer stays on. To mute as well, add Mute On (Switches).",
        @"mute.ring": @"Runs instead of unmuting, so the ringer stays off. To unmute as well, add Mute Off (Switches).",
        @"mute.toggle": @"Runs instead of muting or unmuting. To change it as well, add Toggle Mute (Switches).",
    } : @{
        @"home.single": @"Runs alongside the normal press, which still goes Home.",
        @"home.double": @"Runs alongside the App Switcher.",
        @"touchid.doubletap": @"Runs alongside Reachability.",
        @"home.triple": @"Runs alongside the Accessibility Shortcut.",
        @"home.longhold": @"Runs alongside Siri.",
        @"volume.up": @"Runs alongside the volume change.",
        @"volume.down": @"Runs alongside the volume change.",
        @"volume.both": @"Hold one volume button and press the other. Both still change the volume.",
        @"volume.bothhold": @"Both volume buttons held for 0.5 s. Both still change the volume.",
        @"lock.single": @"Runs alongside every press, which still locks.",
        @"lock.double": @"Runs after the presses stop; each press still locks or wakes.",
        @"lock.triple": @"Runs after the presses stop; each press still locks or wakes.",
        @"lock.longhold": @"Runs alongside the power-off slider.",
        @"mute.silent": @"Runs alongside the switch, which still mutes.",
        @"mute.ring": @"Runs alongside the switch, which still unmutes.",
        @"mute.toggle": @"Runs alongside the switch, which still mutes and unmutes.",
    };
    if (buttons[trigger]) return replaces ? buttons[trigger] : [buttons[trigger] stringByAppendingString:@" To run instead, turn on Replace Button Actions in Options."];
    NSDictionary *warnings = @{
        @"home.shorthold": @"A hold that's released before Siri appears.",
        @"volume.uphold": @"Runs after holding for 0.5 s; the volume still changes by one step.",
        @"volume.downhold": @"Runs after holding for 0.5 s; the volume still changes by one step.",
        @"icon.flickleft": @"A swipe to the next page that starts on an icon runs this instead. Swipe between icons to change pages.",
        @"icon.flickright": @"A swipe to the previous page that starts on an icon runs this instead. Swipe between icons to change pages.",
        @"icon.flickdown": @"A swipe down for Search that starts on an icon runs this instead.",
        @"volume.updown": @"Press Up, then Down within half a second. Runs alongside the two presses.",
        @"volume.downup": @"Press Down, then Up within half a second. Runs alongside the two presses.",
        @"time": @"Runs at this time while Triggr is running. iOS can delay timers while the phone sleeps; if it's more than 5 minutes late, it's skipped.",
        @"battery": @"Runs once when the level passes this percentage, not on every change.",
        @"statusbar.tap": @"If Double Tap is also assigned, single taps wait a moment to see if a second follows.",
    };
    if ([trigger hasPrefix:TGTimePrefix]) return warnings[@"time"];
    if ([trigger hasPrefix:@"icon.flick"] && [trigger containsString:@":"]) return warnings[[trigger componentsSeparatedByString:@":"].firstObject];
    if ([trigger hasPrefix:TGBatteryAbovePrefix] || [trigger hasPrefix:TGBatteryBelowPrefix]) return warnings[@"battery"];
    return warnings[trigger];
}

// Display titles for any trigger or mode id.
// Custom events carry a value after the prefix: "wifi.joined:<network>",
// "bt.connected:<device>", "battery.above:<percent>", "app.launched:<bundle id>",
// "time:<HHMM>:<daily|weekdays|weekends>".

static inline NSArray<NSString *> *TGCustomPrefixes(void) {
    return @[TGWiFiJoinedPrefix, TGWiFiLeftPrefix, TGBTConnectedPrefix, TGBTDisconnectedPrefix,
        TGBatteryAbovePrefix, TGBatteryBelowPrefix, TGAppLaunchedPrefix, TGTimePrefix,
        TGIconFlickUpPrefix, TGIconFlickDownPrefix, TGIconFlickLeftPrefix, TGIconFlickRightPrefix];
}

static inline BOOL TGIsCustomTrigger(NSString *trigger) {
    for (NSString *prefix in TGCustomPrefixes())
        if ([trigger hasPrefix:prefix] && trigger.length > prefix.length) return YES;
    return NO;
}

static inline NSString *TGDaysTitle(NSString *days) {
    if ([days isEqualToString:@"weekdays"]) return @"Weekdays";
    if ([days isEqualToString:@"weekends"]) return @"Weekends";
    return @"Every Day";
}

// "time:0730:weekdays" -> hour 7, minute 30, days "weekdays"; NO if malformed.
static inline BOOL TGParseTime(NSString *trigger, int *hour, int *minute, NSString **days) {
    NSArray *parts = [[trigger substringFromIndex:MIN(TGTimePrefix.length, trigger.length)] componentsSeparatedByString:@":"];
    if (parts.count != 2 || [parts[0] length] != 4) return NO;
    int hhmm = [parts[0] intValue];
    *hour = hhmm / 100;
    *minute = hhmm % 100;
    *days = parts[1];
    return *hour < 24 && *minute < 60;
}

// "Flick Up" for "icon.flickup" or "icon.flickup:<bundle id>".
static inline NSString *TGFlickDirectionTitle(NSString *trigger) {
    NSString *direction = [trigger componentsSeparatedByString:@":"].firstObject;
    for (int i = 0; i < TG_COUNT(TGIcons); i++) if ([direction isEqualToString:@(TGIcons[i].identifier)]) return @(TGIcons[i].title);
    return direction;
}

static inline NSString *TGCustomTriggerTitle(NSString *trigger) {
    NSString *value = nil;
    for (NSString *prefix in TGCustomPrefixes()) if ([trigger hasPrefix:prefix]) value = [trigger substringFromIndex:prefix.length];
    if ([trigger hasPrefix:TGWiFiJoinedPrefix]) return [NSString stringWithFormat:@"Joined \u201c%@\u201d", value];
    if ([trigger hasPrefix:TGWiFiLeftPrefix]) return [NSString stringWithFormat:@"Left \u201c%@\u201d", value];
    if ([trigger hasPrefix:TGBTConnectedPrefix]) return [NSString stringWithFormat:@"Connected to \u201c%@\u201d", value];
    if ([trigger hasPrefix:TGBTDisconnectedPrefix]) return [NSString stringWithFormat:@"Disconnected from \u201c%@\u201d", value];
    if ([trigger hasPrefix:TGBatteryAbovePrefix]) return [NSString stringWithFormat:@"Battery Rises Above %@%%", value];
    if ([trigger hasPrefix:TGBatteryBelowPrefix]) return [NSString stringWithFormat:@"Battery Drops Below %@%%", value];
    if ([trigger hasPrefix:TGAppLaunchedPrefix]) return [@"Opened " stringByAppendingString:value];
    if ([trigger hasPrefix:@"icon.flick"]) return [NSString stringWithFormat:@"%@ on %@", TGFlickDirectionTitle(trigger), value];
    int hour, minute;
    NSString *days;
    if (TGParseTime(trigger, &hour, &minute, &days)) return [NSString stringWithFormat:@"%02d:%02d %@", hour, minute, TGDaysTitle(days)];
    return trigger;
}

static inline NSString *TGTriggerTitle(NSString *trigger) {
    if (TGIsCustomTrigger(trigger)) return TGCustomTriggerTitle(trigger);
    for (int g = 0; g < TG_COUNT(TGTriggerGroups); g++)
        for (int i = 0; i < TGTriggerGroups[g].count; i++)
            if ([trigger isEqualToString:@(TGTriggerGroups[g].items[i].identifier)]) {
                // Events ("Charger Connected") read fine alone; presses need their button.
                BOOL event = TGTriggerGroups[g].items == TGOther || TGTriggerGroups[g].items == TGStateChanges || TGTriggerGroups[g].items == TGMotion;
                if (TGTriggerGroups[g].items == TGIcons) return [NSString stringWithFormat:@"Icon %s", TGTriggerGroups[g].items[i].title];
                return event ? @(TGTriggerGroups[g].items[i].title) : [NSString stringWithFormat:@"%s %s", TGTriggerGroups[g].title, TGTriggerGroups[g].items[i].title];
            }
    return trigger;
}

// Home button and Touch ID triggers need a Home button (Touch ID is in it).
static inline BOOL TGTriggerFitsHardware(NSString *trigger, BOOL hasHomeButton) {
    if ([trigger hasPrefix:@"home."] || [trigger hasPrefix:@"touchid."]) return hasHomeButton;
    return YES;
}

// Only catalogue triggers count; keys left over from older versions are ignored.
static inline BOOL TGIsKnownTrigger(NSString *trigger) {
    if (TGIsCustomTrigger(trigger)) return YES;
    for (int g = 0; g < TG_COUNT(TGTriggerGroups); g++)
        for (int i = 0; i < TGTriggerGroups[g].count; i++)
            if ([trigger isEqualToString:@(TGTriggerGroups[g].items[i].identifier)]) return YES;
    return NO;
}

static inline NSString *TGModeTitle(NSString *mode) {
    for (int m = 0; m < TG_COUNT(TGModes); m++) if ([mode isEqualToString:@(TGModes[m].identifier)]) return @(TGModes[m].title);
    return mode;
}

static inline NSString *TGAssignmentKey(NSString *mode, NSString *trigger) {
    return [NSString stringWithFormat:@"%@/%@", mode, trigger];
}

// Display title for an action id ("None" when unassigned).
static inline NSString *TGActionTitle(NSString *action) {
    if (action.length == 0) return @"None";
    if ([action hasPrefix:TGShortcutPrefix]) return [@"Shortcut: " stringByAppendingString:[action substringFromIndex:TGShortcutPrefix.length]];
    if ([action hasPrefix:TGURLPrefix]) return [@"URL: " stringByAppendingString:[action substringFromIndex:TGURLPrefix.length]];
    if ([action hasPrefix:TGShellPrefix]) return [@"Command: " stringByAppendingString:[action substringFromIndex:TGShellPrefix.length]];
    if ([action hasPrefix:TGAppPrefix]) return [@"Open " stringByAppendingString:[action substringFromIndex:TGAppPrefix.length]];
    if ([action hasPrefix:TGPausePrefix]) return [NSString stringWithFormat:@"Pause %@ s", [action substringFromIndex:TGPausePrefix.length]];
    if ([action hasPrefix:TGMenuPrefix]) return @"Menu";
    if ([action hasPrefix:TGBrightnessPrefix]) return [NSString stringWithFormat:@"Brightness %@%%", [action substringFromIndex:TGBrightnessPrefix.length]];
    if ([action hasPrefix:TGMediaVolumePrefix]) return [NSString stringWithFormat:@"Media Volume %@%%", [action substringFromIndex:TGMediaVolumePrefix.length]];
    if ([action hasPrefix:TGRingerVolumePrefix]) return [NSString stringWithFormat:@"Ringer Volume %@%%", [action substringFromIndex:TGRingerVolumePrefix.length]];
    if ([action hasPrefix:TGMessagePrefix]) return [@"Message: " stringByAppendingString:[action substringFromIndex:TGMessagePrefix.length]];
    if ([action hasPrefix:TGSpeakPrefix]) return [@"Say: " stringByAppendingString:[action substringFromIndex:TGSpeakPrefix.length]];
    if ([action hasPrefix:TGSettingsPrefix]) {
        NSString *page = [action substringFromIndex:TGSettingsPrefix.length];
        for (int i = 0; i < TG_COUNT(TGSettingsPages); i++)
            if ([page isEqualToString:@(TGSettingsPages[i].identifier)]) return [@"Settings: " stringByAppendingString:@(TGSettingsPages[i].title)];
        return [@"Settings: " stringByAppendingString:page];
    }
    for (int g = 0; g < TG_COUNT(TGActionGroups); g++)
        for (int i = 0; i < TGActionGroups[g].count; i++)
            if ([action isEqualToString:@(TGActionGroups[g].items[i].identifier)]) return @(TGActionGroups[g].items[i].title);
    return action;
}
