// Triggr settings, laid out like Activator but with less scrolling:
//   Root (places) -> Place (what's assigned, one row per kind of trigger)
//     -> Trigger group (each trigger shows its action) -> Action picker (folded categories).

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <AltList/ATLApplicationListSelectionController.h>
#import <AltList/ATLApplicationListMultiSelectionController.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <dlfcn.h>
#import <notify.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "../Shared/TGCatalog.h"
#import "../Shared/TGHardware.h"

// Private (MobileCoreServices), used only for the app's display name; AltList
// itself relies on it.
@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
- (NSString *)localizedName;
@end

// [{id, name}] as stored under TGMenusKey.
static NSArray<NSDictionary *> *TGReadMenus(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)TGDomain);
    id menus = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)TGMenusKey, (__bridge CFStringRef)TGDomain));
    NSMutableArray *result = [NSMutableArray array];
    for (id menu in [menus isKindOfClass:NSArray.class] ? menus : @[])
        if ([menu isKindOfClass:NSDictionary.class] && [menu[@"id"] isKindOfClass:NSString.class]) [result addObject:menu];
    return result;
}

static NSString *TGDisplayTitle(NSString *action) {
    if ([action hasPrefix:TGMenuPrefix]) {
        NSString *menuID = [action substringFromIndex:TGMenuPrefix.length];
        for (NSDictionary *menu in TGReadMenus()) if ([menu[@"id"] isEqualToString:menuID]) return [@"Menu: " stringByAppendingString:[menu[@"name"] description]];
        return @"Menu (deleted)";
    }
    if ([action hasPrefix:TGAppPrefix]) {
        NSString *identifier = [action substringFromIndex:TGAppPrefix.length];
        // Looked up at runtime: nothing to link against, and a missing class just shows the id.
        Class proxyClass = NSClassFromString(@"LSApplicationProxy");
        LSApplicationProxy *proxy = [proxyClass respondsToSelector:@selector(applicationProxyForIdentifier:)] ? [proxyClass applicationProxyForIdentifier:identifier] : nil;
        NSString *name = [proxy respondsToSelector:@selector(localizedName)] ? [proxy localizedName] : nil;
        return [@"Open " stringByAppendingString:name.length ? name : identifier];
    }
    return TGActionTitle(action);
}

#pragma mark - Hardware

// Without a Home button (Face ID) there are no Home button or Touch ID triggers.
static BOOL TGShowsTriggerGroup(const TGGroup *group) {
    if (group->items == TGHomeButton || group->items == TGTouchID) return TGHasHomeButton();
    return YES;
}

// Lock button texts in Apple's words where there's no Home button: it's the side
// (or top) button, and holding it opens Siri instead of the power-off slider.
static NSString *TGButtonText(NSString *text) {
    if (!text || TGHasHomeButton()) return text;
    NSString *name = TGLockButtonName();
    text = [text stringByReplacingOccurrencesOfString:@"Lock Button" withString:name];
    text = [text stringByReplacingOccurrencesOfString:@"lock button" withString:name.lowercaseString];
    text = [text stringByReplacingOccurrencesOfString:@"showing the power-off slider" withString:@"opening Siri"];
    text = [text stringByReplacingOccurrencesOfString:@"the power-off slider" withString:@"Siri"];
    return [text stringByReplacingOccurrencesOfString:@"the slider" withString:@"Siri"];
}

#pragma mark - Storage

// Each assignment is its own key ("<mode>/<trigger>" = action id, "" = none),
// saved through PSListController's own preference API (setPreferenceValue: with
// the specifier's defaults/key/PostNotification), which is what persists
// reliably from Settings. A raw CFPreferencesSetAppValue from Settings did not.
static void TGConfigureStorage(PSSpecifier *spec, NSString *mode, NSString *trigger) {
    [spec setProperty:TGDomain forKey:@"defaults"];
    [spec setProperty:TGAssignmentKey(mode, trigger) forKey:@"key"];
    [spec setProperty:@TGPrefsChangedNotification forKey:@"PostNotification"];
}

// A stored assignment is one action (string) or several run in order (array).
static NSArray<NSString *> *TGActionList(id value) {
    NSMutableArray *actions = [NSMutableArray array];
    for (id item in [value isKindOfClass:NSArray.class] ? value : (value ? @[value] : @[]))
        if ([item isKindOfClass:NSString.class] && [item length]) [actions addObject:item];
    return actions;
}

static id TGStoredValue(NSArray<NSString *> *actions) {
    if (actions.count == 0) return @"";
    return actions.count == 1 ? actions.firstObject : actions.copy;
}

static NSString *TGListTitle(NSArray<NSString *> *actions) {
    if (actions.count == 0) return TGDisplayTitle(nil);
    NSMutableArray *titles = [NSMutableArray array];
    for (NSString *action in actions) [titles addObject:TGDisplayTitle(action)];
    return [titles componentsJoinedByString:@" + "];
}

static NSArray<NSString *> *TGReadAssignment(PSListController *list, NSString *mode, NSString *trigger) {
    PSSpecifier *spec = [PSSpecifier emptyGroupSpecifier];
    TGConfigureStorage(spec, mode, trigger);
    return TGActionList([list readPreferenceValue:spec]);
}

// A trigger row that opens the action picker for one mode/trigger.
static PSSpecifier *TGTriggerRow(NSString *name, id target, SEL getter, NSString *mode, NSString *trigger);
static PSSpecifier *TGSubtitled(PSSpecifier *spec);

// An app's name, looked up from its bundle id ("Open Music" -> "Music").
static NSString *TGAppName(NSString *identifier) {
    return [TGDisplayTitle([TGAppPrefix stringByAppendingString:identifier]) substringFromIndex:@"Open ".length];
}

static NSString *TGSettingsTriggerTitle(NSString *trigger) {
    if ([trigger hasPrefix:TGAppLaunchedPrefix]) return [@"Opened " stringByAppendingString:TGAppName([trigger substringFromIndex:TGAppLaunchedPrefix.length])];
    if ([trigger hasPrefix:@"icon.flick"] && TGIsCustomTrigger(trigger)) {
        NSRange colon = [trigger rangeOfString:@":"];
        return [NSString stringWithFormat:@"%@ on %@", TGFlickDirectionTitle(trigger), TGAppName([trigger substringFromIndex:colon.location + 1])];
    }
    return TGButtonText(TGTriggerTitle(trigger));
}

#pragma mark - Shared by every page

static NSArray<NSString *> *TGModeIdentifiers(void) {
    NSMutableArray *modes = [NSMutableArray array];
    for (int m = 0; m < TG_COUNT(TGModes); m++) [modes addObject:@(TGModes[m].identifier)];
    return modes;
}

// Every assignment that runs something on this device: "<mode>/<trigger>" -> actions.
static NSDictionary<NSString *, NSArray<NSString *> *> *TGAllAssignments(void) {
    CFStringRef domain = (__bridge CFStringRef)TGDomain;
    CFPreferencesAppSynchronize(domain);
    NSArray *keys = CFBridgingRelease(CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
    NSDictionary *values = keys.count ? CFBridgingRelease(CFPreferencesCopyMultiple((__bridge CFArrayRef)keys, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)) : @{};
    NSArray *modes = TGModeIdentifiers();
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    [values enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        NSRange slash = [key rangeOfString:@"/"];
        if (slash.location == NSNotFound || ![modes containsObject:[key substringToIndex:slash.location]]) return;
        NSString *trigger = [key substringFromIndex:slash.location + 1];
        if (!TGIsKnownTrigger(trigger) || !TGTriggerFitsHardware(trigger, TGHasHomeButton())) return;
        NSArray *actions = TGActionList(value);
        if (actions.count) result[key] = actions;
    }];
    return result;
}

// "…only work at the Home Screen", "…replace it inside apps".
static NSString *TGModePhrase(NSString *mode) {
    return @{ @"anywhere": @"everywhere", @"home": @"at the Home Screen", @"app": @"inside apps", @"lock": @"on the Lock Screen" }[mode] ?: @"there";
}

static NSString *TGCountTitle(NSUInteger count) {
    return count ? [NSString stringWithFormat:@"%lu", (unsigned long)count] : @"";
}

// A Settings-style icon: a white SF Symbol on a rounded colour square.
static void TGSetIcon(PSSpecifier *spec, NSString *symbol, UIColor *color) {
    UIImage *glyph = [UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightMedium]];
    if (!glyph) return;
    glyph = [glyph imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    CGSize size = CGSizeMake(29, 29);
    UIImage *icon = [[[UIGraphicsImageRenderer alloc] initWithSize:size] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [color setFill];
        [[UIBezierPath bezierPathWithRoundedRect:(CGRect){CGPointZero, size} cornerRadius:6.5] fill];
        CGFloat scale = MIN(1, MIN(21 / glyph.size.width, 21 / glyph.size.height));
        CGSize fitted = CGSizeMake(glyph.size.width * scale, glyph.size.height * scale);
        [glyph drawInRect:CGRectMake((size.width - fitted.width) / 2, (size.height - fitted.height) / 2, fitted.width, fitted.height)];
    }];
    [spec setProperty:icon forKey:@"iconImage"];
}

static PSSpecifier *TGSwitchRow(NSString *name, NSString *key, BOOL defaultValue, id target) {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:name target:target set:@selector(setPreferenceValue:specifier:)
        get:@selector(readPreferenceValue:) detail:nil cell:PSSwitchCell edit:nil];
    [spec setProperty:TGDomain forKey:@"defaults"];
    [spec setProperty:key forKey:@"key"];
    [spec setProperty:@(defaultValue) forKey:@"default"];
    [spec setProperty:@TGPrefsChangedNotification forKey:@"PostNotification"];
    return spec;
}

// Every Triggr page: reloads when you come back to it (so rows show what was
// picked deeper down) and lets subclasses offer a swipe action on a row.
@interface TGListController : PSListController
- (NSString *)swipeTitleForSpecifier:(PSSpecifier *)spec; // nil: this row can't be swiped
- (BOOL)swipedSpecifier:(PSSpecifier *)spec;              // do it; YES when the row goes away
- (BOOL)replacesButtons;
@end

@implementation TGListController

- (NSString *)swipeTitleForSpecifier:(PSSpecifier *)spec {
    return nil;
}

- (BOOL)swipedSpecifier:(PSSpecifier *)spec {
    return NO;
}

- (BOOL)replacesButtons {
    PSSpecifier *setting = [PSSpecifier emptyGroupSpecifier];
    [setting setProperty:TGDomain forKey:@"defaults"];
    [setting setProperty:TGLockReplacesKey forKey:@"key"];
    id value = [self readPreferenceValue:setting];
    return ![value respondsToSelector:@selector(boolValue)] || [value boolValue]; // on unless turned off
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSpecifiers];
}

// Shown on the right of a trigger row, like Activator. With nothing set in a
// specific place, Anywhere's assignment still applies, so show that one.
- (NSString *)assignedActionTitle:(PSSpecifier *)spec {
    NSArray *actions = TGActionList([self readPreferenceValue:spec]);
    if (actions.count) return TGListTitle(actions);
    NSString *mode = [spec propertyForKey:@"tgMode"];
    if (![mode isEqualToString:@"anywhere"]) {
        NSArray *anywhere = TGReadAssignment(self, @"anywhere", [spec propertyForKey:@"tgTrigger"]);
        if (anywhere.count) return [@"Anywhere: " stringByAppendingString:TGListTitle(anywhere)];
    }
    // Nothing assigned: the button keeps doing its own thing; say what that is.
    NSString *stock = TGDefaultActionTitle([spec propertyForKey:@"tgTrigger"]);
    return stock ? [@"Default: " stringByAppendingString:stock] : @"";
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self swipeTitleForSpecifier:[self specifierAtIndex:[self indexForIndexPath:indexPath]]] != nil;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self tableView:tableView canEditRowAtIndexPath:indexPath] ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *spec = [self specifierAtIndex:[self indexForIndexPath:indexPath]];
    NSString *title = [self swipeTitleForSpecifier:spec];
    if (!title) return [UISwipeActionsConfiguration configurationWithActions:@[]];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *action = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:title handler:^(UIContextualAction *a, UIView *view, void (^done)(BOOL)) {
        __strong typeof(self) strongSelf = weakSelf;
        BOOL removed = [strongSelf swipedSpecifier:spec];
        if (removed) [strongSelf removeSpecifier:spec animated:YES];
        done(removed);
        // Counts, headers and the rows left behind catch up once the row has gone.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf reloadSpecifiers]; });
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[action]];
}

