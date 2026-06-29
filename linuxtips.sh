#!/usr/bin/env bash
set -euxo pipefail

work="linuxtips-work-$$"
mkdir "$work"

cleanup() {
    set +e
    if [ ! -d "$work" ]; then
        return
    fi
    if command -v trash >/dev/null 2>&1 && trash "$work"; then
        return
    fi
    grave=".linuxtips-trash-$$"
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
    "${CC:-cc}" -O2 -std=gnu11 -Wall -Wextra -pthread "$src" -o "$exe" -ldl
    printf -- '----- bench/profile: %s -----\n' "$tag"
    if [ -x /usr/bin/time ]; then
        (cd "$work" && /usr/bin/time -f 'PROFILE wall=%e user=%U sys=%S maxrss_kb=%M majflt=%F minflt=%R nvcsw=%w nivcsw=%c' "./$tag")
    else
        (cd "$work" && "./$tag")
    fi
}

trap cleanup EXIT

printf 'Linux tips executable cookbook\n'
printf 'kernel: '
uname -a
printf 'compiler: '
"${CC:-cc}" --version | head -n 1

printf '\nTIP 01: Device Memory TCP vs ordinary host-RAM socket copy\n'
printf 'oldway copies network payloads into ordinary host memory.\n'
cat > "$work/01-devmem-tcp-oldway.c" <<'C'
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

static void xwrite(int fd, const char *p, size_t n) {
    while (n) {
        ssize_t r = write(fd, p, n);
        if (r < 0) {
            perror("write");
            exit(1);
        }
        p += r;
        n -= (size_t)r;
    }
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    int sv[2];
    size_t total = 16u * 1024u * 1024u;
    size_t chunk = 65536;
    char *buf = malloc(chunk);
    if (!buf) {
        perror("malloc");
        return 1;
    }
    memset(buf, 7, chunk);
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv)) {
        perror("socketpair");
        return 1;
    }
    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        return 1;
    }
    if (!pid) {
        close(sv[1]);
        size_t got = 0;
        while (got < total) {
            ssize_t r = read(sv[0], buf, chunk);
            if (r < 0) {
                perror("read");
                return 1;
            }
            if (!r) {
                break;
            }
            got += (size_t)r;
        }
        printf("old host-RAM socket copy received=%zu bytes\n", got);
        return 0;
    }
    close(sv[0]);
    for (size_t sent = 0; sent < total; sent += chunk) {
        xwrite(sv[1], buf, chunk);
    }
    close(sv[1]);
    int status = 0;
    waitpid(pid, &status, 0);
    printf("old host-RAM socket copy sent=%zu child_status=%d\n", total, status);
    return 0;
}
C

printf 'newway probes the devmem TCP/dma-buf surface; real speed needs new kernel, right NIC, and device memory.\n'
cat > "$work/01-devmem-tcp-newway.c" <<'C'
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/utsname.h>
#include <unistd.h>

int main(void) {
    struct utsname u;
    if (!uname(&u)) {
        printf("kernel=%s %s\n", u.sysname, u.release);
    }
#ifdef MSG_SOCK_DEVMEM
    printf("headers expose MSG_SOCK_DEVMEM=%ld\n", (long)MSG_SOCK_DEVMEM);
#else
    printf("headers do not expose MSG_SOCK_DEVMEM; this host cannot compile the real recvmsg flag path\n");
#endif
#ifdef SO_DEVMEM_DONTNEED
    printf("headers expose SO_DEVMEM_DONTNEED=%d\n", SO_DEVMEM_DONTNEED);
#else
    printf("headers do not expose SO_DEVMEM_DONTNEED\n");
#endif
#ifdef SCM_DEVMEM_DMABUF
    printf("headers expose SCM_DEVMEM_DMABUF=%d\n", SCM_DEVMEM_DMABUF);
#else
    printf("headers do not expose SCM_DEVMEM_DMABUF\n");
#endif
    int heap = open("/dev/dma_heap/system", O_RDWR | O_CLOEXEC);
    if (heap < 0) {
        printf("open /dev/dma_heap/system failed: %s\n", strerror(errno));
    } else {
        printf("dma_heap system heap is present as fd=%d\n", heap);
        close(heap);
    }
    DIR *d = opendir("/sys/class/net");
    if (!d) {
        printf("opendir /sys/class/net failed: %s\n", strerror(errno));
    } else {
        struct dirent *e;
        printf("net devices:");
        while ((e = readdir(d))) {
            if (e->d_name[0] != '.') {
                printf(" %s", e->d_name);
            }
        }
        printf("\n");
        closedir(d);
    }
    int s = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (s < 0) {
        printf("tcp socket probe failed: %s\n", strerror(errno));
    } else {
        printf("tcp socket exists; devmem TCP still needs netlink binding and capable NIC queues\n");
        close(s);
    }
    return 0;
}
C
run_c 01-devmem-tcp-oldway
run_c 01-devmem-tcp-newway

printf '\nTIP 02: io_uring ring submission vs one syscall per operation\n'
printf 'oldway pays syscall overhead directly in a tight getpid loop.\n'
cat > "$work/02-io-uring-oldway.c" <<'C'
#define _GNU_SOURCE
#include <stdio.h>
#include <sys/syscall.h>
#include <unistd.h>

int main(void) {
    long sum = 0;
    int n = 200000;
    for (int i = 0; i < n; i++) {
        sum += syscall(SYS_getpid);
    }
    printf("old one-syscall-per-op calls=%d checksum=%ld\n", n, sum);
    return 0;
}
C

printf 'newway builds the mmaped io_uring SQ/CQ rings and submits NOPs in batches.\n'
cat > "$work/02-io-uring-newway.c" <<'C'
#define _GNU_SOURCE
#include <errno.h>
#include <linux/io_uring.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

static unsigned min_u(unsigned a, unsigned b) {
    return a < b ? a : b;
}

