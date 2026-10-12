#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

static int fail(const char *message)
{
    perror(message);
    return 1;
}

int main(int argc, char **argv)
{
    (void)argv;
    if (argc != 1 || getuid() != 1000 || geteuid() != 0) {
        fprintf(stderr, "agent-docker-tun: requires UID 1000 and a root-owned setuid installation\n");
        return 1;
    }

    /* /dev is recreated by microsandbox at boot. Never follow an agent-supplied
     * symlink or change anything except the existing kernel TUN device. */
    int dir = open("/dev/net", O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (dir < 0)
        return fail("agent-docker-tun: open /dev/net");
    int fd = openat(dir, "tun", O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    close(dir);
    if (fd < 0)
        return fail("agent-docker-tun: open /dev/net/tun");

    struct stat st;
    if (fstat(fd, &st) < 0)
        return fail("agent-docker-tun: stat /dev/net/tun");
    if (!S_ISCHR(st.st_mode) || major(st.st_rdev) != 10 || minor(st.st_rdev) != 200) {
        fprintf(stderr, "agent-docker-tun: /dev/net/tun is not the TUN device (10:200)\n");
        return 1;
    }
    if (fchown(fd, 1000, 1000) < 0)
        return fail("agent-docker-tun: chown /dev/net/tun");
    if (fchmod(fd, 0600) < 0)
        return fail("agent-docker-tun: chmod /dev/net/tun");
    close(fd);
    return 0;
}
