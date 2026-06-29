#!/usr/bin/env bash
set -euxo pipefail


# most impressive:

# 1. dispatch_semaphore vs pipe doorbells (tip 06)
#    - old pipe: 90 million cycles
#    - new dispatch_semaphore: 7.4 million cycles
#    - why it matters: pipes force a context switch into the bsd vfs layer, allocating kernel buffers and burning cpu just to move 1 byte. dispatch_semaphore is backed by mach semaphores and resolves uncontended signals entirely in userspace using atomics. it is a 12x performance win for signaling.

# 2. os_unfair_lock vs pthread_mutex (tip 07)
#    - old pthread_mutex: 887 million cycles
#    - new os_unfair_lock: 560 million cycles
#    - why it matters: pthread_mutex carries legacy posix baggage. os_unfair_lock is the lowest-level darwin locking primitive. it refuses to do fair queuing (which prevents lock convoys) and prevents priority inversion natively. it shaves over 300 million cycles off the tight loop simply by avoiding the posix wrapper.

# 3. apple silicon qos asymmetric scheduling (tip 08)
#    - why it matters: your m4 pro has 10 performance cores and 4 efficiency cores. default pthreads do not know about this heterogeneous topology. by applying `pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)`, you explicitly instruct the mach scheduler to pin this thread to the p-cores. without this, heavy background processing silently starves on the e-cores while your thermal envelope sits unused.

# 4. apfs clonefile vs posix read/write (tip 10)
#    - why it matters: the standard read/write loop copies 16mb of memory through the cpu cache. `clonefile` bypasses file data entirely. it instructs the apfs filesystem to duplicate the metadata pointer and mark the blocks as copy-on-write. it turns an O(N) memory/disk bandwidth choke into an O(1) instantaneous transaction.

# 5. kqueue EVFILT_TIMER vs usleep (tip 09)
#    - old usleep drift: ~57 million nanoseconds (57ms)
#    - new kqueue drift: ~785 thousand nanoseconds (0.7ms)
#    - why it matters: `usleep` is bound by default mach timer coalescing, which aggressively defers wakeups to save battery. kqueue timers interface directly with the kernel's event delivery subsystem. the drift was obliterated by nearly two orders of magnitude, providing precise wakeup pacing without burning cpu in a spinlock.


work="linuxtips-macos-work-$$"
mkdir "$work"

cleanup() {
    set +e
    if [ ! -d "$work" ]; then
        return
    fi
    if command -v trash >/dev/null 2>&1 && trash "$work"; then
        return
    fi
    grave=".linuxtips-macos-trash-$$"
    mkdir -p "$grave"
    mv -vn "$work" "$grave/"
    printf 'trash command missing; moved generated files under %s\n' "$grave"
}

run_c() {
    tag="$1"
    src="$work/$tag.c"
    exe="$work/$tag"
    printf '\n========================================================================\n'
    printf '%s\n' "$tag"
    printf '========================================================================\n'
    printf -- '----- source: %s.c -----\n' "$tag"
    cat "$src"
    printf -- '----- build: %s.c -----\n' "$tag"
    "${CC:-cc}" -O2 -std=gnu11 -Wall -Wextra -pthread -fblocks "$src" -o "$exe"
    printf -- '----- bench/profile: %s -----\n' "$tag"
    if [ -x /usr/bin/time ]; then
        (cd "$work" && /usr/bin/time -lp "./$tag")
    else
        (cd "$work" && "./$tag")
    fi
}

sysctl_line() {
    key="$1"
    value="$(sysctl -n "$key" 2>/dev/null || printf unavailable)"
    printf '%s=%s\n' "$key" "$value"
}

trap cleanup EXIT

printf 'macOS executable performance cookbook\n'
printf 'sw_vers:\n'
sw_vers
printf 'kernel: '
uname -a
printf 'compiler: '
"${CC:-cc}" --version | head -n 1
printf 'hardware:\n'
for key in machdep.cpu.brand_string hw.machine hw.optional.arm64 hw.ncpu hw.physicalcpu hw.logicalcpu hw.memsize hw.pagesize hw.cachelinesize hw.perflevel0.name hw.perflevel0.physicalcpu hw.perflevel0.logicalcpu hw.perflevel1.name hw.perflevel1.physicalcpu hw.perflevel1.logicalcpu; do
    sysctl_line "$key"
done

printf '\nTIP 01: mach_absolute_time monotonic ticks vs gettimeofday wall-clock calls\n'
cat > "$work/01-mach-time-oldway.c" <<'C'
#include <stdio.h>
#include <sys/time.h>

int main(void) {
    struct timeval tv;
    long checksum = 0;
    int n = 500000;
    for (int i = 0; i < n; i++) {
        if (gettimeofday(&tv, NULL)) {
            perror("gettimeofday");
            return 1;
        }
        checksum += tv.tv_usec & 1;
    }
    printf("old gettimeofday wall-clock calls=%d checksum=%ld\n", n, checksum);
    return 0;
}
C

cat > "$work/01-mach-time-newway.c" <<'C'
#include <mach/mach_time.h>
#include <stdint.h>
#include <stdio.h>

int main(void) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    uint64_t first = mach_absolute_time();
    uint64_t last = first;
    int n = 500000;
    for (int i = 0; i < n; i++) {
        last = mach_absolute_time();
    }
    unsigned long long ns = (unsigned long long)((__uint128_t)(last - first) * tb.numer / tb.denom);
    printf("new mach_absolute_time calls=%d elapsed_ns=%llu numer=%u denom=%u\n", n, ns, tb.numer, tb.denom);
    return 0;
}
C
run_c 01-mach-time-oldway
run_c 01-mach-time-newway