int main(void) {
    struct io_uring_params p;
    memset(&p, 0, sizeof(p));
    int fd = (int)syscall(SYS_io_uring_setup, 128, &p);
    if (fd < 0) {
        printf("io_uring_setup failed: %s\n", strerror(errno));
        return 0;
    }
    size_t sqsz = p.sq_off.array + p.sq_entries * sizeof(unsigned);
    size_t cqsz = p.cq_off.cqes + p.cq_entries * sizeof(struct io_uring_cqe);
    char *sq = mmap(NULL, sqsz, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_SQ_RING);
    char *cq = mmap(NULL, cqsz, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_CQ_RING);
    struct io_uring_sqe *sqes = mmap(NULL, p.sq_entries * sizeof(*sqes), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_SQES);
    if (sq == MAP_FAILED || cq == MAP_FAILED || sqes == MAP_FAILED) {
        printf("io_uring mmap failed: %s\n", strerror(errno));
        close(fd);
        return 0;
    }
    unsigned *sq_head = (unsigned *)(sq + p.sq_off.head);
    unsigned *sq_tail = (unsigned *)(sq + p.sq_off.tail);
    unsigned *sq_mask = (unsigned *)(sq + p.sq_off.ring_mask);
    unsigned *sq_array = (unsigned *)(sq + p.sq_off.array);
    unsigned *cq_head = (unsigned *)(cq + p.cq_off.head);
    unsigned *cq_tail = (unsigned *)(cq + p.cq_off.tail);
    unsigned *cq_mask = (unsigned *)(cq + p.cq_off.ring_mask);
    struct io_uring_cqe *cqes = (struct io_uring_cqe *)(cq + p.cq_off.cqes);
    unsigned n = 4096;
    unsigned submitted = 0;
    unsigned completed = 0;
    while (submitted < n) {
        unsigned batch = min_u(64, n - submitted);
        unsigned tail = *sq_tail;
        for (unsigned i = 0; i < batch; i++) {
            unsigned idx = tail & *sq_mask;
            memset(&sqes[idx], 0, sizeof(sqes[idx]));
            sqes[idx].opcode = IORING_OP_NOP;
            sqes[idx].user_data = submitted + i;
            sq_array[idx] = idx;
            tail++;
        }
        *sq_tail = tail;
        long r = syscall(SYS_io_uring_enter, fd, batch, batch, IORING_ENTER_GETEVENTS, NULL, 0);
        if (r < 0) {
            printf("io_uring_enter failed: %s\n", strerror(errno));
            break;
        }
        submitted += batch;
        while (*cq_head != *cq_tail) {
            unsigned idx = *cq_head & *cq_mask;
            if (cqes[idx].res < 0) {
                printf("cqe res=%d\n", cqes[idx].res);
            }
            *cq_head = *cq_head + 1;
            completed++;
        }
    }
    printf("new io_uring batched NOP submitted=%u completed=%u sq_head=%u\n", submitted, completed, *sq_head);
    close(fd);
    return 0;
}
C
run_c 02-io-uring-oldway
run_c 02-io-uring-newway

printf '\nTIP 03: AF_XDP mmap rings vs normal UDP socket path\n'
cat > "$work/03-af-xdp-oldway.c" <<'C'
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int main(void) {
    int rx = socket(AF_INET, SOCK_DGRAM, 0);
    int tx = socket(AF_INET, SOCK_DGRAM, 0);
    if (rx < 0 || tx < 0) {
        perror("socket");
        return 1;
    }
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(rx, (struct sockaddr *)&a, sizeof(a))) {
        perror("bind");
        return 1;
    }
    socklen_t alen = sizeof(a);
    getsockname(rx, (struct sockaddr *)&a, &alen);
    char b[32] = "packet";
    for (int i = 0; i < 5000; i++) {
        sendto(tx, b, sizeof(b), 0, (struct sockaddr *)&a, sizeof(a));
        recv(rx, b, sizeof(b), 0);
    }
    printf("old UDP loopback sendto+recv packets=%d\n", 5000);
    return 0;
}
C

cat > "$work/03-af-xdp-newway.c" <<'C'
#define _GNU_SOURCE
#include <errno.h>
#include <linux/if_xdp.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int main(void) {
#ifndef AF_XDP
    printf("headers do not expose AF_XDP\n");
    return 0;
#else
    int fd = socket(AF_XDP, SOCK_RAW | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        printf("socket(AF_XDP) failed: %s\n", strerror(errno));
        return 0;
    }
    struct xdp_mmap_offsets off;
    socklen_t len = sizeof(off);
    if (getsockopt(fd, SOL_XDP, XDP_MMAP_OFFSETS, &off, &len)) {
        printf("XDP_MMAP_OFFSETS failed: %s\n", strerror(errno));
    } else {
        printf("new AF_XDP socket fd=%d rx.desc=%llu tx.desc=%llu fr.desc=%llu cr.desc=%llu\n", fd, (unsigned long long)off.rx.desc, (unsigned long long)off.tx.desc, (unsigned long long)off.fr.desc, (unsigned long long)off.cr.desc);
    }
    printf("real AF_XDP benchmark needs UMEM, bind to ifindex/queue, and usually an XDP program\n");
    close(fd);
    return 0;
#endif
}
C
run_c 03-af-xdp-oldway
run_c 03-af-xdp-newway

printf '\nTIP 04: dma-buf heap fd buffers vs private anonymous memory\n'
cat > "$work/04-dmabuf-oldway.c" <<'C'
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

int main(void) {
    size_t len = 16u * 1024u * 1024u;
    char *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    for (size_t i = 0; i < len; i += 4096) {
        p[i] = (char)i;
    }
    printf("old anonymous memory touched=%zu bytes; only this process owns the pointer\n", len);
    return 0;
}
C

cat > "$work/04-dmabuf-newway.c" <<'C'
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/dma-heap.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

int main(void) {
    size_t len = 16u * 1024u * 1024u;
    int heap = open("/dev/dma_heap/system", O_RDWR | O_CLOEXEC);
    if (heap < 0) {
        printf("open /dev/dma_heap/system failed: %s\n", strerror(errno));
        return 0;
    }
    struct dma_heap_allocation_data a;
    memset(&a, 0, sizeof(a));
    a.len = len;
    a.fd_flags = O_RDWR | O_CLOEXEC;
    if (ioctl(heap, DMA_HEAP_IOCTL_ALLOC, &a)) {
        printf("DMA_HEAP_IOCTL_ALLOC failed: %s\n", strerror(errno));
        close(heap);
        return 0;
    }
    char *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, a.fd, 0);
    if (p == MAP_FAILED) {
        printf("mmap dma-buf fd failed: %s\n", strerror(errno));
        close((int)a.fd);
        close(heap);
        return 0;
    }
    for (size_t i = 0; i < len; i += 4096) {
        p[i] = (char)i;
    }
    printf("new dma-buf heap allocation fd=%d touched=%zu bytes; fd can be imported by capable devices\n", (int)a.fd, len);
    close((int)a.fd);
    close(heap);
    return 0;
}
C
run_c 04-dmabuf-oldway
run_c 04-dmabuf-newway

