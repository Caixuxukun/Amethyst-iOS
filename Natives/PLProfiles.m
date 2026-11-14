#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "utils.h"

static PLProfiles* current;
NSNotificationName const PLProfilesDidChangeNotification = @"PLProfilesDidChange";

@interface PLProfiles()
- (void)migrateLegacyRendererSelection;
@end

@implementation PLProfiles

+ (id)defaultProfiles {
    return @{
        @"profiles": @{
            @"(Default)": @{
                @"name": @"(Default)",
                @"lastVersionId": @"latest-release"
            }
        },
        @"selectedProfile": @"(Default)"
    }.mutableCopy;
}

+ (PLProfiles *)current {
    if (!current) {
        [self updateCurrent];
    }
    return current;
}

+ (void)updateCurrent {
    current = [[PLProfiles alloc] initWithCurrentInstance];
    [NSNotificationCenter.defaultCenter postNotificationName:PLProfilesDidChangeNotification object:current];
}

+ (id)profile:(NSMutableDictionary *)profile resolveKey:(id)key {
    NSString *value = profile[key];
    if (value.length > 0) {
        //NSDebugLog(@"[PLProfiles] Applying %@: \"%@\"", key, value);
        return value;
    }

    NSDictionary *valueDefaults = @{
        @"javaVersion": @"0",
        @"gameDir": @"."
    };
    if (valueDefaults[key]) {
        return valueDefaults[key];
    }

    NSDictionary *prefDefaults = @{
        @"defaultTouchCtrl": @"control.default_ctrl",
        @"defaultGamepadCtrl": @"control.default_gamepad_ctrl",
        @"javaArgs": @"java.java_args",
        @"renderer": @"video.renderer",
        @"vulkanRenderer": @"video.vulkan_renderer"
    };
    return getPrefObject(prefDefaults[key]);
}

+ (id)resolveKeyForCurrentProfile:(id)key {
    return [self profile:self.current.selectedProfile resolveKey:key];
}

- (id)initWithCurrentInstance {
    self = [super init];
    self.profilePath = [@(getenv("GAME_DIR")) stringByAppendingPathComponent:@"launcher_profiles.json"];
    self.profileDict = parseJSONFromFile(self.profilePath);
    if (self.profileDict[@"NSErrorObject"]) {
        self.profileDict = PLProfiles.defaultProfiles;
        [self save];
    }

    [self migrateLegacyRendererSelection];

    return self;
}

// Before the OpenGL renderer and the Vulkan driver were separate settings, picking
// MoltenVK/KosmicKrisp stored the driver in the renderer key and forced ANGLE for OpenGL.
// Move those profiles to ANGLE + the Vulkan driver they had been using.
- (void)migrateLegacyRendererSelection {
    NSMutableDictionary *profiles = self.profileDict[@"profiles"];
    if (![profiles isKindOfClass:NSMutableDictionary.class]) return;

    BOOL changed = NO;
    for (NSString *name in profiles.allKeys) {
        NSMutableDictionary *profile = profiles[name];
        if (![profile isKindOfClass:NSMutableDictionary.class]) continue;
        NSString *storedRenderer = profile[@"renderer"];
        if (!ame_renderer_name_is_vulkan_driver(storedRenderer.UTF8String)) continue;

        NSString *storedDriver = profile[@"vulkanRenderer"];
        if (storedDriver.length == 0 || [storedDriver isEqualToString:@RENDERER_NAME_AUTO]) {
            profile[@"vulkanRenderer"] = storedRenderer;
        }
        profile[@"renderer"] = @RENDERER_NAME_MTL_ANGLE;
        changed = YES;
        NSLog(@"[PLProfiles] Migrated renderer \"%@\" of profile \"%@\" to ANGLE + Vulkan driver %@",
              storedRenderer, name, profile[@"vulkanRenderer"]);
    }

    if (changed) [self save];
}

- (id)profiles {
    return self.profileDict[@"profiles"];
}

- (id)selectedProfile {
    return self.profiles[self.selectedProfileName];
}

- (NSString *)selectedProfileName {
    return (id)self.profileDict[@"selectedProfile"];
}

- (void)setSelectedProfileName:(NSString *)name {
    self.profileDict[@"selectedProfile"] = (id)name;
    [self save];
    [NSNotificationCenter.defaultCenter postNotificationName:PLProfilesDidChangeNotification object:self];
}

- (void)save {
    saveJSONToFile(self.profileDict, self.profilePath);
}

@end
