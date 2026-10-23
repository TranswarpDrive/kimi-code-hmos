// libkimihost.so —— 在鸿蒙PC 应用进程里拉起并管理随包二进制（node + kimi web）。
//
//   spawn   fork + execve，子进程 stdout/stderr 追加写入日志文件，独立会话（进程组 = pid）
//   kill    向整个进程组发信号（kimi 自己拉起的 shell 等孙进程一起结束）
//   onExit  后台线程 waitpid，经 threadsafe function 把退出码送回 ArkTS 线程
//   另提供 isAlive 与 nativeLibDir 供壳管理生命周期和定位运行时。
//
// 2in1 允许应用 fork/exec 包内 bin；进程模型参见 startup_appspawn/service/hnp 官方文档。

#include <napi/native_api.h>
#include <hilog/log.h>

#include <algorithm>
#include <cerrno>
#include <csignal>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <fcntl.h>
#include <string>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#include <vector>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x4B49
#define LOG_TAG "KimiShell"

namespace {

constexpr int kMaxFdToClose = 65536;
constexpr int kExecFailedExitCode = 127;
constexpr off_t kLogLimit = 4 * 1024 * 1024;

// 子进程输出由原生线程排空并轮转，避免常驻调试把磁盘写满或在 UI 线程搬运大文件。
void DrainLog(int readFd, int logFd, std::string logPath)
{
    struct stat st {};
    off_t size = logFd >= 0 && fstat(logFd, &st) == 0 ? st.st_size : 0;
    char buffer[16384];
    while (true) {
        ssize_t count = read(readFd, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        if (logFd < 0) continue;
        if (size + count > kLogLimit) {
            close(logFd);
            (void)rename(logPath.c_str(), (logPath + ".1").c_str());
            logFd = open(logPath.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0600);
            size = 0;
            if (logFd < 0) continue;
        }
        ssize_t written = 0;
        while (written < count) {
            ssize_t n = write(logFd, buffer + written, static_cast<size_t>(count - written));
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) break;
            written += n;
            size += n;
        }
    }
    close(readFd);
    if (logFd >= 0) close(logFd);
}

bool GroupAlive(pid_t pid)
{
    return pid > 0 && (kill(-pid, 0) == 0 || errno == EPERM || kill(pid, 0) == 0 || errno == EPERM);
}

void TerminateGroup(pid_t pid, int graceMs)
{
    if (kill(-pid, SIGTERM) != 0) (void)kill(pid, SIGTERM);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(graceMs);
    while (GroupAlive(pid) && std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    if (GroupAlive(pid) && kill(-pid, SIGKILL) != 0) (void)kill(pid, SIGKILL);
}

struct ExitEvent {
    pid_t pid;
    int code;
    int signal;
};

bool ReadString(napi_env env, napi_value value, std::string &out)
{
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok) {
        return false;
    }
    std::vector<char> buf(len + 1, '\0');
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, value, buf.data(), buf.size(), &copied) != napi_ok) {
        return false;
    }
    out.assign(buf.data(), copied);
    return true;
}

bool ReadNamedString(napi_env env, napi_value obj, const char *name, std::string &out)
{
    bool has = false;
    if (napi_has_named_property(env, obj, name, &has) != napi_ok || !has) {
        return false;
    }
    napi_value value = nullptr;
    if (napi_get_named_property(env, obj, name, &value) != napi_ok) {
        return false;
    }
    napi_valuetype type = napi_undefined;
    napi_typeof(env, value, &type);
    return type == napi_string && ReadString(env, value, out);
}

bool ReadNamedStringArray(napi_env env, napi_value obj, const char *name, std::vector<std::string> &out)
{
    napi_value value = nullptr;
    if (napi_get_named_property(env, obj, name, &value) != napi_ok) {
        return false;
    }
    bool isArray = false;
    if (napi_is_array(env, value, &isArray) != napi_ok || !isArray) {
        return false;
    }
    uint32_t length = 0;
    napi_get_array_length(env, value, &length);
    for (uint32_t i = 0; i < length; ++i) {
        napi_value item = nullptr;
        std::string str;
        if (napi_get_element(env, value, i, &item) != napi_ok || !ReadString(env, item, str)) {
            return false;
        }
        out.push_back(str);
    }
    return true;
}