printf '\nTIP 05: rseq/per-cpu data shape vs contended atomic counter\n'
cat > "$work/05-rseq-oldway.c" <<'C'
#define _GNU_SOURCE
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>

enum { THREADS = 4, N = 1000000 };
static atomic_long counter;

static void *worker(void *arg) {
    (void)arg;
    for (int i = 0; i < N; i++) {
        atomic_fetch_add_explicit(&counter, 1, memory_order_relaxed);
    }
    return NULL;
}

int main(void) {
    pthread_t t[THREADS];
    for (int i = 0; i < THREADS; i++) {
        pthread_create(&t[i], NULL, worker, NULL);
    }
    for (int i = 0; i < THREADS; i++) {
        pthread_join(t[i], NULL);
    }
    printf("old contended atomic counter=%ld expected=%d\n", atomic_load(&counter), THREADS * N);
    return 0;
}
C

cat > "$work/05-rseq-newway.c" <<'C'
#define _GNU_SOURCE
#include <pthread.h>
#include <stdio.h>
#include <sys/auxv.h>
#include <unistd.h>

enum { THREADS = 4, N = 1000000 };
struct Slot {
    long value;
    char pad[64 - sizeof(long)];
};
static struct Slot slots[THREADS];

static void *worker(void *arg) {
    long id = (long)arg;
    for (int i = 0; i < N; i++) {
        slots[id].value++;
    }
    return NULL;
}

int main(void) {
#ifdef AT_RSEQ_FEATURE_SIZE
    printf("AT_RSEQ_FEATURE_SIZE=%lu\n", getauxval(AT_RSEQ_FEATURE_SIZE));
#else
    printf("headers do not expose AT_RSEQ_FEATURE_SIZE; libc may still register rseq internally\n");
#endif
#ifdef AT_RSEQ_ALIGN
    printf("AT_RSEQ_ALIGN=%lu\n", getauxval(AT_RSEQ_ALIGN));
#endif
    pthread_t t[THREADS];
    for (long i = 0; i < THREADS; i++) {
        pthread_create(&t[i], NULL, worker, (void *)i);
    }
    long sum = 0;
    for (int i = 0; i < THREADS; i++) {
        pthread_join(t[i], NULL);
        sum += slots[i].value;
    }
    printf("new sharded cacheline-local counters=%ld expected=%d current_cpu=%d\n", sum, THREADS * N, sched_getcpu());
    printf("real rseq removes even more hot-path bookkeeping by making current-cpu critical sections restartable\n");
    return 0;
}
C
run_c 05-rseq-oldway
run_c 05-rseq-newway

printf '\nTIP 06: futex parking lot vs spin waiting\n'
cat > "$work/06-futex-oldway.c" <<'C'
#define _GNU_SOURCE
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <unistd.h>

static atomic_int flag;

static void *worker(void *arg) {
    (void)arg;
    usleep(200000);
    atomic_store_explicit(&flag, 1, memory_order_release);
    return NULL;
}

int main(void) {
    pthread_t t;
    pthread_create(&t, NULL, worker, NULL);
    unsigned long spins = 0;
    while (!atomic_load_explicit(&flag, memory_order_acquire)) {
        spins++;
    }
    pthread_join(t, NULL);
    printf("old spin wait observed flag after spins=%lu\n", spins);
    return 0;
}
C

cat > "$work/06-futex-newway.c" <<'C'
#define _GNU_SOURCE
#include <errno.h>
#include <linux/futex.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

static atomic_int flag;

static int futex_wait(atomic_int *p, int expected) {
    return (int)syscall(SYS_futex, (int *)p, FUTEX_WAIT, expected, NULL, NULL, 0);
}

static int futex_wake(atomic_int *p) {
    return (int)syscall(SYS_futex, (int *)p, FUTEX_WAKE, 1, NULL, NULL, 0);
}

static void *worker(void *arg) {
    (void)arg;
    usleep(200000);
    atomic_store_explicit(&flag, 1, memory_order_release);
    futex_wake(&flag);
    return NULL;
}

int main(void) {
    pthread_t t;
    pthread_create(&t, NULL, worker, NULL);
    int waits = 0;
    while (!atomic_load_explicit(&flag, memory_order_acquire)) {
        waits++;
        if (futex_wait(&flag, 0) && errno != EAGAIN && errno != EINTR) {
            printf("futex_wait failed: %s\n", strerror(errno));
            break;
        }
    }
    pthread_join(t, NULL);
    printf("new atomic fast path plus futex sleep waits=%d\n", waits);
    return 0;
}
C
run_c 06-futex-oldway
run_c 06-futex-newway

printf '\nTIP 07: userfaultfd page-fault protocol vs blind prefaulting\n'
cat > "$work/07-userfaultfd-oldway.c" <<'C'
#define _GNU_SOURCE
#include <stdio.h>
#include <sys/mman.h>

int main(void) {
    size_t len = 16u * 1024u * 1024u;
    char *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    for (size_t i = 0; i < len; i += 4096) {
        p[i] = 1;
    }
    printf("old prefaulted every page manually bytes=%zu\n", len);
    return 0;
}
C

cat > "$work/07-userfaultfd-newway.c" <<'C'
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/userfaultfd.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

int main(void) {
    int fd = (int)syscall(SYS_userfaultfd, O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) {
        printf("userfaultfd syscall failed: %s\n", strerror(errno));
        return 0;
    }
    struct uffdio_api api;
    memset(&api, 0, sizeof(api));
    api.api = UFFD_API;
    if (ioctl(fd, UFFDIO_API, &api)) {
        printf("UFFDIO_API failed: %s\n", strerror(errno));
        close(fd);
        return 0;
    }
    size_t len = 4u * 4096u;
    void *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) {
        printf("mmap failed: %s\n", strerror(errno));
        close(fd);
        return 0;
    }
    struct uffdio_register r;
    memset(&r, 0, sizeof(r));
    r.range.start = (unsigned long)p;
    r.range.len = len;
    r.mode = UFFDIO_REGISTER_MODE_MISSING;
    if (ioctl(fd, UFFDIO_REGISTER, &r)) {
        printf("UFFDIO_REGISTER missing-page mode failed: %s\n", strerror(errno));
    } else {
        printf("new userfaultfd registered range=%p len=%zu ioctls=0x%llx\n", p, len, (unsigned long long)r.ioctls);
    }
    close(fd);
    return 0;
}
C
run_c 07-userfaultfd-oldway
run_c 07-userfaultfd-newway

