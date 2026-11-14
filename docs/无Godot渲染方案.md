# 不用 Godot 的渲染方案（Vulkan 优先 / OpenGL 回退）

> 状态：**可行性原型已跑通**（分支 `no-godot-vulkan`，代码在 `native/`）。
> 结论先说：技术上成立，成本上很贵——本文件量化这个"很贵"到底是多少，以及哪条路更划算。

## 1. 一句话结论

"自己写渲染层，Vulkan 优先、OpenGL 回退"这件事本身没有技术障碍，原型 600 多行 C++ 就同时跑通了两个后端（同一份 GLSL、同一个场景，截图见 `docs/preview-native-*.png`）。

但把它当成**替换 Godot 的路线**，真正的工作量不在渲染，而在渲染之外：编辑器、资源导入、物理、UI、输入、音频、导出、调试工具——这些 Godot 现在全包了。粗估 **10～16 人月**才到"能替代当前这个项目"的程度，纯渲染部分只占其中 2～3 人月。

## 2. 原型实测（本机，2026-11-14）

| 项 | Vulkan 后端 | OpenGL 后端 |
| --- | --- | --- |
| API 版本 | 1.1 实例 / 1.3–1.4 设备 | 4.5 Core（WGL） |
| 选中的 GPU | NVIDIA MX450（打分优先独显） | Intel Iris Xe（随驱动） |
| 场景 | 32×32 体素列，6964 顶点 / 3482 三角形 | 同一份网格 |
| 30 帧耗时 | 0.88 s（≈34 fps） | 0.08 s（≈355 fps） |
| 说明 | 双帧在飞 + 每帧 fence 等待 + 首帧管线创建，属"能跑"级别 | 单线程即时提交，没有换取队列深度 |

两者画面一致（`native/build/shot-vulkan.png` / `shot-opengl.png`），说明 RHI 抽象层是有效的：上层只认 `RenderDevice`，不知道下面是哪个 API。

Vulkan 那边的 34 fps 不是上限，只是原型没有做多帧并行录制、没有做 descriptor 复用、每帧都在等 fence——这些正是"自己写渲染器"要持续投入的地方。

## 3. 架构：RHI 抽象层

原型的分层（`native/src/`）：

```
main.cpp            应用循环、相机、参数解析（--backend=auto|vulkan|gl）
  ↓ 只依赖 rhi.h
rhi.h               RenderDevice 接口：init / upload_mesh / render_frame / shutdown
  ↓ 两个实现
rhi_vulkan.cpp      instance → 物理设备（独显优先）→ 设备/队列 → Win32 surface
                    → swapchain → 深度 → render pass → 管线（SPIR-V）→ 双帧同步
rhi_opengl.cpp      WGL 4.5 Core → 运行时取函数指针 → VBO/VAO → 程序对象（GLSL 源码）
```

关键设计点，这些在真项目里同样成立：

1. **接口只暴露"网格 + 一帧参数"**，不泄露任何 API 类型；换后端不改上层。
2. **一份 GLSL，两条编译路**：`#ifdef VK` 分支写 descriptor set，否则用普通 uniform；Vulkan 侧用 `glslangValidator -V -DVK` 出 SPIR-V，OpenGL 侧直接编译源码。原型里踩到的坑：GL 对 UBO 的 `glGetUniformLocation` 在不同驱动上行为不一致（返回 -1），所以 OpenGL 路径改用普通 uniform，稳。
3. **能力探测 + 降级**：`--backend=auto` 先试 Vulkan，`vkCreateInstance`/物理设备/队列/swapchain 任一步失败就打印原因并回退 OpenGL。真项目里这一层要扩成"特性档位"（feature level）：无 geometry shader、无 compute、无 bindless……按档位裁剪渲染路径。
4. **坐标系差异集中在后端**：Vulkan 用负高度视口翻转 Y，OpenGL 侧对投影矩阵第 1 行取负。上层永远用同一套右手系矩阵。
5. **截帧验证内建**：`--shot=out.bmp` 让两个后端各写一张 24 位 BMP（Vulkan 走 `vkCmdCopyImageToBuffer`，GL 走 `glReadPixels`）。没有这个，跨后端一致性问题很难定位——原型就是靠它发现 GL 路径一开始整屏空白。

## 4. Godot 现在替你做的事，替换要补什么

| 能力 | Godot 现状 | 自研代价 | 建议 |
| --- | --- | --- | --- |
| 渲染 | Forward+ 每帧上百 draw call、阴影、材质系统 | 2～3 人月（本原型是"能画一个 chunk"，不是引擎） | 自研 |
| 窗口/输入 | 一套 API 三平台 | 1～2 人月（Win32 已写；X11/Wayland/Cocoa 待做） | 自研或 SDL3 |
| 物理 | GodotPhysics/Jolt，刚体、射线、碰撞层 | 2～3 人月，或直接接 Jolt | 用 Jolt |
| UI | Control 节点 + 主题 | 2 人月（代码面板是个真文本编辑器） | 用 ImGui |
| 资源导入 | 编辑器一键导入、热重载 | 1～2 人月 | 自研最小版 |
| 音频 | AudioStreamPlayer | 0.5 人月 | miniaudio |
| 编辑器 | 场景编辑、运行即改 | 3 人月以上（本项目其实不怎么用场景编辑，可省） | 放弃，走纯代码 |
| 导出/打包 | 一键出 Win/mac/Linux | 1 人月 | CPack/自写脚本 |
| 脚本语言 | 已有自研字节码 VM | 0（本项目本来就不依赖 GDScript 写玩法） | 直接迁 |

