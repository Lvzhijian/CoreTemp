#include "SensorBridge.h"
#include "SMCProtocol.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <mach/mach.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * Two read-only temperature paths. Neither writes the SMC and neither
 * asks for root.
 *
 * HID: Apple Silicon exposes die sensors (pACC / eACC / PMU tdie / SOC)
 * as IOHID temperature services. The service list and property calls are
 * in the SDK (IOHIDEventSystemClient.h / IOHIDServiceClient.h). Creating
 * the client, setting the temperature match, and reading the event are
 * still private symbols in IOKit. A non-sandboxed app can call them.
 *
 * SMC: Intel Macs, and some Apple Silicon systems, still publish the
 * AppleSMC user client. macOS 15 on Apple Silicon often has no AppleSMC
 * service at all; that is a normal miss, not a permission prompt.
 */

#define SENSOR_CAP 96
#define SENSOR_SCAN_CAP 256

typedef struct {
    uint32_t dataType;
    uint32_t dataSize;
    uint8_t bytes[32];
} SMCValue;

static io_connect_t g_smc = 0;

/*
 * IOHIDEventSystemClientCopyServices and IOHIDServiceClientCopyProperty are
 * declared by the headers above. Redeclaring them with a different pointer
 * type conflicts with the SDK (Clang modules also require that include).
 *
 * The four calls below are not in those headers. Their argument types use
 * the SDK's IOHIDEventSystemClientRef / IOHIDServiceClientRef.
 */
typedef struct __IOHIDEvent *IOHIDEventRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator)
    __attribute__((weak_import));
extern void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching)
    __attribute__((weak_import));
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp)
    __attribute__((weak_import));
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field)
    __attribute__((weak_import));

static void copy_text(char *dst, size_t cap, const char *src) {
    if (cap == 0) {
        return;
    }
    if (src == NULL) {
        dst[0] = '\0';
        return;
    }
    snprintf(dst, cap, "%s", src);
}

static SensorList make_list(const SensorTemp *items, int count, int32_t status, const char *detail) {
    SensorList list;
    memset(&list, 0, sizeof(list));
    list.status = status;
    copy_text(list.detail, sizeof(list.detail), detail);
    if (count < 0) {
        count = 0;
    }
    if (count > SENSOR_CAP) {
        count = SENSOR_CAP;
    }
    if (count == 0 || items == NULL) {
        return list;
    }
    SensorTemp *copy = calloc((size_t)count, sizeof(SensorTemp));
    if (copy == NULL) {
        list.status = SENSOR_NOMEM;
        copy_text(list.detail, sizeof(list.detail), "nomem");
        return list;
    }
    memcpy(copy, items, (size_t)count * sizeof(SensorTemp));
    list.items = copy;
    list.count = count;
    return list;
}

const char *SensorTempName(const SensorTemp *item) {
    if (item == NULL) {
        return "";
    }
    return item->name;
}

const char *SensorListDetail(const SensorList *list) {
    if (list == NULL) {
        return "";
    }
    return list->detail;
}

void SensorListFree(SensorList *list) {
    if (list == NULL) {
        return;
    }
    free(list->items);
    list->items = NULL;
    list->count = 0;
}

void SensorClose(void) {
    if (g_smc != 0) {
        IOServiceClose(g_smc);
        g_smc = 0;
    }
}

static int hid_symbols_ok(void) {
    return IOHIDEventSystemClientCreate != NULL &&
           IOHIDEventSystemClientSetMatching != NULL &&
           IOHIDServiceClientCopyEvent != NULL &&
           IOHIDEventGetFloatValue != NULL;
}

static void hid_product_name(IOHIDServiceClientRef service, char *name, size_t cap) {
    CFStringRef keys[] = {CFSTR("Product"), CFSTR("IOHIDProduct")};
    name[0] = '\0';
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]) && name[0] == '\0'; i++) {
        CFTypeRef prop = IOHIDServiceClientCopyProperty(service, keys[i]);
        if (prop == NULL) {
            continue;
        }
        if (CFGetTypeID(prop) == CFStringGetTypeID()) {
            if (!CFStringGetCString((CFStringRef)prop, name, (CFIndex)cap, kCFStringEncodingUTF8)) {
                name[0] = '\0';
            }
        }
        CFRelease(prop);
    }
}

static int hid_plausible(double value) {
    return value > 0.0 && value < 150.0;
}