printf '\nTIP 08: MAP_FIXED_NOREPLACE and seals vs clobbering VMAs\n'
cat > "$work/08-vma-oldway.c" <<'C'
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

int main(void) {
    char *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    strcpy(p, "alive");
    void *q = mmap(p, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    if (q == MAP_FAILED) {
        perror("MAP_FIXED");
        return 1;
    }
    printf("old MAP_FIXED replaced the existing mapping at %p first_byte_after=%d\n", p, (int)p[0]);
    return 0;
}
C

cat > "$work/08-vma-newway.c" <<'C'
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/memfd.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef MAP_FIXED_NOREPLACE
#define MAP_FIXED_NOREPLACE 0x100000
#endif

int main(void) {
    char *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    strcpy(p, "still-here");
    void *q = mmap(p, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
    if (q == MAP_FAILED) {
        printf("new MAP_FIXED_NOREPLACE refused clobber errno=%s data=%s\n", strerror(errno), p);
    } else {
        printf("unexpected replacement result=%p data=%s\n", q, p);
    }
    int fd = (int)syscall(SYS_memfd_create, "sealed", MFD_CLOEXEC | MFD_ALLOW_SEALING);
    if (fd < 0) {
        printf("memfd_create failed: %s\n", strerror(errno));
    } else {
        if (ftruncate(fd, 4096)) {
            printf("ftruncate sealed memfd setup failed: %s\n", strerror(errno));
            close(fd);
            return 0;
        }
        int seals = F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_WRITE | F_SEAL_SEAL;
        if (fcntl(fd, F_ADD_SEALS, seals)) {
            printf("F_ADD_SEALS failed: %s\n", strerror(errno));
        } else {
            errno = 0;
            int r = ftruncate(fd, 8192);
            printf("sealed memfd grow result=%d errno=%s\n", r, strerror(errno));
        }
        close(fd);
    }
#ifdef SYS_mseal
    long mr = syscall(SYS_mseal, p, 4096, 0);
    printf("mseal result=%ld errno=%s\n", mr, strerror(errno));
#else
    printf("headers/libc do not expose SYS_mseal on this system\n");
#endif
    return 0;
}
C
run_c 08-vma-oldway
run_c 08-vma-newway

printf '\nTIP 09: pidfd/process_madvise/cachestat-aware supervision vs plain pid wait\n'
cat > "$work/09-supervisor-oldway.c" <<'C'
#define _GNU_SOURCE
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

int main(void) {
    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        return 1;
    }
    if (!pid) {
        usleep(100000);
        return 0;
    }
    int status = 0;
    waitpid(pid, &status, 0);
    printf("old supervisor waited on numeric pid=%ld status=%d\n", (long)pid, status);
    return 0;
}
C

cat > "$work/09-supervisor-newway.c" <<'C'
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef MADV_COLD
#define MADV_COLD 20
#endif
#ifndef MADV_COLLAPSE
#define MADV_COLLAPSE 25
#endif

struct local_cachestat_range {
    unsigned long long off;
    unsigned long long len;
};

struct local_cachestat {
    unsigned long long nr_cache;
    unsigned long long nr_dirty;
    unsigned long long nr_writeback;
    unsigned long long nr_evicted;
    unsigned long long nr_recently_evicted;
};

int main(void) {
    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        return 1;
    }
    if (!pid) {
        usleep(100000);
        return 0;
    }
    int pfd = (int)syscall(SYS_pidfd_open, pid, 0);
    if (pfd < 0) {
        printf("pidfd_open child failed: %s\n", strerror(errno));
        waitpid(pid, NULL, 0);
    } else {
        struct pollfd p = { .fd = pfd, .events = POLLIN };
        poll(&p, 1, -1);
        waitpid(pid, NULL, 0);
        printf("new supervisor polled pidfd=%d revents=0x%x\n", pfd, p.revents);
        close(pfd);
    }
    char *mem = mmap(NULL, 2u * 1024u * 1024u, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mem != MAP_FAILED) {
        mem[0] = 1;
        int self = (int)syscall(SYS_pidfd_open, getpid(), 0);
        if (self >= 0) {
#ifdef SYS_process_madvise
            struct iovec iov = { .iov_base = mem, .iov_len = 2u * 1024u * 1024u };
            long r = syscall(SYS_process_madvise, self, &iov, 1, MADV_COLD, 0);
            printf("process_madvise self MADV_COLD result=%ld errno=%s\n", r, strerror(errno));
#else
            printf("SYS_process_madvise not exposed by headers\n");
#endif
            close(self);
        }
        errno = 0;
        int cr = madvise(mem, 2u * 1024u * 1024u, MADV_COLLAPSE);
        printf("madvise MADV_COLLAPSE result=%d errno=%s\n", cr, strerror(errno));
    }
#ifdef SYS_cachestat
    int fd = open("/etc/hosts", O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        struct local_cachestat_range range = { .off = 0, .len = 4096 };
        struct local_cachestat cs;
        memset(&cs, 0, sizeof(cs));
        long sr = syscall(SYS_cachestat, fd, &range, &cs, 0);
        printf("cachestat /etc/hosts result=%ld errno=%s nr_cache=%llu\n", sr, strerror(errno), cs.nr_cache);
        close(fd);
    }
#else
    printf("SYS_cachestat not exposed by headers\n");
#endif
    return 0;
}
C
run_c 09-supervisor-oldway
run_c 09-supervisor-newway

printf '\nTIP 10: sendmmsg batching vs one datagram syscall at a time\n'
cat > "$work/10-bulk-oldway.c" <<'C'
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

