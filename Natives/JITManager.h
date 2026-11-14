#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AMEJITMethod) {
    AMEJITMethodWait = 0,      // keep waiting for an external debugger (StikDebug / SideStore)
    AMEJITMethodStikDebug = 1, // hand the request to the StikDebug app
    AMEJITMethodBuiltIn = 2,   // run StikJIT in Amethyst's own helper extension
};

/// Launcher side of JIT acquisition: method selection, the pairing file, the
/// built-in StikJIT helper extension and the on-device pairing host.
@interface JITManager : NSObject

+ (instancetype)shared;

#pragma mark Settings

+ (AMEJITMethod)selectedMethod;
+ (void)setSelectedMethod:(AMEJITMethod)method;
+ (BOOL)forceScript;
+ (void)setForceScript:(BOOL)forceScript;

#pragma mark Availability

+ (BOOL)deviceHasGetTaskAllow;
+ (BOOL)builtInSupported;
+ (nullable NSString *)builtInUnavailableReason;
+ (BOOL)pairingSupported;
+ (nullable NSString *)pairingUnavailableReason;
+ (BOOL)isJITReady;
+ (NSString *)txmStatusDescription;

#pragma mark Pairing file

+ (NSString *)pairingPath;
+ (BOOL)hasPairingFile;
+ (void)importPairingFileFromURL:(NSURL *)url
                      completion:(void (^)(NSError *_Nullable error))completion;

#pragma mark Actions

/// Starts the selected method. The completion fires once the request has been
/// handed off (or immediately fails with an error); the caller still has to wait
/// for isJITReady before launching a game.
+ (void)startJITAcquisitionWithProgress:(void (^)(NSString *status))progress
                             completion:(void (^)(NSError *_Nullable error))completion;

/// Shows the on-device pairing flow (StikPair). The caller keeps the app alive
/// while the user pairs in Settings; the pairing file is written on success.
+ (void)startPairingFromViewController:(UIViewController *)presenter;

/// Prepares the device for built-in JIT (checks LocalDevVPN, mounts the DDI).
+ (void)prepareDeviceFromViewController:(UIViewController *)presenter;

/// Removes the cached Developer Disk Image files.
+ (void)resetDeveloperDiskImageFromViewController:(UIViewController *)presenter;

#pragma mark Helpers

+ (void)openStikDebugPage;
+ (void)openLocalDevVPNPage;

@end

NS_ASSUME_NONNULL_END