static CFDictionaryRef hid_matching(void) {
    int page = 0xFF00;
    int usage = 5;
    CFNumberRef pageNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
    CFNumberRef usageNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);
    if (pageNumber == NULL || usageNumber == NULL) {
        if (pageNumber != NULL) {
            CFRelease(pageNumber);
        }
        if (usageNumber != NULL) {
            CFRelease(usageNumber);
        }
        return NULL;
    }
    const void *keys[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")};
    const void *values[] = {pageNumber, usageNumber};
    CFDictionaryRef dict = CFDictionaryCreate(
        kCFAllocatorDefault,
        keys,
        values,
        2,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFRelease(pageNumber);
    CFRelease(usageNumber);
    return dict;
}

static int hid_collect(IOHIDEventSystemClientRef client, CFDictionaryRef matching, SensorTemp *out, int cap) {
    IOHIDEventSystemClientSetMatching(client, matching);
    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (services == NULL) {
        return 0;
    }
    CFIndex total = CFArrayGetCount(services);
    int count = 0;
    for (CFIndex i = 0; i < total && count < cap; i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        if (service == NULL) {
            continue;
        }
        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, 15, 0, 0);
        if (event == NULL) {
            continue;
        }
        double temp = IOHIDEventGetFloatValue(event, (int32_t)(15 << 16));
        CFRelease(event);
        if (!hid_plausible(temp)) {
            continue;
        }
        char name[96];
        hid_product_name(service, name, sizeof(name));
        if (name[0] == '\0') {
            snprintf(name, sizeof(name), "sensor-%ld", (long)i);
        }
        copy_text(out[count].name, sizeof(out[count].name), name);
        out[count].celsius = temp;
        count++;
    }
    CFRelease(services);
    return count;
}

SensorList SensorCopyHID(void) {
    SensorTemp found[SENSOR_CAP];
    memset(found, 0, sizeof(found));
    if (!hid_symbols_ok()) {
        return make_list(NULL, 0, SENSOR_HID_SYMBOLS, "symbols");
    }
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (client == NULL) {
        return make_list(NULL, 0, SENSOR_HID_CLIENT, "client");
    }
    CFDictionaryRef matching = hid_matching();
    if (matching == NULL) {
        CFRelease(client);
        return make_list(NULL, 0, SENSOR_HID_CLIENT, "matching");
    }
    int count = hid_collect(client, matching, found, SENSOR_CAP);
    CFRelease(matching);
    CFRelease(client);
    return make_list(found, count, SENSOR_OK, "");
}

static int smc_call(io_connect_t conn, SMCKeyData_t *input, SMCKeyData_t *output) {
    if (conn == 0) {
        return -1;
    }
    size_t outSize = sizeof(*output);
    memset(output, 0, sizeof(*output));
    kern_return_t kr = IOConnectCallStructMethod(
        conn,
        SMC_KERNEL_INDEX,
        input,
        sizeof(*input),
        output,
        &outSize);
    return (int)kr;
}

static int smc_ensure(char *err, size_t errCap) {
    if (g_smc != 0) {
        return 0;
    }
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (service == 0) {
        copy_text(err, errCap, "not_found");
        return SENSOR_SMC_NOT_FOUND;
    }
    io_connect_t conn = 0;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &conn);
    IOObjectRelease(service);
    if (kr != 0 || conn == 0) {
        snprintf(err, errCap, "open:0x%08x", (unsigned int)kr);
        return kr != 0 ? (int)kr : 5;
    }
    g_smc = conn;
    return 0;
}

static void key_string(uint32_t key, char out[5]) {
    out[0] = (char)((key >> 24) & 0xFF);
    out[1] = (char)((key >> 16) & 0xFF);
    out[2] = (char)((key >> 8) & 0xFF);
    out[3] = (char)(key & 0xFF);
    out[4] = '\0';
    for (int i = 0; i < 4; i++) {
        unsigned char c = (unsigned char)out[i];
        if (c < 32 || c > 126) {
            out[i] = '?';
        }
    }
}

static int smc_read_value(uint32_t key, SMCValue *val) {
    SMCKeyData_t input;
    SMCKeyData_t output;
    memset(&input, 0, sizeof(input));
    input.key = key;
    input.data8 = SMC_CMD_READ_KEYINFO;
    int kr = smc_call(g_smc, &input, &output);
    if (kr != 0) {
        SensorClose();
        char ignored[64];
        if (smc_ensure(ignored, sizeof(ignored)) != 0) {
            return kr;
        }
        memset(&input, 0, sizeof(input));
        input.key = key;
        input.data8 = SMC_CMD_READ_KEYINFO;
        kr = smc_call(g_smc, &input, &output);
    }
    if (kr != 0 || output.result != 0) {
        return -1;
    }
    uint32_t size = output.keyInfo.dataSize;
    if (size == 0 || size > 32) {
        return -1;
    }
    SMCKeyData_keyInfo_t info = output.keyInfo;

    memset(&input, 0, sizeof(input));
    input.key = key;
    input.keyInfo = info;
    input.data8 = SMC_CMD_READ_BYTES;
    kr = smc_call(g_smc, &input, &output);
    if (kr != 0) {
        SensorClose();
        return kr;
    }
    if (output.result != 0) {
        return -1;
    }
    memset(val, 0, sizeof(*val));
    val->dataType = info.dataType;
    val->dataSize = size;
    memcpy(val->bytes, output.bytes, size);
    return 0;
}