@end

#pragma mark - Saved networks and devices (for Custom Events)

// Saved Wi-Fi networks: MobileWiFi's C API (private; verified in Settings on iOS
// 16.7, where WiFiKit's WFKnownNetworksManager returned nothing). Read on demand only.
static NSArray<NSString *> *TGSavedWiFiNetworks(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi", RTLD_LAZY);
    CFTypeRef (*create)(CFAllocatorRef, int) = handle ? dlsym(handle, "WiFiManagerClientCreate") : NULL;
    CFArrayRef (*copyNetworks)(CFTypeRef) = handle ? dlsym(handle, "WiFiManagerClientCopyNetworks") : NULL;
    CFStringRef (*getSSID)(CFTypeRef) = handle ? dlsym(handle, "WiFiNetworkGetSSID") : NULL;
    if (!create || !copyNetworks || !getSSID) return @[];
    NSMutableSet *names = [NSMutableSet set];
    CFTypeRef client = create(kCFAllocatorDefault, 0);
    CFArrayRef networks = client ? copyNetworks(client) : NULL;
    for (CFIndex i = 0; networks && i < CFArrayGetCount(networks); i++) {
        NSString *ssid = (__bridge NSString *)getSSID(CFArrayGetValueAtIndex(networks, i));
        if (ssid.length) [names addObject:ssid];
    }
    if (networks) CFRelease(networks);
    if (client) CFRelease(client);
    return [names.allObjects sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

// Paired Bluetooth devices: BluetoothManager (private, verified), guarded.
static NSArray<NSString *> *TGPairedBluetoothDevices(void) {
    dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager", RTLD_LAZY);
    Class managerClass = objc_getClass("BluetoothManager");
    id manager = [managerClass respondsToSelector:@selector(sharedInstance)] ? [managerClass performSelector:@selector(sharedInstance)] : nil;
    NSArray *devices = [manager respondsToSelector:@selector(pairedDevices)] ? [manager performSelector:@selector(pairedDevices)] : nil;
    NSMutableSet *names = [NSMutableSet set];
    for (id device in devices) {
        id name = [device respondsToSelector:@selector(name)] ? [device performSelector:@selector(name)] : nil;
        if ([name isKindOfClass:NSString.class] && [name length]) [names addObject:name];
    }
    return [names.allObjects sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

#pragma mark - Time picker (Scheduled events)

@interface TGTimePickerController : UIViewController
@property (nonatomic, copy) void (^onSave)(NSString *trigger);
@end

@implementation TGTimePickerController {
    UIDatePicker *_picker;
    UISegmentedControl *_days;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Scheduled Time";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self action:@selector(save)];
    _picker = [UIDatePicker new];
    _picker.datePickerMode = UIDatePickerModeTime;
    _picker.preferredDatePickerStyle = UIDatePickerStyleWheels;
    _days = [[UISegmentedControl alloc] initWithItems:@[@"Every Day", @"Weekdays", @"Weekends"]];
    _days.selectedSegmentIndex = 0;
    UILabel *note = [UILabel new];
    note.text = @"Runs at this time. iOS can delay timers while the phone sleeps; if it's more than 5 minutes late, it's skipped.";
    note.numberOfLines = 0;
    note.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    note.textColor = UIColor.secondaryLabelColor;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_picker, _days, note]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:guide.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-16],
    ]];
}

- (void)save {
    NSDateComponents *time = [NSCalendar.currentCalendar components:NSCalendarUnitHour | NSCalendarUnitMinute fromDate:_picker.date];
    NSString *days = @[@"daily", @"weekdays", @"weekends"][_days.selectedSegmentIndex];
    if (self.onSave) self.onSave([NSString stringWithFormat:@"%@%02ld%02ld:%@", TGTimePrefix, (long)time.hour, (long)time.minute, days]);
}

@end

#pragma mark - Conflict warnings

// Why adding `adding` to `list` probably won't do what the user expects, or nil.
static NSString *TGListWarning(NSArray<NSString *> *list, NSString *adding) {
    if ([list containsObject:@"system.respring"] || [list containsObject:@"system.safemode"])
        return @"Respring and Safe Mode restart SpringBoard, so actions after them won't run. Keep them last.";
    if ([adding isEqualToString:@"system.safemode"])
        return @"Safe Mode restarts SpringBoard with no tweaks, Triggr included, until you tap Dismiss on the Safe Mode screen.";
    NSArray *shutdown = @[@"system.restart", @"system.poweroff"];
    if ([list firstObjectCommonWithArray:shutdown]) return @"Nothing runs after a restart or power off. Keep it last.";
    if ([shutdown containsObject:adding])
        return @"This restarts or powers off the phone as soon as the trigger fires, without asking. The jailbreak stays off until you run Dopamine again.";
    // Toggle / On / Off of the same switch.
    NSArray *verbs = @[@"toggle", @"on", @"off"];
    NSRange dot = [adding rangeOfString:@"."];
    if (dot.location != NSNotFound && [verbs containsObject:[adding substringToIndex:dot.location]]) {
        NSString *name = [adding substringFromIndex:dot.location];
        for (NSString *item in list) {
            NSRange itemDot = [item rangeOfString:@"."];
            if (itemDot.location != NSNotFound && [verbs containsObject:[item substringToIndex:itemDot.location]] && [[item substringFromIndex:itemDot.location] isEqualToString:name])
                return [NSString stringWithFormat:@"%@ and %@ change the same switch, so only the last one sticks.", TGDisplayTitle(item), TGDisplayTitle(adding)];
        }
    }
    // Full-screen UI: only one can open at a time unless a pause separates them.
    NSSet *modal = [NSSet setWithArray:@[@"system.cc", @"system.nc", @"system.spotlight", @"system.switcher", @"system.reachability", @"system.siri", @"system.powerdown"]];
    BOOL (^isModal)(NSString *) = ^BOOL(NSString *action) { return [modal containsObject:action] || [action hasPrefix:TGAppPrefix] || [action hasPrefix:TGSettingsPrefix]; };
    if (isModal(adding)) {
        for (NSString *item in list.reverseObjectEnumerator) {
            if ([item hasPrefix:TGPausePrefix]) break;
            if (isModal(item))
                return [NSString stringWithFormat:@"%@ and %@ can't open at the same time. Add a pause between them in Order & Pauses.", TGDisplayTitle(item), TGDisplayTitle(adding)];
        }
    }
    return nil;
}

#pragma mark - Order & Pauses

@interface TGSequenceController : UITableViewController
@property (nonatomic, strong) NSMutableArray<NSString *> *items;
@property (nonatomic, copy) void (^onChange)(NSArray<NSString *> *items);
@end

@implementation TGSequenceController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Order & Pauses";
    self.tableView.editing = YES;
    self.tableView.allowsSelectionDuringEditing = YES;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Add Pause" style:UIBarButtonItemStylePlain target:self action:@selector(addPause)];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"item"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"item"];
    NSString *item = self.items[indexPath.row];
    cell.textLabel.text = TGDisplayTitle(item);
    cell.textLabel.textColor = [item hasPrefix:TGPausePrefix] ? UIColor.secondaryLabelColor : UIColor.labelColor;
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return self.items.count ? @"Actions run top to bottom. Drag to reorder. Tap an action to add a pause after it, or a pause to change it." : @"No actions yet: pick some first.";
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    NSString *item = self.items[from.row];
    [self.items removeObjectAtIndex:from.row];
    [self.items insertObject:item atIndex:to.row];
    [self changed];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (style != UITableViewCellEditingStyleDelete) return;
    BOOL wasPause = [self.items[indexPath.row] hasPrefix:TGPausePrefix];
    [self.items removeObjectAtIndex:indexPath.row];
    if (wasPause) {
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    } else {
        self.items = TGTidyPauses(self.items); // pauses around a removed action go too
        [tableView reloadData];
    }
    [self changed];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSInteger row = indexPath.row;
    if ([self.items[row] hasPrefix:TGPausePrefix]) {
        [self promptPauseAtIndex:row insert:NO];
        return;
    }
    // An action with another action after it: offer a pause between them.
    if (row + 1 < (NSInteger)self.items.count && ![self.items[row + 1] hasPrefix:TGPausePrefix]) {
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:TGDisplayTitle(self.items[row]) message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Add Pause After" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self promptPauseAtIndex:row + 1 insert:YES];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        sheet.popoverPresentationController.sourceView = cell;
        sheet.popoverPresentationController.sourceRect = cell.bounds;
        [self presentViewController:sheet animated:YES completion:nil];
    }
}

// Add Pause: between the last two actions that don't already have one, so no dragging is needed.
- (void)addPause {
    for (NSInteger i = (NSInteger)self.items.count - 1; i > 0; i--) {
        if (![self.items[i] hasPrefix:TGPausePrefix] && ![self.items[i - 1] hasPrefix:TGPausePrefix]) {
            [self promptPauseAtIndex:i insert:YES];
            return;
        }
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add Pause" message:@"Pauses go between two actions. Pick at least two actions first, or tap an action to add a pause after it." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// insert: a new pause at `index`; otherwise edit the pause at `index`.
- (void)promptPauseAtIndex:(NSInteger)index insert:(BOOL)insert {
    NSString *current = insert ? @"1" : [self.items[index] substringFromIndex:TGPausePrefix.length];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Pause" message:[NSString stringWithFormat:@"Seconds to wait before the next action (0.1–%g).", TGPauseMax] preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = current;
        field.keyboardType = UIKeyboardTypeDecimalPad;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *text = [weakAlert.textFields.firstObject.text stringByReplacingOccurrencesOfString:@"," withString:@"."];
        double seconds = MIN(MAX(text.doubleValue, 0.1), TGPauseMax);
        NSString *pause = [NSString stringWithFormat:@"%@%g", TGPausePrefix, seconds];
        if (insert) [self.items insertObject:pause atIndex:index];
        else self.items[index] = pause;
        [self.tableView reloadData];
        [self changed];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)changed {
    if (self.onChange) self.onChange(self.items.copy);
}

@end

#pragma mark - Action picker

// The picker keeps its long list folded into categories: tap one to open it
// (one at a time). Each shows what's picked inside it, and the search field
// finds any action.
static NSArray<NSArray<NSString *> *> *TGCategories(void) {
    return @[@[@"system", @"System"], @[@"power", @"Power"], @[@"switches", @"Switches"], @[@"media", @"Media"], @[@"levels", @"Levels"],
        @[@"open", @"Open"], @[@"text", @"Text & Commands"], @[@"menus", @"Menus"]];
}

static void TGSetCategoryIcon(PSSpecifier *spec, NSString *category) {
    NSDictionary<NSString *, NSArray *> *icons = @{
        @"system": @[@"house.fill", UIColor.systemBlueColor],
        @"power": @[@"power", UIColor.systemRedColor],
        @"switches": @[@"switch.2", UIColor.systemGreenColor],
        @"media": @[@"play.fill", UIColor.systemPinkColor],
        @"levels": @[@"slider.horizontal.3", UIColor.systemOrangeColor],
        @"open": @[@"arrow.up.right.square.fill", UIColor.systemIndigoColor],
        @"text": @[@"text.bubble.fill", UIColor.systemTealColor],
        @"menus": @[@"list.bullet.rectangle.fill", UIColor.systemPurpleColor],
    };
    if (icons[category]) TGSetIcon(spec, icons[category][0], icons[category][1]);
}

static NSString *TGCategoryOf(NSString *action) {
    if ([action hasPrefix:TGMenuPrefix]) return @"menus";
    for (NSString *prefix in @[TGBrightnessPrefix, TGMediaVolumePrefix, TGRingerVolumePrefix]) if ([action hasPrefix:prefix]) return @"levels";
    for (NSString *prefix in @[TGAppPrefix, TGSettingsPrefix, TGShortcutPrefix, TGURLPrefix]) if ([action hasPrefix:prefix]) return @"open";
    for (NSString *prefix in @[TGMessagePrefix, TGSpeakPrefix, TGShellPrefix]) if ([action hasPrefix:prefix]) return @"text";
    for (NSString *prefix in @[@"toggle.", @"on.", @"off."]) if ([action hasPrefix:prefix]) return @"switches";
    if ([action hasPrefix:@"media."]) return @"media";
    for (int i = 0; i < TG_COUNT(TGPowerActions); i++) if ([action isEqualToString:@(TGPowerActions[i].identifier)]) return @"power";
    if ([action hasPrefix:@"system."]) return @"system";
    return nil;
}

@interface TGActionPickerController : TGListController <UISearchResultsUpdating>
@end

@implementation TGActionPickerController {
    NSString *_mode;
    NSString *_trigger;
    BOOL _menuEditor;
    NSMutableArray<NSString *> *_selection; // in run order
    NSString *_expanded;                    // the open category, or nil
    NSString *_query;                       // search text, or nil
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.placeholder = @"Search Actions";
    search.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!query.length) query = nil;
    if (query == _query || [query isEqualToString:_query]) return;
    _query = query;
    [self reloadSpecifiers];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _mode = [self.specifier propertyForKey:@"tgMode"];
        _trigger = [self.specifier propertyForKey:@"tgTrigger"];
        _menuEditor = [self.specifier propertyForKey:@"tgMenuEditor"] != nil;
        _selection = [TGActionList([self readPreferenceValue:self.specifier]) mutableCopy];
        self.title = self.specifier.name;
        _specifiers = _query ? [self searchSpecifiers] : [self categorySpecifiers];
    }
    return _specifiers;
}

