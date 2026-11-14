// OpenGL 3.3/4.5 Core 后端：WGL 建上下文 + 运行时取函数指针（不依赖 GLAD/GLEW）。
// 与 Vulkan 后端共用同一份 GLSL（Vulkan 侧编译成 SPIR-V，这里直接编译源码）。
#include "rhi.h"

#include <windows.h>
#include <GL/gl.h>

#include <cstddef>
#include <cstdio>
#include "bmp.h"
#include <cstring>
#include <string>
#include <vector>

// ---- 需要的 GL 3.x 入口（<GL/gl.h> 只有 1.1） ----
typedef unsigned int GLuint_;
typedef int GLint_;
typedef int GLsizei_;
typedef unsigned int GLenum_;
typedef char GLchar_;
typedef ptrdiff_t GLsizeiptr_;
typedef ptrdiff_t GLintptr_;

#define GL_ARRAY_BUFFER 0x8892
#define GL_ELEMENT_ARRAY_BUFFER 0x8893
#define GL_STATIC_DRAW 0x88E4
#define GL_VERTEX_SHADER 0x8B31
#define GL_FRAGMENT_SHADER 0x8B30
#define GL_COMPILE_STATUS 0x8B81
#define GL_LINK_STATUS 0x8B82
#define GL_INFO_LOG_LENGTH 0x8B84
#define GL_DEPTH_TEST 0x0B71
#define GL_LEQUAL 0x0203
#define GL_COLOR_BUFFER_BIT 0x00004000
#define GL_DEPTH_BUFFER_BIT 0x00000100
#define GL_TRIANGLES 0x0004
#define GL_UNSIGNED_INT 0x1405
#define GL_FLOAT 0x1406
#define GL_VERSION 0x1F02
#define GL_RENDERER 0x1F01

namespace {

typedef void (*PFN_glGenVertexArrays)(GLsizei_, GLuint_*);
typedef void (*PFN_glBindVertexArray)(GLuint_);
typedef void (*PFN_glDeleteVertexArrays)(GLsizei_, const GLuint_*);
typedef void (*PFN_glGenBuffers)(GLsizei_, GLuint_*);
typedef void (*PFN_glBindBuffer)(GLenum_, GLuint_);
typedef void (*PFN_glBufferData)(GLenum_, GLsizeiptr_, const void*, GLenum_);
typedef void (*PFN_glDeleteBuffers)(GLsizei_, const GLuint_*);
typedef void (*PFN_glVertexAttribPointer)(GLuint_, GLint_, GLenum_, GLboolean, GLsizei_, const void*);
typedef void (*PFN_glEnableVertexAttribArray)(GLuint_);
typedef GLuint_ (*PFN_glCreateShader)(GLenum_);
typedef void (*PFN_glShaderSource)(GLuint_, GLsizei_, const GLchar_* const*, const GLint_*);
typedef void (*PFN_glCompileShader)(GLuint_);
typedef void (*PFN_glGetShaderiv)(GLuint_, GLenum_, GLint_*);
typedef void (*PFN_glGetShaderInfoLog)(GLuint_, GLsizei_, GLsizei_*, GLchar_*);
typedef void (*PFN_glDeleteShader)(GLuint_);
typedef GLuint_ (*PFN_glCreateProgram)(void);
typedef void (*PFN_glAttachShader)(GLuint_, GLuint_);
typedef void (*PFN_glLinkProgram)(GLuint_);
typedef void (*PFN_glGetProgramiv)(GLuint_, GLenum_, GLint_*);
typedef void (*PFN_glGetProgramInfoLog)(GLuint_, GLsizei_, GLsizei_*, GLchar_*);
typedef void (*PFN_glUseProgram)(GLuint_);
typedef void (*PFN_glDeleteProgram)(GLuint_);
typedef GLint_ (*PFN_glGetUniformLocation)(GLuint_, const GLchar_*);
typedef void (*PFN_glUniformMatrix4fv)(GLint_, GLsizei_, GLboolean, const GLfloat*);
typedef void (*PFN_glUniform4fv)(GLint_, GLsizei_, const GLfloat*);
typedef HGLRC (*PFN_wglCreateContextAttribsARB)(HDC, HGLRC, const int*);

struct GlApi {
    PFN_glGenVertexArrays gen_va = nullptr;
    PFN_glBindVertexArray bind_va = nullptr;
    PFN_glDeleteVertexArrays del_va = nullptr;
    PFN_glGenBuffers gen_buf = nullptr;
    PFN_glBindBuffer bind_buf = nullptr;
    PFN_glBufferData buf_data = nullptr;
    PFN_glDeleteBuffers del_buf = nullptr;
    PFN_glVertexAttribPointer attrib_ptr = nullptr;
    PFN_glEnableVertexAttribArray enable_attrib = nullptr;
    PFN_glCreateShader create_shader = nullptr;
    PFN_glShaderSource shader_src = nullptr;
    PFN_glCompileShader compile_shader = nullptr;
    PFN_glGetShaderiv get_shader_iv = nullptr;
    PFN_glGetShaderInfoLog shader_log = nullptr;
    PFN_glDeleteShader del_shader = nullptr;
    PFN_glCreateProgram create_program = nullptr;
    PFN_glAttachShader attach = nullptr;
    PFN_glLinkProgram link = nullptr;
    PFN_glGetProgramiv get_program_iv = nullptr;
    PFN_glGetProgramInfoLog program_log = nullptr;
    PFN_glUseProgram use_program = nullptr;
    PFN_glDeleteProgram del_program = nullptr;
    PFN_glGetUniformLocation uniform_loc = nullptr;
    PFN_glUniformMatrix4fv uniform_mat4 = nullptr;
    PFN_glUniform4fv uniform_vec4 = nullptr;

