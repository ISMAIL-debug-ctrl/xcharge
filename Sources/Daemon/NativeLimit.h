// macOS's own Charge Limit (System Settings → Battery → Charge Limit), via private PowerUI.
// On macOS 27 the SMC charge-inhibit keys are gone, and this is the native way to hold a limit.
// It accepts any whole number from 80 to 100 (100 = off); lower values are refused.
#include <stdint.h>

// Current macOS charge limit, or -1 if unavailable.
int native_limit_get(void);
// Sets it (80...100 only) and returns the value read back, or -1.
int native_limit_set(int limit);
