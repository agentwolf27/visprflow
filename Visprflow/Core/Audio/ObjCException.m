#import "ObjCException.h"

NSErrorDomain const VFObjCExceptionDomain = @"com.vish.visprflow.objc-exception";

BOOL VFRunCatchingExceptions(void (NS_NOESCAPE ^block)(void), NSError *_Nullable *_Nullable error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *reason = exception.reason ?: @"no reason given";
            *error = [NSError errorWithDomain:VFObjCExceptionDomain
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", exception.name, reason],
                @"exceptionName": exception.name,
                @"exceptionReason": reason,
            }];
        }
        return NO;
    }
}
