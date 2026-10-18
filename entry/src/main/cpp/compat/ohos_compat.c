// libkimicompat.so —— 经 LD_PRELOAD 注入 node 及其子进程的兼容层。
//
// 鸿蒙应用沙箱的 seccomp 对部分 syscall（如 io_uring_setup、close_range）使用 SECCOMP_RET_TRAP：
// 内核不执行该调用，而是向线程发送 SIGSYS；默认处理是直接结束进程。
// 这里安装 SIGSYS 处理函数，把被拦截的调用改成返回 -ENOSYS（libc 包装后即 -1/errno=ENOSYS），
// 让 libuv 等调用方走各自的降级路径。若 seccomp 用的是 KILL 动作，本层无能为力。
// 设置 KIMI_HMOS_DEBUG=1 时，加载与每次拦截都会往 stderr 写一行，便于定位是哪个 syscall。
//
// 注意：若触发拦截的线程屏蔽了 SIGSYS（Node 的 inspector 线程、V8/libuv 工作线程会屏蔽全部信号），
// 内核会强制以默认动作处理 SIGSYS，进程直接被杀，处理函数没有机会执行。
// 所以这里同时接管 pthread_sigmask/sigprocmask，任何线程都不允许屏蔽 SIGSYS。

#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/auxv.h>
#include <ucontext.h>
#include <unistd.h>

static int g_debug = 0;

// 只用 async-signal-safe 的 write 输出 "<prefix><number>\n"
static void write_number_line(const char *prefix, long value)
{
    char buf[96];
    size_t len = strlen(prefix);
    if (len > 64) {
        len = 64;
    }
    memcpy(buf, prefix, len);
    char digits[24];
    int n = 0;
    unsigned long v = value < 0 ? (unsigned long)(-value) : (unsigned long)value;
    do {
        digits[n++] = (char)('0' + v % 10);
        v /= 10;
    } while (v != 0 && n < (int)sizeof(digits));
    if (value < 0) {
        buf[len++] = '-';
    }
    while (n > 0) {
        buf[len++] = digits[--n];
    }
    buf[len++] = '\n';
    (void)write(STDERR_FILENO, buf, len);
}

static void kimi_on_sigsys(int sig, siginfo_t *info, void *context)
{
    (void)sig;
    ucontext_t *uc = (ucontext_t *)context;
#if defined(__aarch64__)
    uc->uc_mcontext.regs[0] = (unsigned long)(-ENOSYS);
#elif defined(__x86_64__)
    uc->uc_mcontext.gregs[REG_RAX] = -ENOSYS;
#endif
    if (g_debug && info != NULL) {
        write_number_line("[kimicompat] SIGSYS trapped syscall=", (long)info->si_syscall);
    }
}

typedef int (*sigmask_fn)(int, const sigset_t *, sigset_t *);

static int call_without_sigsys(sigmask_fn real, int how, const sigset_t *set, sigset_t *old)
{
    if (real == NULL) {
        errno = ENOSYS;
        return -1;
    }
    if (set != NULL && (how == SIG_BLOCK || how == SIG_SETMASK) && sigismember(set, SIGSYS) == 1) {
        sigset_t copy = *set;
        sigdelset(&copy, SIGSYS);
        return real(how, &copy, old);
    }
    return real(how, set, old);
}

int pthread_sigmask(int how, const sigset_t *set, sigset_t *old)
{
    static sigmask_fn real = NULL;
    if (real == NULL) {
        real = (sigmask_fn)dlsym(RTLD_NEXT, "pthread_sigmask");
    }
    return call_without_sigsys(real, how, set, old);
}

int sigprocmask(int how, const sigset_t *set, sigset_t *old)
{
    static sigmask_fn real = NULL;
    if (real == NULL) {
        real = (sigmask_fn)dlsym(RTLD_NEXT, "sigprocmask");
    }
    return call_without_sigsys(real, how, set, old);
}

__attribute__((constructor)) static void kimi_compat_init(void)
{
    const char *debug = getenv("KIMI_HMOS_DEBUG");
    g_debug = debug != NULL && debug[0] == '1';
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = kimi_on_sigsys;
    sa.sa_flags = SA_SIGINFO | SA_NODEFER;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSYS, &sa, NULL);
    if (g_debug) {
        write_number_line("[kimicompat] loaded, AT_SECURE=", (long)getauxval(AT_SECURE));
    }
}