printf '\nTIP 02: sysctlbyname in-process hardware facts vs spawning sysctl\n'
cat > "$work/02-sysctl-oldway.c" <<'C'
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    int n = 40;
    int ok = 0;
    for (int i = 0; i < n; i++) {
        ok += system("sysctl -n hw.ncpu >/dev/null") == 0;
    }
    printf("old spawned sysctl commands=%d ok=%d\n", n, ok);
    return 0;
}
C

cat > "$work/02-sysctl-newway.c" <<'C'
#include <stdio.h>
#include <sys/sysctl.h>

static int read_int(const char *key) {
    int value = -1;
    size_t len = sizeof(value);
    if (sysctlbyname(key, &value, &len, NULL, 0)) {
        return -1;
    }
    return value;
}

int main(void) {
    int value = 0;
    int n = 200000;
    for (int i = 0; i < n; i++) {
        value += read_int("hw.ncpu");
    }
    printf("new sysctlbyname calls=%d checksum=%d ncpu=%d pcores=%d ecores=%d\n", n, value, read_int("hw.ncpu"), read_int("hw.perflevel0.physicalcpu"), read_int("hw.perflevel1.physicalcpu"));
    return 0;
}
C
run_c 02-sysctl-oldway
run_c 02-sysctl-newway

printf '\nTIP 03: posix_spawn on Darwin vs fork+exec for simple child startup\n'
cat > "$work/03-spawn-oldway.c" <<'C'
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

int main(void) {
    int n = 120;
    int ok = 0;
    for (int i = 0; i < n; i++) {
        pid_t pid = fork();
        if (pid < 0) {
            perror("fork");
            return 1;
        }
        if (!pid) {
            execl("/usr/bin/true", "true", NULL);
            _exit(127);
        }
        int status = 0;
        waitpid(pid, &status, 0);
        ok += status == 0;
    }
    printf("old fork+exec children=%d ok=%d\n", n, ok);
    return 0;
}
C

cat > "$work/03-spawn-newway.c" <<'C'
#include <spawn.h>
#include <stdio.h>
#include <sys/wait.h>

extern char **environ;

int main(void) {
    int n = 120;
    int ok = 0;
    char *argv[] = { "true", NULL };
    for (int i = 0; i < n; i++) {
        pid_t pid = 0;
        int r = posix_spawn(&pid, "/usr/bin/true", NULL, NULL, argv, environ);
        if (r) {
            printf("posix_spawn failed=%d\n", r);
            return 1;
        }
        int status = 0;
        waitpid(pid, &status, 0);
        ok += status == 0;
    }
    printf("new posix_spawn children=%d ok=%d\n", n, ok);
    return 0;
}
C
run_c 03-spawn-oldway
run_c 03-spawn-newway

printf '\nTIP 04: kqueue EVFILT_USER wakeups vs sleepy polling\n'
cat > "$work/04-kqueue-user-oldway.c" <<'C'
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>

static volatile int ready;

static void *worker(void *arg) {
    (void)arg;
    usleep(100000);
    ready = 1;
    return NULL;
}

int main(void) {
    pthread_t t;
    pthread_create(&t, NULL, worker, NULL);
    int polls = 0;
    while (!ready) {
        usleep(1000);
        polls++;
    }
    pthread_join(t, NULL);
    printf("old usleep polling observed ready after polls=%d\n", polls);
    return 0;
}
C

cat > "$work/04-kqueue-user-newway.c" <<'C'
#include <pthread.h>
#include <stdio.h>
#include <sys/event.h>
#include <unistd.h>

static int kq;

static void *worker(void *arg) {
    (void)arg;
    usleep(100000);
    struct kevent kev;
    EV_SET(&kev, 1, EVFILT_USER, 0, NOTE_TRIGGER, 0, NULL);
    if (kevent(kq, &kev, 1, NULL, 0, NULL) < 0) {
        perror("kevent trigger");
    }
    return NULL;
}

int main(void) {
    kq = kqueue();
    if (kq < 0) {
        perror("kqueue");
        return 1;
    }
    struct kevent kev;
    EV_SET(&kev, 1, EVFILT_USER, EV_ADD | EV_CLEAR, 0, 0, NULL);
    if (kevent(kq, &kev, 1, NULL, 0, NULL) < 0) {
        perror("kevent add");
        return 1;
    }
    pthread_t t;
    pthread_create(&t, NULL, worker, NULL);
    struct kevent ev;
    int n = kevent(kq, NULL, 0, &ev, 1, NULL);
    pthread_join(t, NULL);
    printf("new kqueue EVFILT_USER events=%d ident=%llu fflags=0x%x\n", n, (unsigned long long)ev.ident, ev.fflags);
    return 0;
}
C
run_c 04-kqueue-user-oldway
run_c 04-kqueue-user-newway

printf '\nTIP 05: kqueue EVFILT_VNODE file change events vs stat polling\n'
cat > "$work/05-kqueue-vnode-oldway.c" <<'C'
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *path = "05-vnode-oldway.data";

static void *worker(void *arg) {
    (void)arg;
    usleep(100000);
    int fd = open(path, O_WRONLY | O_APPEND);
    if (fd >= 0) {
        write(fd, "change", 6);
        close(fd);
    }
    return NULL;
}

int main(void) {
    int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0600);
    write(fd, "x", 1);
    close(fd);
    struct stat st;
    stat(path, &st);
    off_t start = st.st_size;
    pthread_t t;
    pthread_create(&t, NULL, worker, NULL);
    int polls = 0;
    do {
        usleep(1000);
        polls++;
        stat(path, &st);
    } while (st.st_size == start);
    pthread_join(t, NULL);
    printf("old stat polling polls=%d old_size=%lld new_size=%lld\n", polls, (long long)start, (long long)st.st_size);
    return 0;
}
C

