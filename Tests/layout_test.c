#include <math.h>
#include <stdio.h>

#include "../CoreTemp/SMCProtocol.h"

static int near(double value, double expected) {
    return fabs(value - expected) < 0.0001;
}

int main(void) {
    int failed = 0;

    printf("sizeof SMCKeyData_t = %zu\n", sizeof(SMCKeyData_t));
    printf("offset data32 = %zu\n", offsetof(SMCKeyData_t, data32));
    printf("offset bytes = %zu\n", offsetof(SMCKeyData_t, bytes));
    printf("offset keyInfo = %zu\n", offsetof(SMCKeyData_t, keyInfo));
    printf("offset pLimitData = %zu\n", offsetof(SMCKeyData_t, pLimitData));

    const uint8_t sp[] = {0x48, 0x40};
    double spValue = SMCDecodeSP78(sp, 2);
    if (!near(spValue, 72.25)) {
        printf("sp78 expected 72.25 got %f\n", spValue);
        failed = 1;
    }

    const uint8_t neg[] = {0xFF, 0x00};
    double negValue = SMCDecodeSP78(neg, 2);
    if (!near(negValue, -1.0)) {
        printf("sp78 expected -1 got %f\n", negValue);
        failed = 1;
    }

    const uint8_t flt[] = {0x42, 0x28, 0x00, 0x00};
    double fltValue = SMCDecodeFLT(flt, 4);
    if (!near(fltValue, 42.0)) {
        printf("flt expected 42 got %f\n", fltValue);
        failed = 1;
    }

    if (SMCFourCC('s', 'p', '7', '8') != 0x73703738u) {
        printf("fourcc mismatch\n");
        failed = 1;
    }
    if (SMCFourCC('f', 'l', 't', ' ') != 0x666c7420u) {
        printf("flt fourcc mismatch\n");
        failed = 1;
    }

    if (failed) {
        return 1;
    }
    printf("ok\n");
    return 0;
}
