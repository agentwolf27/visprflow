#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs a block, turning any Objective-C exception it raises into an `NSError`.
///
/// Swift cannot catch `NSException`. AVFoundation raises them freely — `AVAudioEngine.prepare()`
/// and `installTap` both do — and such a throw unwinds straight past Swift's `catch`, skipping
/// the rest of the function. The run loop swallows it, so the app keeps running with the work
/// half done and nothing logged. That is exactly how the hotkey silently failed to start.
///
/// Returns YES on success. On failure returns NO and fills `error` with the exception's name and
/// reason.
BOOL VFRunCatchingExceptions(void (NS_NOESCAPE ^block)(void), NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
