// 无引擎原型入口：先试 Vulkan，失败自动回退 OpenGL。
// 用法：
//   app.exe [--backend=auto|vulkan|gl] [--frames=N] [--width=W] [--height=H] [--seed=S]
//   --frames=0 表示一直跑到关窗口（默认 0）
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include "mathx.h"
#include "platform_win32.h"
#include "rhi.h"
#include "scene.h"

namespace {

struct Options {
    std::string backend = "auto";
    int frames = 0;
    int width = 1280;
    int height = 720;
    std::string shot;      // --shot=out.bmp：最后一帧写成 BMP
};

int arg_int(const char* s) {
    if (!s || !*s) return 0;
    return std::atoi(s);
}

Options parse_args(int argc, char** argv) {
    Options o;
    for (int i = 1; i < argc; ++i) {
        const char* a = argv[i];
        if (std::strncmp(a, "--backend=", 10) == 0) {
            o.backend = a + 10;
        } else if (std::strncmp(a, "--frames=", 9) == 0) {
            o.frames = arg_int(a + 9);
        } else if (std::strncmp(a, "--width=", 8) == 0) {
            o.width = arg_int(a + 8);
        } else if (std::strncmp(a, "--height=", 9) == 0) {
            o.height = arg_int(a + 9);
        } else if (std::strncmp(a, "--shot=", 7) == 0) {
            o.shot = a + 7;
        } else if (std::strcmp(a, "--help") == 0 || std::strcmp(a, "-h") == 0) {
            std::printf("用法: %s [--backend=auto|vulkan|gl] [--frames=N] [--width=W] [--height=H]\n", argv[0]);
            std::exit(0);
        }
    }
    if (o.width < 320) o.width = 320;
    if (o.height < 240) o.height = 240;
    return o;
}

RenderDevice* try_create(const std::string& backend, void* hwnd, int w, int h) {
    std::string err;
    RenderDevice* dev = nullptr;
    if (backend == "vulkan") {
        dev = create_vulkan_device();
        if (dev && !dev->init(hwnd, w, h, err)) {
            std::printf("[回退] Vulkan 初始化失败：%s\n", err.c_str());
            dev->shutdown();
            delete dev;
            return nullptr;
        }
        return dev;
    }
    if (backend == "gl") {
        dev = create_opengl_device();
        if (dev && !dev->init(hwnd, w, h, err)) {
            std::printf("[错误] OpenGL 初始化失败：%s\n", err.c_str());
            dev->shutdown();
            delete dev;
            return nullptr;
        }
        return dev;
    }
    return nullptr;
}

}  // namespace

int main(int argc, char** argv) {
    Options opt = parse_args(argc, argv);

    WindowHandle win;
    std::string err;
    if (!window_create(L"Block Programming — native renderer prototype", opt.width, opt.height, win, err)) {
        std::printf("[错误] 创建窗口失败：%s\n", err.c_str());
        return 1;
    }
    window_show(win);

    RenderDevice* dev = nullptr;
    if (opt.backend == "auto" || opt.backend == "vulkan") {
        dev = try_create("vulkan", win.hwnd, win.width, win.height);
        if (!dev && opt.backend == "vulkan") {
            std::printf("[错误] 指定了 Vulkan 但不可用\n");
            window_destroy(win);
            return 2;
        }
    }
    if (!dev) {
        if (opt.backend == "auto") std::printf("[回退] 改用 OpenGL\n");
        dev = try_create("gl", win.hwnd, win.width, win.height);
    }
    if (!dev) {
        std::printf("[错误] Vulkan 与 OpenGL 都不可用\n");
        window_destroy(win);
        return 3;
    }

    std::printf("[后端] %s\n", dev->backend_name());

    VoxelScene scene;
    MeshData mesh = build_voxel_mesh(scene);
    std::printf("[场景] %d×%d 体素列，%zu 顶点，%zu 三角形\n", scene.size_x, scene.size_z,
                mesh.vertices.size(), mesh.indices.size() / 3);
    dev->upload_mesh(mesh);

    const float center_x = float(scene.size_x) * 0.5f;
    const float center_z = float(scene.size_z) * 0.5f;
    const float center_y = 4.0f;

    using Clock = std::chrono::steady_clock;
    auto start = Clock::now();
    auto last_report = start;
    int frames_done = 0;
    int frames_since_report = 0;
    int cur_w = win.width;
    int cur_h = win.height;

    for (;;) {
        if (!window_pump(win, cur_w, cur_h)) break;

        const float t = std::chrono::duration<float>(Clock::now() - start).count();
        const float angle = t * 0.35f;
        const float radius = 34.0f;
        const float eye_x = center_x + std::cos(angle) * radius;
        const float eye_z = center_z + std::sin(angle) * radius;
        const float eye_y = 18.0f;

        Mat4 view = Mat4::look_at(eye_x, eye_y, eye_z, center_x, center_y, center_z, 0.0f, 1.0f, 0.0f);
        float aspect = cur_h > 0 ? float(cur_w) / float(cur_h) : 1.0f;
        Mat4 proj = Mat4::perspective(1.0f, aspect, 0.1f, 200.0f);
        Mat4 vp = Mat4::multiply(proj, view);

        FrameParams fp{};
        std::memcpy(fp.view_proj, vp.m, sizeof(fp.view_proj));
        fp.camera[0] = eye_x;
        fp.camera[1] = eye_y;
        fp.camera[2] = eye_z;
        fp.time_seconds = t;

        const char* cap = nullptr;
        if (!opt.shot.empty() && opt.frames > 0 && frames_done + 1 >= opt.frames) cap = opt.shot.c_str();
        dev->render_frame(fp, cap);

        frames_done++;
        frames_since_report++;
        auto now = Clock::now();
        double since = std::chrono::duration<double>(now - last_report).count();
        if (since >= 1.0) {
            std::printf("[帧] %d 累计 | %.1f fps | 分辨率 %dx%d\n", frames_done,
                        frames_since_report / since, cur_w, cur_h);
            last_report = now;
            frames_since_report = 0;
        }
        if (opt.frames > 0 && frames_done >= opt.frames) break;
    }

    dev->wait_idle();
    dev->shutdown();
    delete dev;
    window_destroy(win);

    double total = std::chrono::duration<double>(Clock::now() - start).count();
    std::printf("[完成] 后端=%s 帧=%d 用时=%.2fs 平均=%.1f fps\n", opt.backend.c_str(), frames_done, total,
                total > 0 ? frames_done / total : 0.0);
    return 0;
}
