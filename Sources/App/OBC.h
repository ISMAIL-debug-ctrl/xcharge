// macOS "Optimized Battery Charging" via the private PowerUI framework (no root needed).
#import <Foundation/Foundation.h>

// Returns 1 = on, 0 = off, -1 = unavailable.
int obc_state(void);
// Returns YES if the state now matches `on`.
BOOL obc_set(BOOL on);