    template <typename T>
    bool load(T& fn, const char* name) {
        fn = reinterpret_cast<T>(wglGetProcAddress(name));
        return fn != nullptr;
    }
};

std::string exe_dir() {
    wchar_t buf[MAX_PATH * 2];
    DWORD n = GetModuleFileNameW(nullptr, buf, MAX_PATH * 2);
    if (n == 0) return ".";
    std::wstring w(buf, n);
    size_t slash = w.find_last_of(L"\\/");
    std::string out;
    if (slash == std::wstring::npos) return ".";
    for (size_t i = 0; i < slash; ++i) out.push_back(w[i] < 128 ? char(w[i]) : '?');
    return out;
}

bool read_text(const std::string& path, std::string& out) {
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return false;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    out.resize(size_t(size));
    size_t got = fread(&out[0], 1, out.size(), f);
    fclose(f);
    return got == out.size();
}

bool load_shader_source(const char* name, std::string& out) {
    std::vector<std::string> candidates = {
        exe_dir() + "/shaders/" + name,
        exe_dir() + "/../shaders/" + name,
        std::string("native/shaders/") + name,
        std::string("../native/shaders/") + name,
        std::string("shaders/") + name,
    };
    for (const auto& c : candidates) {
        if (read_text(c, out)) return true;
    }
    return false;
}

class GlDevice : public RenderDevice {
public:
    bool init(void* native_window, int width, int height, std::string& err) override;
    void upload_mesh(const MeshData& mesh) override;
    void render_frame(const FrameParams& params, const char* capture_bmp) override;
    void wait_idle() override;
    const char* backend_name() const override { return "opengl"; }
    void shutdown() override;

private:
    bool load_api(std::string& err);
    GLuint_ compile(GLenum_ type, const std::string& src, const char* label, std::string& err);

