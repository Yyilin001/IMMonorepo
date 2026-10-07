/* Test fixture only. Compile into a task-owned dylib; never change signing.
 * V2_ACTOR_PORT_MAP: original=proxy[,original=proxy...] (maximum six peers).
 * Only TCP connect destinations on IPv4/IPv6 loopback are rewritten.
 */
#include <arpa/inet.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include <stdatomic.h>

static struct { unsigned short original, proxy; } mappings[6];
static unsigned count;
static atomic_flag matched_once = ATOMIC_FLAG_INIT;
__attribute__((constructor)) static void configure(void) {
    const char *value = getenv("V2_ACTOR_PORT_MAP");
    if (!value || strlen(value) > 256) _exit(125);
    const char *cursor = value;
    while (*cursor) {
        if (*cursor < '0' || *cursor > '9') _exit(125);
        char *end; unsigned long from = strtoul(cursor, &end, 10);
        if (end == cursor || *end != '=' || from == 0 || from > 65535 || count == 6) _exit(125);
        cursor = end + 1;
        if (*cursor < '0' || *cursor > '9') _exit(125);
        unsigned long to = strtoul(cursor, &end, 10);
        if (end == cursor || (*end && *end != ',') || to == 0 || to > 65535 || from == to) _exit(125);
        for (unsigned i = 0; i < count; i++) if (mappings[i].original == from) _exit(125);
        mappings[count].original = (unsigned short)from; mappings[count++].proxy = (unsigned short)to;
        cursor = *end ? end + 1 : end;
        if (*end && !*cursor) _exit(125);
    }
    if (!count) _exit(125);
    /* Closed diagnostic: no ports, environment contents or socket payload. */
    static const char marker[] = "v2_actor_fixture_interpose_loaded\n";
    (void)write(STDERR_FILENO, marker, sizeof(marker) - 1);
}
static int fixture_connect(int fd, const struct sockaddr *address, socklen_t length) {
    struct sockaddr_storage copy;
    unsigned short port = 0; int loopback = 0;
    if (address && length <= sizeof(copy) && address->sa_family == AF_INET && length >= sizeof(struct sockaddr_in)) {
        const struct sockaddr_in *v4 = (const void *)address;
        loopback = ntohl(v4->sin_addr.s_addr) == 0x7f000001; port = ntohs(v4->sin_port);
    } else if (address && length <= sizeof(copy) && address->sa_family == AF_INET6 && length >= sizeof(struct sockaddr_in6)) {
        const struct sockaddr_in6 *v6 = (const void *)address;
        loopback = IN6_IS_ADDR_LOOPBACK(&v6->sin6_addr); port = ntohs(v6->sin6_port);
    }
    if (loopback) for (unsigned i = 0; i < count; i++) if (mappings[i].original == port) {
        if (!atomic_flag_test_and_set(&matched_once)) {
            static const char marker[] = "v2_actor_fixture_connect_mapped\n";
            (void)write(STDERR_FILENO, marker, sizeof(marker) - 1);
        }
        memset(&copy, 0, sizeof(copy)); memcpy(&copy, address, length);
        if (address->sa_family == AF_INET) ((struct sockaddr_in *)&copy)->sin_port = htons(mappings[i].proxy);
        else ((struct sockaddr_in6 *)&copy)->sin6_port = htons(mappings[i].proxy);
        /* DYLD excludes this interposer's reference to the replaced symbol. */
        return connect(fd, (const struct sockaddr *)&copy, length);
    }
    return connect(fd, address, length);
}
#define FIXTURE_INTERPOSE(replacement, original) \
    __attribute__((used)) static struct { const void *replacement; const void *original; } pair_##original \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)&replacement, (const void *)&original }
FIXTURE_INTERPOSE(fixture_connect, connect);