int main(void) {
    int sv[2];
    int n = 20000;
    char b[8] = "1234567";
    if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sv)) {
        perror("socketpair");
        return 1;
    }
    pid_t pid = fork();
    if (!pid) {
        close(sv[0]);
        for (int i = 0; i < n; i++) {
            recv(sv[1], b, sizeof(b), 0);
        }
        return 0;
    }
    close(sv[1]);
    for (int i = 0; i < n; i++) {
        send(sv[0], b, sizeof(b), 0);
    }
    waitpid(pid, NULL, 0);
    printf("old send loop datagrams=%d syscalls=%d\n", n, n);
    return 0;
}
C

cat > "$work/10-bulk-newway.c" <<'C'
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

static int min_i(int a, int b) {
    return a < b ? a : b;
}

int main(void) {
    int sv[2];
    int n = 20000;
    char b[32][8];
    if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sv)) {
        perror("socketpair");
        return 1;
    }
    memset(b, 'x', sizeof(b));
    pid_t pid = fork();
    if (!pid) {
        close(sv[0]);
        char r[8];
        for (int i = 0; i < n; i++) {
            recv(sv[1], r, sizeof(r), 0);
        }
        return 0;
    }
    close(sv[1]);
    int sent = 0;
    int calls = 0;
    while (sent < n) {
        int batch = min_i(32, n - sent);
        struct mmsghdr msg[32];
        struct iovec iov[32];
        memset(msg, 0, sizeof(msg));
        for (int i = 0; i < batch; i++) {
            iov[i].iov_base = b[i];
            iov[i].iov_len = sizeof(b[i]);
            msg[i].msg_hdr.msg_iov = &iov[i];
            msg[i].msg_hdr.msg_iovlen = 1;
        }
        int r = sendmmsg(sv[0], msg, (unsigned)batch, 0);
        if (r < 0) {
            perror("sendmmsg");
            return 1;
        }
        sent += r;
        calls++;
    }
    waitpid(pid, NULL, 0);
    printf("new sendmmsg datagrams=%d syscalls=%d batch=32\n", sent, calls);
    return 0;
}
C
run_c 10-bulk-oldway
run_c 10-bulk-newway

printf '\nTIP 11: AF_PACKET TPACKET_V3 mmap ring vs raw packet recvfrom\n'
cat > "$work/11-packet-oldway.c" <<'C'
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int main(void) {
    int fd = socket(AF_PACKET, SOCK_RAW | SOCK_CLOEXEC, htons(ETH_P_ALL));
    if (fd < 0) {
        printf("old AF_PACKET raw socket failed: %s\n", strerror(errno));
        return 0;
    }
    printf("old AF_PACKET raw socket fd=%d would use recvfrom per packet\n", fd);
    close(fd);
    return 0;
}
C

cat > "$work/11-packet-newway.c" <<'C'
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <unistd.h>

int main(void) {
    int fd = socket(AF_PACKET, SOCK_RAW | SOCK_CLOEXEC, htons(ETH_P_ALL));
    if (fd < 0) {
        printf("new AF_PACKET socket failed before ring setup: %s\n", strerror(errno));
        return 0;
    }
    int ver = TPACKET_V3;
    if (setsockopt(fd, SOL_PACKET, PACKET_VERSION, &ver, sizeof(ver))) {
        printf("PACKET_VERSION TPACKET_V3 failed: %s\n", strerror(errno));
        close(fd);
        return 0;
    }
    struct tpacket_req3 req;
    memset(&req, 0, sizeof(req));
    req.tp_block_size = 1u << 20;
    req.tp_block_nr = 1;
    req.tp_frame_size = 2048;
    req.tp_frame_nr = req.tp_block_size * req.tp_block_nr / req.tp_frame_size;
    req.tp_retire_blk_tov = 64;
    if (setsockopt(fd, SOL_PACKET, PACKET_RX_RING, &req, sizeof(req))) {
        printf("PACKET_RX_RING failed: %s\n", strerror(errno));
        close(fd);
        return 0;
    }
    void *ring = mmap(NULL, req.tp_block_size * req.tp_block_nr, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (ring == MAP_FAILED) {
        printf("mmap packet ring failed: %s\n", strerror(errno));
    } else {
        printf("new TPACKET_V3 mmap ring=%p block_size=%u frame_nr=%u\n", ring, req.tp_block_size, req.tp_frame_nr);
    }
    close(fd);
    return 0;
}
C
run_c 11-packet-oldway
run_c 11-packet-newway

printf '\nTIP 12: CPU/NAPI/socket affinity vs wandering worker threads\n'
cat > "$work/12-affinity-oldway.c" <<'C'
#define _GNU_SOURCE
#include <stdio.h>
#include <sched.h>

int main(void) {
    int last = sched_getcpu();
    int changes = 0;
    for (int i = 0; i < 1000000; i++) {
        int c = sched_getcpu();
        if (c != last) {
            changes++;
            last = c;
        }
    }
    printf("old unpinned loop final_cpu=%d observed_cpu_changes=%d\n", last, changes);
    return 0;
}
C

cat > "$work/12-affinity-newway.c" <<'C'
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <sched.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int main(void) {
    int cpu = sched_getcpu();
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    if (sched_setaffinity(0, sizeof(set), &set)) {
        printf("sched_setaffinity cpu=%d failed: %s\n", cpu, strerror(errno));
    }
    int last = sched_getcpu();
    int changes = 0;
    for (int i = 0; i < 1000000; i++) {
        int c = sched_getcpu();
        if (c != last) {
            changes++;
            last = c;
        }
    }
    int s = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (s >= 0) {
#ifdef SO_INCOMING_CPU
        int want = cpu;
        int r = setsockopt(s, SOL_SOCKET, SO_INCOMING_CPU, &want, sizeof(want));
        printf("SO_INCOMING_CPU set cpu=%d result=%d errno=%s\n", want, r, strerror(errno));
#endif
#ifdef SO_INCOMING_NAPI_ID
        int napi = -1;
        socklen_t len = sizeof(napi);
        int gr = getsockopt(s, SOL_SOCKET, SO_INCOMING_NAPI_ID, &napi, &len);
        printf("SO_INCOMING_NAPI_ID get result=%d errno=%s value=%d\n", gr, strerror(errno), napi);
#endif
        close(s);
    }
    printf("new pinned loop final_cpu=%d observed_cpu_changes=%d\n", last, changes);
    return 0;
}
C
run_c 12-affinity-oldway
run_c 12-affinity-newway

printf '\nTIP 13: BPF SOCKMAP probe vs user-space socket proxy copying\n'
cat > "$work/13-sockmap-oldway.c" <<'C'
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

int main(void) {
    int sv[2];
    char b[4096];
    memset(b, 3, sizeof(b));
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv)) {
        perror("socketpair");
        return 1;
    }
    pid_t pid = fork();
    if (!pid) {
        close(sv[0]);
        size_t got = 0;
        while (got < 8u * 1024u * 1024u) {
            ssize_t r = read(sv[1], b, sizeof(b));
            if (r <= 0) {
                break;
            }
            got += (size_t)r;
        }
        return 0;
    }
    close(sv[1]);
    for (size_t sent = 0; sent < 8u * 1024u * 1024u;) {
        ssize_t r = write(sv[0], b, sizeof(b));
        if (r <= 0) {
            perror("write");
            return 1;
        }
        sent += (size_t)r;
    }
    close(sv[0]);
    waitpid(pid, NULL, 0);
    printf("old proxy path copied bytes through user-space read/write loop\n");
    return 0;
}
C

