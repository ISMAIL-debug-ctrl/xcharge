#ifndef XCHARGE_SMC_H
#define XCHARGE_SMC_H
#include <stdint.h>

// Open/close the AppleSMC connection. Returns 0 on success.
int smc_open(void);
void smc_close(void);

// Read a key. Returns number of bytes read (>0), or -1 if missing/failed.
int smc_read(const char *key, uint8_t *out, int maxlen, uint32_t *type_out);

// Write raw bytes to a key (needs root). Returns 0 on success.
int smc_write(const char *key, const uint8_t *bytes, int len);

#endif
