#include "CSearchFileLock.h"
#include <stdlib.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
struct Lease { HANDLE file; OVERLAPPED overlapped; };
void *im_search_lock_open(const char *path, int32_t *status, int32_t *native_error) {
    *status = 2; *native_error = 0;
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
    if (count == 0) { *native_error = GetLastError(); return NULL; }
    wchar_t *wide = malloc((size_t)count * sizeof(wchar_t));
    if (!wide) { *native_error = ERROR_NOT_ENOUGH_MEMORY; return NULL; }
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, count)) {
        *native_error = GetLastError(); free(wide); return NULL;
    }
    HANDLE file = CreateFileW(wide, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                              NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    free(wide);
    if (file == INVALID_HANDLE_VALUE) { *native_error = GetLastError(); return NULL; }
    BY_HANDLE_FILE_INFORMATION facts;
    if (!GetFileInformationByHandle(file, &facts) || (facts.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY))) {
        *native_error = ERROR_ACCESS_DENIED; CloseHandle(file); return NULL;
    }
    struct Lease *lease = calloc(1, sizeof(struct Lease));
    if (!lease) { *native_error = ERROR_NOT_ENOUGH_MEMORY; CloseHandle(file); return NULL; }
    lease->file = file;
    if (!LockFileEx(file, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &lease->overlapped)) {
        *native_error = GetLastError(); *status = *native_error == ERROR_LOCK_VIOLATION ? 1 : 3;
        CloseHandle(file); free(lease); return NULL;
    }
    *status = 0; return lease;
}
void im_search_lock_close(void *value) {
    if (!value) return;
    struct Lease *lease = value;
    UnlockFileEx(lease->file, 0, 1, 0, &lease->overlapped); CloseHandle(lease->file); free(lease);
}
#else
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
struct Lease { int descriptor; };
void *im_search_lock_open(const char *path, int32_t *status, int32_t *native_error) {
    *status = 2; *native_error = 0;
    int descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR);
    if (descriptor < 0) { *native_error = errno; return NULL; }
    if (flock(descriptor, LOCK_EX | LOCK_NB) != 0) {
        *native_error = errno; *status = errno == EWOULDBLOCK ? 1 : 3; close(descriptor); return NULL;
    }
    struct Lease *lease = malloc(sizeof(struct Lease));
    if (!lease) { *native_error = ENOMEM; *status = 3; flock(descriptor, LOCK_UN); close(descriptor); return NULL; }
    lease->descriptor = descriptor; *status = 0; return lease;
}
void im_search_lock_close(void *value) {
    if (!value) return;
    struct Lease *lease = value;
    flock(lease->descriptor, LOCK_UN); close(lease->descriptor); free(lease);
}
#endif