cat > "$work/13-sockmap-newway.c" <<'C'
#define _GNU_SOURCE
#include <errno.h>
#include <linux/bpf.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

int main(void) {
    union bpf_attr a;
    memset(&a, 0, sizeof(a));
    a.map_type = BPF_MAP_TYPE_SOCKMAP;
    a.key_size = 4;
    a.value_size = 4;
    a.max_entries = 8;
    int fd = (int)syscall(SYS_bpf, BPF_MAP_CREATE, &a, sizeof(a));
    if (fd < 0) {
        printf("BPF_MAP_CREATE SOCKMAP failed: %s\n", strerror(errno));
        printf("real SOCKMAP also needs BPF programs and privileges/capabilities on many systems\n");
        return 0;
    }
    printf("new SOCKMAP fd=%d created; sockets can be inserted and BPF can redirect stream data\n", fd);
    close(fd);
    return 0;
}
C
run_c 13-sockmap-oldway
run_c 13-sockmap-newway

printf '\nTIP 14: reuseport BPF steering vs default reuseport hash\n'
cat > "$work/14-reuseport-oldway.c" <<'C'
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int receiver(int port) {
    int s = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons((unsigned short)port);
    if (bind(s, (struct sockaddr *)&a, sizeof(a))) {
        perror("bind");
        return -1;
    }
    fcntl(s, F_SETFL, fcntl(s, F_GETFL, 0) | O_NONBLOCK);
    return s;
}

static int count_recv(int s) {
    char b[16];
    int n = 0;
    while (recv(s, b, sizeof(b), 0) > 0) {
        n++;
    }
    return n;
}

int main(void) {
    int a = receiver(0);
    struct sockaddr_in sa;
    socklen_t sl = sizeof(sa);
    getsockname(a, (struct sockaddr *)&sa, &sl);
    int port = ntohs(sa.sin_port);
    int b = receiver(port);
    char x = 'x';
    for (int i = 0; i < 200; i++) {
        int tx = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
        sendto(tx, &x, 1, 0, (struct sockaddr *)&sa, sizeof(sa));
        close(tx);
    }
    usleep(50000);
    printf("old SO_REUSEPORT default hash counts socket0=%d socket1=%d\n", count_recv(a), count_recv(b));
    return 0;
}
C

cat > "$work/14-reuseport-newway.c" <<'C'
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/filter.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#ifndef SO_ATTACH_REUSEPORT_CBPF
#define SO_ATTACH_REUSEPORT_CBPF 51
#endif

static int receiver(int port) {
    int s = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons((unsigned short)port);
    if (bind(s, (struct sockaddr *)&a, sizeof(a))) {
        perror("bind");
        return -1;
    }
    fcntl(s, F_SETFL, fcntl(s, F_GETFL, 0) | O_NONBLOCK);
    return s;
}

static int count_recv(int s) {
    char b[16];
    int n = 0;
    while (recv(s, b, sizeof(b), 0) > 0) {
        n++;
    }
    return n;
}

int main(void) {
    int a = receiver(0);
    struct sockaddr_in sa;
    socklen_t sl = sizeof(sa);
    getsockname(a, (struct sockaddr *)&sa, &sl);
    int port = ntohs(sa.sin_port);
    int b = receiver(port);
    struct sock_filter code[] = {
        BPF_STMT(BPF_RET | BPF_K, 0),
    };
    struct sock_fprog prog = { .len = 1, .filter = code };
    int ar = setsockopt(a, SOL_SOCKET, SO_ATTACH_REUSEPORT_CBPF, &prog, sizeof(prog));
    printf("SO_ATTACH_REUSEPORT_CBPF force-index-0 result=%d errno=%s\n", ar, strerror(errno));
    char x = 'x';
    for (int i = 0; i < 200; i++) {
        int tx = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
        sendto(tx, &x, 1, 0, (struct sockaddr *)&sa, sizeof(sa));
        close(tx);
    }
    usleep(50000);
    printf("new reuseport BPF counts socket0=%d socket1=%d\n", count_recv(a), count_recv(b));
    return 0;
}
C
run_c 14-reuseport-oldway
run_c 14-reuseport-newway

printf '\nTIP 15: RDMA verbs capability probe vs kernel socket copy\n'
cat > "$work/15-rdma-oldway.c" <<'C'
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

int main(void) {
    int sv[2];
    char b[4096];
    memset(b, 4, sizeof(b));
    socketpair(AF_UNIX, SOCK_STREAM, 0, sv);
    pid_t pid = fork();
    if (!pid) {
        close(sv[0]);
        size_t got = 0;
        while (got < 8u * 1024u * 1024u) {
            ssize_t r = read(sv[1], b, sizeof(b));
            if (r <= 0) {
                break;
            }
            got += (size_t)r;
        }
        return 0;
    }
    close(sv[1]);
    for (size_t sent = 0; sent < 8u * 1024u * 1024u;) {
        ssize_t r = write(sv[0], b, sizeof(b));
        if (r <= 0) {
            perror("write");
            return 1;
        }
        sent += (size_t)r;
    }
    close(sv[0]);
    waitpid(pid, NULL, 0);
    printf("old kernel-mediated socket copy bytes=%u\n", 8u * 1024u * 1024u);
    return 0;
}
C

