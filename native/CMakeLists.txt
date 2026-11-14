cmake_minimum_required(VERSION 3.20)
project(block_programming_native LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

# ---- 着色器：Vulkan 侧要 SPIR-V，OpenGL 侧直接吃源码 ----
find_program(GLSLANG_VALIDATOR NAMES glslangValidator glslangValidator.exe)
if(GLSLANG_VALIDATOR)
  set(SHADER_OUT ${CMAKE_BINARY_DIR}/shaders)
  add_custom_command(
    OUTPUT ${SHADER_OUT}/chunk.vert.spv ${SHADER_OUT}/chunk.frag.spv
    COMMAND ${CMAKE_COMMAND} -E make_directory ${SHADER_OUT}
    COMMAND ${GLSLANG_VALIDATOR} -V -DVK ${CMAKE_CURRENT_SOURCE_DIR}/shaders/chunk.vert -o ${SHADER_OUT}/chunk.vert.spv
    COMMAND ${GLSLANG_VALIDATOR} -V -DVK ${CMAKE_CURRENT_SOURCE_DIR}/shaders/chunk.frag -o ${SHADER_OUT}/chunk.frag.spv
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            ${CMAKE_CURRENT_SOURCE_DIR}/shaders/chunk.vert
            ${CMAKE_CURRENT_SOURCE_DIR}/shaders/chunk.frag ${SHADER_OUT}
    DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/shaders/chunk.vert ${CMAKE_CURRENT_SOURCE_DIR}/shaders/chunk.frag
    COMMENT "编译 GLSL -> SPIR-V（Vulkan），并拷贝源码（OpenGL）"
  )
  add_custom_target(shaders DEPENDS ${SHADER_OUT}/chunk.vert.spv ${SHADER_OUT}/chunk.frag.spv)
else()
  message(WARNING "找不到 glslangValidator：跳过 SPIR-V 编译，Vulkan 后端会因缺 .spv 回退到 OpenGL")
endif()

add_executable(block_programming_native
  src/main.cpp
  src/platform_win32.cpp
  src/scene.cpp
  src/rhi_vulkan.cpp
  src/rhi_opengl.cpp
)

if(GLSLANG_VALIDATOR)
  add_dependencies(block_programming_native shaders)
endif()

if(WIN32)
  target_link_libraries(block_programming_native PRIVATE vulkan-1 opengl32 gdi32 user32)
else()
  # Linux/macOS 需要补平台窗口层（platform_x11.cpp / platform_cocoa.mm），这里先占位
  target_link_libraries(block_programming_native PRIVATE vulkan GL X11)
endif()

if(MSVC)
  target_compile_options(block_programming_native PRIVATE /W3)
else()
  target_compile_options(block_programming_native PRIVATE -Wall -Wextra
    -Wno-missing-field-initializers -Wno-cast-function-type)
endif()

