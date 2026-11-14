#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <dlfcn.h>
#import <objc/message.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#import "JITManager.h"
#import "LauncherPreferences.h"
#import "utils.h"

#if AME_JIT
#import <AVFAudio/AVFAudio.h>
#import "external/stikpair/include/stikpair.h"
#endif

static NSString *const AMEJITHelperItemKey = @"amethyst-jit-request";
static NSString *const AMEJITHelperResponseKey = @"amethyst-jit-response";
static NSString *const AMEJITHelperBundleName = @"AmethystJITHelper.appex";

#pragma mark - Helper extension plumbing

// The private NSExtension API from ExtensionFoundation, the same calls
// LiveContainer uses to start its LiveProcess. The helper is a classic app
// extension on com.apple.ar.viewer (see Natives/jit/AmethystJITHelper-Info.plist),
// so it has to be started through this interface rather than a URL scheme.
typedef id (*AMEJITExtensionWithIdentifier)(id, SEL, NSString *, NSError **);
typedef void (*AMEJITBeginExtensionRequest)(id, SEL, NSArray *, void (^)(NSUUID *));
typedef void (*AMEJITSetRequestCompletion)(id, SEL, void (^)(NSUUID *, NSArray *));
typedef void (*AMEJITSetRequestCancellation)(id, SEL, void (^)(NSUUID *, NSError *));
typedef void (*AMEJITSetRequestInterruption)(id, SEL, void (^)(NSUUID *));
typedef int32_t (*AMEJITPIDForRequest)(id, SEL, NSUUID *);

@interface AMEJITHelperRequest : NSObject
@property(nonatomic, strong) id extension;
@property(nonatomic, copy) void (^completion)(NSDictionary *_Nullable response, NSError *_Nullable error);
@end

@implementation AMEJITHelperRequest
@end

static NSMutableArray<AMEJITHelperRequest *> *AMEJITRunningRequests(void) {
    static NSMutableArray *requests;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ requests = [NSMutableArray array]; });
    return requests;
}

static Class AMEJITExtensionClass(void) {
    Class cls = NSClassFromString(@"NSExtension");
    if (cls == Nil) {
        dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW);
        cls = NSClassFromString(@"NSExtension");
    }
    return cls;
}

static NSString *AMEJITHelperIdentifier(void) {
    NSURL *plugins = NSBundle.mainBundle.builtInPlugInsURL;
    NSURL *bundleURL = [plugins URLByAppendingPathComponent:AMEJITHelperBundleName];
    NSString *identifier = [NSBundle bundleWithURL:bundleURL].bundleIdentifier;
    return identifier;
}

#if AME_JIT

#pragma mark - Pairing host

static NSString *const AMEPairingServiceType = @"_remotepairing-pairable-host._tcp.";

static void AMEPairingReadyCallback(void *context, const char *serviceID, uint16_t port,
                                    const char *const *txtKeys, const char *const *txtVals, size_t txtCount);
static void AMEPairingPINCallback(const char *pin, void *context);

static NSMutableSet *AMEJITActivePairings(void) {
    static NSMutableSet *sessions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sessions = [NSMutableSet set]; });
    return sessions;
}

@class AMEJITPairingKeepAlive;

@interface AMEJITPairingSession : NSObject
@property(nonatomic, weak) UIViewController *presenter;
@property(nonatomic, strong) NSNetService *service;
@property(nonatomic, strong) AMEJITPairingKeepAlive *keepAlive;
@property(nonatomic, assign) UIBackgroundTaskIdentifier backgroundTask;
@property(nonatomic, assign) BOOL finished;
@property(nonatomic, copy) void (^completion)(BOOL success, NSString *message);
- (void)start;
- (void)finishWithCode:(int32_t)code result:(StikPairResult *)result;
- (void)advertiseWithName:(NSString *)name port:(int32_t)port txt:(NSDictionary<NSString *, NSData *> *)txt;
- (void)showPIN:(NSString *)pin;
@end

