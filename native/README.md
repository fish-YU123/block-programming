# native/ — 不用 Godot 的渲染原型

同一份 `RenderDevice` 接口，两个后端：**Vulkan 优先，失败回退 OpenGL**。只依赖系统 DLL，不需要引擎。

## 构建（Windows / MinGW）

```sh
./build.sh
```

依赖（MSYS2 ucrt64）：

```sh
pacman -S mingw-w64-ucrt-x86_64-gcc \
         mingw-w64-ucrt-x86_64-glslang \
         mingw-w64-ucrt-x86_64-vulkan-headers \
         mingw-w64-ucrt-x86_64-vulkan-loader
```

或者用 CMake：

```sh
cmake -S . -B build-cmake -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build-cmake
```

## 运行

```sh
./build/block_programming_native.exe                     # auto：先 Vulkan，失败回退 GL
./build/block_programming_native.exe --backend=vulkan    # 指定后端（失败直接报错，不回退）
./build/block_programming_native.exe --backend=gl
./build/block_programming_native.exe --frames=30         # 跑 30 帧退出（自动测试用）
./build/block_programming_native.exe --frames=30 --shot=out.bmp   # 最后一帧存 BMP
./build/block_programming_native.exe --width=1920 --height=1080
```

输出示例：

```
[后端] vulkan
[场景] 32×32 体素列，6964 顶点，3482 三角形
[帧] 30 累计 | 34.2 fps | 分辨率 1280x720
[完成] 后端=vulkan 帧=30 用时=0.88s 平均=34.2 fps
```

## 结构

| 文件 | 作用 |
| --- | --- |
| `src/rhi.h` | 后端接口：`init / upload_mesh / render_frame / wait_idle / shutdown` |
| `src/rhi_vulkan.cpp` | instance → 物理设备（独显优先）→ 设备/队列 → Win32 surface → swapchain → 深度 → render pass → 管线 → 双帧同步 → 截帧（`vkCmdCopyImageToBuffer`） |
| `src/rhi_opengl.cpp` | WGL 4.5 Core + 运行时加载函数指针（不依赖 GLAD/GLEW）+ `glReadPixels` 截帧 |
| `src/platform_win32.*` | 窗口与消息泵 |
| `src/scene.*` | 体素网格生成（只生成暴露面，配色对齐 `data/blocks/*.json` 的观感） |
| `src/mathx.h` | 最小 4×4 矩阵（列主序） |
| `src/bmp.h` | 无依赖 BMP 写出 |
| `shaders/chunk.vert` `chunk.frag` | 一份 GLSL：`#ifdef VK` 走 descriptor set，否则普通 uniform |

## 已知坑（都踩过）

- Vulkan 的 NDC 与 GL 的 Y 方向相反：Vulkan 用负高度视口，GL 侧对投影矩阵第 1 行取负。
- GL 对 UBO 成员用 `glGetUniformLocation("Block.member")` 查询在部分驱动上返回 -1，所以 GL 路径改用普通 uniform。
- 着色器文件不能带 UTF-8 BOM，GL 驱动会报 `illegal non-ASCII character (0xef)`。
- swapchain 用 sRGB 格式会把线性色提亮，和 GL 对不上；原型选 UNORM。
- `-lvulkan` 在 MSYS2 上找不到，导入库名是 `-lvulkan-1`。

## 还没做

- 多 chunk 批处理 / 实例化 / 纹理图集 / 阴影
- 窗口缩放时的 swapchain 重建（原型只处理了固定尺寸）
- Linux（X11/Wayland）与 macOS（Cocoa/Metal）窗口层
- 音频、输入映射、UI —— 这些是"替换 Godot"真正的大头，见 `docs/无Godot渲染方案.md`
