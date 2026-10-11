#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and converts a raised Objective-C exception into an NSError.
/// AVAudioEngine and Core Audio raise NSException for some invalid states; Swift cannot catch those.
BOOL TBDCatchObjCException(NS_NOESCAPE void (^block)(void), NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
