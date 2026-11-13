#include <stdint.h>
int64_t im_probe_start(const uint8_t *input, int64_t count);
char *im_probe_poll(int64_t handle);
void im_probe_cancel(int64_t handle);
int32_t im_probe_release(int64_t handle);
int32_t im_probe_active(void);
void im_probe_free(char *value);
