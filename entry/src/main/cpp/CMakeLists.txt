cmake_minimum_required(VERSION 3.5.0)
project(kimihost)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# libkimihost.so：给 ArkTS 用的进程管理（fork+execve / kill / 退出回调 / 原生库目录）
add_library(kimihost SHARED kimihost.cpp)
target_compile_options(kimihost PRIVATE -Wall -Wextra -fno-exceptions)
target_link_libraries(kimihost PUBLIC libace_napi.z.so libhilog_ndk.z.so)

# libkimicompat.so：经 LD_PRELOAD 注入 node 及其子进程的 SIGSYS 兼容层（不链接任何 OHOS 库）
add_library(kimicompat SHARED compat/ohos_compat.c)
target_compile_options(kimicompat PRIVATE -Wall -Wextra)