- (NSMutableArray *)categorySpecifiers {
    NSMutableArray *specs = [NSMutableArray array];
    NSMutableArray *notes = [NSMutableArray array];
    // Assignments outside Anywhere only work in their place; say so where it's picked.
    if (_mode && ![_mode isEqualToString:@"anywhere"]) [notes addObject:[NSString stringWithFormat:@"This assignment only works %@.", TGModePhrase(_mode)]];
    NSArray *anywhere = (!_mode || [_mode isEqualToString:@"anywhere"]) ? nil : TGReadAssignment(self, @"anywhere", _trigger);
    if (anywhere.count) [notes addObject:[NSString stringWithFormat:@"Anywhere runs %@ for this trigger. Actions picked here replace it %@; leave this empty to keep Anywhere's.", TGListTitle(anywhere), TGModePhrase(_mode)]];
    NSString *warning = TGTriggerWarning(_trigger, [self replacesButtons]);
    if (!_selection.count && TGDefaultActionTitle(_trigger)) warning = nil; // the empty-state note covers it
    if (warning) [notes addObject:TGButtonText(warning)];

    // What's picked, in run order, so it's visible without opening each category.
    PSSpecifier *picked = [PSSpecifier groupSpecifierWithName:_selection.count ? (_menuEditor ? @"In This Menu" : _selection.count > 1 ? @"Runs in This Order" : @"Selected") : nil];
    if (_selection.count) [notes insertObject:@"Swipe left on one to remove it." atIndex:0];
    else if (!_menuEditor && TGDefaultActionTitle(_trigger))
        [notes insertObject:[NSString stringWithFormat:[self replacesButtons]
            ? @"Nothing picked, so it does its normal thing (%@). Pick an action below to run instead, or Do Nothing (System) to turn it off."
            : @"Nothing picked, so it just does its normal thing (%@). Pick an action below to run alongside it.", TGDefaultActionTitle(_trigger)] atIndex:0];
    else [notes insertObject:_menuEditor ? @"Nothing in this menu yet. Open a category below and tap the actions it should offer."
        : @"Nothing picked yet. Open a category below and tap an action. Pick several to run them in order." atIndex:0];
    [picked setProperty:[notes componentsJoinedByString:@"\n\n"] forKey:@"footerText"];
    [specs addObject:picked];
    NSUInteger number = 0;
    for (NSString *item in _selection) {
        BOOL pause = [item hasPrefix:TGPausePrefix];
        NSString *title = TGDisplayTitle(item);
        if (!pause && _selection.count > 1) title = [NSString stringWithFormat:@"%lu.  %@", (unsigned long)++number, title];
        PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:title target:self set:nil get:nil detail:nil cell:PSListItemCell edit:nil];
        [row setProperty:item forKey:@"tgPicked"];
        [specs addObject:row];
    }
    if (_selection.count > 1) {
        PSSpecifier *order = [PSSpecifier preferenceSpecifierNamed:@"Order & Pauses" target:self set:nil get:nil detail:nil cell:PSListItemCell edit:nil];
        [order setProperty:@YES forKey:@"tgOrder"];
        [specs addObject:order];
        PSSpecifier *clear = [PSSpecifier preferenceSpecifierNamed:@"Remove All" target:self set:nil get:nil detail:nil cell:PSListItemCell edit:nil];
        [clear setProperty:@YES forKey:@"tgClear"];
        [specs addObject:clear];
    }
    [specs addObject:[PSSpecifier groupSpecifierWithName:@"Actions"]];
    for (NSArray<NSString *> *category in TGCategories()) {
        NSArray *rows = [self rowsForCategory:category[0]];
        if (!rows.count) continue;
        PSSpecifier *header = [PSSpecifier preferenceSpecifierNamed:category[1] target:self set:nil get:nil detail:nil cell:PSListItemCell edit:nil];
        [header setProperty:category[0] forKey:@"tgCategory"];
        TGSetCategoryIcon(header, category[0]);
        [specs addObject:header];
        if ([_expanded isEqualToString:category[0]]) [specs addObjectsFromArray:rows];
    }
    return specs;
}

- (NSArray<PSSpecifier *> *)rowsForCategory:(NSString *)category {
    NSMutableArray *rows = [NSMutableArray array];
    const TGItem *items = NULL;
    int count = 0;
    if ([category isEqualToString:@"system"]) { items = TGSystemActions; count = TG_COUNT(TGSystemActions); }
    else if ([category isEqualToString:@"power"]) { items = TGPowerActions; count = TG_COUNT(TGPowerActions); }
    else if ([category isEqualToString:@"media"]) { items = TGMediaActions; count = TG_COUNT(TGMediaActions); }
    for (int i = 0; i < count; i++) [rows addObject:[self rowForAction:@(items[i].identifier) title:@(items[i].title)]];
    if ([category isEqualToString:@"switches"]) {
        for (int i = 0; i < TG_COUNT(TGSwitches); i++) {
            PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:@(TGSwitches[i].title) target:self set:nil get:nil detail:nil cell:PSListItemCell edit:nil];
            [spec setProperty:@(TGSwitches[i].identifier) forKey:@"tgSwitch"];
            [rows addObject:spec];
        }
    } else if ([category isEqualToString:@"levels"]) {
        [rows addObject:[self rowForCommand:TGBrightnessPrefix title:@"Set Brightness…" prompt:@"Brightness, 0–100 %"]];
        [rows addObject:[self rowForCommand:TGMediaVolumePrefix title:@"Set Media Volume…" prompt:@"Media volume, 0–100 %"]];
        [rows addObject:[self rowForCommand:TGRingerVolumePrefix title:@"Set Ringer Volume…" prompt:@"Ringer volume, 0–100 %"]];
    } else if ([category isEqualToString:@"open"]) {
        // AltList's single-app list saves and loads through this row's own setter
        // and getter, so Triggr receives the picked bundle id directly.
        PSSpecifier *openApp = [PSSpecifier preferenceSpecifierNamed:@"Open App…" target:self set:@selector(setPickedApp:specifier:)
            get:@selector(pickedApp:) detail:ATLApplicationListSelectionController.class cell:PSLinkCell edit:nil];
        [openApp setProperty:@YES forKey:@"useSearchBar"];
        [openApp setProperty:@[@{ @"sectionType": @"Visible" }] forKey:@"sections"];
        [openApp setProperty:TGAppPrefix forKey:@"tgCommandPrefix"];
        [rows addObject:openApp];
        [rows addObject:[self rowForCommand:TGSettingsPrefix title:@"Open Settings Page…" prompt:nil]];
        [rows addObject:[self rowForCommand:TGShortcutPrefix title:@"Run Shortcut…" prompt:@"Shortcut name, exactly as in the Shortcuts app"]];
        [rows addObject:[self rowForCommand:TGURLPrefix title:@"Open URL…" prompt:@"Any URL or URL scheme, e.g. https://…, tel:… or music://"]];
    } else if ([category isEqualToString:@"text"]) {
        [rows addObject:[self rowForCommand:TGMessagePrefix title:@"Show Message…" prompt:@"Text to show in an alert"]];
        [rows addObject:[self rowForCommand:TGSpeakPrefix title:@"Speak Text…" prompt:@"Text for the device to say"]];
        [rows addObject:[self rowForCommand:TGShellPrefix title:@"Run Command…" prompt:@"Shell command. Runs with /var/jb/bin/sh -c as the mobile user."]];
    } else if ([category isEqualToString:@"menus"] && !_menuEditor) {
        for (NSDictionary *menu in TGReadMenus())
            [rows addObject:[self rowForAction:[TGMenuPrefix stringByAppendingString:menu[@"id"]] title:[menu[@"name"] description]]];
    }
    return rows;
}

// Search: every action as one flat list, with each switch's Toggle / On / Off as its own row.
- (NSMutableArray *)searchSpecifiers {
    NSMutableArray *rows = [NSMutableArray array];
    for (int g = 0; g < TG_COUNT(TGActionGroups); g++)
        for (int i = 0; i < TGActionGroups[g].count; i++)
            [rows addObject:[self rowForAction:@(TGActionGroups[g].items[i].identifier) title:@(TGActionGroups[g].items[i].title)]];
    for (NSString *category in @[@"levels", @"open", @"text", @"menus"]) [rows addObjectsFromArray:[self rowsForCategory:category]];
    NSMutableArray *specs = [NSMutableArray array];
    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:nil];
    [specs addObject:group];
    for (PSSpecifier *row in rows)
        if ([row.name rangeOfString:_query options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound) [specs addObject:row];
    if (specs.count == 1) [group setProperty:[NSString stringWithFormat:@"No action matches “%@”.", _query] forKey:@"footerText"];
    return specs;
}

- (PSSpecifier *)rowForAction:(NSString *)action title:(NSString *)title {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:title target:self set:nil get:nil detail:nil cell:PSListItemCell edit:nil];
    [spec setProperty:action forKey:@"tgAction"];
    return spec;
}

// A command row: tapping asks for its text; the saved action is prefix + text.
- (PSSpecifier *)rowForCommand:(NSString *)prefix title:(NSString *)title prompt:(NSString *)prompt {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:title target:self set:nil get:nil detail:nil cell:PSListItemCell edit:nil];
    [spec setProperty:prefix forKey:@"tgCommandPrefix"];
    [spec setProperty:prompt forKey:@"tgPrompt"];
    return spec;
}

// The selected command/app item with this prefix (one of each kind).
- (NSString *)itemWithPrefix:(NSString *)prefix {
    for (NSString *item in _selection) if ([item hasPrefix:prefix]) return item;
    return nil;
}

// "Toggle", "On", "Off": what's picked for this switch, in that order.
- (NSArray<NSString *> *)verbsForSwitch:(NSString *)name {
    NSMutableArray *verbs = [NSMutableArray array];
    for (NSArray<NSString *> *verb in @[@[@"toggle", @"Toggle"], @[@"on", @"On"], @[@"off", @"Off"]])
        if ([_selection containsObject:[NSString stringWithFormat:@"%@.%@", verb[0], name]]) [verbs addObject:verb[1]];
    return verbs;
}

// Replace the item with this prefix in place, or append it; nil removes it.
- (void)setItem:(NSString *)item forPrefix:(NSString *)prefix {
    NSString *existing = [self itemWithPrefix:prefix];
    NSUInteger index = existing ? [_selection indexOfObject:existing] : NSNotFound;
    if (index != NSNotFound) {
        if (item) _selection[index] = item;
        else {
            [_selection removeObjectAtIndex:index];
            _selection = TGTidyPauses(_selection);
        }
        [self save];
    } else if (item) {
        [self confirmAdding:item then:^{
            [self->_selection addObject:item];
            [self save];
        }];
    }
}

