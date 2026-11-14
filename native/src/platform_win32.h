// Win32 窗口与消息泵（Vulkan 与 OpenGL 后端共用同一个 HWND）
#pragma once

#include <windows.h>

#include <string>

struct WindowHandle {
    HWND hwnd = nullptr;
    HINSTANCE instance = nullptr;
    int width = 0;
    int height = 0;
};

bool window_create(const wchar_t* title, int width, int height, WindowHandle& out, std::string& err);
void window_show(WindowHandle& w);
// 处理消息；窗口关闭返回 false。width/height 是进出参：被系统改动（拖拽/最大化）后会更新。
bool window_pump(const WindowHandle& w, int& width, int& height);
void window_destroy(const WindowHandle& w);