static int smc_key_at_index(uint32_t index, uint32_t *keyOut) {
    SMCKeyData_t input;
    SMCKeyData_t output;
    memset(&input, 0, sizeof(input));
    input.data8 = SMC_CMD_READ_INDEX;
    input.data32 = index;
    int kr = smc_call(g_smc, &input, &output);
    if (kr != 0) {
        SensorClose();
        return -1;
    }
    if (output.result != 0) {
        return -1;
    }
    *keyOut = output.key;
    return 0;
}

static int decode_temperature(const SMCValue *val, double *out) {
    double decoded;
    if (val->dataType == SMCFourCC('s', 'p', '7', '8')) {
        decoded = SMCDecodeSP78(val->bytes, val->dataSize);
    } else if (val->dataType == SMCFourCC('f', 'l', 't', ' ')) {
        decoded = SMCDecodeFLT(val->bytes, val->dataSize);
    } else {
        return -1;
    }
    if (!(decoded == decoded)) {
        return -1;
    }
    *out = decoded;
    return 0;
}

static int already_have(const SensorTemp *items, int count, const char *name) {
    for (int i = 0; i < count; i++) {
        if (strcmp(items[i].name, name) == 0) {
            return 1;
        }
    }
    return 0;
}

static int priority_key(const char *name) {
    char second = name[1];
    if (!(name[0] == 'T' || name[0] == 't')) {
        return 0;
    }
    return second == 'p' || second == 'P' ||
           second == 'e' || second == 'E' ||
           second == 'g' || second == 'G' ||
           second == 'c' || second == 'C';
}

static int keep_temperatures(const SensorTemp *found, int nfound, SensorTemp *out, int cap) {
    if (nfound <= cap) {
        memcpy(out, found, (size_t)nfound * sizeof(SensorTemp));
        return nfound;
    }
    SensorTemp ranked[SENSOR_SCAN_CAP];
    int count = 0;
    for (int pass = 0; pass < 2; pass++) {
        for (int i = 0; i < nfound && count < cap; i++) {
            int pri = priority_key(found[i].name);
            if ((pass == 0 && pri) || (pass == 1 && !pri)) {
                ranked[count++] = found[i];
            }
        }
    }
    memcpy(out, ranked, (size_t)count * sizeof(SensorTemp));
    return count;
}

SensorList SensorCopySMC(void) {
    char err[160];
    err[0] = '\0';
    int openStatus = smc_ensure(err, sizeof(err));
    if (openStatus != 0) {
        return make_list(NULL, 0, openStatus, err);
    }

    uint32_t keyCount = 0;
    int probing = 0;
    SMCValue countValue;
    if (smc_read_value(SMCFourCC('#', 'K', 'E', 'Y'), &countValue) == 0 && countValue.dataSize >= 4) {
        keyCount = ((uint32_t)countValue.bytes[0] << 24) |
                   ((uint32_t)countValue.bytes[1] << 16) |
                   ((uint32_t)countValue.bytes[2] << 8) |
                   (uint32_t)countValue.bytes[3];
    }
    if (keyCount == 0 || keyCount > 2000) {
        keyCount = 400;
        probing = 1;
    }

    SensorTemp found[SENSOR_SCAN_CAP];
    memset(found, 0, sizeof(found));
    int nfound = 0;
    for (uint32_t index = 0; index < keyCount && nfound < SENSOR_SCAN_CAP; index++) {
        if (g_smc == 0) {
            break;
        }
        uint32_t key = 0;
        if (smc_key_at_index(index, &key) != 0) {
            if (probing) {
                break;
            }
            continue;
        }
        char name[5];
        key_string(key, name);
        if (name[0] != 'T' && name[0] != 't') {
            continue;
        }
        if (already_have(found, nfound, name)) {
            continue;
        }
        SMCValue val;
        if (smc_read_value(key, &val) != 0) {
            continue;
        }
        double temp = 0.0;
        if (decode_temperature(&val, &temp) != 0) {
            continue;
        }
        if (!(temp > 0.0 && temp < 150.0)) {
            continue;
        }
        copy_text(found[nfound].name, sizeof(found[nfound].name), name);
        found[nfound].celsius = temp;
        nfound++;
    }

    SensorTemp kept[SENSOR_CAP];
    int count = keep_temperatures(found, nfound, kept, SENSOR_CAP);
    return make_list(kept, count, SENSOR_OK, "");
}
