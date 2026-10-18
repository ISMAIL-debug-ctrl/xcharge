#include "smc.h"
#include <IOKit/IOKitLib.h>
#include <string.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_KEYINFO 9

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } smc_vers_t;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, mem; } smc_plimit_t;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } smc_keyinfo_t;
typedef struct {
    uint32_t key;
    smc_vers_t vers;
    smc_plimit_t pLimitData;
    smc_keyinfo_t keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} smc_param_t;

static io_connect_t conn = 0;

static uint32_t fourcc(const char *s) {
    return ((uint32_t)s[0] << 24) | ((uint32_t)s[1] << 16) | ((uint32_t)s[2] << 8) | (uint32_t)s[3];
}

static kern_return_t call(smc_param_t *in, smc_param_t *out) {
    size_t outSize = sizeof(smc_param_t);
    return IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, in, sizeof(smc_param_t), out, &outSize);
}

int smc_open(void) {
    if (conn) return 0;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return -1;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    return kr == KERN_SUCCESS ? 0 : -1;
}

void smc_close(void) {
    if (conn) { IOServiceClose(conn); conn = 0; }
}

static int keyinfo(const char *key, smc_keyinfo_t *info) {
    smc_param_t in = {0}, out = {0};
    in.key = fourcc(key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    *info = out.keyInfo;
    return 0;
}

int smc_read(const char *key, uint8_t *outBytes, int maxlen, uint32_t *type_out) {
    if (smc_open() != 0) return -1;
    smc_keyinfo_t info;
    if (keyinfo(key, &info) != 0 || info.dataSize == 0) return -1;
    smc_param_t in = {0}, out = {0};
    in.key = fourcc(key);
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = SMC_CMD_READ_BYTES;
    if (call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    int n = (int)info.dataSize < maxlen ? (int)info.dataSize : maxlen;
    memcpy(outBytes, out.bytes, n);
    if (type_out) *type_out = info.dataType;
    return n;
}

int smc_write(const char *key, const uint8_t *bytes, int len) {
    if (smc_open() != 0) return -1;
    smc_keyinfo_t info;
    if (keyinfo(key, &info) != 0 || (int)info.dataSize != len) return -1;
    smc_param_t in = {0}, out = {0};
    in.key = fourcc(key);
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = SMC_CMD_WRITE_BYTES;
    memcpy(in.bytes, bytes, len);
    if (call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    return 0;
}
