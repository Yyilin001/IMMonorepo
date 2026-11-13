#ifndef IM_SHARED_SDK_H
#define IM_SHARED_SDK_H
#include <stdint.h>
int64_t im_shared_create(const uint8_t *, int32_t);
int64_t im_shared_submit(int64_t, const uint8_t *, int32_t);
char *im_shared_poll(int64_t);
void im_shared_cancel(int64_t);
int32_t im_shared_release(int64_t);
int32_t im_shared_release_client(int64_t);
int32_t im_shared_active(void);
int32_t im_shared_clients(void);
void im_shared_free(char *);
#endif