cat > "$work/15-rdma-newway.c" <<'C'
#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <stdio.h>

int main(void) {
    void *h = dlopen("libibverbs.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        printf("libibverbs.so.1 not available: %s\n", dlerror());
    } else {
        printf("libibverbs.so.1 loaded; real code uses ibv_get_device_list, ibv_reg_mr, QPs, and CQs\n");
        dlclose(h);
    }
    DIR *d = opendir("/sys/class/infiniband");
    if (!d) {
        perror("opendir /sys/class/infiniband");
        return 0;
    }
    struct dirent *e;
    int n = 0;
    printf("rdma devices:");
    while ((e = readdir(d))) {
        if (e->d_name[0] != '.') {
            printf(" %s", e->d_name);
            n++;
        }
    }
    printf(" count=%d\n", n);
    closedir(d);
    return 0;
}
C
run_c 15-rdma-oldway
run_c 15-rdma-newway

printf '\nTIP 16: kTLS ULP probe vs userspace TCP data path\n'
cat > "$work/16-ktls-oldway.c" <<'C'
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

int main(void) {
    int l = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
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
        int c = accept4(l, NULL, NULL, SOCK_CLOEXEC);
        char x;
        if (read(c, &x, 1) != 1) {
            perror("read");
            return 1;
        }
        return 0;
    }
    int s = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    connect(s, (struct sockaddr *)&a, sizeof(a));
    char x = 'x';
    if (write(s, &x, 1) != 1) {
        perror("write");
        return 1;
    }
    waitpid(pid, NULL, 0);
    printf("old userspace TCP data path sent one byte after normal connect\n");
    return 0;
}
C

cat > "$work/16-ktls-newway.c" <<'C'
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <linux/tls.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

int main(void) {
    int l = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
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
        int c = accept4(l, NULL, NULL, SOCK_CLOEXEC);
        usleep(100000);
        close(c);
        return 0;
    }
    int s = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    connect(s, (struct sockaddr *)&a, sizeof(a));
    const char *ulp = "tls";
    int r = setsockopt(s, IPPROTO_TCP, TCP_ULP, ulp, strlen(ulp));
    printf("new TCP_ULP tls result=%d errno=%s\n", r, strerror(errno));
#ifdef SOL_TLS
    printf("SOL_TLS=%d is visible; real kTLS then installs TLS_TX/TLS_RX crypto_info from userspace handshake\n", SOL_TLS);
#else
    printf("SOL_TLS not visible in headers\n");
#endif
    close(s);
    waitpid(pid, NULL, 0);
    return 0;
}
C
run_c 16-ktls-oldway
run_c 16-ktls-newway

printf '\nTIP 17: NUMA-aware placement vs malloc anywhere\n'
cat > "$work/17-numa-oldway.c" <<'C'
#define _GNU_SOURCE
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(void) {
    size_t len = 32u * 1024u * 1024u;
    char *p = malloc(len);
    if (!p) {
        perror("malloc");
        return 1;
    }
    for (size_t i = 0; i < len; i += 4096) {
        p[i] = 1;
    }
    printf("old malloc-anywhere touched=%zu bytes current_cpu=%d\n", len, sched_getcpu());
    return 0;
}
C

cat > "$work/17-numa-newway.c" <<'C'
#define _GNU_SOURCE
#include <errno.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef MPOL_BIND
#define MPOL_BIND 2
#endif

int main(void) {
    int cpu = sched_getcpu();
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    int ar = sched_setaffinity(0, sizeof(set), &set);
    printf("sched_setaffinity cpu=%d result=%d errno=%s\n", cpu, ar, strerror(errno));
    size_t len = 32u * 1024u * 1024u;
    char *p = aligned_alloc(4096, len);
    if (!p) {
        perror("aligned_alloc");
        return 1;
    }
    unsigned long mask = 1;
#ifdef SYS_mbind
    long br = syscall(SYS_mbind, p, len, MPOL_BIND, &mask, 8 * sizeof(mask), 0);
    printf("mbind node0 result=%ld errno=%s\n", br, strerror(errno));
#else
    printf("SYS_mbind not exposed by headers\n");
#endif
    for (size_t i = 0; i < len; i += 4096) {
        p[i] = 1;
    }
#ifdef SYS_move_pages
    void *page = p;
    int status = -999;
    long mr = syscall(SYS_move_pages, 0, 1, &page, NULL, &status, 0);
    printf("move_pages query result=%ld errno=%s first_page_node=%d\n", mr, strerror(errno), status);
#endif
    printf("new NUMA-aware path touched=%zu bytes final_cpu=%d\n", len, sched_getcpu());
    return 0;
}
C
run_c 17-numa-oldway
run_c 17-numa-newway

printf '\nTIP 18: eventfd doorbell vs pipe byte notification\n'
cat > "$work/18-eventfd-oldway.c" <<'C'
#define _GNU_SOURCE
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
        if (write(p[1], &x, 8) != 8) {
            perror("write");
            return 1;
        }
        if (read(p[0], &x, 8) != 8) {
            perror("read");
            return 1;
        }
    }
    printf("old pipe doorbell roundtrips=%d bytes_per_signal=8\n", n);
    return 0;
}
C

cat > "$work/18-eventfd-newway.c" <<'C'
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <sys/eventfd.h>
#include <unistd.h>

int main(void) {
    int fd = eventfd(0, EFD_CLOEXEC);
    if (fd < 0) {
        perror("eventfd");
        return 1;
    }
    uint64_t x = 1;
    int n = 50000;
    for (int i = 0; i < n; i++) {
        if (write(fd, &x, 8) != 8) {
            perror("write");
            return 1;
        }
        if (read(fd, &x, 8) != 8) {
            perror("read");
            return 1;
        }
    }
    printf("new eventfd doorbell roundtrips=%d counter_width=64bits epollable=yes\n", n);
    return 0;
}
C
run_c 18-eventfd-oldway
run_c 18-eventfd-newway

printf '\nTIP 19: process_vm_readv bulk cross-process copy vs pipe transfer\n'
cat > "$work/19-processvm-oldway.c" <<'C'
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