cat > "$work/05-kqueue-vnode-newway.c" <<'C'
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <sys/event.h>
#include <unistd.h>

static const char *path = "05-vnode-newway.data";

static void *worker(void *arg) {
    (void)arg;
    usleep(100000);
    int fd = open(path, O_WRONLY | O_APPEND);
    if (fd >= 0) {
        write(fd, "change", 6);
        close(fd);
    }
    return NULL;
}

int main(void) {
    int w = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0600);
    write(w, "x", 1);
    close(w);
    int flags = O_RDONLY;
#ifdef O_EVTONLY
    flags = O_EVTONLY;
#endif
    int fd = open(path, flags);
    if (fd < 0) {
        perror("open watch");
        return 1;
    }
    int kq = kqueue();
    struct kevent kev;
    EV_SET(&kev, fd, EVFILT_VNODE, EV_ADD | EV_CLEAR, NOTE_WRITE | NOTE_EXTEND | NOTE_DELETE | NOTE_RENAME, 0, NULL);
    if (kevent(kq, &kev, 1, NULL, 0, NULL) < 0) {
        perror("kevent vnode add");
        return 1;
    }
    pthread_t t;
    pthread_create(&t, NULL, worker, NULL);
    struct kevent ev;
    int n = kevent(kq, NULL, 0, &ev, 1, NULL);
    pthread_join(t, NULL);
    printf("new kqueue EVFILT_VNODE events=%d fflags=0x%x\n", n, ev.fflags);
    return 0;
}
C
run_c 05-kqueue-vnode-oldway
run_c 05-kqueue-vnode-newway

printf '\nTIP 06: dispatch semaphore token counter vs pipe byte notification\n'
cat > "$work/06-dispatch-sem-oldway.c" <<'C'
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

int main(void) {
    int p[2];
    if (pipe(p)) {
        perror("pipe");
        return 1;
    }
    uint64_t x = 1;
    int n = 50000;
    for (int i = 0; i < n; i++) {
        if (write(p[1], &x, sizeof(x)) != (ssize_t)sizeof(x)) {
            perror("write");
            return 1;
        }
        if (read(p[0], &x, sizeof(x)) != (ssize_t)sizeof(x)) {
            perror("read");
            return 1;
        }
    }
    printf("old pipe byte doorbell roundtrips=%d\n", n);
    return 0;
}
C

cat > "$work/06-dispatch-sem-newway.c" <<'C'
#include <dispatch/dispatch.h>
#include <stdio.h>

int main(void) {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    int n = 50000;
    for (int i = 0; i < n; i++) {
        dispatch_semaphore_signal(sem);
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    }
    printf("new dispatch_semaphore token roundtrips=%d\n", n);
    return 0;
}
C
run_c 06-dispatch-sem-oldway
run_c 06-dispatch-sem-newway

printf '\nTIP 07: os_unfair_lock low-level Darwin mutex vs pthread_mutex\n'
cat > "$work/07-unfair-lock-oldway.c" <<'C'
#include <pthread.h>
#include <stdio.h>
#include <sys/sysctl.h>

enum { N = 200000 };
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static long counter;

static int threads(void) {
    int v = 4;
    size_t len = sizeof(v);
    sysctlbyname("hw.ncpu", &v, &len, NULL, 0);
    if (v < 1) {
        return 1;
    }
    if (v > 14) {
        return 14;
    }
    return v;
}

static void *worker(void *arg) {
    (void)arg;
    for (int i = 0; i < N; i++) {
        pthread_mutex_lock(&lock);
        counter++;
        pthread_mutex_unlock(&lock);
    }
    return NULL;
}

int main(void) {
    int tcount = threads();
    pthread_t t[32];
    for (int i = 0; i < tcount; i++) {
        pthread_create(&t[i], NULL, worker, NULL);
    }
    for (int i = 0; i < tcount; i++) {
        pthread_join(t[i], NULL);
    }
    printf("old pthread_mutex threads=%d counter=%ld expected=%ld\n", tcount, counter, (long)tcount * N);
    return 0;
}
C

cat > "$work/07-unfair-lock-newway.c" <<'C'
#include <os/lock.h>
#include <pthread.h>
#include <stdio.h>
#include <sys/sysctl.h>

enum { N = 200000 };
static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
static long counter;

static int threads(void) {
    int v = 4;
    size_t len = sizeof(v);
    sysctlbyname("hw.ncpu", &v, &len, NULL, 0);
    if (v < 1) {
        return 1;
    }
    if (v > 14) {
        return 14;
    }
    return v;
}

static void *worker(void *arg) {
    (void)arg;
    for (int i = 0; i < N; i++) {
        os_unfair_lock_lock(&lock);
        counter++;
        os_unfair_lock_unlock(&lock);
    }
    return NULL;
}

int main(void) {
    int tcount = threads();
    pthread_t t[32];
    for (int i = 0; i < tcount; i++) {
        pthread_create(&t[i], NULL, worker, NULL);
    }
    for (int i = 0; i < tcount; i++) {
        pthread_join(t[i], NULL);
    }
    printf("new os_unfair_lock threads=%d counter=%ld expected=%ld\n", tcount, counter, (long)tcount * N);
    return 0;
}
C
run_c 07-unfair-lock-oldway
run_c 07-unfair-lock-newway

printf '\nTIP 08: QoS-aware work on M4 Pro performance/efficiency cores vs default pthreads\n'
cat > "$work/08-qos-oldway.c" <<'C'
#include <pthread.h>
#include <stdio.h>
#include <sys/sysctl.h>

