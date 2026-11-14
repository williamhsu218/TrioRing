#import <Foundation/Foundation.h>

typedef struct {
    BOOL valid;
    NSUInteger mode;
    NSInteger limit;
    BOOL canResume;
    uint32_t allowedLimits;
} TRChargeState;

TRChargeState TRReadChargeState(void);
BOOL TRRequestFullCharge(NSInteger expectedLimit, BOOL allowOptimizedPause);
BOOL TRRestoreChargeLimit(NSInteger expectedLimit);
BOOL TRSetChargeLimit(NSInteger limit, NSInteger expectedLimit);
