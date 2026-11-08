#ifndef SMC_PROTOCOL_H
#define SMC_PROTOCOL_H

/*
 * Read-only layout of the AppleSMC user-client struct passed to
 * IOConnectCallStructMethod (selector 2).
 *
 * Natural alignment, not packed. Apple's client expects 80 bytes.
 * Packing this struct would shift the bytes and decode garbage.
 * A wrong size fails the build instead of showing a fake temperature.
 */

#include <stddef.h>
#include <stdint.h>

typedef struct {
    char major;
    char minor;
    char build;
    char reserved[1];
    uint16_t release;
} SMCKeyData_vers_t;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    char dataAttributes;
} SMCKeyData_keyInfo_t;

typedef uint8_t SMCBytes_t[32];

typedef struct {
    uint32_t key;
    SMCKeyData_vers_t vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    SMCBytes_t bytes;
} SMCKeyData_t;

_Static_assert(sizeof(SMCKeyData_vers_t) == 6, "SMC version block");
_Static_assert(sizeof(SMCKeyData_pLimitData_t) == 16, "SMC power-limit block");
_Static_assert(sizeof(SMCKeyData_keyInfo_t) == 12, "SMC key info block");
_Static_assert(sizeof(SMCKeyData_t) == 80, "SMCKeyData_t must be 80 bytes");
_Static_assert(offsetof(SMCKeyData_t, key) == 0, "SMC key offset");
_Static_assert(offsetof(SMCKeyData_t, data32) == 44, "SMC data32 offset");
_Static_assert(offsetof(SMCKeyData_t, bytes) == 48, "SMC bytes offset");

#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_READ_INDEX 8
#define SMC_CMD_READ_KEYINFO 9
#define SMC_KERNEL_INDEX 2

static inline uint32_t SMCFourCC(char a, char b, char c, char d) {
    return ((uint32_t)(uint8_t)a << 24) |
           ((uint32_t)(uint8_t)b << 16) |
           ((uint32_t)(uint8_t)c << 8) |
           (uint32_t)(uint8_t)d;
}

/* sp78: signed 7.8 fixed point, big-endian. 72.25°C -> bytes 0x48 0x40. */
static inline double SMCDecodeSP78(const uint8_t *bytes, uint32_t size) {
    if (bytes == NULL || size < 2) {
        return 0.0 / 0.0; /* NaN */
    }
    int16_t raw = (int16_t)(((uint16_t)bytes[0] << 8) | (uint16_t)bytes[1]);
    return (double)raw / 256.0;
}

/* flt : IEEE-754 float stored big-endian. */
static inline double SMCDecodeFLT(const uint8_t *bytes, uint32_t size) {
    if (bytes == NULL || size < 4) {
        return 0.0 / 0.0;
    }
    uint32_t be = ((uint32_t)bytes[0] << 24) |
                  ((uint32_t)bytes[1] << 16) |
                  ((uint32_t)bytes[2] << 8) |
                  (uint32_t)bytes[3];
    float value = 0.0f;
    __builtin_memcpy(&value, &be, sizeof(value));
    return (double)value;
}

#endif
