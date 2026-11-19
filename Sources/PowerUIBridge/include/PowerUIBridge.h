#import <Foundation/Foundation.h>

typedef struct {
    BOOL valid;
    NSUInteger mode;
    NSInteger limit;
    BOOL canResume;
    uint32_t allowedLimits;
} TRChargeState;

typedef NS_ENUM(NSInteger, TRSystemCalibration) {
    TRSystemCalibrationUnknown,
    TRSystemCalibrationInactive,
    TRSystemCalibrationActive,
};

TRSystemCalibration TRReadSystemCalibration(void);
int TRObserveSystemCalibration(void (^ _Nonnull handler)(void));
void TRStopObservingSystemCalibration(int token);

TRChargeState TRReadChargeState(void);
BOOL TRRequestFullCharge(NSInteger expectedLimit, BOOL allowOptimizedPause);
BOOL TRRestoreChargeLimit(NSInteger expectedLimit);
BOOL TRSetChargeLimit(NSInteger limit, NSInteger expectedLimit);