/// Silent looping audio, the same keep-alive the StikPair app uses, so the pairing
/// socket survives while the player is in Settings entering the code. Amethyst
/// declares the audio background mode for this.
@interface AMEJITPairingKeepAlive : NSObject
@property(nonatomic, strong) AVAudioEngine *engine;
@property(nonatomic, strong) AVAudioPlayerNode *player;
@property(nonatomic, assign) BOOL running;
- (void)start;
- (void)stop;
@end

@implementation AMEJITPairingKeepAlive

- (void)start {
    if (self.running) return;
    AVAudioEngine *engine = [AVAudioEngine new];
    AVAudioPlayerNode *player = [AVAudioPlayerNode new];
    @try {
        AVAudioSession *session = AVAudioSession.sharedInstance;
        [session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault
                     options:AVAudioSessionCategoryOptionMixWithOthers error:nil];
        [session setActive:YES error:nil];

        AVAudioFormat *format = [engine.outputNode inputFormatForBus:0];
        [engine attachNode:player];
        [engine connect:player to:engine.mainMixerNode format:format];

        AVAudioFrameCount frames = (AVAudioFrameCount)format.sampleRate;
        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:frames];
        if (buffer == nil) return;
        buffer.frameLength = frames;
        [engine startAndReturnError:nil];
        [player scheduleBuffer:buffer atTime:nil options:AVAudioPlayerNodeBufferLoops completionHandler:nil];
        [player play];
        self.engine = engine;
        self.player = player;
        self.running = YES;
        NSLog(@"[JIT] pairing keep-alive audio started");
    } @catch (NSException *exception) {
        NSLog(@"[JIT] pairing keep-alive audio failed: %@", exception.reason);
    }
}

- (void)stop {
    if (!self.running) return;
    [self.player stop];
    [self.engine stop];
    [self.engine detachNode:self.player];
    [[AVAudioSession sharedInstance] setActive:NO
                                   withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                         error:nil];
    self.player = nil;
    self.engine = nil;
    self.running = NO;
}

@end

static void AMEJITPostLocalNotification(NSString *title, NSString *body) {
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = title;
    content.body = body;
    content.sound = nil;
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:@"amethyst-jit-pairing"
                                                                         content:content
                                                                         trigger:nil];
    [center addNotificationRequest:request withCompletionHandler:nil];
}

#endif // AME_JIT

@interface JITManager ()
@end

@implementation JITManager

+ (instancetype)shared {
    static JITManager *manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ manager = [JITManager new]; });
    return manager;
}

#pragma mark Settings

+ (AMEJITMethod)selectedMethod {
    NSString *value = getPrefObject(@"jit.method");
    if ([value isEqualToString:@"wait"]) return AMEJITMethodWait;
    if ([value isEqualToString:@"builtin"]) return AMEJITMethodBuiltIn;
    return AMEJITMethodStikDebug;
}

+ (void)setSelectedMethod:(AMEJITMethod)method {
    NSString *value = @"stikdebug";
    if (method == AMEJITMethodWait) value = @"wait";
    else if (method == AMEJITMethodBuiltIn) value = @"builtin";
    setPrefObject(@"jit.method", value);
}

+ (BOOL)forceScript {
    return getPrefBool(@"jit.force_script");
}

+ (void)setForceScript:(BOOL)forceScript {
    setPrefBool(@"jit.force_script", forceScript);
}

#pragma mark Availability

+ (BOOL)deviceHasGetTaskAllow {
    return getEntitlementValue(@"get-task-allow");
}

+ (BOOL)builtInSupported {
    return self.builtInUnavailableReason == nil;
}

+ (nullable NSString *)builtInUnavailableReason {
#if TARGET_OS_SIMULATOR
    return @"Built-in JIT is available only on a physical device.";
#else
    if (@available(iOS 17.4, *)) {
        if (getenv("LC_HOME_PATH") != NULL) {
            return @"Built-in JIT is unavailable inside LiveContainer. Use StikDebug instead.";
        }
        if (AMEJITHelperIdentifier() == nil) {
            return @"Amethyst's JIT helper is missing from this installation. Reinstall the app and keep its app extensions, or use StikDebug.";
        }
        return nil;
    }
    return @"Built-in JIT requires iOS 17.4 or later.";
#endif
}

+ (BOOL)pairingSupported {
    return self.pairingUnavailableReason == nil;
}

