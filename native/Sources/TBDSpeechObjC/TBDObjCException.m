#import "TBDObjCException.h"

BOOL TBDCatchObjCException(NS_NOESCAPE void (^block)(void), NSError *_Nullable *_Nullable error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *reason = exception.reason ?: exception.name;
            *error = [NSError errorWithDomain:@"TBD.ObjCException" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: reason ?: @"Objective-C exception"}];
        }
        return NO;
    }
}