int ReadInt32Arg(napi_env env, napi_value value, int fallback)
{
    int32_t result = fallback;
    if (napi_get_value_int32(env, value, &result) != napi_ok) {
        return fallback;
    }
    return result;
}

std::vector<char *> ToCArray(std::vector<std::string> &items)
{
    std::vector<char *> out;
    out.reserve(items.size() + 1);
    for (auto &item : items) {
        out.push_back(item.data());
    }
    out.push_back(nullptr);
    return out;
}

// fork 之后、execve 之前只调用 async-signal-safe 的函数；所需数据都在 fork 前准备好。
void WriteErrnoLine(const char *prefix, int err)
{
    char digits[16];
    int n = 0;
    unsigned int value = static_cast<unsigned int>(err);
    do {
        digits[n++] = static_cast<char>('0' + value % 10);
        value /= 10;
    } while (value != 0 && n < static_cast<int>(sizeof(digits)));
    (void)write(STDERR_FILENO, prefix, strlen(prefix));
    while (n > 0) {
        (void)write(STDERR_FILENO, &digits[--n], 1);
    }
    (void)write(STDERR_FILENO, "\n", 1);
}

[[noreturn]] void ExecChild(const char *file, char *const argv[], char *const envp[], const char *cwd,
                            int logFd, int maxFd, pid_t parentPid)
{
    // 应用进程可能屏蔽或忽略了部分信号，这些状态会被 execve 继承，先全部复位
    sigset_t emptySet;
    sigemptyset(&emptySet);
    sigprocmask(SIG_SETMASK, &emptySet, nullptr);
    struct sigaction dfl;
    memset(&dfl, 0, sizeof(dfl));
    dfl.sa_handler = SIG_DFL;
    for (int sig = 1; sig < NSIG; ++sig) {
        if (sig != SIGKILL && sig != SIGSTOP) {
            sigaction(sig, &dfl, nullptr);
        }
    }

    // 独立会话，进程组 id = pid；应用进程被强杀时服务不能依赖 JS 信号回调才能退出。
    setsid();
    prctl(PR_SET_PDEATHSIG, SIGKILL);
    if (getppid() != parentPid) {
        _exit(0);
    }

    int nullFd = open("/dev/null", O_RDWR);
    if (nullFd >= 0) {
        dup2(nullFd, STDIN_FILENO);
    }
    int outFd = logFd >= 0 ? logFd : nullFd;
    if (outFd >= 0) {
        dup2(outFd, STDOUT_FILENO);
        dup2(outFd, STDERR_FILENO);
    }
    // 不用 close_range：应用沙箱的 seccomp 可能拦截它
    for (int fd = STDERR_FILENO + 1; fd < maxFd; ++fd) {
        close(fd);
    }

    if (cwd != nullptr && cwd[0] != '\0' && chdir(cwd) != 0) {
        WriteErrnoLine("[kimihost] chdir failed, errno=", errno);
        _exit(kExecFailedExitCode);
    }
    execve(file, argv, envp);
    WriteErrnoLine("[kimihost] execve failed, errno=", errno);
    _exit(kExecFailedExitCode);
}

void CallJsOnExit(napi_env env, napi_value jsCallback, void *context, void *data)
{
    (void)context;
    auto *event = static_cast<ExitEvent *>(data);
    if (env != nullptr && jsCallback != nullptr && event != nullptr) {
        napi_value args[3];
        napi_create_int32(env, event->pid, &args[0]);
        napi_create_int32(env, event->code, &args[1]);
        napi_create_int32(env, event->signal, &args[2]);
        napi_value undefined = nullptr;
        napi_get_undefined(env, &undefined);
        napi_call_function(env, undefined, jsCallback, 3, args, nullptr);
    }
    delete event;
}

