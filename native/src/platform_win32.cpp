#include "platform_win32.h"

static LRESULT CALLBACK _wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_CLOSE) {
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

bool window_create(const wchar_t* title, int width, int height, WindowHandle& out, std::string& err) {
    out.instance = GetModuleHandleW(nullptr);
    out.width = width;
    out.height = height;

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.style = CS_HREDRAW | CS_VREDRAW | CS_OWNDC;
    wc.lpfnWndProc = _wndproc;
    wc.hInstance = out.instance;
    wc.hCursor = LoadCursorW(nullptr, MAKEINTRESOURCEW(32512));
    wc.lpszClassName = L"BlockProgrammingNative";
    if (!RegisterClassExW(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        err = "RegisterClassExW 失败";
        return false;
    }

    RECT rect{0, 0, width, height};
    AdjustWindowRect(&rect, WS_OVERLAPPEDWINDOW, FALSE);
    HWND hwnd = CreateWindowExW(0, wc.lpszClassName, title, WS_OVERLAPPEDWINDOW,
                                CW_USEDEFAULT, CW_USEDEFAULT,
                                rect.right - rect.left, rect.bottom - rect.top,
                                nullptr, nullptr, out.instance, nullptr);
    if (!hwnd) {
        err = "CreateWindowExW 失败";
        return false;
    }
    out.hwnd = hwnd;
    return true;
}

void window_show(WindowHandle& w) {
    ShowWindow(w.hwnd, SW_SHOW);
    UpdateWindow(w.hwnd);
    SetForegroundWindow(w.hwnd);
    RECT rc{};
    GetClientRect(w.hwnd, &rc);
    if (rc.right > 0 && rc.bottom > 0) {
        w.width = rc.right;
        w.height = rc.bottom;
    }
}

bool window_pump(const WindowHandle& w, int& width, int& height) {
    MSG msg;
    while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
        if (msg.message == WM_QUIT) return false;
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    RECT rc{};
    if (GetClientRect(w.hwnd, &rc) && rc.right > 0 && rc.bottom > 0) {
        width = rc.right;
        height = rc.bottom;
    }
    return true;
}

void window_destroy(const WindowHandle& w) {
    if (w.hwnd) DestroyWindow(w.hwnd);
    if (w.instance) UnregisterClassW(L"BlockProgrammingNative", w.instance);
}
