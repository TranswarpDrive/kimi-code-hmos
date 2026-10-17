// jitprobe —— 诊断用可执行文件：与 node 一样经 executableBinaryPaths 声明、由应用 fork+execve 拉起，
// 打印本进程能否申请匿名可执行内存（V8 JIT 的前提），用于判断应用的内核权限是否传递给了子进程。
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

int main(void)
{
    size_t size = (size_t)sysconf(_SC_PAGESIZE);
    void *rwx = mmap(NULL, size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (rwx == MAP_FAILED) {
        printf("[jitprobe] mmap(RWX) failed errno=%d (%s)\n", errno, strerror(errno));
    } else {
        printf("[jitprobe] mmap(RWX) ok\n");
        munmap(rwx, size);
    }
    void *rw = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (rw != MAP_FAILED) {
        int ret = mprotect(rw, size, PROT_READ | PROT_EXEC);
        printf("[jitprobe] mprotect(RW->RX) %s errno=%d\n", ret == 0 ? "ok" : "failed", ret == 0 ? 0 : errno);
        munmap(rw, size);
    }
    printf("[jitprobe] uid=%d pid=%d ppid=%d\n", (int)getuid(), (int)getpid(), (int)getppid());
    fflush(stdout);
    return 0;
}