int main(void) {
    int p[2];
    if (pipe(p)) {
        perror("pipe");
        return 1;
    }
    size_t len = 4u * 1024u * 1024u;
    char *buf = malloc(len);
    memset(buf, 9, len);
    pid_t pid = fork();
    if (!pid) {
        close(p[0]);
        size_t off = 0;
        while (off < len) {
            ssize_t r = write(p[1], buf + off, len - off);
            if (r <= 0) {
                break;
            }
            off += (size_t)r;
        }
        return 0;
    }
    close(p[1]);
    size_t got = 0;
    while (got < len) {
        ssize_t r = read(p[0], buf + got, len - got);
        if (r <= 0) {
            break;
        }
        got += (size_t)r;
    }
    waitpid(pid, NULL, 0);
    printf("old pipe copied bytes=%zu\n", got);
    return 0;
}
C

cat > "$work/19-processvm-newway.c" <<'C'
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>

struct Info {
    uintptr_t addr;
    size_t len;
};

int main(void) {
    int info_pipe[2];
    int done_pipe[2];
    if (pipe(info_pipe)) {
        perror("pipe info");
        return 1;
    }
    if (pipe(done_pipe)) {
        perror("pipe done");
        return 1;
    }
    size_t len = 4u * 1024u * 1024u;
    pid_t pid = fork();
    if (!pid) {
        close(info_pipe[0]);
        close(done_pipe[1]);
        char *remote = malloc(len);
        memset(remote, 8, len);
        struct Info info = { .addr = (uintptr_t)remote, .len = len };
        if (write(info_pipe[1], &info, sizeof(info)) != (ssize_t)sizeof(info)) {
            perror("write info");
            return 1;
        }
        char done;
        if (read(done_pipe[0], &done, 1) != 1) {
            perror("read done");
            return 1;
        }
        return 0;
    }
    close(info_pipe[1]);
    close(done_pipe[0]);
    struct Info info;
    if (read(info_pipe[0], &info, sizeof(info)) != (ssize_t)sizeof(info)) {
        perror("read info");
        return 1;
    }
    char *local = malloc(info.len);
    struct iovec liov = { .iov_base = local, .iov_len = info.len };
    struct iovec riov = { .iov_base = (void *)info.addr, .iov_len = info.len };
    ssize_t got = process_vm_readv(pid, &liov, 1, &riov, 1, 0);
    printf("new process_vm_readv copied bytes=%zd first_byte=%d\n", got, got > 0 ? local[0] : -1);
    if (write(done_pipe[1], "x", 1) != 1) {
        perror("write done");
        return 1;
    }
    waitpid(pid, NULL, 0);
    return 0;
}
C
run_c 19-processvm-oldway
run_c 19-processvm-newway

printf '\nTIP 20: explicit fault/page-table/I/O flags vs manual touching and guessing\n'
cat > "$work/20-faults-oldway.c" <<'C'
#define _GNU_SOURCE
#include <stdio.h>
#include <sys/mman.h>
#include <time.h>

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
}

int main(void) {
    size_t len = 16u * 1024u * 1024u;
    char *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    double t0 = now();
    for (size_t i = 0; i < len; i += 4096) {
        p[i] = 1;
    }
    double t1 = now();
    printf("old manual page touch bytes=%zu seconds=%.6f\n", len, t1 - t0);
    return 0;
}
C

cat > "$work/20-faults-newway.c" <<'C'
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/mman.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

#ifndef MADV_POPULATE_WRITE
#define MADV_POPULATE_WRITE 23
#endif
#ifndef MLOCK_ONFAULT
#define MLOCK_ONFAULT 1
#endif
#ifndef MREMAP_DONTUNMAP
#define MREMAP_DONTUNMAP 4
#endif

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
}

int main(void) {
    size_t len = 16u * 1024u * 1024u;
    char *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    double t0 = now();
    errno = 0;
    int pr = madvise(p, len, MADV_POPULATE_WRITE);
    double t1 = now();
    for (size_t i = 0; i < len; i += 4096) {
        p[i] = 2;
    }
    double t2 = now();
    printf("new MADV_POPULATE_WRITE result=%d errno=%s populate_seconds=%.6f later_touch_seconds=%.6f\n", pr, strerror(errno), t1 - t0, t2 - t1);
#ifdef SYS_mlock2
    errno = 0;
    long lr = syscall(SYS_mlock2, p, 4096, MLOCK_ONFAULT);
    printf("mlock2 MLOCK_ONFAULT result=%ld errno=%s\n", lr, strerror(errno));
#endif
    void *q = mremap(p, 4096, 4096, MREMAP_MAYMOVE | MREMAP_DONTUNMAP);
    if (q == MAP_FAILED) {
        printf("mremap MREMAP_DONTUNMAP failed: %s\n", strerror(errno));
    } else {
        printf("mremap MREMAP_DONTUNMAP new_addr=%p old_addr=%p\n", q, p);
    }
#ifdef STATX_DIOALIGN
    struct statx stx;
    memset(&stx, 0, sizeof(stx));
    int sx = statx(AT_FDCWD, ".", AT_STATX_SYNC_AS_STAT, STATX_DIOALIGN, &stx);
    printf("statx STATX_DIOALIGN result=%d errno=%s mem_align=%u off_align=%u\n", sx, strerror(errno), stx.stx_dio_mem_align, stx.stx_dio_offset_align);
#else
    printf("headers do not expose STATX_DIOALIGN\n");
#endif
#ifdef SYS_pwritev2
    int fd = open("20-faults-newway.data", O_CREAT | O_TRUNC | O_RDWR | O_CLOEXEC, 0600);
    if (fd >= 0) {
        char x[4096];
        memset(x, 5, sizeof(x));
        struct iovec iov = { .iov_base = x, .iov_len = sizeof(x) };
        int flags = 0;
#ifdef RWF_DSYNC
        flags |= RWF_DSYNC;
#endif
#ifdef RWF_DONTCACHE
        flags |= RWF_DONTCACHE;
#endif
#ifdef RWF_ATOMIC
        flags |= RWF_ATOMIC;
#endif
        errno = 0;
        long wr = syscall(SYS_pwritev2, fd, &iov, 1, 0, 0, flags);
        printf("pwritev2 flags=0x%x result=%ld errno=%s\n", flags, wr, strerror(errno));
        close(fd);
    }
#endif
    return 0;
}
C
run_c 20-faults-oldway
run_c 20-faults-newway

printf '\nDone. The generated C sources/binaries were cat-built-run inside %s and will be trashed by the EXIT trap.\n' "$work"
