#include <sys/types.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/event.h>
#include <sys/proc_info.h>
#include <libproc.h>
#include <spawn.h>
#include <fcntl.h>
#include <net/if.h>
#include <ifaddrs.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

/* No subprocess, filesystem access or preference lookup on the fast path.
   Reuse one control socket and close physical interfaces before tunnels. */
int sg_fast_cutoff(const char *preferred) {
    struct ifaddrs *head = NULL;
    if (getifaddrs(&head) < 0) return 1;
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) { freeifaddrs(head); return 1; }
    char names[256][IFNAMSIZ];
    unsigned int count = 0;
    int errors = 0;
    for (struct ifaddrs *p = head; p; p = p->ifa_next) {
        if (!(p->ifa_flags & IFF_UP) || (p->ifa_flags & IFF_LOOPBACK)) continue;
        unsigned int i;
        for (i = 0; i < count; i++) if (!strcmp(names[i], p->ifa_name)) break;
        if (i < count) continue;
        if (count == 256) { errors++; continue; }
        strlcpy(names[count++], p->ifa_name, IFNAMSIZ);
    }
    for (int pass = 0; pass < 3; pass++) {
        for (unsigned int i = 0; i < count; i++) {
            int physical = !strncmp(names[i], "en", 2) || !strncmp(names[i], "bridge", 6);
            int priority = preferred && preferred[0] && !strcmp(names[i], preferred);
            if (pass == 0 && !priority) continue;
            if (pass == 1 && (priority || !physical)) continue;
            if (pass == 2 && (priority || physical)) continue;
            struct ifreq req = {0};
            strlcpy(req.ifr_name, names[i], sizeof(req.ifr_name));
            if (ioctl(fd, SIOCGIFFLAGS, &req) < 0) {
                if (errno != ENXIO && errno != ENODEV) errors++;
                continue;
            }
            req.ifr_flags &= ~IFF_UP;
            if (ioctl(fd, SIOCSIFFLAGS, &req) < 0 && errno != ENXIO && errno != ENODEV) errors++;
        }
    }
    close(fd);
    freeifaddrs(head);
    return errors;
}

int sg_process_uid(int pid) {
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return -1;
    return (int)info.pbi_uid;
}

/* Isolate each command in its own process group. On timeout the caller can
   terminate the entire launchctl/sudo/CLI tree, not just its outer wrapper. */
int sg_spawn(const char *path, char *const argv[], char *const envp[], int *output_fd, int *child_pid) {
    int pipes[2];
    if (pipe(pipes) < 0) return errno;
    fcntl(pipes[0], F_SETFD, FD_CLOEXEC);
    fcntl(pipes[1], F_SETFD, FD_CLOEXEC);
    posix_spawnattr_t attr;
    posix_spawn_file_actions_t actions;
    int e = posix_spawnattr_init(&attr);
    if (e) { close(pipes[0]); close(pipes[1]); return e; }
    e = posix_spawn_file_actions_init(&actions);
    if (e) { posix_spawnattr_destroy(&attr); close(pipes[0]); close(pipes[1]); return e; }
    e = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT);
    if (!e) e = posix_spawnattr_setpgroup(&attr, 0);
    if (!e) e = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    if (!e) e = posix_spawn_file_actions_adddup2(&actions, pipes[1], STDOUT_FILENO);
    if (!e) e = posix_spawn_file_actions_adddup2(&actions, pipes[1], STDERR_FILENO);
    if (!e) e = posix_spawn_file_actions_addclose(&actions, pipes[0]);
    if (!e) e = posix_spawn_file_actions_addclose(&actions, pipes[1]);
    pid_t pid = 0;
    if (!e) e = posix_spawn(&pid, path, &actions, &attr, argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    close(pipes[1]);
    if (e) { close(pipes[0]); return e; }
    int flags = fcntl(pipes[0], F_GETFL);
    fcntl(pipes[0], F_SETFL, flags | O_NONBLOCK);
    *output_fd = pipes[0];
    *child_pid = pid;
    return 0;
}

/* A private stdin pipe keeps one interactive CLI connection alive. */
int sg_spawn_interactive(const char *path, char *const argv[], char *const envp[],
                         int *output_fd, int *input_fd, int *child_pid) {
    int out[2], in[2];
    if (pipe(out) < 0) return errno;
    if (pipe(in) < 0) { int e = errno; close(out[0]); close(out[1]); return e; }
    int fds[] = {out[0], out[1], in[0], in[1]};
    for (int i = 0; i < 4; i++) fcntl(fds[i], F_SETFD, FD_CLOEXEC);
    posix_spawnattr_t attr;
    posix_spawn_file_actions_t actions;
    int e = posix_spawnattr_init(&attr);
    if (e) { for (int i = 0; i < 4; i++) close(fds[i]); return e; }
    e = posix_spawn_file_actions_init(&actions);
    if (e) { posix_spawnattr_destroy(&attr); for (int i = 0; i < 4; i++) close(fds[i]); return e; }
    e = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT);
    if (!e) e = posix_spawnattr_setpgroup(&attr, 0);
    if (!e) e = posix_spawn_file_actions_adddup2(&actions, in[0], STDIN_FILENO);
    if (!e) e = posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO);
    if (!e) e = posix_spawn_file_actions_adddup2(&actions, out[1], STDERR_FILENO);
    for (int i = 0; i < 4 && !e; i++) e = posix_spawn_file_actions_addclose(&actions, fds[i]);
    pid_t pid = 0;
    if (!e) e = posix_spawn(&pid, path, &actions, &attr, argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    close(out[1]); close(in[0]);
    if (e) { close(out[0]); close(in[1]); return e; }
    fcntl(out[0], F_SETFL, fcntl(out[0], F_GETFL) | O_NONBLOCK);
    fcntl(in[1], F_SETFL, fcntl(in[1], F_GETFL) | O_NONBLOCK);
    // An exited CLI must produce a recoverable EPIPE, not kill the watchdog.
    fcntl(in[1], F_SETNOSIGPIPE, 1);
    *output_fd = out[0]; *input_fd = in[1]; *child_pid = pid;
    return 0;
}

/* Read current flags again, preserving flags unrelated to administrative UP. */
int sg_set_up(const char *name, int up) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return errno;
    struct ifreq req = {0};
    strlcpy(req.ifr_name, name, sizeof(req.ifr_name));
    if (ioctl(fd, SIOCGIFFLAGS, &req) < 0) {
        int e = errno; close(fd); return e;
    }
    if (up) req.ifr_flags |= IFF_UP;
    else req.ifr_flags &= ~IFF_UP;
    int result = ioctl(fd, SIOCSIFFLAGS, &req) < 0 ? errno : 0;
    close(fd);
    return result;
}

int sg_watch_exit(int queue, int pid) {
    struct kevent event;
    EV_SET(&event, pid, EVFILT_PROC, EV_ADD | EV_ENABLE | EV_ONESHOT,
           NOTE_EXIT, 0, NULL);
    return kevent(queue, &event, 1, NULL, 0, NULL);
}

/* 1 = exit, 0 = timeout, -1 = monitoring error (caller fails closed). */
int sg_wait_exit(int queue, int milliseconds) {
    struct kevent event;
    struct timespec timeout = { milliseconds / 1000,
                               (milliseconds % 1000) * 1000000L };
    int n = kevent(queue, NULL, 0, &event, 1, &timeout);
    if (n < 0 && errno == EINTR) return 0;
    if (n < 0 || (n > 0 && (event.flags & EV_ERROR))) return -1;
    return n > 0 ? 1 : 0;
}