+ (nullable NSString *)pairingUnavailableReason {
#if !AME_JIT
    return @"On-device pairing is included in the iOS build only.";
#elif TARGET_OS_SIMULATOR
    return @"On-device pairing is available only on a physical device.";
#else
    if (@available(iOS 27.0, *)) {
        if (getenv("LC_HOME_PATH") != NULL) {
            return @"On-device pairing is unavailable inside LiveContainer. Import a pairing file instead.";
        }
        return nil;
    }
    return @"On-device pairing requires iOS 27 or later. Import a pairing file made on a computer instead.";
#endif
}

+ (BOOL)isJITReady {
    return isJITEnabled(NO);
}

+ (NSString *)txmStatusDescription {
    JITFlags flags = DeviceGetJITFlags(YES);
    if ((flags & JIT_FLAG_HAS_TXM) != 0) return @"Present";
    return @"Not present";
}

#pragma mark Pairing file

+ (NSString *)pairingPath {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [[documents stringByAppendingPathComponent:@"StikJIT"] stringByAppendingPathComponent:@"pairingFile.plist"];
}

+ (BOOL)hasPairingFile {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:self.pairingPath error:nil];
    return [attributes[NSFileSize] unsignedLongLongValue] > 0;
}

+ (void)importPairingFileFromURL:(NSURL *)url completion:(void (^)(NSError *_Nullable))completion {
    BOOL scoped = [url startAccessingSecurityScopedResource];
    void (^finish)(NSError *) = ^(NSError *error) {
        if (scoped) [url stopAccessingSecurityScopedResource];
        if (completion) completion(error);
    };
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:nil];
    if (data.length == 0) {
        finish([NSError errorWithDomain:@"AmethystJIT" code:1
                              userInfo:@{NSLocalizedDescriptionKey: @"That file is empty or could not be read."}]);
        return;
    }

    NSString *path = self.pairingPath;
    NSString *directory = path.stringByDeletingLastPathComponent;
    NSError *error = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error];
    if (error == nil) {
        [data writeToFile:path options:NSDataWritingAtomic error:&error];
    }
    finish(error);
}

#pragma mark Helper extension requests