void WatchChild(pid_t pid, napi_threadsafe_function tsfn)
{
    int status = 0;
    pid_t ret = -1;
    do {
        ret = waitpid(pid, &status, 0);
    } while (ret == -1 && errno == EINTR);

    auto *event = new ExitEvent{pid, -1, 0};
    if (ret == pid) {
        if (WIFEXITED(status)) {
            event->code = WEXITSTATUS(status);
        } else if (WIFSIGNALED(status)) {
            event->signal = WTERMSIG(status);
        }
    } else {
        // ECHILD：SIGCHLD 被忽略时由内核自动回收，拿不到退出码，只能等进程消失
        OH_LOG_WARN(LOG_APP, "waitpid(%{public}d) failed errno=%{public}d, polling", pid, errno);
        while (kill(pid, 0) == 0) {
            usleep(200 * 1000);
        }
    }
    OH_LOG_INFO(LOG_APP, "child %{public}d exited code=%{public}d signal=%{public}d", pid, event->code,
                event->signal);
    if (tsfn == nullptr) {
        delete event;
        return;
    }
    if (napi_call_threadsafe_function(tsfn, event, napi_tsfn_blocking) != napi_ok) {
        delete event;
    }
    napi_release_threadsafe_function(tsfn, napi_tsfn_release);
}

napi_value ThrowError(napi_env env, const std::string &message)
{
    OH_LOG_ERROR(LOG_APP, "%{public}s", message.c_str());
    napi_throw_error(env, nullptr, message.c_str());
    return nullptr;
}

// spawn({ file, args, env, cwd?, logPath?, onExit? }): number
// args 是完整 argv（含 argv[0]）；env 是 "KEY=VALUE" 列表（不继承应用进程环境变量）。
napi_value Spawn(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 1) {
        return ThrowError(env, "spawn: options required");
    }
    napi_value options = argv[0];

    std::string file;
    std::string cwd;
    std::string logPath;
    std::vector<std::string> args;
    std::vector<std::string> envs;
    if (!ReadNamedString(env, options, "file", file) || file.empty()) {
        return ThrowError(env, "spawn: options.file must be a non-empty string");
    }
    if (!ReadNamedStringArray(env, options, "args", args) || !ReadNamedStringArray(env, options, "env", envs)) {
        return ThrowError(env, "spawn: options.args / options.env must be string arrays");
    }
    ReadNamedString(env, options, "cwd", cwd);
    ReadNamedString(env, options, "logPath", logPath);
    if (args.empty()) {
        args.push_back(file);
    }
    if (access(file.c_str(), X_OK) != 0) {
        return ThrowError(env, "spawn: not executable: " + file + " (errno " + std::to_string(errno) + ")");
    }

    napi_threadsafe_function tsfn = nullptr;
    napi_value onExit = nullptr;
    napi_valuetype onExitType = napi_undefined;
    if (napi_get_named_property(env, options, "onExit", &onExit) == napi_ok) {
        napi_typeof(env, onExit, &onExitType);
    }
    if (onExitType == napi_function) {
        napi_value resourceName = nullptr;
        napi_create_string_utf8(env, "kimihostOnExit", NAPI_AUTO_LENGTH, &resourceName);
        if (napi_create_threadsafe_function(env, onExit, nullptr, resourceName, 0, 1, nullptr, nullptr, nullptr,
                                            CallJsOnExit, &tsfn) != napi_ok) {
            return ThrowError(env, "spawn: failed to create exit callback");
        }
    }

    int logFd = -1;
    if (!logPath.empty()) {
        logFd = open(logPath.c_str(), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
        if (logFd < 0) {
            OH_LOG_WARN(LOG_APP, "open log %{public}s failed errno=%{public}d", logPath.c_str(), errno);
        }
    }

    int logPipe[2];
    if (pipe2(logPipe, O_CLOEXEC) != 0) {
        if (logFd >= 0) close(logFd);
        if (tsfn != nullptr) napi_release_threadsafe_function(tsfn, napi_tsfn_abort);
        return ThrowError(env, "spawn: failed to create log pipe");
    }

    struct rlimit limit;
    int maxFd = 1024;
    if (getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur != RLIM_INFINITY) {
        maxFd = static_cast<int>(std::min<rlim_t>(limit.rlim_cur, kMaxFdToClose));
    } else {
        maxFd = kMaxFdToClose;
    }
    std::vector<char *> cArgs = ToCArray(args);
    std::vector<char *> cEnvs = ToCArray(envs);
    const char *cwdPtr = cwd.empty() ? nullptr : cwd.c_str();
    pid_t parentPid = getpid();

    pid_t pid = fork();
    if (pid == 0) {
        ExecChild(file.c_str(), cArgs.data(), cEnvs.data(), cwdPtr, logPipe[1], maxFd, parentPid);
    }
    int forkErrno = errno;
    close(logPipe[1]);
    if (pid < 0) {
        close(logPipe[0]);
        if (logFd >= 0) close(logFd);
        if (tsfn != nullptr) {
            napi_release_threadsafe_function(tsfn, napi_tsfn_abort);
        }
        return ThrowError(env, "spawn: fork failed (errno " + std::to_string(forkErrno) + ")");
    }

    OH_LOG_INFO(LOG_APP, "spawned %{public}s pid=%{public}d", file.c_str(), pid);
    std::thread(DrainLog, logPipe[0], logFd, logPath).detach();
    std::thread(WatchChild, pid, tsfn).detach();

    napi_value result = nullptr;
    napi_create_int32(env, pid, &result);
    return result;
}