// Warn about likely conflicts before adding, like Activator's "Ignore / Cancel".
- (void)confirmAdding:(NSString *)action then:(void (^)(void))add {
    // Menu items never run together (one is picked), so conflicts don't apply.
    NSString *warning = _menuEditor ? nil : TGListWarning(_selection, action);
    if (!warning) {
        add();
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Heads Up" message:warning preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Add Anyway" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { add(); }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)save {
    [self setPreferenceValue:TGStoredValue(_selection) specifier:self.specifier];
    [self reloadSpecifiers];
}

// None clears; any other action toggles, appended to the run order.
- (void)toggle:(NSString *)action {
    if (action.length == 0) [_selection removeAllObjects];
    else if ([_selection containsObject:action]) {
        [_selection removeObject:action];
        _selection = TGTidyPauses(_selection);
    }
    else {
        [self confirmAdding:action then:^{
            [self->_selection addObject:action];
            [self save];
        }];
        return;
    }
    [self save];
}

#pragma mark Selected rows

- (NSString *)swipeTitleForSpecifier:(PSSpecifier *)spec {
    return [spec propertyForKey:@"tgPicked"] ? @"Remove" : nil;
}

- (BOOL)swipedSpecifier:(PSSpecifier *)spec {
    NSString *item = [spec propertyForKey:@"tgPicked"];
    NSUInteger index = [_selection indexOfObject:item];
    if (index == NSNotFound) return NO;
    [_selection removeObjectAtIndex:index];
    _selection = TGTidyPauses(_selection);
    [self setPreferenceValue:TGStoredValue(_selection) specifier:self.specifier];
    return YES;
}

// Tapping a picked row opens its category with that row in view.
- (void)revealItem:(NSString *)item {
    NSString *category = TGCategoryOf(item);
    if (!category) return;
    _expanded = category;
    [self reloadSpecifiers];
    for (PSSpecifier *row in self.specifiers) {
        NSString *action = [row propertyForKey:@"tgAction"], *prefix = [row propertyForKey:@"tgCommandPrefix"], *name = [row propertyForKey:@"tgSwitch"];
        BOOL match = (action.length && [action isEqualToString:item]) || (prefix && [item hasPrefix:prefix])
            || (name && [@[@"toggle.", @"on.", @"off."] indexOfObjectPassingTest:^BOOL(NSString *verb, NSUInteger i, BOOL *stop) { return [item isEqualToString:[verb stringByAppendingString:name]]; }] != NSNotFound);
        if (!match) continue;
        NSIndexPath *path = [self indexPathForSpecifier:row];
        [self.table scrollToRowAtIndexPath:path atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.table selectRowAtIndexPath:path animated:NO scrollPosition:UITableViewScrollPositionNone];
            [self.table deselectRowAtIndexPath:path animated:YES];
        });
        return;
    }
}

#pragma mark Cells

- (NSString *)titleForCategory:(NSString *)category {
    for (NSArray<NSString *> *entry in TGCategories()) if ([entry[0] isEqualToString:category]) return entry[1];
    return nil;
}

// 1-based run position among the picked actions (pauses not counted).
- (NSUInteger)positionOfItem:(NSString *)item {
    NSUInteger number = 0;
    for (NSString *picked in _selection) {
        if ([picked hasPrefix:TGPausePrefix]) continue;
        number++;
        if ([picked isEqualToString:item]) return number;
    }
    return 0;
}

// What's picked inside a category, shown on its row while it's closed or open.
- (NSString *)summaryForCategory:(NSString *)category {
    NSMutableArray *titles = [NSMutableArray array];
    for (NSString *action in _selection) if ([TGCategoryOf(action) isEqualToString:category]) [titles addObject:TGDisplayTitle(action)];
    return [titles componentsJoinedByString:@", "];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    PSSpecifier *spec = [self specifierAtIndex:[self indexForIndexPath:indexPath]];
    NSString *category = [spec propertyForKey:@"tgCategory"], *action = [spec propertyForKey:@"tgAction"];
    NSString *prefix = [spec propertyForKey:@"tgCommandPrefix"], *name = [spec propertyForKey:@"tgSwitch"];
    UIFont *body = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    NSString *picked = [spec propertyForKey:@"tgPicked"];
    cell.textLabel.font = body;
    cell.textLabel.textColor = [spec propertyForKey:@"tgClear"] ? UIColor.systemRedColor
        : [picked hasPrefix:TGPausePrefix] ? UIColor.secondaryLabelColor : UIColor.labelColor;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    // An open category's rows line up under its title, past the icon.
    BOOL child = !_query && !picked && !category && ![spec propertyForKey:@"tgOrder"] && ![spec propertyForKey:@"tgClear"];
    static UIImage *spacer;
    if (!spacer) spacer = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(29, 29)] imageWithActions:^(UIGraphicsImageRendererContext *context) {}];
    if (child) cell.imageView.image = spacer;
    else if (!category) cell.imageView.image = nil;
    cell.separatorInset = UIEdgeInsetsMake(0, child ? 60 : (category ? 60 : 16), 0, 0);
    NSString *detail = nil;
    if (picked) {
        if (TGCategoryOf(picked)) detail = [self titleForCategory:TGCategoryOf(picked)];
    } else if (category) {
        BOOL open = [_expanded isEqualToString:category];
        UIImage *chevron = [UIImage systemImageNamed:open ? @"chevron.down" : @"chevron.right"
            withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold]];
        UIImageView *view = [[UIImageView alloc] initWithImage:chevron];
        view.tintColor = UIColor.tertiaryLabelColor;
        cell.accessoryView = view;
        detail = [self summaryForCategory:category];
    } else if ([spec propertyForKey:@"tgOrder"]) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (action) {
        BOOL selected = action.length ? [_selection containsObject:action] : _selection.count == 0;
        if (selected) cell.accessoryType = UITableViewCellAccessoryCheckmark;
        // With several picked, show where this one runs in the list.
        if (selected && action.length && _selection.count > 1) detail = [NSString stringWithFormat:@"%lu", (unsigned long)[self positionOfItem:action]];
    } else if (name) {
        NSArray *verbs = [self verbsForSwitch:name];
        if (verbs.count) cell.accessoryType = UITableViewCellAccessoryCheckmark;
        detail = [verbs componentsJoinedByString:@", "];
    } else if (prefix) {
        NSString *item = [self itemWithPrefix:prefix];
        if (item) cell.accessoryType = UITableViewCellAccessoryCheckmark;
        BOOL titled = [prefix isEqualToString:TGAppPrefix] || [prefix isEqualToString:TGSettingsPrefix];
        if (item) detail = titled ? [TGDisplayTitle(item) substringFromIndex:[TGDisplayTitle(item) rangeOfString:@" "].location + 1] : [item substringFromIndex:prefix.length];
    }
    // Search mixes every category; say where each result lives.
    if (_query && !detail.length && !picked) {
        NSString *item = action.length ? action : prefix ?: (name ? [@"toggle." stringByAppendingString:name] : nil);
        if (item) detail = [self titleForCategory:TGCategoryOf(item)];
    }
    cell.detailTextLabel.text = detail;
    return cell;
}

#pragma mark Taps

// AltList's app list calls these on the Open App row.
- (void)setPickedApp:(NSString *)identifier specifier:(PSSpecifier *)spec {
    if ([identifier isKindOfClass:NSString.class] && identifier.length) [self setItem:[TGAppPrefix stringByAppendingString:identifier] forPrefix:TGAppPrefix];
}

- (NSString *)pickedApp:(PSSpecifier *)spec {
    return [[self itemWithPrefix:TGAppPrefix] substringFromIndex:TGAppPrefix.length];
}

- (void)presentSheet:(UIAlertController *)sheet fromRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self.table cellForRowAtIndexPath:indexPath];
    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

// A switch can be toggled, turned on or turned off; several can be picked
// (e.g. Flashlight On, a pause, Flashlight Off).
- (void)pickVerbsForSwitch:(NSString *)name title:(NSString *)title atIndexPath:(NSIndexPath *)indexPath {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSArray<NSString *> *verb in @[@[@"toggle", @"Toggle"], @[@"on", @"Turn On"], @[@"off", @"Turn Off"]]) {
        NSString *action = [NSString stringWithFormat:@"%@.%@", verb[0], name];
        BOOL selected = [_selection containsObject:action];
        UIAlertAction *item = [UIAlertAction actionWithTitle:verb[1] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self toggle:action]; }];
        // UIAlertAction's own checkmark (private key); without it the row's detail still says what's picked.
        @try { if (selected) [item setValue:@YES forKey:@"checked"]; } @catch (NSException *exception) {}
        [sheet addAction:item];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentSheet:sheet fromRowAtIndexPath:indexPath];
}