注意最后一行：**这个项目最值钱的部分是它自己的 VM 和玩法数据（JSON），这两块和引擎无关**，换引擎不用重写。

## 5. 风险清单

1. **没有编辑器 → 迭代变慢**。现在改数值/看效果靠 Godot 编辑器，自研后全靠代码 + 热重载，得有替代方案（ImGui 调试面板 + 命令行）。
2. **Vulkan 驱动碎片**。原型在 Intel/NVIDIA 双卡机器上一次过，但老 Intel 核显、无 Vulkan 的 Win7、Linux 上的 Mesa 组合都要覆盖；这正是 GL 回退存在的意义，也是要持续维护两条路径的代价。
3. **GL 回退的坑**（原型已踩）：UBO 查询不一致、Core Profile 函数指针要自己加载、sRGB/UNORM 色彩差异、Y 轴翻转。每加一个渲染特性都要做两遍。
4. **调试工具缺失**。RenderDoc 能抓 Vulkan/GL，但 Godot 自带的 Remote Inspector、性能面板、场景树都没有了。
5. **跨平台窗口层**。原型只有 Win32。Linux 要 X11 + Wayland 两套，macOS 要 Cocoa + Metal 才有好性能（Vulkan 在 mac 上只有 MoltenVK）。
6. **人力连续性**。引擎层是长期资产，写它的人走了就是负债。

## 6. 三条路线对比

| 路线 | 工作量 | 风险 | 适合谁 |
| --- | --- | --- | --- |
| A. 留在 Godot | 0（现状） | 受引擎限制：想改渲染管线、想减包体、想接自研 VM 到渲染层，都要绕 | 想继续做玩法 |
| B. 自研 Vulkan + OpenGL 双后端（本原型） | 10～16 人月到可替代 | 高：两条渲染路径 + 三平台窗口 + 无编辑器 | 有图形人力、想做长期引擎 |
| C. 自研但基于现成 RHI（wgpu / bgfx / SDL3 GPU） | 5～8 人月 | 中：RHI 帮你处理 Vulkan/GL/Metal/D3D 回退 | 想要"自己的引擎"但不想维护双后端 |

**如果目标只是"不用 Godot"**，C 比 B 划算得多：wgpu 本身就是 Vulkan 优先、GL/GLES 回退、mac 走 Metal，你写一套 `wgpu` 调用就拿到四个后端；bgfx 更老但同样的思路；SDL3 的 GPU API 也在收敛。**B 的价值只在于"完全掌控"**，代价是不管驱动怎么变都得自己扛。

## 7. 本分支里有什么

```
native/
  build.sh                    MinGW + glslang 一键构建（Windows）
  CMakeLists.txt              CMake 构建（Ninja/MSVC 都行）
  src/rhi.h                   渲染后端接口
  src/rhi_vulkan.cpp          Vulkan 后端（真实 swapchain/管线/同步/截帧）
  src/rhi_opengl.cpp          OpenGL 后端（WGL Core + 运行时函数指针）
  src/platform_win32.*        Win32 窗口与消息泵
  src/scene.*                 体素网格生成（只生成暴露面）
  src/mathx.h                 最小矩阵库
  src/bmp.h                   无依赖 BMP 写出
  shaders/chunk.vert|frag     一份 GLSL，两条编译路
```

跑起来：

```sh
cd native
./build.sh
./build/block_programming_native.exe                    # auto：先 Vulkan，失败回退 OpenGL
./build/block_programming_native.exe --backend=gl
./build/block_programming_native.exe --frames=30 --shot=out.bmp
```

依赖（MSYS2 ucrt64）：`g++`、`glslang`、`vulkan-headers`、`vulkan-loader`。Linux 侧窗口层还没做，`rhi_*` 与平台无关，只需补一个 `platform_x11.cpp`。

## 8. 建议的下一步（真要往这条走的话）

1. 先做**路线 C 的 spike**：用 wgpu 把同一片体素地形画出来，比较开发速度与跨平台成本，再决定要不要自己扛双后端。
2. 无论走 B 还是 C，先把**玩法和 VM 从 Godot API 里解耦**（现在 `main.gd` 2400 行把渲染、输入、经济、联机搅在一起），这部分重构在哪个路线都得做，且对现游戏无副作用。
3. 渲染层优先补：多 chunk 批处理、实例化、图集纹理、阴影——这四个决定"像不像一个体素游戏"。