+ (void)sendHelperRequest:(NSDictionary *)request
               completion:(void (^)(NSDictionary *_Nullable response, NSError *_Nullable error))completion {
    void (^fail)(NSString *) = ^(NSString *message) {
        if (completion) {
            completion(nil, [NSError errorWithDomain:@"AmethystJIT" code:2
                                           userInfo:@{NSLocalizedDescriptionKey: message}]);
        }
    };

    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self sendHelperRequest:request completion:completion];
        });
        return;
    }

    if (self.builtInUnavailableReason != nil) {
        fail(self.builtInUnavailableReason);
        return;
    }
    NSString *identifier = AMEJITHelperIdentifier();
    Class extensionClass = AMEJITExtensionClass();
    if (extensionClass == Nil) {
        fail(@"iOS did not provide the extension API the JIT helper needs.");
        return;
    }

    NSError *error = nil;
    id extension = ((AMEJITExtensionWithIdentifier)objc_msgSend)(
        (id)extensionClass, @selector(extensionWithIdentifier:error:), identifier, &error);
    if (extension == nil) {
        fail([NSString stringWithFormat:
              @"Amethyst's JIT helper (%@) could not be found: %@. Reinstall the app and keep its app extensions, or use StikDebug.",
              identifier, error.localizedDescription ?: @"unknown error"]);
        return;
    }

    NSData *payload = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    if (payload == nil) {
        fail(@"The JIT helper request could not be encoded.");
        return;
    }

    AMEJITHelperRequest *running = [AMEJITHelperRequest new];
    running.extension = extension;
    running.completion = completion;
    [AMEJITRunningRequests() addObject:running];

    void (^finish)(NSDictionary *, NSError *) = ^(NSDictionary *response, NSError *failure) {
        if (![AMEJITRunningRequests() containsObject:running]) return;
        [AMEJITRunningRequests() removeObject:running];
        if (running.completion) running.completion(response, failure);
    };

    ((AMEJITSetRequestCompletion)objc_msgSend)(extension, @selector(setRequestCompletionBlock:),
        ^(NSUUID *uuid, NSArray *items) {
            NSData *data = ((NSExtensionItem *)items.firstObject).userInfo[AMEJITHelperResponseKey];
            NSDictionary *response = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (response == nil) {
                    finish(nil, [NSError errorWithDomain:@"AmethystJIT" code:3
                                               userInfo:@{NSLocalizedDescriptionKey:
                                                   @"Amethyst's JIT helper finished without an answer."}]);
                } else {
                    finish(response, nil);
                }
            });
        });
    ((AMEJITSetRequestCancellation)objc_msgSend)(extension, @selector(setRequestCancellationBlock:),
        ^(NSUUID *uuid, NSError *cancelError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                finish(nil, [NSError errorWithDomain:@"AmethystJIT" code:4
                                           userInfo:@{NSLocalizedDescriptionKey:
                                               [NSString stringWithFormat:@"Amethyst's JIT helper stopped: %@",
                                                cancelError.localizedDescription ?: @"the request was cancelled"]}]);
            });
        });
    ((AMEJITSetRequestInterruption)objc_msgSend)(extension, @selector(setRequestInterruptionBlock:),
        ^(NSUUID *uuid) {
            dispatch_async(dispatch_get_main_queue(), ^{
                finish(nil, [NSError errorWithDomain:@"AmethystJIT" code:5
                                           userInfo:@{NSLocalizedDescriptionKey:
                                               @"Amethyst's JIT helper stopped unexpectedly. Try again."}]);
            });
        });

    NSExtensionItem *item = [NSExtensionItem new];
    item.userInfo = @{AMEJITHelperItemKey: payload};
    ((AMEJITBeginExtensionRequest)objc_msgSend)(extension, @selector(beginExtensionRequestWithInputItems:completion:),
        @[item], ^(NSUUID *uuid) {
            if (uuid == nil) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    finish(nil, [NSError errorWithDomain:@"AmethystJIT" code:6
                                               userInfo:@{NSLocalizedDescriptionKey:
                                                   @"Amethyst's JIT helper did not start. Reinstall the app and keep its app extensions, or use StikDebug."}]);
                });
            } else {
                NSLog(@"[JIT] helper request started as pid %d",
                      ((AMEJITPIDForRequest)objc_msgSend)(extension, @selector(pidForRequestIdentifier:), uuid));
            }
        });
}

+ (NSData *)pairingDataOrError:(NSError **)error {
    NSString *path = self.pairingPath;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"AmethystJIT" code:7
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"Import a pairing file first (Settings -> JIT -> pairing file)."}];
        }
        return nil;
    }
    return data;
}