enum { N = 2000000 };
static volatile unsigned long long slots[32];

static int read_int(const char *key, int fallback) {
    int value = fallback;
    size_t len = sizeof(value);
    sysctlbyname(key, &value, &len, NULL, 0);
    return value;
}

static void *worker(void *arg) {
    long id = (long)arg;
    unsigned long long x = (unsigned long long)id + 1;
    for (int i = 0; i < N; i++) {
        x = x * 2862933555777941757ULL + 3037000493ULL;
    }
    slots[id] = x;
    return NULL;
}

int main(void) {
    int tcount = read_int("hw.ncpu", 4);
    if (tcount > 14) {
        tcount = 14;
    }
    pthread_t t[32];
    for (long i = 0; i < tcount; i++) {
        pthread_create(&t[i], NULL, worker, (void *)i);
    }
    unsigned long long checksum = 0;
    for (int i = 0; i < tcount; i++) {
        pthread_join(t[i], NULL);
        checksum ^= slots[i];
    }
    printf("old default pthreads threads=%d checksum=%llu pcores=%d ecores=%d\n", tcount, checksum, read_int("hw.perflevel0.physicalcpu", -1), read_int("hw.perflevel1.physicalcpu", -1));
    return 0;
}
C

cat > "$work/08-qos-newway.c" <<'C'
#include <pthread.h>
#include <pthread/qos.h>
#include <stdio.h>
#include <sys/sysctl.h>

enum { N = 2000000 };
static volatile unsigned long long slots[32];
static qos_class_t seen_qos[32];
static int seen_rel[32];

static int read_int(const char *key, int fallback) {
    int value = fallback;
    size_t len = sizeof(value);
    sysctlbyname(key, &value, &len, NULL, 0);
    return value;
}

static void *worker(void *arg) {
    long id = (long)arg;
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
    pthread_get_qos_class_np(pthread_self(), &seen_qos[id], &seen_rel[id]);
    unsigned long long x = (unsigned long long)id + 1;
    for (int i = 0; i < N; i++) {
        x = x * 2862933555777941757ULL + 3037000493ULL;
    }
    slots[id] = x;
    return NULL;
}

int main(void) {
    int tcount = read_int("hw.ncpu", 4);
    if (tcount > 14) {
        tcount = 14;
    }
    pthread_t t[32];
    for (long i = 0; i < tcount; i++) {
        pthread_create(&t[i], NULL, worker, (void *)i);
    }
    unsigned long long checksum = 0;
    for (int i = 0; i < tcount; i++) {
        pthread_join(t[i], NULL);
        checksum ^= slots[i];
    }
    printf("new USER_INITIATED QoS threads=%d checksum=%llu first_qos=%u pcores=%d ecores=%d\n", tcount, checksum, (unsigned)seen_qos[0], read_int("hw.perflevel0.physicalcpu", -1), read_int("hw.perflevel1.physicalcpu", -1));
    return 0;
}
C
run_c 08-qos-oldway
run_c 08-qos-newway

printf '\nTIP 09: kqueue EVFILT_TIMER kernel timer vs usleep loop drift\n'
cat > "$work/09-kqueue-timer-oldway.c" <<'C'
#include <mach/mach_time.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

static uint64_t now_ns(void) {
    mach_timebase_info_data_t tb;
    uint64_t t = mach_absolute_time();
    mach_timebase_info(&tb);
    return (uint64_t)((__uint128_t)t * tb.numer / tb.denom);
}

int main(void) {
    int n = 25;
    uint64_t step_ns = 10u * 1000u * 1000u;
    uint64_t start = now_ns();
    for (int i = 0; i < n; i++) {
        usleep((useconds_t)(step_ns / 1000u));
    }
    uint64_t elapsed = now_ns() - start;
    long long drift = (long long)elapsed - (long long)(step_ns * (uint64_t)n);
    printf("old usleep loop sleeps=%d expected_ns=%llu elapsed_ns=%llu drift_ns=%lld\n", n, (unsigned long long)(step_ns * (uint64_t)n), (unsigned long long)elapsed, drift);
    return 0;
}
C

cat > "$work/09-kqueue-timer-newway.c" <<'C'
#include <mach/mach_time.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/event.h>
#include <unistd.h>

static uint64_t now_ns(void) {
    mach_timebase_info_data_t tb;
    uint64_t t = mach_absolute_time();
    mach_timebase_info(&tb);
    return (uint64_t)((__uint128_t)t * tb.numer / tb.denom);
}

int main(void) {
    int kq = kqueue();
    if (kq < 0) {
        perror("kqueue");
        return 1;
    }
    struct kevent kev;
    EV_SET(&kev, 1, EVFILT_TIMER, EV_ADD | EV_ENABLE, 0, 10, NULL);
    if (kevent(kq, &kev, 1, NULL, 0, NULL) < 0) {
        perror("kevent add timer");
        return 1;
    }
    int n = 25;
    int events = 0;
    uint64_t step_ns = 10u * 1000u * 1000u;
    uint64_t start = now_ns();
    struct kevent ev;
    for (int i = 0; i < n; i++) {
        int r = kevent(kq, NULL, 0, &ev, 1, NULL);
        if (r < 0) {
            perror("kevent wait timer");
            return 1;
        }
        events += r;
    }
    uint64_t elapsed = now_ns() - start;
    long long drift = (long long)elapsed - (long long)(step_ns * (uint64_t)n);
    close(kq);
    printf("new kqueue EVFILT_TIMER events=%d expected_ns=%llu elapsed_ns=%llu drift_ns=%lld last_data=%ld\n", events, (unsigned long long)(step_ns * (uint64_t)n), (unsigned long long)elapsed, drift, (long)ev.data);
    return 0;
}
C
run_c 09-kqueue-timer-oldway
run_c 09-kqueue-timer-newway