    HWND hwnd_ = nullptr;
    HDC dc_ = nullptr;
    HGLRC rc_ = nullptr;
    GlApi api_;
    GLuint_ vao_ = 0, vbo_ = 0, ibo_ = 0, program_ = 0;
    GLint_ loc_viewproj_ = -1, loc_camera_ = -1;
    uint32_t index_count_ = 0;
};

bool GlDevice::init(void* native_window, int width, int height, std::string& err) {
    (void)width;
    (void)height;
    hwnd_ = static_cast<HWND>(native_window);
    dc_ = GetDC(hwnd_);
    if (!dc_) { err = "GetDC 失败"; return false; }

    PIXELFORMATDESCRIPTOR pfd{};
    pfd.nSize = sizeof(pfd);
    pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA;
    pfd.cColorBits = 32;
    pfd.cDepthBits = 24;
    pfd.iLayerType = PFD_MAIN_PLANE;
    int pf = ChoosePixelFormat(dc_, &pfd);
    if (!pf || !SetPixelFormat(dc_, pf, &pfd)) { err = "像素格式设置失败"; return false; }

    // 先用临时上下文拿到 wglCreateContextAttribsARB，再建 4.5 Core
    HGLRC temp = wglCreateContext(dc_);
    if (!temp) { err = "wglCreateContext 失败"; return false; }
    wglMakeCurrent(dc_, temp);

    auto create_attribs = reinterpret_cast<PFN_wglCreateContextAttribsARB>(wglGetProcAddress("wglCreateContextAttribsARB"));
    if (create_attribs) {
        const int attribs[] = {
            0x2091 /*WGL_CONTEXT_MAJOR_VERSION_ARB*/, 4,
            0x2092 /*WGL_CONTEXT_MINOR_VERSION_ARB*/, 5,
            0x9126 /*WGL_CONTEXT_PROFILE_MASK_ARB*/, 0x0001 /*CORE*/,
            0,
        };
        HGLRC core = create_attribs(dc_, nullptr, attribs);
        if (core) {
            wglMakeCurrent(nullptr, nullptr);
            wglDeleteContext(temp);
            rc_ = core;
            wglMakeCurrent(dc_, rc_);
        } else {
            rc_ = temp;
        }
    } else {
        rc_ = temp;   // 老驱动：退回兼容上下文
    }

    if (!load_api(err)) return false;

    const char* ver = reinterpret_cast<const char*>(glGetString(GL_VERSION));
    printf("[gl] 上下文就绪：%s\n", ver ? ver : "?");

    std::string vert_src, frag_src;
    if (!load_shader_source("chunk.vert", vert_src)) { err = "找不到 native/shaders/chunk.vert"; return false; }
    if (!load_shader_source("chunk.frag", frag_src)) { err = "找不到 native/shaders/chunk.frag"; return false; }

    GLuint_ vs = compile(GL_VERTEX_SHADER, vert_src, "chunk.vert", err);
    if (!vs) return false;
    GLuint_ fs = compile(GL_FRAGMENT_SHADER, frag_src, "chunk.frag", err);
    if (!fs) return false;

    program_ = api_.create_program();
    api_.attach(program_, vs);
    api_.attach(program_, fs);
    api_.link(program_);
    GLint_ ok = 0;
    api_.get_program_iv(program_, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[2048] = {0};
        GLsizei_ len = 0;
        api_.program_log(program_, 2048, &len, log);
        err = std::string("链接失败：") + log;
        return false;
    }
    api_.del_shader(vs);
    api_.del_shader(fs);

    loc_viewproj_ = api_.uniform_loc(program_, "u_view_proj");
    loc_camera_ = api_.uniform_loc(program_, "u_camera");

    api_.gen_va(1, &vao_);
    api_.gen_buf(1, &vbo_);
    api_.gen_buf(1, &ibo_);

    glEnable(GL_DEPTH_TEST);
    glDepthFunc(GL_LEQUAL);
    glClearColor(0.55f, 0.72f, 0.92f, 1.0f);
    return true;
}

bool GlDevice::load_api(std::string& err) {
    bool ok = true;
    ok &= api_.load(api_.gen_va, "glGenVertexArrays");
    ok &= api_.load(api_.bind_va, "glBindVertexArray");
    ok &= api_.load(api_.del_va, "glDeleteVertexArrays");
    ok &= api_.load(api_.gen_buf, "glGenBuffers");
    ok &= api_.load(api_.bind_buf, "glBindBuffer");
    ok &= api_.load(api_.buf_data, "glBufferData");
    ok &= api_.load(api_.del_buf, "glDeleteBuffers");
    ok &= api_.load(api_.attrib_ptr, "glVertexAttribPointer");
    ok &= api_.load(api_.enable_attrib, "glEnableVertexAttribArray");
    ok &= api_.load(api_.create_shader, "glCreateShader");
    ok &= api_.load(api_.shader_src, "glShaderSource");
    ok &= api_.load(api_.compile_shader, "glCompileShader");
    ok &= api_.load(api_.get_shader_iv, "glGetShaderiv");
    ok &= api_.load(api_.shader_log, "glGetShaderInfoLog");
    ok &= api_.load(api_.del_shader, "glDeleteShader");
    ok &= api_.load(api_.create_program, "glCreateProgram");
    ok &= api_.load(api_.attach, "glAttachShader");
    ok &= api_.load(api_.link, "glLinkProgram");
    ok &= api_.load(api_.get_program_iv, "glGetProgramiv");
    ok &= api_.load(api_.program_log, "glGetProgramInfoLog");
    ok &= api_.load(api_.use_program, "glUseProgram");
    ok &= api_.load(api_.del_program, "glDeleteProgram");
    ok &= api_.load(api_.uniform_loc, "glGetUniformLocation");
    ok &= api_.load(api_.uniform_mat4, "glUniformMatrix4fv");
    ok &= api_.load(api_.uniform_vec4, "glUniform4fv");
    if (!ok) err = "OpenGL 函数指针加载失败（驱动太老或不是 Core Profile）";
    return ok;
}

GLuint_ GlDevice::compile(GLenum_ type, const std::string& src, const char* label, std::string& err) {
    GLuint_ sh = api_.create_shader(type);
    const GLchar_* p = src.c_str();
    GLint_ len = GLint_(src.size());
    api_.shader_src(sh, 1, &p, &len);
    api_.compile_shader(sh);
    GLint_ ok = 0;
    api_.get_shader_iv(sh, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[2048] = {0};
        GLsizei_ n = 0;
        api_.shader_log(sh, 2048, &n, log);
        err = std::string(label) + " 编译失败：" + log;
        return 0;
    }
    return sh;
}

void GlDevice::upload_mesh(const MeshData& mesh) {
    index_count_ = uint32_t(mesh.indices.size());
    api_.bind_va(vao_);
    api_.bind_buf(GL_ARRAY_BUFFER, vbo_);
    api_.buf_data(GL_ARRAY_BUFFER, GLsizeiptr_(mesh.vertices.size() * sizeof(Vertex)), mesh.vertices.data(), GL_STATIC_DRAW);
    api_.bind_buf(GL_ELEMENT_ARRAY_BUFFER, ibo_);
    api_.buf_data(GL_ELEMENT_ARRAY_BUFFER, GLsizeiptr_(mesh.indices.size() * sizeof(uint32_t)), mesh.indices.data(), GL_STATIC_DRAW);

    api_.enable_attrib(0);
    api_.attrib_ptr(0, 3, GL_FLOAT, GL_FALSE, sizeof(Vertex), reinterpret_cast<const void*>(offsetof(Vertex, x)));
    api_.enable_attrib(1);
    api_.attrib_ptr(1, 3, GL_FLOAT, GL_FALSE, sizeof(Vertex), reinterpret_cast<const void*>(offsetof(Vertex, r)));
    api_.bind_va(0);
}

void GlDevice::render_frame(const FrameParams& params, const char* capture_bmp) {
    RECT rc{};
    GetClientRect(hwnd_, &rc);
    int w = rc.right - rc.left, h = rc.bottom - rc.top;
    if (w <= 0 || h <= 0) return;
    glViewport(0, 0, w, h);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

    // GL 的 NDC 与 Vulkan 相反：这里把投影矩阵第 1 行取负（等价于 Y 翻转）
    float vp[16];
    std::memcpy(vp, params.view_proj, sizeof(vp));
    vp[1] = -vp[1];
    vp[5] = -vp[5];
    vp[9] = -vp[9];
    vp[13] = -vp[13];

    api_.use_program(program_);
    if (loc_viewproj_ >= 0) api_.uniform_mat4(loc_viewproj_, 1, GL_FALSE, vp);
    if (loc_camera_ >= 0) {
        float cam[4] = {params.camera[0], params.camera[1], params.camera[2], params.time_seconds};
        api_.uniform_vec4(loc_camera_, 1, cam);
    }
    api_.bind_va(vao_);
    glDrawElements(GL_TRIANGLES, GLsizei_(index_count_), GL_UNSIGNED_INT, nullptr);
    api_.bind_va(0);

    if (capture_bmp) {
        std::vector<uint8_t> rgba(size_t(w) * size_t(h) * 4);
        glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, rgba.data());
        if (write_bmp_rgba(capture_bmp, rgba, w, h)) {
            printf("[截图] %s (%dx%d)\n", capture_bmp, w, h);
        } else {
            printf("[截图] 写入失败：%s\n", capture_bmp);
        }
    }
    SwapBuffers(dc_);
}

void GlDevice::wait_idle() { glFinish(); }

void GlDevice::shutdown() {
    if (rc_) {
        wglMakeCurrent(dc_, rc_);
        if (program_) api_.del_program(program_);
        if (vbo_) api_.del_buf(1, &vbo_);
        if (ibo_) api_.del_buf(1, &ibo_);
        if (vao_) api_.del_va(1, &vao_);
        wglMakeCurrent(nullptr, nullptr);
        wglDeleteContext(rc_);
        rc_ = nullptr;
    }
    if (dc_) { ReleaseDC(hwnd_, dc_); dc_ = nullptr; }
}

}  // namespace

RenderDevice* create_opengl_device() { return new GlDevice(); }
