// macOS 26 built-in charge limit ("MCL", Battery settings → Charge Limit) via private PowerUI.
// macOS only accepts 80, 85, 90, 95 or 100. For those limits we let macOS hold the charge itself
// (its native mechanism, survives sleep); below 80 XCharge holds it. Note: Apple's menu bar icon
// keeps the bolt at the limit either way — that is Apple's design on macOS 26, also for its own limit.
#include <stdint.h>

// Current macOS charge limit, or -1 if unavailable.
int mcl_get(void);
// Sets it and returns the value read back (or -1).
int mcl_set(int limit);
