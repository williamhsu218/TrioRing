// Runtime checks and PowerUI selectors adapted from Status Trio v1.9.5 (Apache-2.0).
#import "PowerUIBridge.h"
#import <dlfcn.h>
#import <notify.h>
#import <objc/runtime.h>

// Powerd publishes its own battery-gauging override independently of the
// temporary charge-limit override exposed by PowerUI.
static const char *calibrationNotification = "com.apple.system.powersources.chargingtofulloverride";

TRSystemCalibration TRReadSystemCalibration(void) {
    int token;
    if (notify_register_check(calibrationNotification, &token) != NOTIFY_STATUS_OK) return TRSystemCalibrationUnknown;
    uint64_t state;
    uint32_t result = notify_get_state(token, &state);
    notify_cancel(token);
    if (result != NOTIFY_STATUS_OK || state > 1) return TRSystemCalibrationUnknown;
    return state == 1 ? TRSystemCalibrationActive : TRSystemCalibrationInactive;
}

int TRObserveSystemCalibration(void (^handler)(void)) {
    int token;
    return notify_register_dispatch(calibrationNotification, &token, dispatch_get_main_queue(), ^(int received) {
        handler();
    }) == NOTIFY_STATUS_OK ? token : -1;
}

void TRStopObservingSystemCalibration(int token) {
    if (token >= 0) notify_cancel(token);
}

@protocol TRPowerUIClient
- (instancetype)initWithClientName:(NSString *)name;
- (BOOL)isMCLSupported;
- (NSUInteger)isMCLCurrentlyEnabled:(NSError **)error;
- (unsigned char)getMCLLimitWithError:(NSError **)error;
- (BOOL)smartChargingUIState:(NSUInteger *)state chargeLimit:(NSUInteger *)limit
     chargingOverrideAllowed:(BOOL *)allowed withError:(NSError **)error;
- (BOOL)temporarilyDisableMCL:(NSError **)error;
- (BOOL)temporarilyEnableCharging:(NSError **)error;
- (NSArray<NSNumber *> *)availableChargeLimitsWithError:(NSError **)error;
- (BOOL)setMCLLimit:(unsigned char)limit error:(NSError **)error;
@end

static BOOL matches(Class cls, SEL selector, const char *result, NSArray<NSString *> *arguments) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (!signature || strcmp(signature.methodReturnType, result) ||
        signature.numberOfArguments != arguments.count + 2) return NO;
    for (NSUInteger index = 0; index < arguments.count; index++) {
        if (strcmp([signature getArgumentTypeAtIndex:index + 2], arguments[index].UTF8String)) return NO;
    }
    return YES;
}

static id<TRPowerUIClient> makeClient(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
#if defined(__arm64__)
        if (@available(macOS 26.4, *)) {
            if (!dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW | RTLD_LOCAL)) return;
            Class candidate = NSClassFromString(@"PowerUISmartChargeClient");
            if (!candidate) return;
            NSString *error = @(@encode(NSError *__autoreleasing *));
            if (matches(candidate, @selector(initWithClientName:), @encode(id), @[@(@encode(id))]) &&
                matches(candidate, @selector(isMCLSupported), @encode(BOOL), @[]) &&
                matches(candidate, @selector(isMCLCurrentlyEnabled:), @encode(NSUInteger), @[error]) &&
                matches(candidate, @selector(getMCLLimitWithError:), @encode(unsigned char), @[error]) &&
                matches(candidate, @selector(smartChargingUIState:chargeLimit:chargingOverrideAllowed:withError:),
                        @encode(BOOL), @[@(@encode(NSUInteger *)), @(@encode(NSUInteger *)), @(@encode(BOOL *)), error])) {
                cls = candidate;
            }
        }
#endif
    });
    return cls ? [(id<TRPowerUIClient>)[cls alloc] initWithClientName:@"TrioRing"] : nil;
}

static TRChargeState readState(id<TRPowerUIClient> client) {
    TRChargeState result = {0};
    if (!client || ![client isMCLSupported]) return result;
    NSError *modeError = nil, *limitError = nil, *uiError = nil;
    NSUInteger uiState = 0, uiLimit = 0;
    BOOL canResume = NO;
    result.mode = [client isMCLCurrentlyEnabled:&modeError];
    result.limit = [client getMCLLimitWithError:&limitError];
    BOOL success = [client smartChargingUIState:&uiState chargeLimit:&uiLimit chargingOverrideAllowed:&canResume withError:&uiError];
    result.valid = success && !modeError && !limitError && !uiError;
    result.canResume = result.valid && canResume;
    return result;
}

