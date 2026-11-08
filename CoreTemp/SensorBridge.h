#ifndef SENSOR_BRIDGE_H
#define SENSOR_BRIDGE_H

#include <stdint.h>

/*
 * Raw temperature samples from macOS.
 *
 * SENSOR_OK with count 0 means the call worked and the machine
 * simply did not return any plausible readings. Callers must not
 * invent a temperature in that case.
 *
 * SensorCopyHID / SensorCopySMC malloc the items buffer.
 * Pass the same struct to SensorListFree.
 *
 * Only call these functions from one thread. The SMC connection is cached.
 */

#define SENSOR_OK 0
#define SENSOR_HID_SYMBOLS 1
#define SENSOR_HID_CLIENT 2
#define SENSOR_SMC_NOT_FOUND 3
#define SENSOR_NOMEM 4

typedef struct SensorTemp {
    char name[96];
    double celsius;
} SensorTemp;

typedef struct SensorList {
    SensorTemp *items;
    int32_t count;
    int32_t status;
    char detail[160];
} SensorList;

SensorList SensorCopyHID(void);
SensorList SensorCopySMC(void);
void SensorListFree(SensorList *list);
void SensorClose(void);

const char *SensorTempName(const SensorTemp *item);
const char *SensorListDetail(const SensorList *list);

#endif