printf '\nTIP 10: APFS clonefile copy-on-write clone vs manual read/write copy\n'
cat > "$work/10-clonefile-oldway.c" <<'C'
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void xwrite(int fd, const void *p, size_t n) {
    const char *b = p;
    while (n) {
        ssize_t r = write(fd, b, n);
        if (r <= 0) {
            perror("write");
            exit(1);
        }
        b += r;
        n -= (size_t)r;
    }
}

static void make_file(const char *path, size_t len) {
    char buf[65536];
    memset(buf, 7, sizeof(buf));
    int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0600);
    if (fd < 0) {
        perror("open source");
        exit(1);
    }
    for (size_t off = 0; off < len; off += sizeof(buf)) {
        xwrite(fd, buf, sizeof(buf));
    }
    close(fd);
}

int main(void) {
    size_t len = 16u * 1024u * 1024u;
    make_file("10-copy-src.data", len);
    int in = open("10-copy-src.data", O_RDONLY);
    int out = open("10-copy-dst.data", O_CREAT | O_TRUNC | O_WRONLY, 0600);
    char buf[65536];
    size_t copied = 0;
    for (;;) {
        ssize_t r = read(in, buf, sizeof(buf));
        if (r < 0) {
            perror("read");
            return 1;
        }
        if (!r) {
            break;
        }
        xwrite(out, buf, (size_t)r);
        copied += (size_t)r;
    }
    close(in);
    close(out);
    struct stat st;
    stat("10-copy-dst.data", &st);
    printf("old read/write copy bytes=%zu dst_size=%lld\n", copied, (long long)st.st_size);
    return 0;
}
C

cat > "$work/10-clonefile-newway.c" <<'C'
#include <sys/clonefile.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void xwrite(int fd, const void *p, size_t n) {
    const char *b = p;
    while (n) {
        ssize_t r = write(fd, b, n);
        if (r <= 0) {
            perror("write");
            exit(1);
        }
        b += r;
        n -= (size_t)r;
    }
}

static void make_file(const char *path, size_t len) {
    char buf[65536];
    memset(buf, 8, sizeof(buf));
    int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0600);
    if (fd < 0) {
        perror("open source");
        exit(1);
    }
    for (size_t off = 0; off < len; off += sizeof(buf)) {
        xwrite(fd, buf, sizeof(buf));
    }
    close(fd);
}

int main(void) {
    size_t len = 16u * 1024u * 1024u;
    make_file("10-clone-src.data", len);
    errno = 0;
    int r = clonefile("10-clone-src.data", "10-clone-dst.data", 0);
    if (r) {
        printf("new clonefile failed errno=%s\n", strerror(errno));
        return 0;
    }
    struct stat st;
    stat("10-clone-dst.data", &st);
    printf("new APFS clonefile result=%d dst_size=%lld bytes_logical=%zu\n", r, (long long)st.st_size, len);
    return 0;
}
C
run_c 10-clonefile-oldway
run_c 10-clonefile-newway

printf '\nTIP 11: macOS sendfile kernel path vs userspace read/write to TCP\n'
cat > "$work/11-sendfile-oldway.c" <<'C'
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

static void xwrite(int fd, const void *p, size_t n) {
    const char *b = p;
    while (n) {
        ssize_t r = write(fd, b, n);
        if (r <= 0) {
            perror("write");
            exit(1);
        }
        b += r;
        n -= (size_t)r;
    }
}

static void make_file(const char *path, size_t len) {
    char buf[65536];
    memset(buf, 9, sizeof(buf));
    int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0600);
    if (fd < 0) {
        perror("open make_file");
        exit(1);
    }
    for (size_t off = 0; off < len; off += sizeof(buf)) {
        xwrite(fd, buf, sizeof(buf));
    }
    close(fd);
}

int main(void) {
    size_t total = 4u * 1024u * 1024u;
    make_file("11-sendfile-oldway.data", total);
    int l = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(l, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    bind(l, (struct sockaddr *)&a, sizeof(a));
    listen(l, 1);
    socklen_t alen = sizeof(a);
    getsockname(l, (struct sockaddr *)&a, &alen);
    pid_t pid = fork();
    if (!pid) {
        int c = accept(l, NULL, NULL);
        char buf[65536];
        size_t got = 0;
        for (;;) {
            ssize_t r = read(c, buf, sizeof(buf));
            if (r <= 0) {
                break;
            }
            got += (size_t)r;
        }
        printf("old child received=%zu\n", got);
        return 0;
    }
    int s = socket(AF_INET, SOCK_STREAM, 0);
    connect(s, (struct sockaddr *)&a, sizeof(a));
    int fd = open("11-sendfile-oldway.data", O_RDONLY);
    char buf[65536];
    size_t sent = 0;
    for (;;) {
        ssize_t r = read(fd, buf, sizeof(buf));
        if (r < 0) {
            perror("read file");
            return 1;
        }
        if (!r) {
            break;
        }
        xwrite(s, buf, (size_t)r);
        sent += (size_t)r;
    }
    shutdown(s, SHUT_WR);
    waitpid(pid, NULL, 0);
    printf("old userspace file-to-TCP copy bytes=%zu\n", sent);
    return 0;
}
C

cat > "$work/11-sendfile-newway.c" <<'C'
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>

static void xwrite(int fd, const void *p, size_t n) {
    const char *b = p;
    while (n) {
        ssize_t r = write(fd, b, n);
        if (r <= 0) {
            perror("write");
            exit(1);
        }
        b += r;
        n -= (size_t)r;
    }
}

static void make_file(const char *path, size_t len) {
    char buf[65536];
    memset(buf, 10, sizeof(buf));
    int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0600);
    if (fd < 0) {
        perror("open make_file");
        exit(1);
    }
    for (size_t off = 0; off < len; off += sizeof(buf)) {
        xwrite(fd, buf, sizeof(buf));
    }
    close(fd);
}

