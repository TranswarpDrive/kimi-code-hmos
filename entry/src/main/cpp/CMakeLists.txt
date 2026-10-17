cmake_minimum_required(VERSION 3.5.0)
project(kimihost)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# libkimihost.so：给 ArkTS 用的进程管理（fork+execve / kill / 退出回调）
add_library(kimihost SHARED kimihost.cpp)
target_compile_options(kimihost PRIVATE -Wall -Wextra -fno-exceptions)
target_link_libraries(kimihost PUBLIC libace_napi.z.so libhilog_ndk.z.so)
