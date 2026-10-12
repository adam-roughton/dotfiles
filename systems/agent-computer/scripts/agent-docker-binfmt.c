#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/statfs.h>
#include <unistd.h>

#ifndef AGENT_QEMU_X86_64
#error "AGENT_QEMU_X86_64 must name the static qemu-x86_64 interpreter"
#endif

#define BINFMT_DIR "/proc/sys/fs/binfmt_misc"
#define BINFMT_MISC_MAGIC 0x42494e4d

/* x86_64 ELF magic and mask, as in NixOS boot.binfmt
 * (nixos/lib/binfmt-magics.nix). The kernel decodes the \x escapes.
 *   P  preserve argv[0] (QEMU reads AT_FLAGS)
 *   O  hand the interpreter an open file descriptor for the binary
 *   C  use the binary's credentials, so setuid programs in amd64 images
 *      behave as they would natively (implies O)
 *   F  open the interpreter now, so it works in container mount namespaces
 *      where the Nix store is absent; the interpreter must be static */
static const char registration[] =
    ":qemu-x86_64:M::"
    "\\x7fELF\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\x3e\\x00:"
    "\\xff\\xff\\xff\\xff\\xff\\xfe\\xfe\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff:"
    AGENT_QEMU_X86_64 ":POCF";

static int fail(const char *message)
{
    perror(message);
    return 1;
}

int main(int argc, char **argv)
{
    (void)argv;
    if (argc != 1 || getuid() != 1000 || geteuid() != 0) {
        fprintf(stderr, "agent-docker-binfmt: requires UID 1000 and a root-owned setuid installation\n");
        return 1;
    }

    /* binfmt_misc registrations do not survive a VM restart, and microsandbox
     * does not mount the filesystem. Mount it on its fixed procfs mount point
     * unless that is already done. */
    struct statfs fs;
    if (statfs(BINFMT_DIR, &fs) < 0)
        return fail("agent-docker-binfmt: statfs " BINFMT_DIR);
    if (fs.f_type != BINFMT_MISC_MAGIC
        && mount("binfmt_misc", BINFMT_DIR, "binfmt_misc", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL) < 0)
        return fail("agent-docker-binfmt: mount " BINFMT_DIR);

    /* Only the fixed registration above is ever written. An existing entry of
     * the same name was registered by an earlier run in this boot. */
    int fd = open(BINFMT_DIR "/register", O_WRONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0)
        return fail("agent-docker-binfmt: open " BINFMT_DIR "/register");
    ssize_t written = write(fd, registration, strlen(registration));
    int saved = errno;
    close(fd);
    if (written < 0 && saved != EEXIST) {
        errno = saved;
        return fail("agent-docker-binfmt: register qemu-x86_64");
    }
    if (written >= 0 && (size_t)written != strlen(registration)) {
        fprintf(stderr, "agent-docker-binfmt: short write registering qemu-x86_64\n");
        return 1;
    }
    return 0;
}