int main(void) {
    size_t total = 4u * 1024u * 1024u;
    make_file("11-sendfile-newway.data", total);
    int l = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(l, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    bind(l, (struct sockaddr *)&a, sizeof(a));
    listen(l, 1);
    socklen_t alen = sizeof(a);
    getsockname(l, (struct sockaddr *)&a, &alen);
    pid_t pid = fork();
    if (!pid) {
        int c = accept(l, NULL, NULL);
        char buf[65536];
        size_t got = 0;
        for (;;) {
            ssize_t r = read(c, buf, sizeof(buf));
            if (r <= 0) {
                break;
            }
            got += (size_t)r;
        }
        printf("new child received=%zu\n", got);
        return 0;
    }
    int s = socket(AF_INET, SOCK_STREAM, 0);
    connect(s, (struct sockaddr *)&a, sizeof(a));
    int fd = open("11-sendfile-newway.data", O_RDONLY);
    off_t sent = (off_t)total;
    errno = 0;
    int r = sendfile(fd, s, 0, &sent, NULL, 0);
    int err = errno;
    shutdown(s, SHUT_WR);
    waitpid(pid, NULL, 0);
    printf("new sendfile result=%d errno=%s bytes=%lld\n", r, (err ? strerror(err) : "none"), (long long)sent);
    return 0;
}
C
run_c 11-sendfile-oldway
run_c 11-sendfile-newway

printf '\nTIP 12: F_NOCACHE file descriptor policy vs default cached reads\n'
cat > "$work/12-fnocache-oldway.c" <<'C'
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void xwrite(int fd, const void *p, size_t n) {
    const char *b = p;
    while (n) {
        ssize_t r = write(fd, b, n);
        if (r <= 0) {
            perror("write");
            exit(1);
        }
        b += r;
        n -= (size_t)r;
    }
}

int main(void) {
    size_t len = 16u * 1024u * 1024u;
    char buf[65536];
    memset(buf, 1, sizeof(buf));
    int fd = open("12-fnocache-oldway.data", O_CREAT | O_TRUNC | O_RDWR, 0600);
    for (size_t off = 0; off < len; off += sizeof(buf)) {
        xwrite(fd, buf, sizeof(buf));
    }
    lseek(fd, 0, SEEK_SET);
    size_t got = 0;
    for (;;) {
        ssize_t r = read(fd, buf, sizeof(buf));
        if (r <= 0) {
            break;
        }
        got += (size_t)r;
    }
    printf("old default cached read bytes=%zu\n", got);
    return 0;
}
C

cat > "$work/12-fnocache-newway.c" <<'C'
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void xwrite(int fd, const void *p, size_t n) {
    const char *b = p;
    while (n) {
        ssize_t r = write(fd, b, n);
        if (r <= 0) {
            perror("write");
            exit(1);
        }
        b += r;
        n -= (size_t)r;
    }
}

int main(void) {
    size_t len = 16u * 1024u * 1024u;
    char buf[65536];
    memset(buf, 2, sizeof(buf));
    int fd = open("12-fnocache-newway.data", O_CREAT | O_TRUNC | O_RDWR, 0600);
    for (size_t off = 0; off < len; off += sizeof(buf)) {
        xwrite(fd, buf, sizeof(buf));
    }
    lseek(fd, 0, SEEK_SET);
    errno = 0;
#ifdef F_NOCACHE
    int fr = fcntl(fd, F_NOCACHE, 1);
#else
    int fr = -1;
#endif
    int err = errno;
    size_t got = 0;
    for (;;) {
        ssize_t r = read(fd, buf, sizeof(buf));
        if (r <= 0) {
            break;
        }
        got += (size_t)r;
    }
    printf("new F_NOCACHE result=%d errno=%s read_bytes=%zu\n", fr, (err ? strerror(err) : "none"), got);
    return 0;
}
C
run_c 12-fnocache-oldway
run_c 12-fnocache-newway

printf '\nTIP 13: F_RDADVISE kernel readahead hint vs blind sequential read\n'
cat > "$work/13-rdadvice-oldway.c" <<'C'
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void xwrite(int fd, const void *p, size_t n) {
    const char *b = p;
    while (n) {
        ssize_t r = write(fd, b, n);
        if (r <= 0) {
            perror("write");
            exit(1);
        }
        b += r;
        n -= (size_t)r;
    }
}

int main(void) {
    size_t len = 16u * 1024u * 1024u;
    char buf[65536];
    memset(buf, 3, sizeof(buf));
    int fd = open("13-rdadvice-oldway.data", O_CREAT | O_TRUNC | O_RDWR, 0600);
    for (size_t off = 0; off < len; off += sizeof(buf)) {
        xwrite(fd, buf, sizeof(buf));
    }
    lseek(fd, 0, SEEK_SET);
    size_t got = 0;
    while (read(fd, buf, sizeof(buf)) > 0) {
        got += sizeof(buf);
    }
    printf("old blind sequential read approx_bytes=%zu\n", got);
    return 0;
}
C

cat > "$work/13-rdadvice-newway.c" <<'C'
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void xwrite(int fd, const void *p, size_t n) {
    const char *b = p;
    while (n) {
        ssize_t r = write(fd, b, n);
        if (r <= 0) {
            perror("write");
            exit(1);
        }
        b += r;
        n -= (size_t)r;
    }
}

int main(void) {
    size_t len = 16u * 1024u * 1024u;
    char buf[65536];
    memset(buf, 4, sizeof(buf));
    int fd = open("13-rdadvice-newway.data", O_CREAT | O_TRUNC | O_RDWR, 0600);
    for (size_t off = 0; off < len; off += sizeof(buf)) {
        xwrite(fd, buf, sizeof(buf));
    }
    lseek(fd, 0, SEEK_SET);
    errno = 0;
#ifdef F_RDADVISE
    struct radvisory ra;
    ra.ra_offset = 0;
    ra.ra_count = (int)len;
    int rr = fcntl(fd, F_RDADVISE, &ra);
#else
    int rr = -1;
#endif
    int err = errno;
    size_t got = 0;
    while (read(fd, buf, sizeof(buf)) > 0) {
        got += sizeof(buf);
    }
    printf("new F_RDADVISE result=%d errno=%s approx_bytes=%zu\n", rr, (err ? strerror(err) : "none"), got);
    return 0;
}
C
run_c 13-rdadvice-oldway
run_c 13-rdadvice-newway

printf '\nTIP 14: MADV_FREE recyclable pages vs explicit memset cleanup\n'
cat > "$work/14-madv-free-oldway.c" <<'C'
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

int main(void) {
    size_t len = 64u * 1024u * 1024u;
    char *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    for (size_t i = 0; i < len; i += 4096) {
        p[i] = 1;
    }
    memset(p, 0, len);
    printf("old memset cleanup bytes=%zu first=%d\n", len, p[0]);
    return 0;
}
C

cat > "$work/14-madv-free-newway.c" <<'C'
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

int main(void) {
    size_t len = 64u * 1024u * 1024u;
    char *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    for (size_t i = 0; i < len; i += 4096) {
        p[i] = 1;
    }
    errno = 0;
    int r = madvise(p, len, MADV_FREE);
    int err = errno;
    p[0] = 2;
    printf("new MADV_FREE result=%d errno=%s bytes=%zu first=%d\n", r, (err ? strerror(err) : "none"), len, p[0]);
    return 0;
}
C
run_c 14-madv-free-oldway
run_c 14-madv-free-newway

printf '\nTIP 15: Mach vm_allocate and superpage probe vs plain mmap\n'
cat > "$work/15-mach-vm-oldway.c" <<'C'
#include <stdio.h>
#include <sys/mman.h>

int main(void) {
    size_t len = 2u * 1024u * 1024u;
    char *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    for (size_t i = 0; i < len; i += 4096) {
        p[i] = 1;
    }
    printf("old mmap anonymous bytes=%zu addr=%p\n", len, p);
    return 0;
}
C

cat > "$work/15-mach-vm-newway.c" <<'C'
#include <mach/mach.h>
#include <stdio.h>

int main(void) {
    vm_size_t len = 2u * 1024u * 1024u;
    vm_address_t addr = 0;
#ifdef VM_FLAGS_SUPERPAGE_SIZE_2MB
    int flags = VM_FLAGS_ANYWHERE | VM_FLAGS_SUPERPAGE_SIZE_2MB;
#else
    int flags = VM_FLAGS_ANYWHERE;
#endif
    kern_return_t kr = vm_allocate(mach_task_self(), &addr, len, flags);
    if (kr == KERN_SUCCESS) {
        volatile char *p = (volatile char *)addr;
        for (vm_size_t i = 0; i < len; i += 4096) {
            p[i] = 1;
        }
        vm_deallocate(mach_task_self(), addr, len);
    }
    printf("new vm_allocate flags=0x%x result=%s addr=0x%llx bytes=%llu\n", flags, mach_error_string(kr), (unsigned long long)addr, (unsigned long long)len);
    return 0;
}
C
run_c 15-mach-vm-oldway
run_c 15-mach-vm-newway

printf '\nTIP 16: SO_NOSIGPIPE per-socket policy vs global SIGPIPE ignore\n'
cat > "$work/16-nosigpipe-oldway.c" <<'C'
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int main(void) {
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv)) {
        perror("socketpair");
        return 1;
    }
    close(sv[1]);
    signal(SIGPIPE, SIG_IGN);
    errno = 0;
    ssize_t r = write(sv[0], "x", 1);
    printf("old global SIGPIPE ignore write_result=%zd errno=%s\n", r, strerror(errno));
    return 0;
}
C