static uint32_t allowedLimits(id<TRPowerUIClient> client) {
    NSString *errorArgument = @(@encode(NSError *__autoreleasing *));
    if (!matches(object_getClass(client), @selector(availableChargeLimitsWithError:), @encode(id), @[errorArgument]) ||
        !matches(object_getClass(client), @selector(setMCLLimit:error:), @encode(BOOL),
                 @[@(@encode(unsigned char)), errorArgument])) return 0;

    NSError *error = nil;
    NSArray<NSNumber *> *limits = [client availableChargeLimitsWithError:&error];
    if (error || ![limits isKindOfClass:[NSArray class]]) return 0;
    uint32_t result = 0;
    for (NSNumber *limit in limits) {
        if (![limit isKindOfClass:[NSNumber class]]) continue;
        NSInteger value = limit.integerValue;
        if (value >= 80 && value <= 100) result |= 1u << (value - 80);
    }
    return result;
}

TRChargeState TRReadChargeState(void) {
    @try {
        id<TRPowerUIClient> client = makeClient();
        TRChargeState state = readState(client);
        if (state.valid) state.allowedLimits = allowedLimits(client);
        return state;
    }
    @catch (NSException *exception) { return (TRChargeState){0}; }
}

BOOL TRRequestFullCharge(NSInteger expectedLimit, BOOL allowOptimizedPause) {
    @try {
        id<TRPowerUIClient> client = makeClient();
        TRChargeState state = readState(client);
        if (!state.valid || state.mode == 3) return NO;
        NSError *error = nil;
        NSArray *signature = @[@(@encode(NSError *__autoreleasing *))];
        if (expectedLimit >= 80 && expectedLimit < 100 && state.mode == 1 && state.limit == expectedLimit) {
            if (!matches(object_getClass(client), @selector(temporarilyDisableMCL:), @encode(BOOL), signature) ||
                TRReadSystemCalibration() == TRSystemCalibrationActive) return NO;
            return [client temporarilyDisableMCL:&error] && !error;
        }
        if (expectedLimit == 0 && allowOptimizedPause && state.canResume && !(state.mode == 1 && state.limit < 100)) {
            if (!matches(object_getClass(client), @selector(temporarilyEnableCharging:), @encode(BOOL), signature) ||
                TRReadSystemCalibration() == TRSystemCalibrationActive) return NO;
            return [client temporarilyEnableCharging:&error] && !error;
        }
        return NO;
    } @catch (NSException *exception) { return NO; }
}

BOOL TRRestoreChargeLimit(NSInteger expectedLimit) {
    @try {
        id<TRPowerUIClient> client = makeClient();
        TRChargeState state = readState(client);
        // A temporary bypass can report 100% and enableMCL: can select the
        // system default. Set the saved target directly to end the bypass.
        if (!state.valid || state.mode != 3 || expectedLimit < 80 || expectedLimit >= 100 ||
            (state.limit >= 80 && state.limit < 100 && state.limit != expectedLimit) ||
            !(allowedLimits(client) & (1u << (expectedLimit - 80)))) return NO;
        if (TRReadSystemCalibration() == TRSystemCalibrationActive) return NO;
        NSError *error = nil;
        return [client setMCLLimit:(unsigned char)expectedLimit error:&error] && !error;
    } @catch (NSException *exception) { return NO; }
}

BOOL TRSetChargeLimit(NSInteger limit, NSInteger expectedLimit) {
    @try {
        if (limit < 80 || limit > 100) return NO;
        id<TRPowerUIClient> client = makeClient();
        TRChargeState before = readState(client);
        if (!before.valid || before.mode == 3 || before.limit != expectedLimit ||
            !(allowedLimits(client) & (1u << (limit - 80)))) return NO;
        if (limit == before.limit) return YES;
        if (TRReadSystemCalibration() == TRSystemCalibrationActive) return NO;
        NSError *error = nil;
        return [client setMCLLimit:(unsigned char)limit error:&error] && !error;
    } @catch (NSException *exception) { return NO; }
}