+ (void)enableBuiltInJITWithCompletion:(void (^)(NSError *_Nullable error))completion {
    NSError *error = nil;
    if (!self.builtInSupported) {
        if (completion) completion([NSError errorWithDomain:@"AmethystJIT" code:8
                                                   userInfo:@{NSLocalizedDescriptionKey: self.builtInUnavailableReason}]);
        return;
    }
    if (!self.deviceHasGetTaskAllow) {
        if (completion) completion([NSError errorWithDomain:@"AmethystJIT" code:9
                                                   userInfo:@{NSLocalizedDescriptionKey:
                                                       @"This installation does not have the get-task-allow entitlement. Reinstall Amethyst with a signing method that keeps it (SideStore, AltStore, iloader, StikDebug-supported installers)."}]);
        return;
    }
    NSData *pairing = [self pairingDataOrError:&error];
    if (pairing == nil) {
        if (completion) completion(error);
        return;
    }
    NSData *scriptData = [NSData dataWithContentsOfFile:
        [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
    if (scriptData.length == 0) {
        if (completion) completion([NSError errorWithDomain:@"AmethystJIT" code:10
                                                   userInfo:@{NSLocalizedDescriptionKey:
                                                       @"UniversalJIT26.js is missing from the app bundle."}]);
        return;
    }

    NSDictionary *request = @{
        @"operation": @"enable",
        @"targetPID": @(getpid()),
        @"pairingBase64": [pairing base64EncodedStringWithOptions:0],
        @"scriptBase64": [scriptData base64EncodedStringWithOptions:0],
    };
    [self sendHelperRequest:request completion:^(NSDictionary *response, NSError *error) {
        if (error) {
            if (completion) completion(error);
            return;
        }
        BOOL success = [response[@"success"] boolValue];
        NSString *message = response[@"message"] ?: @"";
        if (!success && completion) {
            completion([NSError errorWithDomain:@"AmethystJIT" code:11
                                       userInfo:@{NSLocalizedDescriptionKey: message.length ? message : @"The JIT helper failed."}]);
        } else if (completion) {
            completion(nil);
        }
    }];
}

#pragma mark JIT acquisition

+ (NSString *)stikDebugURLString {
    NSMutableString *url = [NSMutableString stringWithFormat:
        @"stikdebug://enable-jit?bundle-id=%@&pid=%d",
        NSBundle.mainBundle.bundleIdentifier, getpid()];
    if (DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM)) {
        NSString *scriptPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"];
        NSData *script = [NSData dataWithContentsOfFile:scriptPath];
        if (script.length > 0) {
            [url appendFormat:@"&script-data=%@", [script base64EncodedStringWithOptions:0]];
        }
    }
    return url;
}

+ (void)openStikDebugForJIT {
    NSURL *stikDebug = [NSURL URLWithString:self.stikDebugURLString];
    if ([UIApplication.sharedApplication canOpenURL:stikDebug]) {
        [UIApplication.sharedApplication openURL:stikDebug options:@{} completionHandler:nil];
        return;
    }
    NSURL *legacy = [NSURL URLWithString:[self.stikDebugURLString stringByReplacingOccurrencesOfString:@"stikdebug://" withString:@"stikjit://"]];
    if ([UIApplication.sharedApplication canOpenURL:legacy]) {
        [UIApplication.sharedApplication openURL:legacy options:@{} completionHandler:nil];
    }
}

+ (void)startJITAcquisitionWithProgress:(void (^)(NSString *status))progress
                             completion:(void (^)(NSError *_Nullable error))completion {
    AMEJITMethod method = self.selectedMethod;
    if (method == AMEJITMethodBuiltIn) {
        NSError *error = nil;
        if (!self.builtInSupported) {
            error = [NSError errorWithDomain:@"AmethystJIT" code:12
                                    userInfo:@{NSLocalizedDescriptionKey: self.builtInUnavailableReason}];
        } else if (!self.deviceHasGetTaskAllow) {
            error = [NSError errorWithDomain:@"AmethystJIT" code:13
                                    userInfo:@{NSLocalizedDescriptionKey:
                                        @"This installation does not have get-task-allow; built-in JIT cannot attach. Reinstall with a debug-signing installer or choose StikDebug."}];
        } else if (!self.hasPairingFile) {
            error = [NSError errorWithDomain:@"AmethystJIT" code:14
                                    userInfo:@{NSLocalizedDescriptionKey:
                                        @"Built-in JIT needs this device's pairing file. Import one in Settings -> JIT, or pair this iPhone there."}];
        }
        if (error) {
            if (completion) completion(error);
            return;
        }
        if (progress) progress(@"Starting the built-in JIT helper...");
        [self enableBuiltInJITWithCompletion:^(NSError *error) {
            if (error) NSLog(@"[JIT] built-in JIT failed: %@", error.localizedDescription);
        }];
        if (completion) completion(nil);
        return;
    }

    if (method == AMEJITMethodStikDebug) {
        if (progress) progress(@"Opening StikDebug...");
        [self openStikDebugForJIT];
        if (completion) completion(nil);
        return;
    }

    if (progress) progress(@"Waiting for an external debugger...");
    if (completion) completion(nil);
}

#pragma mark Pairing

+ (void)startPairingFromViewController:(UIViewController *)presenter {
#if !AME_JIT
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"On-device pairing"
                                                                   message:self.pairingUnavailableReason
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
    return;
#else
    if (self.pairingUnavailableReason != nil) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"On-device pairing"
                                                                       message:self.pairingUnavailableReason
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
        return;
    }

    UIAlertController *intro = [UIAlertController
        alertControllerWithTitle:@"Pair this iPhone"
                         message:@"1. Keep Wi-Fi on and allow Local Network access.\n"
                                 @"2. Return to Amethyst when Settings opens on \"Pair with Amethyst\".\n"
                                 @"3. Enter the code Amethyst shows; it also arrives as a notification.\n\n"
                                 @"Keep Amethyst in the background while the code is being entered."
                  preferredStyle:UIAlertControllerStyleAlert];
    [intro addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [intro addAction:[UIAlertAction actionWithTitle:@"Start pairing" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            [self runPairingWithPresenter:presenter];
        }]];
    [presenter presentViewController:intro animated:YES completion:nil];
#endif
}

