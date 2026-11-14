// 渲染后端抽象接口：上层（main / scene）只认这个，不知道下面是 Vulkan 还是 OpenGL。
#pragma once

#include <cstdint>
#include <string>
#include <vector>

struct Vertex {
    float x, y, z;   // 位置（米）
    float r, g, b;   // 顶点色（方块配色）
};

struct MeshData {
    std::vector<Vertex> vertices;
    std::vector<uint32_t> indices;
};

struct FrameParams {
    float view_proj[16];   // 列主序
    float camera[3];       // 相机世界坐标（shader 里算雾）
    float time_seconds;    // 保留给后续动画用
};

class RenderDevice {
public:
    virtual ~RenderDevice() = default;

    // native_window: Windows 下是 HWND。失败时把原因写进 err 并返回 false（上层据此回退）。
    virtual bool init(void* native_window, int width, int height, std::string& err) = 0;
    virtual void upload_mesh(const MeshData& mesh) = 0;
    // capture_bmp 非空时，画完这一帧后把它写成 24 位 BMP（用于肉眼/自动验证）
    virtual void render_frame(const FrameParams& params, const char* capture_bmp) = 0;
    virtual void wait_idle() = 0;
    virtual const char* backend_name() const = 0;
    virtual void shutdown() = 0;
};

RenderDevice* create_vulkan_device();
RenderDevice* create_opengl_device();