// kill(pid, signal): boolean —— 先发给进程组，失败再发给单个进程
napi_value Kill(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int pid = argc > 0 ? ReadInt32Arg(env, argv[0], 0) : 0;
    int sig = argc > 1 ? ReadInt32Arg(env, argv[1], SIGTERM) : SIGTERM;
    bool ok = false;
    if (pid > 0) {
        ok = kill(-pid, sig) == 0 || kill(pid, sig) == 0;
    }
    napi_value result = nullptr;
    napi_get_boolean(env, ok, &result);
    return result;
}

// nativeLibDir(): string —— 本 so 所在目录。compressNativeLibs=true 时 libs 会解压成真实文件，
// executableBinaryPaths 声明的 node 也在这里。
napi_value NativeLibDir(napi_env env, napi_callback_info info)
{
    (void)info;
    Dl_info dlInfo;
    std::string dir;
    if (dladdr(reinterpret_cast<void *>(&NativeLibDir), &dlInfo) != 0 && dlInfo.dli_fname != nullptr) {
        dir = dlInfo.dli_fname;
        size_t slash = dir.find_last_of('/');
        dir = slash == std::string::npos ? std::string() : dir.substr(0, slash);
    }
    napi_value result = nullptr;
    napi_create_string_utf8(env, dir.c_str(), dir.size(), &result);
    return result;
}

// isAlive(pid): boolean
napi_value IsAlive(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int pid = argc > 0 ? ReadInt32Arg(env, argv[0], 0) : 0;
    bool alive = pid > 0 && (kill(pid, 0) == 0 || errno == EPERM);
    napi_value result = nullptr;
    napi_get_boolean(env, alive, &result);
    return result;
}

napi_value IsGroupAlive(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    const int pid = argc > 0 ? ReadInt32Arg(env, argv[0], 0) : 0;
    napi_value result = nullptr;
    napi_get_boolean(env, GroupAlive(pid), &result);
    return result;
}

napi_value Terminate(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    const int pid = argc > 0 ? ReadInt32Arg(env, argv[0], 0) : 0;
    const int graceMs = argc > 1 ? std::clamp(ReadInt32Arg(env, argv[1], 4000), 0, 10000) : 4000;
    if (pid > 0) std::thread(TerminateGroup, pid, graceMs).detach();
    napi_value result = nullptr;
    napi_get_undefined(env, &result);
    return result;
}

} // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"spawn", nullptr, Spawn, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"kill", nullptr, Kill, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isAlive", nullptr, IsAlive, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isGroupAlive", nullptr, IsGroupAlive, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"terminate", nullptr, Terminate, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nativeLibDir", nullptr, NativeLibDir, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module g_kimihostModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "kimihost",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterKimihostModule(void)
{
    napi_module_register(&g_kimihostModule);
}