#if AME_JIT
+ (void)runPairingWithPresenter:(UIViewController *)presenter {
    NSString *outPath = self.pairingPath;
    NSError *directoryError = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:outPath.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:&directoryError];
    if (directoryError != nil) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Pairing failed"
                                                                       message:directoryError.localizedDescription
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
        return;
    }

    AMEJITPairingSession *session = [AMEJITPairingSession new];
    session.presenter = presenter;
    session.completion = ^(BOOL success, NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:success ? @"Pairing complete" : @"Pairing failed"
                                 message:message
                          preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [presenter presentViewController:alert animated:YES completion:nil];
        });
    };
    [session start];
}

#endif // AME_JIT

+ (void)prepareDeviceFromViewController:(UIViewController *)presenter {
    if (self.builtInUnavailableReason != nil) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Prepare JIT"
                                                                       message:self.builtInUnavailableReason
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
        return;
    }
    NSError *pairingError = nil;
    NSData *pairing = [self pairingDataOrError:&pairingError];
    if (pairing == nil) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Prepare JIT"
                                                                       message:pairingError.localizedDescription
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
        return;
    }

    UIAlertController *progressAlert = [UIAlertController alertControllerWithTitle:@"Preparing JIT"
                                                                           message:@"Checking LocalDevVPN and the Developer Disk Image..."
                                                                    preferredStyle:UIAlertControllerStyleAlert];
    [presenter presentViewController:progressAlert animated:YES completion:^{
        NSDictionary *request = @{
            @"operation": @"prepare",
            @"pairingBase64": [pairing base64EncodedStringWithOptions:0],
        };
        [self sendHelperRequest:request completion:^(NSDictionary *response, NSError *error) {
            [progressAlert dismissViewControllerAnimated:YES completion:^{
                BOOL success = error == nil && [response[@"success"] boolValue];
                NSString *message = error.localizedDescription ?: (response[@"message"] ?: @"");
                if (success) {
                    message = [NSString stringWithFormat:@"%@\n\nTXM/SPTM: %@", message, self.txmStatusDescription];
                }
                UIAlertController *alert = [UIAlertController
                    alertControllerWithTitle:success ? @"JIT is ready" : @"JIT is not ready"
                                     message:message
                              preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
                [presenter presentViewController:alert animated:YES completion:nil];
            }];
        }];
    }];
}

+ (void)resetDeveloperDiskImageFromViewController:(UIViewController *)presenter {
    if (self.builtInUnavailableReason != nil) return;
    [self sendHelperRequest:@{@"operation": @"resetDDI"} completion:^(NSDictionary *response, NSError *error) {
        BOOL success = error == nil && [response[@"success"] boolValue];
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:success ? @"Developer Disk Image" : @"Reset failed"
                             message:error.localizedDescription ?: (response[@"message"] ?: @"")
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    }];
}

#pragma mark Helpers

+ (void)openStikDebugPage {
    [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://github.com/StikDebug/StikDebug/releases/latest"]
                                     options:@{} completionHandler:nil];
}

+ (void)openLocalDevVPNPage {
    [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://apps.apple.com/us/app/localdevvpn/id6755608044"]
                                     options:@{} completionHandler:nil];
}

@end

#if AME_JIT

#pragma mark - Pairing session

@implementation AMEJITPairingSession