cat > "$work/16-nosigpipe-newway.c" <<'C'
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int main(void) {
#ifndef SO_NOSIGPIPE
    printf("SO_NOSIGPIPE is not exposed by headers\n");
    return 0;
#else
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv)) {
        perror("socketpair");
        return 1;
    }
    int one = 1;
    errno = 0;
    int sr = setsockopt(sv[0], SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    int seterr = errno;
    close(sv[1]);
    if (sr) {
        printf("SO_NOSIGPIPE setsockopt failed errno=%s\n", (seterr ? strerror(seterr) : "none"));
        return 0;
    }
    errno = 0;
    ssize_t r = write(sv[0], "x", 1);
    int writeerr = errno;
    printf("new SO_NOSIGPIPE setsockopt=%d set_errno=%s write_result=%zd write_errno=%s\n", sr, (seterr ? strerror(seterr) : "none"), r, (writeerr ? strerror(writeerr) : "none"));
    return 0;
#endif
}
C
run_c 16-nosigpipe-oldway
run_c 16-nosigpipe-newway

printf '\nTIP 17: libproc pid information vs shelling out to ps\n'
cat > "$work/17-libproc-oldway.c" <<'C'
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

int main(void) {
    char cmd[128];
    snprintf(cmd, sizeof(cmd), "ps -p %ld -o comm=", (long)getpid());
    FILE *f = popen(cmd, "r");
    if (!f) {
        perror("popen");
        return 1;
    }
    char line[256] = "";
    fgets(line, sizeof(line), f);
    int status = pclose(f);
    printf("old ps subprocess status=%d comm=%s", status, line);
    return 0;
}
C

