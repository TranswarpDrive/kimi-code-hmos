// libkimicompat.so —— 经 LD_PRELOAD 注入 node 及其子进程的兼容层。
//
// 鸿蒙应用沙箱的 seccomp 对部分 syscall（如 io_uring_setup、close_range）使用 SECCOMP_RET_TRAP：
// 内核不执行该调用，而是向线程发送 SIGSYS；默认处理是直接结束进程。
// 这里安装 SIGSYS 处理函数，把被拦截的调用改成返回 -ENOSYS（libc 包装后即 -1/errno=ENOSYS），
// 让 libuv 等调用方走各自的降级路径。若 seccomp 用的是 KILL 动作，本层无能为力。

#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <string.h>
#include <ucontext.h>
#include <unistd.h>

static void kimi_on_sigsys(int sig, siginfo_t *info, void *context)
{
    (void)sig;
    (void)info;
    ucontext_t *uc = (ucontext_t *)context;
#if defined(__aarch64__)
    uc->uc_mcontext.regs[0] = (unsigned long)(-ENOSYS);
#elif defined(__x86_64__)
    uc->uc_mcontext.gregs[REG_RAX] = -ENOSYS;
#endif
}

__attribute__((constructor)) static void kimi_compat_init(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = kimi_on_sigsys;
    sa.sa_flags = SA_SIGINFO | SA_NODEFER;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSYS, &sa, NULL);
}