- (void)pickSettingsPageAtIndexPath:(NSIndexPath *)indexPath existing:(NSString *)existingItem {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Open Settings Page" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (int i = 0; i < TG_COUNT(TGSettingsPages); i++) {
        NSString *page = @(TGSettingsPages[i].identifier);
        [sheet addAction:[UIAlertAction actionWithTitle:@(TGSettingsPages[i].title) style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self setItem:[TGSettingsPrefix stringByAppendingString:page] forPrefix:TGSettingsPrefix];
        }]];
    }
    if (existingItem) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            [self setItem:nil forPrefix:TGSettingsPrefix];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentSheet:sheet fromRowAtIndexPath:indexPath];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    PSSpecifier *spec = [self specifierAtIndex:[self indexForIndexPath:indexPath]];
    NSString *category = [spec propertyForKey:@"tgCategory"];
    if (category) {
        // One category open at a time keeps the page short.
        _expanded = [_expanded isEqualToString:category] ? nil : category;
        [self reloadSpecifiers];
        for (PSSpecifier *header in _expanded ? self.specifiers : @[]) {
            if (![[header propertyForKey:@"tgCategory"] isEqualToString:category]) continue;
            NSIndexPath *first = [self indexPathForSpecifier:header];
            NSIndexPath *last = [NSIndexPath indexPathForRow:first.row + [self rowsForCategory:category].count inSection:first.section];
            // Bring as much of the opened category into view as fits.
            [tableView scrollToRowAtIndexPath:last atScrollPosition:UITableViewScrollPositionNone animated:NO];
            [tableView scrollToRowAtIndexPath:first atScrollPosition:UITableViewScrollPositionNone animated:YES];
            break;
        }
        return;
    }
    NSString *picked = [spec propertyForKey:@"tgPicked"];
    if (picked) {
        [self revealItem:picked];
        return;
    }
    if ([spec propertyForKey:@"tgClear"]) {
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Remove All Actions" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) { [self toggle:@""]; }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentSheet:sheet fromRowAtIndexPath:indexPath];
        return;
    }
    NSString *action = [spec propertyForKey:@"tgAction"];
    if (action) {
        [[UISelectionFeedbackGenerator new] selectionChanged];
        [self toggle:action];
        return;
    }
    NSString *name = [spec propertyForKey:@"tgSwitch"];
    if (name) {
        [self pickVerbsForSwitch:name title:spec.name atIndexPath:indexPath];
        return;
    }
    if ([spec propertyForKey:@"tgOrder"]) {
        TGSequenceController *editor = [TGSequenceController new];
        editor.items = [_selection mutableCopy];
        __weak typeof(self) weakSelf = self;
        editor.onChange = ^(NSArray<NSString *> *items) {
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_selection = [items mutableCopy];
            [strongSelf setPreferenceValue:TGStoredValue(strongSelf->_selection) specifier:strongSelf.specifier];
        };
        [self.navigationController pushViewController:editor animated:YES];
        return;
    }
    NSString *prefix = [spec propertyForKey:@"tgCommandPrefix"];
    if (!prefix) return;
    NSString *existingItem = [self itemWithPrefix:prefix];
    if ([prefix isEqualToString:TGAppPrefix]) {
        if (!existingItem) {
            [super tableView:tableView didSelectRowAtIndexPath:indexPath]; // push AltList's app list
            return;
        }
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:TGDisplayTitle(existingItem) message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Choose Another App…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [super tableView:tableView didSelectRowAtIndexPath:indexPath];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            [self setItem:nil forPrefix:prefix];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentSheet:sheet fromRowAtIndexPath:indexPath];
        return;
    }
    if ([prefix isEqualToString:TGSettingsPrefix]) {
        [self pickSettingsPageAtIndexPath:indexPath existing:existingItem];
        return;
    }
    BOOL percent = [prefix isEqualToString:TGBrightnessPrefix] || [prefix isEqualToString:TGMediaVolumePrefix] || [prefix isEqualToString:TGRingerVolumePrefix];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[spec.name stringByReplacingOccurrencesOfString:@"…" withString:@""] message:[spec propertyForKey:@"tgPrompt"] preferredStyle:UIAlertControllerStyleAlert];
    NSString *existing = existingItem ? [existingItem substringFromIndex:prefix.length] : @"";
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = existing;
        if (percent) field.keyboardType = UIKeyboardTypeNumberPad;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *text = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (percent && text.length) text = [NSString stringWithFormat:@"%d", (int)MIN(MAX(text.intValue, 0), 100)];
        if (text.length) [self setItem:[prefix stringByAppendingString:text] forPrefix:prefix];
    }]];
    if (existingItem) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            [self setItem:nil forPrefix:prefix];
        }]];
    }
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Trigger group (one button's triggers, or the custom events)

static NSString *const TGCustomGroupTitle = @"Custom Events";

// Which row of a place's page a trigger belongs under: an index into
// TGTriggerGroups, or -1 for Custom Events.
static NSInteger TGGroupOfTrigger(NSString *trigger) {
    if (TGIsCustomTrigger(trigger)) return -1;
    for (int g = 0; g < TG_COUNT(TGTriggerGroups); g++)
        for (int i = 0; i < TGTriggerGroups[g].count; i++)
            if ([trigger isEqualToString:@(TGTriggerGroups[g].items[i].identifier)]) return g;
    return NSNotFound;
}

// Lists of assigned triggers follow the catalog order (Single, Double, Triple...),
// with custom events after them by name.
static NSInteger TGTriggerRank(NSString *trigger) {
    NSInteger rank = 0;
    for (int g = 0; g < TG_COUNT(TGTriggerGroups); g++)
        for (int i = 0; i < TGTriggerGroups[g].count; i++, rank++)
            if ([trigger isEqualToString:@(TGTriggerGroups[g].items[i].identifier)]) return rank;
    return NSIntegerMax;
}

static NSComparator const TGCatalogOrder = ^NSComparisonResult(PSSpecifier *a, PSSpecifier *b) {
    NSInteger ra = TGTriggerRank([a propertyForKey:@"tgTrigger"]), rb = TGTriggerRank([b propertyForKey:@"tgTrigger"]);
    if (ra != rb) return ra < rb ? NSOrderedAscending : NSOrderedDescending;
    return [a.name localizedStandardCompare:b.name];
};

@interface TGGroupController : TGListController
@end

@implementation TGGroupController {
    NSString *_mode;
    NSInteger _group;
    NSString *_pendingTrigger;   // App Opened event waiting for its action
    NSString *_pendingFlickApp;  // App Icon Flicked: app picked, direction still to choose
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _mode = [self.specifier propertyForKey:@"tgMode"];
        _group = [[self.specifier propertyForKey:@"tgGroup"] integerValue];
        self.title = self.specifier.name;
        NSMutableArray *specs = [NSMutableArray array];
        if (_group >= 0) {
            const TGGroup *triggers = &TGTriggerGroups[_group];
            PSSpecifier *group = [PSSpecifier groupSpecifierWithName:nil];
            NSString *footer = triggers->footer ? @(triggers->footer) : nil;
            // Buttons follow Replace Button Actions; say which way it's set.
            if (triggers->items == TGHomeButton || triggers->items == TGLockButton || triggers->items == TGVolume || triggers->items == TGTouchID || triggers->items == TGMuteSwitch) {
                NSString *mode = [self replacesButtons]
                    ? @"Replace Button Actions is on (Options): an assigned press runs instead of the button's own action. Unassigned presses work as usual."
                    : @"Replace Button Actions is off (Options): assigned presses run alongside the button's own action.";
                footer = footer ? [NSString stringWithFormat:@"%@ %@", mode, footer] : mode;
            }
            // On Face ID devices Apple calls the lock button the side button.
            if (triggers->items == TGLockButton && !TGHasHomeButton() && UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone)
                footer = [footer stringByAppendingString:@" On Face ID devices a double-click still opens Wallet / Apple Pay and a triple-click still runs the Accessibility Shortcut, because Triggr runs alongside them. (Untested on Face ID devices.)"];
            if (footer) [group setProperty:TGButtonText(footer) forKey:@"footerText"];
            [specs addObject:group];
            for (int i = 0; i < triggers->count; i++)
                [specs addObject:TGTriggerRow(@(triggers->items[i].title), self, @selector(assignedActionTitle:), _mode, @(triggers->items[i].identifier))];
        } else {
            NSArray *events = [self customEventRows];
            PSSpecifier *mine = [PSSpecifier groupSpecifierWithName:nil];
            [mine setProperty:events.count ? @"Swipe left on an event to delete it." : @"No custom events yet. Add one below, then pick what it runs." forKey:@"footerText"];
            [specs addObject:mine];
            [specs addObjectsFromArray:events];
            [specs addObject:[PSSpecifier groupSpecifierWithName:@"Add Event"]];
            NSArray<NSArray<NSString *> *> *kinds = @[
                @[@"Joined Wi-Fi Network", TGWiFiJoinedPrefix], @[@"Left Wi-Fi Network", TGWiFiLeftPrefix],
                @[@"Bluetooth Device Connected", TGBTConnectedPrefix], @[@"Bluetooth Device Disconnected", TGBTDisconnectedPrefix],
                @[@"Battery Rises Above", TGBatteryAbovePrefix], @[@"Battery Drops Below", TGBatteryBelowPrefix],
                @[@"Scheduled Time", TGTimePrefix],
            ];
            for (NSArray<NSString *> *kind in kinds) {
                PSSpecifier *add = [PSSpecifier preferenceSpecifierNamed:kind[0] target:self set:nil get:nil detail:nil cell:PSListItemCell edit:nil];
                [add setProperty:kind[1] forKey:@"tgAddEvent"];
                [specs addObject:add];
            }
            // AltList's app list saves through this row's own setter, like Open App.
            PSSpecifier *addApp = [PSSpecifier preferenceSpecifierNamed:@"App Opened" target:self set:@selector(setOpenedApp:specifier:)
                get:@selector(openedApp:) detail:ATLApplicationListSelectionController.class cell:PSLinkCell edit:nil];
            [addApp setProperty:@YES forKey:@"useSearchBar"];
            [addApp setProperty:@[@{ @"sectionType": @"Visible" }] forKey:@"sections"];
            [specs addObject:addApp];
            PSSpecifier *addFlick = [PSSpecifier preferenceSpecifierNamed:@"App Icon Flicked" target:self set:@selector(setFlickedApp:specifier:)
                get:@selector(openedApp:) detail:ATLApplicationListSelectionController.class cell:PSLinkCell edit:nil];
            [addFlick setProperty:@YES forKey:@"useSearchBar"];
            [addFlick setProperty:@[@{ @"sectionType": @"Visible" }] forKey:@"sections"];
            [specs addObject:addFlick];
        }
        _specifiers = specs;
    }
    return _specifiers;
}

// Custom events assigned in this place (key "<mode>/<custom trigger>" with actions).
- (NSArray<PSSpecifier *> *)customEventRows {
    NSString *prefix = [_mode stringByAppendingString:@"/"];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *key in TGAllAssignments()) {
        if (![key hasPrefix:prefix]) continue;
        NSString *trigger = [key substringFromIndex:prefix.length];
        if (!TGIsCustomTrigger(trigger)) continue;
        [rows addObject:TGSubtitled(TGTriggerRow(TGSettingsTriggerTitle(trigger), self, @selector(assignedActionTitle:), _mode, trigger))];
    }
    return [rows sortedArrayUsingComparator:^NSComparisonResult(PSSpecifier *a, PSSpecifier *b) { return [a.name localizedStandardCompare:b.name]; }];
}

- (NSString *)swipeTitleForSpecifier:(PSSpecifier *)spec {
    NSString *trigger = [spec propertyForKey:@"tgTrigger"];
    if (!trigger || !TGActionList([self readPreferenceValue:spec]).count) return nil;
    return TGIsCustomTrigger(trigger) ? @"Delete" : @"Clear";
}

- (BOOL)swipedSpecifier:(PSSpecifier *)spec {
    [self setPreferenceValue:@"" specifier:spec];
    return TGIsCustomTrigger([spec propertyForKey:@"tgTrigger"]); // a button's row stays, now empty
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // Back from AltList with an app picked: go straight to its action picker.
    if (_pendingTrigger) {
        NSString *trigger = _pendingTrigger;
        _pendingTrigger = nil;
        [self pushPickerForTrigger:trigger];
    }
    // Back from AltList with an app for a flick: which way, then its action picker.
    if (_pendingFlickApp) {
        NSString *app = _pendingFlickApp;
        _pendingFlickApp = nil;
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Flick on %@", TGAppName(app)]
            message:@"Runs instead of the plain icon flick in that direction." preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSString *prefix in @[TGIconFlickUpPrefix, TGIconFlickDownPrefix, TGIconFlickLeftPrefix, TGIconFlickRightPrefix]) {
            NSString *trigger = [prefix stringByAppendingString:app];
            [sheet addAction:[UIAlertAction actionWithTitle:TGFlickDirectionTitle(trigger) style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                [self pushPickerForTrigger:trigger];
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        sheet.popoverPresentationController.sourceView = self.view;
        sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
        [self presentViewController:sheet animated:YES completion:nil];
    }
}

- (void)setFlickedApp:(NSString *)identifier specifier:(PSSpecifier *)spec {
    if ([identifier isKindOfClass:NSString.class] && identifier.length) _pendingFlickApp = identifier;
}

- (void)pushPickerForTrigger:(NSString *)trigger {
    TGActionPickerController *picker = [TGActionPickerController new];
    picker.specifier = TGTriggerRow(TGSettingsTriggerTitle(trigger), self, @selector(assignedActionTitle:), _mode, trigger);
    [self.navigationController pushViewController:picker animated:YES];
}

- (void)setOpenedApp:(NSString *)identifier specifier:(PSSpecifier *)spec {
    if ([identifier isKindOfClass:NSString.class] && identifier.length) _pendingTrigger = [TGAppLaunchedPrefix stringByAppendingString:identifier];
}

- (NSString *)openedApp:(PSSpecifier *)spec {
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    PSSpecifier *spec = [self specifierAtIndex:[self indexForIndexPath:indexPath]];
    if ([spec propertyForKey:@"tgAddEvent"]) cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; // each leads to one more step
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *spec = [self specifierAtIndex:[self indexForIndexPath:indexPath]];
    NSString *prefix = [spec propertyForKey:@"tgAddEvent"];
    if (!prefix) {
        [super tableView:tableView didSelectRowAtIndexPath:indexPath];
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ([prefix isEqualToString:TGTimePrefix]) {
        TGTimePickerController *timePicker = [TGTimePickerController new];
        __weak typeof(self) weakSelf = self;
        timePicker.onSave = ^(NSString *trigger) {
            [weakSelf.navigationController popViewControllerAnimated:NO];
            [weakSelf pushPickerForTrigger:trigger];
        };
        [self.navigationController pushViewController:timePicker animated:YES];
        return;
    }
    void (^next)(NSString *) = ^(NSString *value) { [self pushPickerForTrigger:[prefix stringByAppendingString:value]]; };
    if ([prefix isEqualToString:TGBatteryAbovePrefix] || [prefix isEqualToString:TGBatteryBelowPrefix]) {
        BOOL above = [prefix isEqualToString:TGBatteryAbovePrefix];
        [self promptTitle:spec.name message:above ? @"Battery level, 1–100 %. Runs once when the level climbs past it; 100 means fully charged."
            : @"Battery level, 1–100 %. Runs once when the level falls past it." percent:YES then:next];
        return;
    }
    // Wi-Fi and Bluetooth: pick from the saved networks / paired devices, or type a name.
    BOOL wifi = [prefix isEqualToString:TGWiFiJoinedPrefix] || [prefix isEqualToString:TGWiFiLeftPrefix];
    NSString *prompt = wifi ? @"Network name (SSID), as shown in Settings → Wi-Fi" : @"Device name, as shown in Settings → Bluetooth";
    UIAlertController *list = [UIAlertController alertControllerWithTitle:spec.name message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *name in wifi ? TGSavedWiFiNetworks() : TGPairedBluetoothDevices())
        [list addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { next(name); }]];
    [list addAction:[UIAlertAction actionWithTitle:@"Other…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self promptTitle:spec.name message:prompt percent:NO then:next];
    }]];
    [list addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    list.popoverPresentationController.sourceView = cell;
    list.popoverPresentationController.sourceRect = cell.bounds;
    [self presentViewController:list animated:YES completion:nil];
}

- (void)promptTitle:(NSString *)title message:(NSString *)message percent:(BOOL)percent then:(void (^)(NSString *value))done {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        if (percent) field.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Next" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *value = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (percent) value = value.length ? [NSString stringWithFormat:@"%d", (int)MIN(MAX(value.intValue, 1), 100)] : @"";
        if (value.length) done(value);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Place (what's assigned there, then one row per kind of trigger)

@interface TGModeController : TGListController
@end

@implementation TGModeController {
    NSString *_mode;
    NSArray<NSString *> *_assigned; // this place's assigned triggers
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _mode = [self.specifier propertyForKey:@"tgMode"];
        self.title = self.specifier.name;
        NSString *prefix = [_mode stringByAppendingString:@"/"];
        NSMutableArray *assigned = [NSMutableArray array];
        for (NSString *key in TGAllAssignments()) if ([key hasPrefix:prefix]) [assigned addObject:[key substringFromIndex:prefix.length]];
        _assigned = assigned;

        NSMutableArray *specs = [NSMutableArray array];
        BOOL anywhere = [_mode isEqualToString:@"anywhere"];
        if (!anywhere) {
            // Said up front: what's set here only works in this place.
            PSSpecifier *intro = [PSSpecifier groupSpecifierWithName:nil];
            [intro setProperty:[NSString stringWithFormat:@"Assignments made here only work %@, where they replace Anywhere's for the same trigger. Everywhere else, Anywhere's still apply.", TGModePhrase(_mode)] forKey:@"footerText"];
            [specs addObject:intro];
        }
        if (assigned.count) {
            PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"Assigned"];
            [group setProperty:@"Tap one to change it, or swipe left to remove it." forKey:@"footerText"];
            [specs addObject:group];
            NSMutableArray *rows = [NSMutableArray array];
            for (NSString *trigger in assigned) [rows addObject:TGSubtitled(TGTriggerRow(TGSettingsTriggerTitle(trigger), self, @selector(assignedActionTitle:), _mode, trigger))];
            [specs addObjectsFromArray:[rows sortedArrayUsingComparator:TGCatalogOrder]];
        }

        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"Triggers"];
        if (anywhere) [group setProperty:@"Assignments made here work everywhere, unless one of the other places has its own for the same trigger." forKey:@"footerText"];
        [specs addObject:group];
        NSDictionary<NSString *, NSArray *> *icons = @{
            @"Home Button": @[@"circle.circle", UIColor.systemGrayColor], @"Touch ID": @[@"touchid", UIColor.systemRedColor],
            @"Lock Button": @[@"lock.fill", UIColor.systemBlueColor], @"Volume Buttons": @[@"speaker.wave.2.fill", UIColor.systemPinkColor],
            @"Mute Switch": @[@"bell.slash.fill", UIColor.systemOrangeColor], @"Status Bar": @[@"rectangle.topthird.inset.filled", UIColor.systemIndigoColor],
            @"Home Screen Icons": @[@"square.grid.3x3.fill", UIColor.systemBlueColor], @"Motion": @[@"iphone.radiowaves.left.and.right", UIColor.systemYellowColor],
            @"Charger & Headphones": @[@"bolt.fill", UIColor.systemGreenColor], @"State Changes": @[@"arrow.triangle.2.circlepath", UIColor.systemTealColor],
        };
        for (int g = 0; g < TG_COUNT(TGTriggerGroups); g++) {
            if (!TGShowsTriggerGroup(&TGTriggerGroups[g])) continue;
            NSString *title = @(TGTriggerGroups[g].title);
            PSSpecifier *row = [self rowForGroup:g title:TGTriggerGroups[g].items == TGLockButton ? TGLockButtonName() : title];
            if (icons[title]) TGSetIcon(row, icons[title][0], icons[title][1]);
            [specs addObject:row];
        }
        PSSpecifier *custom = [self rowForGroup:-1 title:TGCustomGroupTitle];
        TGSetIcon(custom, @"sparkles", UIColor.systemPurpleColor);
        [specs addObject:custom];
        _specifiers = specs;
    }
    return _specifiers;
}

- (PSSpecifier *)rowForGroup:(NSInteger)group title:(NSString *)title {
    PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:title target:self set:nil get:@selector(groupCount:) detail:TGGroupController.class cell:PSLinkListCell edit:nil];
    [row setProperty:_mode forKey:@"tgMode"];
    [row setProperty:@(group) forKey:@"tgGroup"];
    return row;
}