cat > "$work/17-libproc-newway.c" <<'C'
#include <errno.h>
#include <libproc.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(void) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    errno = 0;
    int n = proc_pidpath(getpid(), path, sizeof(path));
    if (n <= 0) {
        printf("proc_pidpath failed errno=%s\n", strerror(errno));
        return 0;
    }
    printf("new proc_pidpath bytes=%d path=%s\n", n, path);
    return 0;
}
C
run_c 17-libproc-oldway
run_c 17-libproc-newway

printf '\nTIP 18: arc4random_buf kernel-seeded randomness vs opening /dev/urandom\n'
cat > "$work/18-random-oldway.c" <<'C'
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(void) {
    size_t len = 1u * 1024u * 1024u;
    unsigned char *p = malloc(len);
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0) {
        perror("open urandom");
        return 1;
    }
    size_t got = 0;
    while (got < len) {
        ssize_t r = read(fd, p + got, len - got);
        if (r <= 0) {
            perror("read urandom");
            return 1;
        }
        got += (size_t)r;
    }
    unsigned long long sum = 0;
    for (size_t i = 0; i < len; i++) {
        sum += p[i];
    }
    printf("old /dev/urandom bytes=%zu checksum=%llu\n", got, sum);
    return 0;
}
C

cat > "$work/18-random-newway.c" <<'C'
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    size_t len = 1u * 1024u * 1024u;
    unsigned char *p = malloc(len);
    arc4random_buf(p, len);
    unsigned long long sum = 0;
    for (size_t i = 0; i < len; i++) {
        sum += p[i];
    }
    printf("new arc4random_buf bytes=%zu checksum=%llu\n", len, sum);
    return 0;
}
C
run_c 18-random-oldway
run_c 18-random-newway

printf '\nTIP 19: malloc_good_size allocator-aware buffers vs arbitrary sizes\n'
cat > "$work/19-malloc-size-oldway.c" <<'C'
#include <malloc/malloc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    size_t want = 1000003;
    void *p = malloc(want);
    if (!p) {
        perror("malloc");
        return 1;
    }
    memset(p, 1, want);
    printf("old malloc requested=%zu usable=%zu\n", want, malloc_size(p));
    free(p);
    return 0;
}
C

cat > "$work/19-malloc-size-newway.c" <<'C'
#include <malloc/malloc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    size_t want = 1000003;
    size_t good = malloc_good_size(want);
    void *p = malloc(good);
    if (!p) {
        perror("malloc");
        return 1;
    }
    memset(p, 2, want);
    printf("new malloc_good_size requested=%zu good=%zu usable=%zu\n", want, good, malloc_size(p));
    free(p);
    return 0;
}
C
run_c 19-malloc-size-oldway
run_c 19-malloc-size-newway

printf '\nTIP 20: dispatch_apply over M4 Pro cores vs serial chunk loop\n'
cat > "$work/20-dispatch-apply-oldway.c" <<'C'
#include <stdio.h>
#include <sys/sysctl.h>

static unsigned long long burn(size_t seed) {
    unsigned long long x = seed + 1;
    for (int i = 0; i < 800000; i++) {
        x = x * 2862933555777941757ULL + 3037000493ULL;
    }
    return x;
}

static int ncpu(void) {
    int value = 4;
    size_t len = sizeof(value);
    sysctlbyname("hw.ncpu", &value, &len, NULL, 0);
    return value < 1 ? 1 : value;
}

int main(void) {
    int chunks = ncpu() * 4;
    if (chunks > 64) {
        chunks = 64;
    }
    unsigned long long checksum = 0;
    for (int i = 0; i < chunks; i++) {
        checksum ^= burn((size_t)i);
    }
    printf("old serial chunks=%d checksum=%llu\n", chunks, checksum);
    return 0;
}
C

cat > "$work/20-dispatch-apply-newway.c" <<'C'
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <sys/sysctl.h>

static unsigned long long slots[128];

static unsigned long long burn(size_t seed) {
    unsigned long long x = seed + 1;
    for (int i = 0; i < 800000; i++) {
        x = x * 2862933555777941757ULL + 3037000493ULL;
    }
    return x;
}

static int ncpu(void) {
    int value = 4;
    size_t len = sizeof(value);
    sysctlbyname("hw.ncpu", &value, &len, NULL, 0);
    return value < 1 ? 1 : value;
}

int main(void) {
    int chunks = ncpu() * 4;
    if (chunks > 64) {
        chunks = 64;
    }
    dispatch_apply((size_t)chunks, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
        slots[i] = burn(i);
    });
    unsigned long long checksum = 0;
    for (int i = 0; i < chunks; i++) {
        checksum ^= slots[i];
    }
    printf("new dispatch_apply chunks=%d checksum=%llu ncpu=%d\n", chunks, checksum, ncpu());
    return 0;
}
C
run_c 20-dispatch-apply-oldway
run_c 20-dispatch-apply-newway

printf '\nDone. The generated C sources/binaries were cat-built-run inside %s and will be trashed by the EXIT trap.\n' "$work"
