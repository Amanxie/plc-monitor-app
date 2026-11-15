cmake_minimum_required(VERSION 3.22.1)
project(license CXX)

# 期望的应用签名指纹（SHA-256，64 位十六进制），由 Gradle 传入
if(NOT DEFINED EXPECTED_SIG)
    set(EXPECTED_SIG "0000000000000000000000000000000000000000000000000000000000000000")
endif()

add_library(license SHARED license.cpp)

target_compile_options(license PRIVATE
        -Os
        -fvisibility=hidden
        -fvisibility-inlines-hidden
        -fno-exceptions
        -fno-rtti)

target_link_options(license PRIVATE -Wl,-s)
target_compile_definitions(license PRIVATE EXPECTED_SIG="${EXPECTED_SIG}")