// How many of a group's triggers are assigned in this place.
- (NSString *)groupCount:(PSSpecifier *)spec {
    NSInteger group = [[spec propertyForKey:@"tgGroup"] integerValue];
    NSUInteger count = 0;
    for (NSString *trigger in _assigned) if (TGGroupOfTrigger(trigger) == group) count++;
    return TGCountTitle(count);
}

- (NSString *)swipeTitleForSpecifier:(PSSpecifier *)spec {
    return [spec propertyForKey:@"tgTrigger"] ? @"Remove" : nil;
}

- (BOOL)swipedSpecifier:(PSSpecifier *)spec {
    [self setPreferenceValue:@"" specifier:spec];
    return YES;
}

@end

// Rows whose trigger and actions are both worth reading in full: the trigger
// on top, what it runs (or where) underneath, instead of cut off on the right.
@interface TGSubtitleCell : PSTableCell
@end

@implementation TGSubtitleCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    return [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier specifier:specifier];
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    id value = [specifier performGetter];
    self.detailTextLabel.text = [value isKindOfClass:NSString.class] ? value : nil;
    self.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    self.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.detailTextLabel.numberOfLines = 2;
    self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
}

@end

static PSSpecifier *TGSubtitled(PSSpecifier *spec) {
    [spec setProperty:TGSubtitleCell.class forKey:@"cellClass"];
    [spec setProperty:@64 forKey:@"height"];
    return spec;
}

static PSSpecifier *TGTriggerRow(NSString *name, id target, SEL getter, NSString *mode, NSString *trigger) {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:name target:target set:nil get:getter
        detail:TGActionPickerController.class cell:PSLinkListCell edit:nil];
    [spec setProperty:mode forKey:@"tgMode"];
    [spec setProperty:trigger forKey:@"tgTrigger"];
    TGConfigureStorage(spec, mode, trigger);
    return spec;
}

#pragma mark - All Assignments (every assignment, grouped by action)

@interface TGByActionController : TGListController
@end

@implementation TGByActionController {
    BOOL _byAction; // the page's two views: by trigger (grouped by place) or by action
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UISegmentedControl *view = [[UISegmentedControl alloc] initWithItems:@[@"By Trigger", @"By Action"]];
    view.selectedSegmentIndex = _byAction;
    [view addTarget:self action:@selector(viewChanged:) forControlEvents:UIControlEventValueChanged];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 52)];
    [header addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [view.leadingAnchor constraintEqualToAnchor:header.layoutMarginsGuide.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor:header.layoutMarginsGuide.trailingAnchor],
        [view.bottomAnchor constraintEqualToAnchor:header.bottomAnchor],
    ]];
    self.table.tableHeaderView = header;
}

- (void)viewChanged:(UISegmentedControl *)view {
    _byAction = view.selectedSegmentIndex == 1;
    [self reloadSpecifiers];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        self.title = @"All Assignments";
        NSDictionary<NSString *, NSArray<NSString *> *> *assignments = TGAllAssignments();
        NSMutableArray *specs = [NSMutableArray array];
        PSSpecifier *top = [PSSpecifier groupSpecifierWithName:nil];
        [top setProperty:!assignments.count ? @"Nothing is assigned yet. Go back, choose a place, then a trigger."
            : _byAction ? @"Grouped by what runs. Tap a trigger to change it, or swipe left to take that action off it."
            : @"Grouped by where it works. Tap one to change it, or swipe left to remove it." forKey:@"footerText"];
        [specs addObject:top];
        if (!_byAction) {
            for (int m = 0; m < TG_COUNT(TGModes); m++) {
                NSString *prefix = [@(TGModes[m].identifier) stringByAppendingString:@"/"];
                NSMutableArray *rows = [NSMutableArray array];
                for (NSString *key in assignments) {
                    if (![key hasPrefix:prefix]) continue;
                    NSString *trigger = [key substringFromIndex:prefix.length];
                    [rows addObject:TGSubtitled(TGTriggerRow(TGSettingsTriggerTitle(trigger), self, @selector(assignedActionTitle:), @(TGModes[m].identifier), trigger))];
                }
                if (!rows.count) continue;
                [specs addObject:[PSSpecifier groupSpecifierWithName:@(TGModes[m].title)]];
                [specs addObjectsFromArray:[rows sortedArrayUsingComparator:TGCatalogOrder]];
            }
            _specifiers = specs;
            return _specifiers;
        }
        NSMutableDictionary<NSString *, NSMutableArray *> *byAction = [NSMutableDictionary dictionary];
        [assignments enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSArray<NSString *> *actions, BOOL *stop) {
            NSRange slash = [key rangeOfString:@"/"];
            NSString *mode = [key substringToIndex:slash.location], *trigger = [key substringFromIndex:slash.location + 1];
            for (NSString *action in actions) {
                if ([action hasPrefix:TGPausePrefix]) continue;
                NSString *title = TGDisplayTitle(action);
                if (!byAction[title]) byAction[title] = [NSMutableArray array];
                PSSpecifier *row = TGSubtitled(TGTriggerRow(TGSettingsTriggerTitle(trigger), self, @selector(modeTitle:), mode, trigger));
                [row setProperty:action forKey:@"tgListedAction"];
                [byAction[title] addObject:row];
            }
        }];
        for (NSString *title in [byAction.allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
            [specs addObject:[PSSpecifier groupSpecifierWithName:title]];
            [specs addObjectsFromArray:[byAction[title] sortedArrayUsingComparator:TGCatalogOrder]];
        }
        _specifiers = specs;
    }
    return _specifiers;
}

- (NSString *)modeTitle:(PSSpecifier *)spec {
    return TGModeTitle([spec propertyForKey:@"tgMode"]);
}

- (NSString *)swipeTitleForSpecifier:(PSSpecifier *)spec {
    return [spec propertyForKey:@"tgTrigger"] ? @"Remove" : nil;
}

// By trigger: clears the assignment. By action: takes just this action off the trigger; its other actions stay.
- (BOOL)swipedSpecifier:(PSSpecifier *)spec {
    if (![spec propertyForKey:@"tgListedAction"]) {
        [self setPreferenceValue:@"" specifier:spec];
        return YES;
    }
    NSMutableArray *actions = [TGActionList([self readPreferenceValue:spec]) mutableCopy];
    NSUInteger index = [actions indexOfObject:[spec propertyForKey:@"tgListedAction"]];
    if (index != NSNotFound) [actions removeObjectAtIndex:index];
    [self setPreferenceValue:TGStoredValue(TGTidyPauses(actions)) specifier:spec];
    return YES;
}

@end

#pragma mark - Menus

@interface TGMenusController : TGListController
@end

@implementation TGMenusController

- (PSSpecifier *)menusStorage {
    PSSpecifier *spec = [PSSpecifier emptyGroupSpecifier];
    [spec setProperty:TGDomain forKey:@"defaults"];
    [spec setProperty:TGMenusKey forKey:@"key"];
    [spec setProperty:@TGPrefsChangedNotification forKey:@"PostNotification"];
    return spec;
}

- (void)saveMenus:(NSArray *)menus {
    [self setPreferenceValue:menus specifier:[self menusStorage]];
}

- (PSSpecifier *)editorSpecifierForMenu:(NSDictionary *)menu {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:[menu[@"name"] description] target:self set:nil get:@selector(menuSummary:)
        detail:TGActionPickerController.class cell:PSLinkListCell edit:nil];
    [spec setProperty:TGDomain forKey:@"defaults"];
    [spec setProperty:[TGMenuKeyPrefix stringByAppendingString:menu[@"id"]] forKey:@"key"];
    [spec setProperty:@TGPrefsChangedNotification forKey:@"PostNotification"];
    [spec setProperty:@YES forKey:@"tgMenuEditor"];
    [spec setProperty:menu[@"id"] forKey:@"tgMenuID"];
    return spec;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        self.title = @"Menus";
        NSMutableArray *specs = [NSMutableArray array];
        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:nil];
        [group setProperty:TGReadMenus().count ? @"A menu pops up a list of actions to choose from. Assign it to a trigger from the action picker's Menus category. Swipe left on a menu to delete it."
            : @"A menu pops up a list of actions to choose from. Make one, then assign it to a trigger from the action picker." forKey:@"footerText"];
        [specs addObject:group];
        for (NSDictionary *menu in TGReadMenus()) [specs addObject:[self editorSpecifierForMenu:menu]];
        [specs addObject:[PSSpecifier emptyGroupSpecifier]];
        PSSpecifier *add = [PSSpecifier preferenceSpecifierNamed:@"New Menu…" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
        [add setProperty:@"new" forKey:@"tgMenuCommand"];
        [specs addObject:add];
        _specifiers = specs;
    }
    return _specifiers;
}

