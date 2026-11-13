#ifndef IM_V2_ANDROID_PLATFORM_H
#define IM_V2_ANDROID_PLATFORM_H
#include <stdint.h>
#include <stddef.h>
typedef struct { int32_t status; uint8_t *bytes; size_t count; } IMV2AndroidResult;
IMV2AndroidResult im_v2_android_call(int32_t operation, int64_t handle, const char *name, const uint8_t *bytes, size_t count, int32_t value);
void im_v2_android_free(IMV2AndroidResult result);
#endif