- (void)start {
    self.finished = NO;
    self.backgroundTask = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"amethyst-pairing"
                                                                       expirationHandler:^{
        NSLog(@"[JIT] pairing background task expired");
    }];
    self.keepAlive = [AMEJITPairingKeepAlive new];
    [self.keepAlive start];
    [AMEJITActivePairings() addObject:self];

    [UNUserNotificationCenter.currentNotificationCenter
        requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                      completionHandler:nil];

    NSString *outPath = JITManager.pairingPath;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // The device name is not readable from a sandboxed app, so the service is
        // just called Amethyst; iOS shows that name as "Pair with Amethyst".
        const char *name = "Amethyst";
        const char *model = "iPhone";
        StikPairResult result = {0};
        void *context = (__bridge void *)self;
        int32_t rc = stikpair_run_host(
            "0.0.0.0", 0, name, model, outPath.UTF8String,
            AMEPairingReadyCallback, AMEPairingPINCallback, context, &result);
        [self finishWithCode:rc result:&result];
    });
}

- (void)finishWithCode:(int32_t)code result:(StikPairResult *)result {
    NSString *message = @"Pairing did not complete.";
    BOOL success = NO;
    if (code == 0) {
        success = YES;
        message = @"The pairing file was saved. Amethyst can enable JIT by itself now.";
    } else if (result->error != NULL) {
        message = @(result->error);
    }
    stikpair_result_free(result);

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.finished) return;
        self.finished = YES;
        [self.service stop];
        self.service = nil;
        [self.keepAlive stop];
        self.keepAlive = nil;
        if (self.backgroundTask != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTask];
            self.backgroundTask = UIBackgroundTaskInvalid;
        }
        if (self.completion) self.completion(success, message);
        [AMEJITActivePairings() removeObject:self];
    });
}

- (void)advertiseWithName:(NSString *)name port:(int32_t)port txt:(NSDictionary<NSString *, NSData *> *)txt {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.finished || port <= 0) return;
        NSString *serviceName = name.length > 0 ? name : @"Amethyst";
        self.service = [[NSNetService alloc] initWithDomain:@"" type:AMEPairingServiceType
                                                       name:serviceName port:port];
        if (txt.count > 0) {
            [self.service setTXTRecord:[NSNetService dataFromTXTRecordDictionary:txt]];
        }
        self.service.delegate = nil;
        [self.service publish];
        NSLog(@"[JIT] advertising %@ on port %d", AMEPairingServiceType, port);
    });
}

- (void)showPIN:(NSString *)pin {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.finished) return;
        NSString *message = [NSString stringWithFormat:
            @"Open Settings -> Privacy & Security -> Developer Mode, tap \"Pair with Amethyst\", then enter this code:\n\n%@\n\n"
             "Come back to Amethyst once pairing finishes.", pin];
        AMEJITPostLocalNotification(@"Amethyst pairing code", [NSString stringWithFormat:
            @"Pair with Amethyst. Code: %@", pin]);
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Enter this code in Settings"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Copy code" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) {
                UIPasteboard.generalPasteboard.string = pin;
            }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Open Settings" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) {
                NSURL *settings = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
                [UIApplication.sharedApplication openURL:settings options:@{} completionHandler:nil];
            }]];
        [self.presenter presentViewController:alert animated:YES completion:nil];
    });
}

@end

static void AMEPairingReadyCallback(void *context, const char *serviceID, uint16_t port,
                                    const char *const *txtKeys, const char *const *txtVals, size_t txtCount) {
    AMEJITPairingSession *session = (__bridge AMEJITPairingSession *)context;
    NSMutableDictionary<NSString *, NSData *> *txt = [NSMutableDictionary dictionary];
    for (size_t index = 0; index < txtCount; index++) {
        if (txtKeys[index] == NULL || txtVals[index] == NULL) continue;
        NSString *key = @(txtKeys[index]);
        txt[key] = [NSData dataWithBytes:txtVals[index] length:strlen(txtVals[index])];
    }
    [session advertiseWithName:(serviceID ? @(serviceID) : nil) port:port txt:txt];
}

static void AMEPairingPINCallback(const char *pin, void *context) {
    AMEJITPairingSession *session = (__bridge AMEJITPairingSession *)context;
    [session showPIN:(pin ? @(pin) : @"")];
}

#endif // AME_JIT
