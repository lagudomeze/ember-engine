#!/bin/bash
# 下载跨平台编译所需的第三方库
# 运行此脚本一次，之后即可交叉编译到所有支持平台

set -e

DEPS_DIR="$(cd "$(dirname "$0")" && pwd)/deps"
mkdir -p "$DEPS_DIR"

echo "=== 下载 Windows SDL2 开发库 ==="
WIN_SDL_URL="https://github.com/libsdl-org/SDL/releases/download/release-2.30.0/SDL2-devel-2.30.0-mingw.tar.gz"
WIN_TMP="/tmp/SDL2-mingw.tar.gz"

if [ ! -d "$DEPS_DIR/win" ]; then
    curl -L -o "$WIN_TMP" "$WIN_SDL_URL"
    mkdir -p "$DEPS_DIR/win_tmp"
    tar xzf "$WIN_TMP" -C "$DEPS_DIR/win_tmp"
    SDL_DIR=$(ls -d "$DEPS_DIR/win_tmp"/SDL2-*)
    mv "$SDL_DIR/x86_64-w64-mingw32" "$DEPS_DIR/win"
    rm -rf "$DEPS_DIR/win_tmp" "$WIN_TMP"
    echo "  Windows SDL2 已安装到 deps/win/"
else
    echo "  Windows SDL2 已存在，跳过"
fi

echo ""
echo "=== 依赖下载完成 ==="
echo "现在可以交叉编译："
echo "  zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast"
