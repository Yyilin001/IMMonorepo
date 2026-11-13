#ifndef IM_SEARCH_FILE_LOCK_H
#define IM_SEARCH_FILE_LOCK_H
#include <stdint.h>
// Opaque, single-owner lease. status: 0 success, 1 busy, 2 create/open failure, 3 lock failure.
void *im_search_lock_open(const char *path, int32_t *status, int32_t *native_error);
void im_search_lock_close(void *lease);
#endif
