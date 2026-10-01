// triggr: run Triggr actions, triggers and menus from the command line.
// It only posts the API's Darwin notifications; SpringBoard decides what runs
// (and nothing does unless "Allow API" is on in Settings → Triggr).

#import <Foundation/Foundation.h>
#import <notify.h>
#import "../Shared/TGCatalog.h"

// Triggr's settings live in the mobile user's domain, whoever runs this.
static id TGSetting(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyValue((__bridge CFStringRef)key, (__bridge CFStringRef)TGDomain, CFSTR("mobile"), kCFPreferencesAnyHost));
}

static int TGUsage(void) {
    fprintf(stderr,
        "usage: triggr run <action>        run a built-in action (see: triggr list)\n"
        "       triggr trigger <trigger>   run what's assigned to a trigger\n"
        "       triggr menu <name>         show one of your menus\n"
        "       triggr list                list actions and triggers\n");
    return 64;
}

static void TGPrint(const TGGroup *groups, int count) {
    for (int g = 0; g < count; g++) {
        printf("%s\n", groups[g].title);
        for (int i = 0; i < groups[g].count; i++) printf("  %-22s %s\n", groups[g].items[i].identifier, groups[g].items[i].title);
    }
}

static int TGPost(NSString *name) {
    uint32_t status = notify_post([@TGAPIPrefix stringByAppendingString:name].UTF8String);
    if (status != NOTIFY_STATUS_OK) {
        fprintf(stderr, "triggr: couldn't send (notify status %u)\n", status);
        return 1;
    }
    return 0;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc < 2) return TGUsage();
        NSString *command = @(argv[1]);
        if ([command isEqualToString:@"list"]) {
            printf("Actions (triggr run <action>):\n");
            TGPrint(TGActionGroups, TG_COUNT(TGActionGroups));
            printf("\nTriggers (triggr trigger <trigger>; runs only if assigned):\n");
            TGPrint(TGTriggerGroups, TG_COUNT(TGTriggerGroups));
            return 0;
        }
        if (argc < 3) return TGUsage();
        NSString *value = @(argv[2]);
        if (![TGSetting(TGAllowAPIKey) boolValue]) {
            fprintf(stderr, "triggr: turn on Settings → Triggr → Allow API first.\n");
            return 1;
        }
        if ([command isEqualToString:@"run"]) {
            BOOL known = NO;
            for (int g = 0; g < TG_COUNT(TGActionGroups); g++)
                for (int i = 0; i < TGActionGroups[g].count; i++)
                    if ([value isEqualToString:@(TGActionGroups[g].items[i].identifier)]) known = YES;
            if (!known) {
                fprintf(stderr, "triggr: unknown action '%s' (see: triggr list)\n", argv[2]);
                return 1;
            }
            return TGPost([@"run/" stringByAppendingString:value]);
        }
        if ([command isEqualToString:@"trigger"]) {
            if (!TGIsKnownTrigger(value)) {
                fprintf(stderr, "triggr: unknown trigger '%s' (see: triggr list)\n", argv[2]);
                return 1;
            }
            return TGPost([@"trigger/" stringByAppendingString:value]);
        }
        if ([command isEqualToString:@"menu"]) {
            id menus = TGSetting(TGMenusKey);
            for (id menu in [menus isKindOfClass:NSArray.class] ? menus : @[])
                if ([menu isKindOfClass:NSDictionary.class] && [[menu[@"name"] description] caseInsensitiveCompare:value] == NSOrderedSame)
                    return TGPost([@"menu/" stringByAppendingString:[menu[@"id"] description]]);
            fprintf(stderr, "triggr: no menu named '%s'\n", argv[2]);
            return 1;
        }
        return TGUsage();
    }
}
