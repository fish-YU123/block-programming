#version 450
// 体素面片着色：顶点色 + 简单雾化。Vulkan 与 OpenGL 共用同一份源码：
//   Vulkan 用 -DVK（descriptor set + UBO），OpenGL 用普通 uniform（兼容性最好）。
layout(location = 0) in vec3 a_pos;
layout(location = 1) in vec3 a_color;

#ifdef VK
layout(set = 0, binding = 0) uniform SceneUbo {
    mat4 view_proj;
    vec4 camera;      // xyz = 相机位置，w = 时间
} ubo;
#define VP ubo.view_proj
#define CAM ubo.camera
#else
uniform mat4 u_view_proj;
uniform vec4 u_camera;
#define VP u_view_proj
#define CAM u_camera
#endif

layout(location = 0) out vec3 v_color;
layout(location = 1) out float v_dist;

void main() {
    v_color = a_color;
    v_dist = length(a_pos - CAM.xyz);
    gl_Position = VP * vec4(a_pos, 1.0);
}
