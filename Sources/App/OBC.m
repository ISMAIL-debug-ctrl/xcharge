#import "OBC.h"
#include <dlfcn.h>

@interface NSObject (XChargeSmartCharge)
- (id)initWithClientName:(NSString *)name;
- (BOOL)isOBCSupported;
- (BOOL)isSmartChargingCurrentlyEnabled:(NSError **)error;
- (void)enableSmartCharging:(NSError **)error;
- (void)disableSmartCharging:(NSError **)error;
@end

static id client(void) {
    static id c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW);
        Class cls = NSClassFromString(@"PowerUISmartChargeClient");
        if (cls && [cls instancesRespondToSelector:@selector(isSmartChargingCurrentlyEnabled:)])
            c = [[cls alloc] initWithClientName:@"XCharge"];
    });
    return c;
}

int obc_state(void) {
    id c = client();
    if (!c || ![c isOBCSupported]) return -1;
    NSError *e = nil;
    BOOL on = [c isSmartChargingCurrentlyEnabled:&e];
    return e ? -1 : (on ? 1 : 0);
}

BOOL obc_set(BOOL on) {
    id c = client();
    if (!c) return NO;
    NSError *e = nil;
    if (on) [c enableSmartCharging:&e]; else [c disableSmartCharging:&e];
    return obc_state() == (on ? 1 : 0);
}