- (NSString *)menuSummary:(PSSpecifier *)spec {
    NSUInteger count = 0;
    for (NSString *item in TGActionList([self readPreferenceValue:spec])) if (![item hasPrefix:TGPausePrefix]) count++;
    return count == 1 ? @"1 action" : [NSString stringWithFormat:@"%lu actions", (unsigned long)count];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *spec = [self specifierAtIndex:[self indexForIndexPath:indexPath]];
    NSString *command = [spec propertyForKey:@"tgMenuCommand"];
    if (!command) {
        [super tableView:tableView didSelectRowAtIndexPath:indexPath];
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"New Menu" message:@"Name shown at the top of the menu" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:nil];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Create" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!name.length) return;
        NSDictionary *menu = @{ @"id": [NSUUID.UUID.UUIDString substringToIndex:8], @"name": name };
        [self saveMenus:[TGReadMenus() arrayByAddingObject:menu]];
        TGActionPickerController *editor = [TGActionPickerController new];
        editor.specifier = [self editorSpecifierForMenu:menu];
        [self.navigationController pushViewController:editor animated:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSString *)swipeTitleForSpecifier:(PSSpecifier *)spec {
    return [spec propertyForKey:@"tgMenuID"] ? @"Delete" : nil;
}

// Triggers that used the menu simply stop showing it.
- (BOOL)swipedSpecifier:(PSSpecifier *)spec {
    NSString *menuID = [spec propertyForKey:@"tgMenuID"];
    NSMutableArray *menus = [TGReadMenus() mutableCopy];
    [menus filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *menu, NSDictionary *bindings) { return ![menu[@"id"] isEqualToString:menuID]; }]];
    [self setPreferenceValue:@"" specifier:spec]; // clear its items
    [self saveMenus:menus];
    return YES;
}

@end

#pragma mark - Setups (profiles, export / import, reset)

// Settings keys that belong to a setup, besides "<mode>/<trigger>" and "menu/<id>".
static NSDictionary *TGSetupDefaults(void) {
    return @{ TGEnabledKey: @YES, TGRequireUnlockKey: @YES, TGShowBannersKey: @NO, TGBlockedAppsKey: @[], TGMenusKey: @[] };
}

static BOOL TGIsStringList(id value) {
    if ([value isKindOfClass:NSString.class]) return YES;
    if (![value isKindOfClass:NSArray.class]) return NO;
    for (id item in value) if (![item isKindOfClass:NSString.class]) return NO;
    return YES;
}

// Keeps only keys and value types Triggr understands; everything else is dropped.
static NSDictionary *TGSanitizedSetup(NSDictionary *input) {
    NSMutableDictionary *setup = [NSMutableDictionary dictionary];
    NSSet *modes = [NSSet setWithObjects:@"anywhere", @"home", @"app", @"lock", nil];
    [input enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        if (![key isKindOfClass:NSString.class]) return;
        NSRange slash = [key rangeOfString:@"/"];
        if ([key hasPrefix:TGMenuKeyPrefix]) {
            if (TGIsStringList(value)) setup[key] = value;
        } else if (slash.location != NSNotFound) {
            if ([modes containsObject:[key substringToIndex:slash.location]] && TGIsKnownTrigger([key substringFromIndex:slash.location + 1]) && TGIsStringList(value)) setup[key] = value;
        } else if ([key isEqualToString:TGEnabledKey] || [key isEqualToString:TGRequireUnlockKey] || [key isEqualToString:TGShowBannersKey]) {
            // (Allow API is deliberately not imported: a shared setup shouldn't switch it on.)
            if ([value isKindOfClass:NSNumber.class]) setup[key] = value;
        } else if ([key isEqualToString:TGBlockedAppsKey]) {
            if ([value isKindOfClass:NSArray.class] && TGIsStringList(value)) setup[key] = value;
        } else if ([key isEqualToString:TGMenusKey] && [value isKindOfClass:NSArray.class]) {
            NSMutableArray *menus = [NSMutableArray array];
            for (id menu in value)
                if ([menu isKindOfClass:NSDictionary.class] && [menu[@"id"] isKindOfClass:NSString.class] && [menu[@"name"] isKindOfClass:NSString.class]) [menus addObject:@{ @"id": menu[@"id"], @"name": menu[@"name"] }];
            setup[key] = menus;
        }
    }];
    return setup;
}

// The current setup: every setup key with a real value (empty assignments skipped).
static NSDictionary *TGCurrentSetup(void) {
    CFStringRef domain = (__bridge CFStringRef)TGDomain;
    CFPreferencesAppSynchronize(domain);
    NSArray *keys = CFBridgingRelease(CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
    NSDictionary *values = keys.count ? CFBridgingRelease(CFPreferencesCopyMultiple((__bridge CFArrayRef)keys, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)) : @{};
    NSMutableDictionary *setup = [TGSanitizedSetup(values) mutableCopy];
    for (NSString *key in setup.allKeys)
        if (TGIsStringList(setup[key]) && ![key isEqualToString:TGBlockedAppsKey] && !TGActionList(setup[key]).count) [setup removeObjectForKey:key];
    return setup;
}

// What a setup would do, for the import review and export warning.
static NSString *TGSetupSummary(NSDictionary *setup, BOOL *hasCommands, BOOL *hasPersonal) {
    NSUInteger assignments = 0, commands = 0, urls = 0;
    BOOL personal = NO;
    for (NSString *key in setup) {
        if (!TGIsStringList(setup[key]) || [key isEqualToString:TGBlockedAppsKey]) continue;
        if ([key containsString:@"/"] && ![key hasPrefix:TGMenuKeyPrefix]) assignments++;
        if ([key containsString:TGWiFiJoinedPrefix] || [key containsString:TGWiFiLeftPrefix] || [key containsString:TGBTConnectedPrefix] || [key containsString:TGBTDisconnectedPrefix]) personal = YES;
        for (NSString *action in TGActionList(setup[key])) {
            if ([action hasPrefix:TGShellPrefix]) commands++;
            if ([action hasPrefix:TGURLPrefix] || [action hasPrefix:TGShortcutPrefix]) urls++;
        }
    }
    if (hasCommands) *hasCommands = commands > 0;
    if (hasPersonal) *hasPersonal = personal;
    return [NSString stringWithFormat:@"%lu assignments, %lu menus, %lu shell commands, %lu URLs or Shortcuts.",
        (unsigned long)assignments, (unsigned long)[setup[TGMenusKey] count], (unsigned long)commands, (unsigned long)urls];
}

@interface TGProfilesController : TGListController <UIDocumentPickerDelegate>
@end

@implementation TGProfilesController

- (PSSpecifier *)storageForKey:(NSString *)key {
    PSSpecifier *spec = [PSSpecifier emptyGroupSpecifier];
    [spec setProperty:TGDomain forKey:@"defaults"];
    [spec setProperty:key forKey:@"key"];
    return spec;
}

- (void)writeValue:(id)value forKey:(NSString *)key {
    [self setPreferenceValue:value specifier:[self storageForKey:key]];
}

- (NSDictionary *)profiles {
    id profiles = [self readPreferenceValue:[self storageForKey:TGProfilesKey]];
    return [profiles isKindOfClass:NSDictionary.class] ? profiles : @{};
}

- (NSString *)activeProfile {
    id name = [self readPreferenceValue:[self storageForKey:TGActiveProfileKey]];
    return [name isKindOfClass:NSString.class] && [name length] && self.profiles[name] ? name : nil;
}

// Replace the live setup: clear what isn't in `setup`, then write it.
- (void)applySetup:(NSDictionary *)setup {
    NSDictionary *defaults = TGSetupDefaults();
    for (NSString *key in TGCurrentSetup()) if (!setup[key]) [self writeValue:defaults[key] ?: @"" forKey:key];
    for (NSString *key in defaults) if (!setup[key]) [self writeValue:defaults[key] forKey:key];
    [setup enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) { [self writeValue:value forKey:key]; }];
    notify_post(TGPrefsChangedNotification);
}

- (void)saveCurrentAs:(NSString *)name {
    NSMutableDictionary *profiles = [self.profiles mutableCopy];
    profiles[name] = TGCurrentSetup();
    [self writeValue:profiles forKey:TGProfilesKey];
    [self writeValue:name forKey:TGActiveProfileKey];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        self.title = @"Profiles & Sharing";
        NSMutableArray *specs = [NSMutableArray array];
        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"Profiles"];
        [group setProperty:@"Tap a profile to switch to it or export it; swipe left to delete it. Switching saves your current setup into the active profile first, so nothing is lost." forKey:@"footerText"];
        [specs addObject:group];
        for (NSString *name in [self.profiles.allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
            PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:name target:self set:nil get:@selector(profileStatus:) detail:nil cell:PSTitleValueCell edit:nil];
            [row setProperty:name forKey:@"tgProfile"];
            [specs addObject:row];
        }
        [specs addObject:[self button:@"Save Current as Profile…" command:@"save"]];

        PSSpecifier *share = [PSSpecifier groupSpecifierWithName:@"Share"];
        [share setProperty:@"Export makes a file you can send with AirDrop, Messages or Files. Import replaces your current setup after showing what it contains." forKey:@"footerText"];
        [specs addObject:share];
        [specs addObject:[self button:@"Export Current Setup…" command:@"export"]];
        [specs addObject:[self button:@"Import Setup…" command:@"import"]];

        PSSpecifier *reset = [PSSpecifier groupSpecifierWithName:nil];
        [reset setProperty:TGButtonText(@"Clears every assignment, menu and setting, and turns off Allow API (Replace Button Actions goes back on). Saved profiles are kept.") forKey:@"footerText"];
        [specs addObject:reset];
        [specs addObject:[self button:@"Reset to Defaults…" command:@"reset"]];
        _specifiers = specs;
    }
    return _specifiers;
}

- (PSSpecifier *)button:(NSString *)title command:(NSString *)command {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:title target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
    [spec setProperty:command forKey:@"tgCommand"];
    return spec;
}

- (NSString *)swipeTitleForSpecifier:(PSSpecifier *)spec {
    return [spec propertyForKey:@"tgProfile"] ? @"Delete" : nil;
}

- (BOOL)swipedSpecifier:(PSSpecifier *)spec {
    [self deleteProfile:[spec propertyForKey:@"tgProfile"]];
    return YES;
}

- (void)deleteProfile:(NSString *)name {
    NSMutableDictionary *profiles = [self.profiles mutableCopy];
    BOOL active = [name isEqualToString:self.activeProfile];
    [profiles removeObjectForKey:name];
    [self writeValue:profiles forKey:TGProfilesKey];
    if (active) [self writeValue:@"" forKey:TGActiveProfileKey];
}

- (NSString *)profileStatus:(PSSpecifier *)spec {
    return [[spec propertyForKey:@"tgProfile"] isEqualToString:self.activeProfile] ? @"Active" : @"";
}

- (void)confirm:(NSString *)title message:(NSString *)message button:(NSString *)button destructive:(BOOL)destructive then:(void (^)(void))done {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:button style:destructive ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault handler:^(UIAlertAction *a) { done(); }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    PSSpecifier *spec = [self specifierAtIndex:[self indexForIndexPath:indexPath]];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    NSString *profile = [spec propertyForKey:@"tgProfile"], *command = [spec propertyForKey:@"tgCommand"];
    if (profile) [self showProfile:profile fromCell:cell];
    else if ([command isEqualToString:@"save"]) [self promptSave];
    else if ([command isEqualToString:@"export"]) [self exportSetup:TGCurrentSetup() name:@"Triggr Setup" fromCell:cell];
    else if ([command isEqualToString:@"import"]) [self pickImport];
    else if ([command isEqualToString:@"reset"]) {
        [self confirm:@"Reset to Defaults?" message:@"Every assignment, menu and setting is cleared. Saved profiles are kept." button:@"Reset" destructive:YES then:^{
            [self applySetup:@{}];
            [self writeValue:@NO forKey:TGAllowAPIKey]; // only Reset (or their switches) change these two
            [self writeValue:@YES forKey:TGLockReplacesKey];
            [self writeValue:@"" forKey:TGActiveProfileKey];
            [self reloadSpecifiers];
        }];
    }
}

