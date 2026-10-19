#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include "AppleLimit.h"

@interface NSObject (XChargeMCL)
- (id)initWithClientName:(NSString *)name;
- (BOOL)isMCLSupported;
- (unsigned long long)getMCLLimitWithError:(NSError **)error;
- (BOOL)setMCLLimit:(unsigned long long)limit error:(NSError **)error;
@end

static id client(void) {
    static id c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW);
        Class cls = NSClassFromString(@"PowerUISmartChargeClient");
        if (cls && [cls instancesRespondToSelector:@selector(setMCLLimit:error:)]
                && [cls instancesRespondToSelector:@selector(getMCLLimitWithError:)])
            c = [[cls alloc] initWithClientName:@"XCharge"];
    });
    return c;
}

int mcl_get(void) {
    id c = client();
    if (!c || ![c isMCLSupported]) return -1;
    NSError *e = nil;
    unsigned long long v = [c getMCLLimitWithError:&e];
    return e ? -1 : (int)v;
}

int mcl_set(int limit) {
    if (limit < 80 || limit > 100 || limit % 5 != 0) return -1;
    id c = client();
    if (!c) return -1;
    NSError *e = nil;
    [c setMCLLimit:(unsigned long long)limit error:&e];
    return mcl_get();
}
