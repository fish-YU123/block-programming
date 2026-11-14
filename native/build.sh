#!/bin/sh
# 构建无引擎渲染原型（Windows + MinGW/ucrt64）。
#
#   ./build.sh             # Release
#   CXX=clang++ ./build.sh # 换编译器
#
# 依赖：g++（或 clang++）、glslangValidator（mingw-w64-ucrt-x86_64-glslang）、
#       Vulkan 头文件与导入库（mingw-w64-ucrt-x86_64-vulkan-headers / -loader）。
# 产物：build/block_programming_native.exe + build/shaders/*
set -e
cd "$(dirname "$0")"

CXX="${CXX:-g++}"
GLSLANG="${GLSLANG:-glslangValidator}"

command -v "$CXX" >/dev/null 2>&1 || { echo "找不到 C++ 编译器：$CXX" >&2; exit 1; }
command -v "$GLSLANG" >/dev/null 2>&1 || { echo "找不到 glslangValidator（SPIR-V 编译器）" >&2; exit 1; }

mkdir -p build/shaders

echo "== 编译着色器 -> SPIR-V（Vulkan）"
"$GLSLANG" -V -DVK shaders/chunk.vert -o build/shaders/chunk.vert.spv
"$GLSLANG" -V -DVK shaders/chunk.frag -o build/shaders/chunk.frag.spv

echo "== 拷贝 GLSL 源码（OpenGL 回退路径要直接编译源码）"
cp shaders/chunk.vert shaders/chunk.frag build/shaders/

echo "== 编译程序"
"$CXX" -std=c++17 -O2 -Wall -Wextra \
	src/main.cpp src/platform_win32.cpp src/scene.cpp src/rhi_vulkan.cpp src/rhi_opengl.cpp \
	-o build/block_programming_native.exe \
	-lvulkan-1 -lopengl32 -lgdi32 -luser32

echo "== 完成：build/block_programming_native.exe"