- (void)showProfile:(NSString *)name fromCell:(UITableViewCell *)cell {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:name message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    if (![name isEqualToString:self.activeProfile]) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Switch To" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSString *active = self.activeProfile;
            if (active) [self saveCurrentAs:active]; // keep edits made since switching
            [self applySetup:TGSanitizedSetup(self.profiles[name])];
            [self writeValue:name forKey:TGActiveProfileKey];
            [self reloadSpecifiers];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Export" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSDictionary *setup = [name isEqualToString:self.activeProfile] ? TGCurrentSetup() : TGSanitizedSetup(self.profiles[name]);
        [self exportSetup:setup name:name fromCell:cell];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [self deleteProfile:name];
        [self reloadSpecifiers];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = cell;
    sheet.popoverPresentationController.sourceRect = cell.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)promptSave {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Save Profile" message:@"Saves your current assignments, menus and settings. An existing profile with this name is replaced." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"Name"; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *name = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!name.length) return;
        [self saveCurrentAs:name];
        [self reloadSpecifiers];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark Export / import

- (void)exportSetup:(NSDictionary *)setup name:(NSString *)name fromCell:(UITableViewCell *)cell {
    BOOL commands = NO, personal = NO;
    NSString *summary = TGSetupSummary(setup, &commands, &personal);
    NSMutableString *message = [summary mutableCopy];
    if (personal) [message appendString:@"\n\nIt includes the Wi-Fi network and Bluetooth device names used in your events."];
    if (commands) [message appendString:@"\n\nIt includes your shell commands; check they don't contain anything private."];
    [self confirm:@"Export Setup" message:message button:@"Share" destructive:NO then:^{
        NSDictionary *file = @{ @"Triggr": @1, @"setup": setup };
        NSData *data = [NSJSONSerialization dataWithJSONObject:file options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
        NSString *safeName = [[name componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\:"]] componentsJoinedByString:@"-"];
        NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[safeName stringByAppendingString:@".json"]]];
        if (![data writeToURL:url atomically:YES]) return;
        UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
        share.popoverPresentationController.sourceView = cell;
        share.popoverPresentationController.sourceRect = cell.bounds;
        [self presentViewController:share animated:YES completion:nil];
    }];
}

- (void)pickImport {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeJSON] asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSData *data = urls.firstObject ? [NSData dataWithContentsOfURL:urls.firstObject] : nil;
    id file = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![file isKindOfClass:NSDictionary.class] || ![file[@"Triggr"] isKindOfClass:NSNumber.class] || ![file[@"setup"] isKindOfClass:NSDictionary.class]) {
        [self confirm:@"Not a Triggr Setup" message:@"That file isn't a setup exported from Triggr." button:@"OK" destructive:NO then:^{}];
        return;
    }
    NSDictionary *setup = TGSanitizedSetup(file[@"setup"]);
    BOOL commands = NO;
    NSMutableString *message = [TGSetupSummary(setup, &commands, NULL) mutableCopy];
    [message appendString:@"\n\nThis replaces your current setup. Save it as a profile first if you want to keep it."];
    if (commands) [message appendString:@"\n\nThis setup runs shell commands on your device. Only import setups from people you trust."];
    [self confirm:@"Import Setup?" message:message button:@"Replace My Setup" destructive:YES then:^{
        [self applySetup:setup];
        [self writeValue:@"" forKey:TGActiveProfileKey];
        [self reloadSpecifiers];
    }];
}

@end

#pragma mark - Options

@interface TGOptionsController : TGListController
@end

@implementation TGOptionsController

- (NSArray *)specifiers {
    if (!_specifiers) {
        self.title = @"Options";
        NSMutableArray *specs = [NSMutableArray array];
        PSSpecifier *banners = [PSSpecifier groupSpecifierWithName:nil];
        [banners setProperty:@"A small banner names what just ran." forKey:@"footerText"];
        [specs addObject:banners];
        [specs addObject:TGSwitchRow(@"Show Action Banners", TGShowBannersKey, NO, self)];

        PSSpecifier *block = [PSSpecifier groupSpecifierWithName:nil];
        [block setProperty:@"Triggers are ignored while one of these apps is open, e.g. a game that uses the volume buttons." forKey:@"footerText"];
        [specs addObject:block];
        // AltList's multi-app list saves through this row's own setter and getter
        // (like Open App), which store the list through PSListController.
        PSSpecifier *blockList = [PSSpecifier preferenceSpecifierNamed:@"Block List" target:self set:@selector(setBlockedApps:specifier:)
            get:@selector(blockedApps:) detail:ATLApplicationListMultiSelectionController.class cell:PSLinkCell edit:nil];
        [blockList setProperty:@YES forKey:@"useSearchBar"];
        [blockList setProperty:@[@{ @"sectionType": @"Visible" }] forKey:@"sections"];
        [specs addObject:blockList];

        PSSpecifier *lock = [PSSpecifier groupSpecifierWithName:@"Lock Screen"];
        [lock setProperty:@"Apps, URLs and Shortcuts can't open over the Lock Screen, so they always wait until you unlock. With this on, shell commands wait too (when a passcode is set). Other actions run straight away." forKey:@"footerText"];
        [specs addObject:lock];
        [specs addObject:TGSwitchRow(@"Commands Need Passcode", TGRequireUnlockKey, YES, self)];

        PSSpecifier *buttons = [PSSpecifier groupSpecifierWithName:@"Buttons"];
        [buttons setProperty:TGButtonText(@"On: an assigned press runs instead of the button's own action (going Home, the volume step, locking, muting…). To keep that too, add the matching action, like Sleep for the lock button. Off: everything runs alongside the buttons and the mute switch. Waking, Emergency SOS and force restart always work as usual.") forKey:@"footerText"];
        [specs addObject:buttons];
        PSSpecifier *replace = [PSSpecifier preferenceSpecifierNamed:@"Replace Button Actions" target:self set:@selector(setPreferenceValue:specifier:)
            get:@selector(readPreferenceValue:) detail:nil cell:PSSwitchCell edit:nil];
        [replace setProperty:TGDomain forKey:@"defaults"];
        [replace setProperty:TGLockReplacesKey forKey:@"key"];
        [replace setProperty:@YES forKey:@"default"];
        [replace setProperty:@TGPrefsChangedNotification forKey:@"PostNotification"];
        [specs addObject:replace];

        PSSpecifier *api = [PSSpecifier groupSpecifierWithName:@"API"];
        [api setProperty:@"Lets other tweaks and the triggr command run your triggers, menus and built-in actions (never shell commands, URLs or apps directly). Any app could ask, so leave it off unless you use it. \"triggr list\" shows the ids." forKey:@"footerText"];
        [specs addObject:api];
        [specs addObject:TGSwitchRow(@"Allow API", TGAllowAPIKey, NO, self)];
        _specifiers = specs;
    }
    return _specifiers;
}

- (PSSpecifier *)blockListStorage {
    PSSpecifier *spec = [PSSpecifier emptyGroupSpecifier];
    [spec setProperty:TGDomain forKey:@"defaults"];
    [spec setProperty:TGBlockedAppsKey forKey:@"key"];
    [spec setProperty:@TGPrefsChangedNotification forKey:@"PostNotification"];
    return spec;
}

- (void)setBlockedApps:(NSArray *)apps specifier:(PSSpecifier *)spec {
    [self setPreferenceValue:[apps isKindOfClass:NSArray.class] ? apps : @[] specifier:[self blockListStorage]];
}

- (NSArray *)blockedApps:(PSSpecifier *)spec {
    id apps = [self readPreferenceValue:[self blockListStorage]];
    return [apps isKindOfClass:NSArray.class] ? apps : @[];
}

@end

#pragma mark - Root

@interface TGRootListController : TGListController
@end

@implementation TGRootListController {
    NSDictionary<NSString *, NSArray<NSString *> *> *_assignments;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _assignments = TGAllAssignments();
        NSMutableArray *specs = [NSMutableArray array];
        [specs addObject:[PSSpecifier emptyGroupSpecifier]];
        [specs addObject:TGSwitchRow(@"Enabled", TGEnabledKey, YES, self)];

        PSSpecifier *assign = [PSSpecifier groupSpecifierWithName:@"Assign"];
        [assign setProperty:@"Choose where it should work, then a trigger and what it runs. Most assignments belong in Anywhere." forKey:@"footerText"];
        [specs addObject:assign];
        NSDictionary<NSString *, NSArray *> *icons = @{
            @"anywhere": @[@"globe", UIColor.systemBlueColor], @"home": @[@"house.fill", UIColor.systemIndigoColor],
            @"app": @[@"square.grid.2x2.fill", UIColor.systemOrangeColor], @"lock": @[@"lock.fill", UIColor.systemGrayColor],
        };
        for (int m = 0; m < TG_COUNT(TGModes); m++) {
            NSString *mode = @(TGModes[m].identifier);
            PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:@(TGModes[m].title) target:self set:nil get:@selector(modeCount:)
                detail:TGModeController.class cell:PSLinkListCell edit:nil];
            [spec setProperty:mode forKey:@"tgMode"];
            TGSetIcon(spec, icons[mode][0], icons[mode][1]);
            [specs addObject:spec];
        }

        [specs addObject:[PSSpecifier emptyGroupSpecifier]];
        PSSpecifier *all = [PSSpecifier preferenceSpecifierNamed:@"All Assignments" target:self set:nil get:@selector(assignmentCount:)
            detail:TGByActionController.class cell:PSLinkListCell edit:nil];
        TGSetIcon(all, @"list.bullet", UIColor.systemGreenColor);
        [specs addObject:all];
        PSSpecifier *menus = [PSSpecifier preferenceSpecifierNamed:@"Menus" target:self set:nil get:@selector(menuCount:) detail:TGMenusController.class cell:PSLinkListCell edit:nil];
        TGSetIcon(menus, @"list.bullet.rectangle.fill", UIColor.systemPinkColor);
        [specs addObject:menus];

        PSSpecifier *more = [PSSpecifier groupSpecifierWithName:nil];
        [more setProperty:[NSString stringWithFormat:@"Triggr %@ by John d_ie", [TG_VERSION stringByReplacingOccurrencesOfString:@"~" withString:@" "]] forKey:@"footerText"];
        [more setProperty:@1 forKey:@"footerAlignment"]; // centred
        [specs addObject:more];
        PSSpecifier *options = [PSSpecifier preferenceSpecifierNamed:@"Options" target:self set:nil get:nil detail:TGOptionsController.class cell:PSLinkCell edit:nil];
        TGSetIcon(options, @"gearshape.fill", UIColor.systemGrayColor);
        [specs addObject:options];
        PSSpecifier *profiles = [PSSpecifier preferenceSpecifierNamed:@"Profiles & Sharing" target:self set:nil get:@selector(activeProfileName:) detail:TGProfilesController.class cell:PSLinkListCell edit:nil];
        TGSetIcon(profiles, @"square.and.arrow.up.fill", UIColor.systemBlueColor);
        [specs addObject:profiles];
        _specifiers = specs;
    }
    return _specifiers;
}

- (NSString *)modeCount:(PSSpecifier *)spec {
    NSString *prefix = [[spec propertyForKey:@"tgMode"] stringByAppendingString:@"/"];
    NSUInteger count = 0;
    for (NSString *key in _assignments) if ([key hasPrefix:prefix]) count++;
    return TGCountTitle(count);
}

- (NSString *)assignmentCount:(PSSpecifier *)spec {
    return TGCountTitle(_assignments.count);
}

- (NSString *)menuCount:(PSSpecifier *)spec {
    return TGCountTitle(TGReadMenus().count);
}

- (NSString *)activeProfileName:(PSSpecifier *)spec {
    PSSpecifier *storage = [PSSpecifier emptyGroupSpecifier];
    [storage setProperty:TGDomain forKey:@"defaults"];
    [storage setProperty:TGActiveProfileKey forKey:@"key"];
    id name = [self readPreferenceValue:storage];
    return [name isKindOfClass:NSString.class] ? name : @"";
}

@end

