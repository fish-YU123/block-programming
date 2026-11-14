// Vulkan 后端：instance → 物理设备（优先独显）→ 设备/队列 → Win32 surface → swapchain
// → 深度缓冲 → render pass → 图形管线（SPIR-V）→ 顶点/索引/UBO → 双帧在飞。
#include "rhi.h"

#include <windows.h>
#define VK_USE_PLATFORM_WIN32_KHR
#include <vulkan/vulkan.h>

#include <cstddef>
#include <cstring>
#include <string>

#include "bmp.h"
#include <string>
#include <vector>

namespace {

constexpr int kMaxFrames = 2;

struct UboData {
    float view_proj[16];
    float camera[4];
};

std::string exe_dir() {
    wchar_t buf[MAX_PATH * 2];
    DWORD n = GetModuleFileNameW(nullptr, buf, MAX_PATH);
    if (n == 0) return ".";
    std::wstring w(buf, n);
    size_t slash = w.find_last_of(L"\\/");
    if (slash == std::wstring::npos) return ".";
    std::wstring dir = w.substr(0, slash);
    // 宽字符转 UTF-8（路径基本是 ASCII，简单截断即可）
    std::string out;
    for (wchar_t c : dir) out.push_back(c < 128 ? char(c) : '?');
    return out;
}

bool read_file(const std::string& path, std::vector<char>& out) {
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return false;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    out.resize(size_t(size));
    size_t got = fread(out.data(), 1, out.size(), f);
    fclose(f);
    return got == out.size();
}

bool load_spirv(const char* name, std::vector<char>& out, std::string& err) {
    std::vector<std::string> candidates = {
        exe_dir() + "/shaders/" + name,
        exe_dir() + "/../shaders/" + name,
        std::string("native/shaders/") + name,
        std::string("../native/shaders/") + name,
        std::string("shaders/") + name,
    };
    for (const auto& c : candidates) {
        if (read_file(c, out)) return true;
    }
    err = std::string("找不到 SPIR-V：") + name + "（先跑 native/build.sh 编译着色器）";
    return false;
}

class VulkanDevice : public RenderDevice {
public:
    bool init(void* native_window, int width, int height, std::string& err) override;
    void upload_mesh(const MeshData& mesh) override;
    void render_frame(const FrameParams& params, const char* capture_bmp) override;
    bool ensure_capture_buffer(std::string& err);
    void wait_idle() override;
    const char* backend_name() const override { return "vulkan"; }
    void shutdown() override;

private:
    bool create_instance(std::string& err);
    bool pick_physical(std::string& err);
    bool create_device(std::string& err);
    bool create_swapchain(std::string& err);
    bool create_depth(std::string& err);
    bool create_render_pass(std::string& err);
    bool create_pipeline(std::string& err);
    bool create_buffers(std::string& err);
    bool create_sync(std::string& err);
    void destroy_swapchain();
    uint32_t find_memory_type(uint32_t type_bits, VkMemoryPropertyFlags props) const;
    VkCommandBuffer begin_single_time();

    HWND hwnd_ = nullptr;
    int width_ = 0;
    int height_ = 0;

    VkInstance instance_ = VK_NULL_HANDLE;
    VkSurfaceKHR surface_ = VK_NULL_HANDLE;
    VkPhysicalDevice phys_ = VK_NULL_HANDLE;
    VkDevice device_ = VK_NULL_HANDLE;
    VkQueue queue_ = VK_NULL_HANDLE;
    uint32_t queue_family_ = 0;
    VkPhysicalDeviceMemoryProperties mem_props_{};

    VkSwapchainKHR swapchain_ = VK_NULL_HANDLE;
    VkFormat color_format_ = VK_FORMAT_B8G8R8A8_UNORM;
    VkExtent2D extent_{0, 0};
    std::vector<VkImage> images_;
    std::vector<VkImageView> views_;
    std::vector<VkFramebuffer> framebuffers_;

    VkImage depth_image_ = VK_NULL_HANDLE;
    VkDeviceMemory depth_mem_ = VK_NULL_HANDLE;
    VkImageView depth_view_ = VK_NULL_HANDLE;

    VkRenderPass render_pass_ = VK_NULL_HANDLE;
    VkPipelineLayout pipeline_layout_ = VK_NULL_HANDLE;
    VkPipeline pipeline_ = VK_NULL_HANDLE;
    VkDescriptorSetLayout set_layout_ = VK_NULL_HANDLE;
    VkDescriptorPool desc_pool_ = VK_NULL_HANDLE;
    VkDescriptorSet desc_set_ = VK_NULL_HANDLE;

    VkBuffer vbo_ = VK_NULL_HANDLE;
    VkDeviceMemory vbo_mem_ = VK_NULL_HANDLE;
    VkBuffer ibo_ = VK_NULL_HANDLE;
    VkDeviceMemory ibo_mem_ = VK_NULL_HANDLE;
    uint32_t index_count_ = 0;

    VkBuffer ubo_ = VK_NULL_HANDLE;
    VkDeviceMemory ubo_mem_ = VK_NULL_HANDLE;
    void* ubo_mapped_ = nullptr;

    VkCommandPool cmd_pool_ = VK_NULL_HANDLE;
    std::vector<VkCommandBuffer> cmd_bufs_;
    VkSemaphore sem_image_[kMaxFrames]{};
    VkSemaphore sem_render_[kMaxFrames]{};
    VkBuffer cap_buf_ = VK_NULL_HANDLE;
    VkDeviceMemory cap_mem_ = VK_NULL_HANDLE;
    void* cap_mapped_ = nullptr;
    VkDeviceSize cap_size_ = 0;
    VkFence fences_[kMaxFrames]{};
    uint32_t frame_ = 0;
};

bool VulkanDevice::init(void* native_window, int width, int height, std::string& err) {
    hwnd_ = static_cast<HWND>(native_window);
    width_ = width;
    height_ = height;
    if (!create_instance(err)) return false;
    if (!pick_physical(err)) return false;
    if (!create_device(err)) return false;
    if (!create_swapchain(err)) return false;
    if (!create_depth(err)) return false;
    if (!create_render_pass(err)) return false;
    if (!create_pipeline(err)) return false;
    if (!create_buffers(err)) return false;
    if (!create_sync(err)) return false;
    return true;
}

bool VulkanDevice::create_instance(std::string& err) {
    VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
    app.pApplicationName = "block-programming-native";
    app.applicationVersion = VK_MAKE_VERSION(0, 1, 0);
    app.pEngineName = "none";
    app.apiVersion = VK_API_VERSION_1_1;

    const char* exts[] = {VK_KHR_SURFACE_EXTENSION_NAME, VK_KHR_WIN32_SURFACE_EXTENSION_NAME};
    VkInstanceCreateInfo ci{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    ci.pApplicationInfo = &app;
    ci.enabledExtensionCount = 2;
    ci.ppEnabledExtensionNames = exts;

    VkResult r = vkCreateInstance(&ci, nullptr, &instance_);
    if (r != VK_SUCCESS) {
        err = "vkCreateInstance 失败（驱动没装 Vulkan 运行库？）";
        return false;
    }

    VkWin32SurfaceCreateInfoKHR sci{VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR};
    sci.hinstance = GetModuleHandleW(nullptr);
    sci.hwnd = hwnd_;
    r = vkCreateWin32SurfaceKHR(instance_, &sci, nullptr, &surface_);
    if (r != VK_SUCCESS) {
        err = "vkCreateWin32SurfaceKHR 失败";
        return false;
    }
    return true;
}

bool VulkanDevice::pick_physical(std::string& err) {
    uint32_t count = 0;
    vkEnumeratePhysicalDevices(instance_, &count, nullptr);
    if (count == 0) {
        err = "没有可用的 Vulkan 物理设备";
        return false;
    }
    std::vector<VkPhysicalDevice> devices(count);
    vkEnumeratePhysicalDevices(instance_, &count, devices.data());

    int best_score = -1;
    for (VkPhysicalDevice d : devices) {
        VkPhysicalDeviceProperties props{};
        vkGetPhysicalDeviceProperties(d, &props);

        uint32_t qcount = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(d, &qcount, nullptr);
        std::vector<VkQueueFamilyProperties> queues(qcount);
        vkGetPhysicalDeviceQueueFamilyProperties(d, &qcount, queues.data());

        uint32_t family = UINT32_MAX;
        for (uint32_t i = 0; i < qcount; ++i) {
            VkBool32 present = VK_FALSE;
            vkGetPhysicalDeviceSurfaceSupportKHR(d, i, surface_, &present);
            if ((queues[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) && present) {
                family = i;
                break;
            }
        }
        if (family == UINT32_MAX) continue;

        VkPhysicalDeviceFeatures feats{};
        vkGetPhysicalDeviceFeatures(d, &feats);
        if (!feats.samplerAnisotropy) { /* 不影响，本原型不用采样器 */ }

        // 打分：独显优先，其次 Vulkan 版本高的
        int score = (props.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) ? 1000 : 100;
        score += int(VK_VERSION_MAJOR(props.apiVersion)) * 10;
        if (score > best_score) {
            best_score = score;
            phys_ = d;
            queue_family_ = family;
        }
    }
    if (phys_ == VK_NULL_HANDLE) {
        err = "没有同时支持图形与呈现的 Vulkan 队列";
        return false;
    }
    vkGetPhysicalDeviceMemoryProperties(phys_, &mem_props_);
    return true;
}

bool VulkanDevice::create_device(std::string& err) {
    float priority = 1.0f;
    VkDeviceQueueCreateInfo qci{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    qci.queueFamilyIndex = queue_family_;
    qci.queueCount = 1;
    qci.pQueuePriorities = &priority;

    const char* dev_exts[] = {VK_KHR_SWAPCHAIN_EXTENSION_NAME};
    VkDeviceCreateInfo ci{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
    ci.queueCreateInfoCount = 1;
    ci.pQueueCreateInfos = &qci;
    ci.enabledExtensionCount = 1;
    ci.ppEnabledExtensionNames = dev_exts;

    if (vkCreateDevice(phys_, &ci, nullptr, &device_) != VK_SUCCESS) {
        err = "vkCreateDevice 失败（缺 VK_KHR_swapchain？）";
        return false;
    }
    vkGetDeviceQueue(device_, queue_family_, 0, &queue_);
    return true;
}

bool VulkanDevice::create_swapchain(std::string& err) {
    VkSurfaceCapabilitiesKHR caps{};
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(phys_, surface_, &caps);

    uint32_t format_count = 0;
    vkGetPhysicalDeviceSurfaceFormatsKHR(phys_, surface_, &format_count, nullptr);
    std::vector<VkSurfaceFormatKHR> formats(format_count);
    if (format_count) vkGetPhysicalDeviceSurfaceFormatsKHR(phys_, surface_, &format_count, formats.data());

    // 优先 8bit sRGB，没有就用第一个
    VkSurfaceFormatKHR chosen = formats.empty() ? VkSurfaceFormatKHR{VK_FORMAT_B8G8R8A8_UNORM, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR}
                                               : formats[0];
    for (const auto& f : formats) {
        if (f.format == VK_FORMAT_B8G8R8A8_UNORM) { chosen = f; break; }
    }
    color_format_ = chosen.format;

    extent_ = caps.currentExtent;
    if (extent_.width == UINT32_MAX) {
        extent_.width = uint32_t(width_);
        extent_.height = uint32_t(height_);
    }

    uint32_t image_count = caps.minImageCount + 1;
    if (caps.maxImageCount > 0 && image_count > caps.maxImageCount) image_count = caps.maxImageCount;

    VkCompositeAlphaFlagBitsKHR alpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    VkSwapchainCreateInfoKHR ci{VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR};
    ci.surface = surface_;
    ci.minImageCount = image_count;
    ci.imageFormat = chosen.format;
    ci.imageColorSpace = chosen.colorSpace;
    ci.imageExtent = extent_;
    ci.imageArrayLayers = 1;
    ci.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    ci.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    ci.preTransform = caps.currentTransform;
    ci.compositeAlpha = alpha;
    ci.presentMode = VK_PRESENT_MODE_FIFO_KHR;
    ci.clipped = VK_TRUE;

    if (vkCreateSwapchainKHR(device_, &ci, nullptr, &swapchain_) != VK_SUCCESS) {
        err = "vkCreateSwapchainKHR 失败";
        return false;
    }

    uint32_t n = 0;
    vkGetSwapchainImagesKHR(device_, swapchain_, &n, nullptr);
    images_.resize(n);
    vkGetSwapchainImagesKHR(device_, swapchain_, &n, images_.data());

    views_.resize(n);
    framebuffers_.resize(n);
    return true;
}

void VulkanDevice::destroy_swapchain() {
    for (auto fb : framebuffers_) vkDestroyFramebuffer(device_, fb, nullptr);
    framebuffers_.clear();
    for (auto v : views_) vkDestroyImageView(device_, v, nullptr);
    views_.clear();
    images_.clear();
    if (depth_view_) { vkDestroyImageView(device_, depth_view_, nullptr); depth_view_ = VK_NULL_HANDLE; }
    if (depth_image_) { vkDestroyImage(device_, depth_image_, nullptr); depth_image_ = VK_NULL_HANDLE; }
    if (depth_mem_) { vkFreeMemory(device_, depth_mem_, nullptr); depth_mem_ = VK_NULL_HANDLE; }
    if (swapchain_) { vkDestroySwapchainKHR(device_, swapchain_, nullptr); swapchain_ = VK_NULL_HANDLE; }
}

uint32_t VulkanDevice::find_memory_type(uint32_t type_bits, VkMemoryPropertyFlags props) const {
    for (uint32_t i = 0; i < mem_props_.memoryTypeCount; ++i) {
        if ((type_bits & (1u << i)) && (mem_props_.memoryTypes[i].propertyFlags & props) == props) return i;
    }
    return UINT32_MAX;
}

bool VulkanDevice::create_depth(std::string& err) {
    VkImageCreateInfo ci{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
    ci.imageType = VK_IMAGE_TYPE_2D;
    ci.format = VK_FORMAT_D32_SFLOAT;
    ci.extent = {extent_.width, extent_.height, 1};
    ci.mipLevels = 1;
    ci.arrayLayers = 1;
    ci.samples = VK_SAMPLE_COUNT_1_BIT;
    ci.tiling = VK_IMAGE_TILING_OPTIMAL;
    ci.usage = VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;

    if (vkCreateImage(device_, &ci, nullptr, &depth_image_) != VK_SUCCESS) {
        err = "创建深度图失败";
        return false;
    }
    VkMemoryRequirements req{};
    vkGetImageMemoryRequirements(device_, depth_image_, &req);
    VkMemoryAllocateInfo ai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    ai.allocationSize = req.size;
    ai.memoryTypeIndex = find_memory_type(req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (ai.memoryTypeIndex == UINT32_MAX || vkAllocateMemory(device_, &ai, nullptr, &depth_mem_) != VK_SUCCESS) {
        err = "深度图内存分配失败";
        return false;
    }
    vkBindImageMemory(device_, depth_image_, depth_mem_, 0);

    VkImageViewCreateInfo vi{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
    vi.image = depth_image_;
    vi.viewType = VK_IMAGE_VIEW_TYPE_2D;
    vi.format = VK_FORMAT_D32_SFLOAT;
    vi.subresourceRange = {VK_IMAGE_ASPECT_DEPTH_BIT, 0, 1, 0, 1};
    if (vkCreateImageView(device_, &vi, nullptr, &depth_view_) != VK_SUCCESS) {
        err = "深度图视图失败";
        return false;
    }
    return true;
}

bool VulkanDevice::create_render_pass(std::string& err) {
    VkAttachmentDescription color{};
    color.format = color_format_;
    color.samples = VK_SAMPLE_COUNT_1_BIT;
    color.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    color.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    color.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    color.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    color.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    color.finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

    VkAttachmentDescription depth{};
    depth.format = VK_FORMAT_D32_SFLOAT;
    depth.samples = VK_SAMPLE_COUNT_1_BIT;
    depth.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    depth.storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    depth.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    depth.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    depth.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    depth.finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

    VkAttachmentReference color_ref{0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkAttachmentReference depth_ref{1, VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL};

    VkSubpassDescription sub{};
    sub.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    sub.colorAttachmentCount = 1;
    sub.pColorAttachments = &color_ref;
    sub.pDepthStencilAttachment = &depth_ref;

    VkSubpassDependency dep{};
    dep.srcSubpass = VK_SUBPASS_EXTERNAL;
    dep.dstSubpass = 0;
    dep.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
    dep.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
    dep.srcAccessMask = 0;
    dep.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;

    VkAttachmentDescription atts[2] = {color, depth};
    VkRenderPassCreateInfo ci{VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO};
    ci.attachmentCount = 2;
    ci.pAttachments = atts;
    ci.subpassCount = 1;
    ci.pSubpasses = &sub;
    ci.dependencyCount = 1;
    ci.pDependencies = &dep;

    if (vkCreateRenderPass(device_, &ci, nullptr, &render_pass_) != VK_SUCCESS) {
        err = "vkCreateRenderPass 失败";
        return false;
    }

    for (size_t i = 0; i < images_.size(); ++i) {
        VkImageViewCreateInfo vi{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
        vi.image = images_[i];
        vi.viewType = VK_IMAGE_VIEW_TYPE_2D;
        vi.format = color_format_;
        vi.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        if (vkCreateImageView(device_, &vi, nullptr, &views_[i]) != VK_SUCCESS) {
            err = "swapchain image view 失败";
            return false;
        }

        VkImageView fb_atts[2] = {views_[i], depth_view_};
        VkFramebufferCreateInfo fbi{VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO};
        fbi.renderPass = render_pass_;
        fbi.attachmentCount = 2;
        fbi.pAttachments = fb_atts;
        fbi.width = extent_.width;
        fbi.height = extent_.height;
        fbi.layers = 1;
        if (vkCreateFramebuffer(device_, &fbi, nullptr, &framebuffers_[i]) != VK_SUCCESS) {
            err = "vkCreateFramebuffer 失败";
            return false;
        }
    }
    return true;
}

static VkShaderModule make_module(VkDevice dev, const std::vector<char>& code) {
    VkShaderModuleCreateInfo ci{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
    ci.codeSize = code.size();
    ci.pCode = reinterpret_cast<const uint32_t*>(code.data());
    VkShaderModule m = VK_NULL_HANDLE;
    if (vkCreateShaderModule(dev, &ci, nullptr, &m) != VK_SUCCESS) return VK_NULL_HANDLE;
    return m;
}

bool VulkanDevice::create_pipeline(std::string& err) {
    std::vector<char> vert_code, frag_code;
    if (!load_spirv("chunk.vert.spv", vert_code, err)) return false;
    if (!load_spirv("chunk.frag.spv", frag_code, err)) return false;

    VkShaderModule vert = make_module(device_, vert_code);
    VkShaderModule frag = make_module(device_, frag_code);
    if (!vert || !frag) {
        err = "vkCreateShaderModule 失败";
        return false;
    }

    VkPipelineShaderStageCreateInfo stages[2]{};
    stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module = vert;
    stages[0].pName = "main";
    stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].module = frag;
    stages[1].pName = "main";

    VkVertexInputBindingDescription bind{0, sizeof(Vertex), VK_VERTEX_INPUT_RATE_VERTEX};
    VkVertexInputAttributeDescription attrs[2]{};
    attrs[0] = {0, 0, VK_FORMAT_R32G32B32_SFLOAT, offsetof(Vertex, x)};
    attrs[1] = {1, 0, VK_FORMAT_R32G32B32_SFLOAT, offsetof(Vertex, r)};

    VkPipelineVertexInputStateCreateInfo vin{VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
    vin.vertexBindingDescriptionCount = 1;
    vin.pVertexBindingDescriptions = &bind;
    vin.vertexAttributeDescriptionCount = 2;
    vin.pVertexAttributeDescriptions = attrs;

    VkPipelineInputAssemblyStateCreateInfo ia{VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO};
    ia.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

    VkPipelineViewportStateCreateInfo vp{VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO};
    vp.viewportCount = 1;
    vp.scissorCount = 1;

    VkPipelineRasterizationStateCreateInfo rs{VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
    rs.polygonMode = VK_POLYGON_MODE_FILL;
    rs.cullMode = VK_CULL_MODE_NONE;
    rs.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
    rs.lineWidth = 1.0f;

    VkPipelineMultisampleStateCreateInfo ms{VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO};
    ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;

    VkPipelineDepthStencilStateCreateInfo ds{VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO};
    ds.depthTestEnable = VK_TRUE;
    ds.depthWriteEnable = VK_TRUE;
    ds.depthCompareOp = VK_COMPARE_OP_LESS_OR_EQUAL;

    VkPipelineColorBlendAttachmentState blend{};
    blend.colorWriteMask = 0xF;
    VkPipelineColorBlendStateCreateInfo cb{VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO};
    cb.attachmentCount = 1;
    cb.pAttachments = &blend;

    VkDynamicState dyn_states[2] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
    VkPipelineDynamicStateCreateInfo dyn{VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO};
    dyn.dynamicStateCount = 2;
    dyn.pDynamicStates = dyn_states;

    VkDescriptorSetLayoutBinding ubo_binding{};
    ubo_binding.binding = 0;
    ubo_binding.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    ubo_binding.descriptorCount = 1;
    ubo_binding.stageFlags = VK_SHADER_STAGE_VERTEX_BIT;

    VkDescriptorSetLayoutCreateInfo sl{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
    sl.bindingCount = 1;
    sl.pBindings = &ubo_binding;
    if (vkCreateDescriptorSetLayout(device_, &sl, nullptr, &set_layout_) != VK_SUCCESS) {
        err = "vkCreateDescriptorSetLayout 失败";
        return false;
    }


    VkPipelineLayoutCreateInfo pl{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    pl.setLayoutCount = 1;
    pl.pSetLayouts = &set_layout_;
    if (vkCreatePipelineLayout(device_, &pl, nullptr, &pipeline_layout_) != VK_SUCCESS) {
        err = "vkCreatePipelineLayout 失败";
        return false;
    }

    VkGraphicsPipelineCreateInfo pci{VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO};
    pci.stageCount = 2;
    pci.pStages = stages;
    pci.pVertexInputState = &vin;
    pci.pInputAssemblyState = &ia;
    pci.pViewportState = &vp;
    pci.pRasterizationState = &rs;
    pci.pMultisampleState = &ms;
    pci.pDepthStencilState = &ds;
    pci.pColorBlendState = &cb;
    pci.pDynamicState = &dyn;
    pci.layout = pipeline_layout_;
    pci.renderPass = render_pass_;
    pci.subpass = 0;

    if (vkCreateGraphicsPipelines(device_, VK_NULL_HANDLE, 1, &pci, nullptr, &pipeline_) != VK_SUCCESS) {
        err = "vkCreateGraphicsPipelines 失败";
        return false;
    }

    vkDestroyShaderModule(device_, vert, nullptr);
    vkDestroyShaderModule(device_, frag, nullptr);
    return true;
}

bool VulkanDevice::create_buffers(std::string& err) {
    VkBufferCreateInfo bi{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
    bi.size = sizeof(UboData);
    bi.usage = VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
    if (vkCreateBuffer(device_, &bi, nullptr, &ubo_) != VK_SUCCESS) {
        err = "UBO 创建失败";
        return false;
    }
    VkMemoryRequirements req{};
    vkGetBufferMemoryRequirements(device_, ubo_, &req);
    VkMemoryAllocateInfo ai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    ai.allocationSize = req.size;
    ai.memoryTypeIndex = find_memory_type(req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (ai.memoryTypeIndex == UINT32_MAX || vkAllocateMemory(device_, &ai, nullptr, &ubo_mem_) != VK_SUCCESS) {
        err = "UBO 内存分配失败";
        return false;
    }
    vkBindBufferMemory(device_, ubo_, ubo_mem_, 0);
    vkMapMemory(device_, ubo_mem_, 0, sizeof(UboData), 0, &ubo_mapped_);

    VkDescriptorPoolSize pool_size{VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1};
    VkDescriptorPoolCreateInfo dp{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
    dp.maxSets = 1;
    dp.poolSizeCount = 1;
    dp.pPoolSizes = &pool_size;
    if (vkCreateDescriptorPool(device_, &dp, nullptr, &desc_pool_) != VK_SUCCESS) {
        err = "descriptor pool 创建失败";
        return false;
    }

    VkDescriptorSetAllocateInfo ds{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
    ds.descriptorPool = desc_pool_;
    ds.descriptorSetCount = 1;
    ds.pSetLayouts = &set_layout_;
    if (vkAllocateDescriptorSets(device_, &ds, &desc_set_) != VK_SUCCESS) {
        err = "descriptor set 分配失败";
        return false;
    }

    VkDescriptorBufferInfo dbi{ubo_, 0, sizeof(UboData)};
    VkWriteDescriptorSet write{VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};
    write.dstSet = desc_set_;
    write.dstBinding = 0;
    write.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    write.descriptorCount = 1;
    write.pBufferInfo = &dbi;
    vkUpdateDescriptorSets(device_, 1, &write, 0, nullptr);

    // 命令池
    VkCommandPoolCreateInfo cp{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
    cp.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    cp.queueFamilyIndex = queue_family_;
    if (vkCreateCommandPool(device_, &cp, nullptr, &cmd_pool_) != VK_SUCCESS) {
        err = "vkCreateCommandPool 失败";
        return false;
    }
    cmd_bufs_.resize(kMaxFrames);
    VkCommandBufferAllocateInfo cba{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    cba.commandPool = cmd_pool_;
    cba.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cba.commandBufferCount = kMaxFrames;
    if (vkAllocateCommandBuffers(device_, &cba, cmd_bufs_.data()) != VK_SUCCESS) {
        err = "vkAllocateCommandBuffers 失败";
        return false;
    }
    return true;
}

bool VulkanDevice::create_sync(std::string& err) {
    VkSemaphoreCreateInfo si{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    VkFenceCreateInfo fi{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    fi.flags = VK_FENCE_CREATE_SIGNALED_BIT;
    for (int i = 0; i < kMaxFrames; ++i) {
        if (vkCreateSemaphore(device_, &si, nullptr, &sem_image_[i]) != VK_SUCCESS ||
            vkCreateSemaphore(device_, &si, nullptr, &sem_render_[i]) != VK_SUCCESS ||
            vkCreateFence(device_, &fi, nullptr, &fences_[i]) != VK_SUCCESS) {
            err = "同步对象创建失败";
            return false;
        }
    }
    return true;
}

void VulkanDevice::upload_mesh(const MeshData& mesh) {
    index_count_ = uint32_t(mesh.indices.size());
    auto make = [&](const void* data, VkDeviceSize size, VkBufferUsageFlags usage, VkBuffer& buf, VkDeviceMemory& mem) -> bool {
        VkBufferCreateInfo bi{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
        bi.size = size;
        bi.usage = usage;
        if (vkCreateBuffer(device_, &bi, nullptr, &buf) != VK_SUCCESS) return false;
        VkMemoryRequirements req{};
        vkGetBufferMemoryRequirements(device_, buf, &req);
        VkMemoryAllocateInfo ai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        ai.allocationSize = req.size;
        ai.memoryTypeIndex = find_memory_type(req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        if (ai.memoryTypeIndex == UINT32_MAX || vkAllocateMemory(device_, &ai, nullptr, &mem) != VK_SUCCESS) return false;
        vkBindBufferMemory(device_, buf, mem, 0);
        void* dst = nullptr;
        vkMapMemory(device_, mem, 0, size, 0, &dst);
        std::memcpy(dst, data, size_t(size));
        vkUnmapMemory(device_, mem);
        return true;
    };
    make(mesh.vertices.data(), VkDeviceSize(mesh.vertices.size() * sizeof(Vertex)),
         VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, vbo_, vbo_mem_);
    make(mesh.indices.data(), VkDeviceSize(mesh.indices.size() * sizeof(uint32_t)),
         VK_BUFFER_USAGE_INDEX_BUFFER_BIT, ibo_, ibo_mem_);
}

bool VulkanDevice::ensure_capture_buffer(std::string& err) {
    VkDeviceSize need = VkDeviceSize(extent_.width) * VkDeviceSize(extent_.height) * 4;
    if (cap_buf_ != VK_NULL_HANDLE && cap_size_ >= need) return true;
    if (cap_buf_) { vkDestroyBuffer(device_, cap_buf_, nullptr); cap_buf_ = VK_NULL_HANDLE; }
    if (cap_mem_) { vkFreeMemory(device_, cap_mem_, nullptr); cap_mem_ = VK_NULL_HANDLE; }
    cap_mapped_ = nullptr;

    VkBufferCreateInfo bi{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
    bi.size = need;
    bi.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    if (vkCreateBuffer(device_, &bi, nullptr, &cap_buf_) != VK_SUCCESS) {
        err = "截图缓冲创建失败";
        return false;
    }
    VkMemoryRequirements req{};
    vkGetBufferMemoryRequirements(device_, cap_buf_, &req);
    VkMemoryAllocateInfo ai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    ai.allocationSize = req.size;
    ai.memoryTypeIndex = find_memory_type(req.memoryTypeBits,
                                          VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (ai.memoryTypeIndex == UINT32_MAX || vkAllocateMemory(device_, &ai, nullptr, &cap_mem_) != VK_SUCCESS) {
        err = "截图缓冲内存分配失败";
        return false;
    }
    vkBindBufferMemory(device_, cap_buf_, cap_mem_, 0);
    vkMapMemory(device_, cap_mem_, 0, need, 0, &cap_mapped_);
    cap_size_ = need;
    return true;
}

void VulkanDevice::render_frame(const FrameParams& params, const char* capture_bmp) {
    vkWaitForFences(device_, 1, &fences_[frame_], VK_TRUE, UINT64_MAX);

    uint32_t image_index = 0;
    VkResult r = vkAcquireNextImageKHR(device_, swapchain_, UINT64_MAX, sem_image_[frame_], VK_NULL_HANDLE, &image_index);
    if (r == VK_ERROR_OUT_OF_DATE_KHR) return;
    if (r != VK_SUCCESS && r != VK_SUBOPTIMAL_KHR) return;

    vkResetFences(device_, 1, &fences_[frame_]);

    UboData ubo{};
    std::memcpy(ubo.view_proj, params.view_proj, sizeof(ubo.view_proj));
    ubo.camera[0] = params.camera[0];
    ubo.camera[1] = params.camera[1];
    ubo.camera[2] = params.camera[2];
    ubo.camera[3] = params.time_seconds;
    std::memcpy(ubo_mapped_, &ubo, sizeof(ubo));

    VkCommandBuffer cb = cmd_bufs_[frame_];
    vkResetCommandBuffer(cb, 0);
    VkCommandBufferBeginInfo bi{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    vkBeginCommandBuffer(cb, &bi);

    VkClearValue clears[2]{};
    clears[0].color = {{0.55f, 0.72f, 0.92f, 1.0f}};
    clears[1].depthStencil = {1.0f, 0};

    VkRenderPassBeginInfo rp{VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO};
    rp.renderPass = render_pass_;
    rp.framebuffer = framebuffers_[image_index];
    rp.renderArea = {{0, 0}, extent_};
    rp.clearValueCount = 2;
    rp.pClearValues = clears;
    vkCmdBeginRenderPass(cb, &rp, VK_SUBPASS_CONTENTS_INLINE);

    vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline_);
    VkViewport viewport{0.0f, float(extent_.height), float(extent_.width), -float(extent_.height), 0.0f, 1.0f};
    VkRect2D scissor{{0, 0}, extent_};
    vkCmdSetViewport(cb, 0, 1, &viewport);
    vkCmdSetScissor(cb, 0, 1, &scissor);

    VkDeviceSize offset = 0;
    vkCmdBindVertexBuffers(cb, 0, 1, &vbo_, &offset);
    vkCmdBindIndexBuffer(cb, ibo_, 0, VK_INDEX_TYPE_UINT32);
    vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline_layout_, 0, 1, &desc_set_, 0, nullptr);
    vkCmdDrawIndexed(cb, index_count_, 1, 0, 0, 0);

    vkCmdEndRenderPass(cb);

    bool want_capture = false;
    std::string capture_err;
    if (capture_bmp && ensure_capture_buffer(capture_err)) {
        want_capture = true;

        VkImageMemoryBarrier to_src{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
        to_src.oldLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        to_src.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        to_src.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        to_src.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        to_src.image = images_[image_index];
        to_src.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        to_src.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        to_src.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
                             0, nullptr, 0, nullptr, 1, &to_src);

        VkBufferImageCopy region{};
        region.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
        region.imageExtent = {extent_.width, extent_.height, 1};
        vkCmdCopyImageToBuffer(cb, images_[image_index], VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, cap_buf_, 1, &region);

        VkImageMemoryBarrier to_present{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
        to_present.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        to_present.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        to_present.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        to_present.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        to_present.image = images_[image_index];
        to_present.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        to_present.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        to_present.dstAccessMask = 0;
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0,
                             0, nullptr, 0, nullptr, 1, &to_present);
    } else if (capture_bmp) {
        std::printf("[截图] 跳过：%s\n", capture_err.c_str());
    }

    vkEndCommandBuffer(cb);

    VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
    submit.waitSemaphoreCount = 1;
    submit.pWaitSemaphores = &sem_image_[frame_];
    submit.pWaitDstStageMask = &wait_stage;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &cb;
    submit.signalSemaphoreCount = 1;
    submit.pSignalSemaphores = &sem_render_[frame_];
    if (vkQueueSubmit(queue_, 1, &submit, fences_[frame_]) != VK_SUCCESS) return;

    VkPresentInfoKHR pi{VK_STRUCTURE_TYPE_PRESENT_INFO_KHR};
    pi.waitSemaphoreCount = 1;
    pi.pWaitSemaphores = &sem_render_[frame_];
    pi.swapchainCount = 1;
    pi.pSwapchains = &swapchain_;
    pi.pImageIndices = &image_index;
    vkQueuePresentKHR(queue_, &pi);

    if (want_capture) {
        vkDeviceWaitIdle(device_);
        // swapchain 格式是 BGRA，转成 BMP 需要的 RGBA
        const size_t pixels = size_t(extent_.width) * size_t(extent_.height);
        std::vector<uint8_t> rgba(pixels * 4);
        const uint8_t* src = static_cast<const uint8_t*>(cap_mapped_);
        for (size_t i = 0; i < pixels; ++i) {
            rgba[i * 4 + 0] = src[i * 4 + 2];
            rgba[i * 4 + 1] = src[i * 4 + 1];
            rgba[i * 4 + 2] = src[i * 4 + 0];
            rgba[i * 4 + 3] = 255;
        }
        if (write_bmp_rgba(capture_bmp, rgba, int(extent_.width), int(extent_.height))) {
            std::printf("[截图] %s (%ux%u)\n", capture_bmp, extent_.width, extent_.height);
        } else {
            std::printf("[截图] 写入失败：%s\n", capture_bmp);
        }
    }

    frame_ = (frame_ + 1) % kMaxFrames;
}

void VulkanDevice::wait_idle() {
    if (device_) vkDeviceWaitIdle(device_);
}

void VulkanDevice::shutdown() {
    if (!device_) return;
    vkDeviceWaitIdle(device_);
    destroy_swapchain();
    if (pipeline_) vkDestroyPipeline(device_, pipeline_, nullptr);
    if (pipeline_layout_) vkDestroyPipelineLayout(device_, pipeline_layout_, nullptr);
    if (set_layout_) vkDestroyDescriptorSetLayout(device_, set_layout_, nullptr);
    if (desc_pool_) vkDestroyDescriptorPool(device_, desc_pool_, nullptr);
    if (render_pass_) vkDestroyRenderPass(device_, render_pass_, nullptr);
    if (vbo_) vkDestroyBuffer(device_, vbo_, nullptr);
    if (vbo_mem_) vkFreeMemory(device_, vbo_mem_, nullptr);
    if (ibo_) vkDestroyBuffer(device_, ibo_, nullptr);
    if (ibo_mem_) vkFreeMemory(device_, ibo_mem_, nullptr);
    if (ubo_) vkDestroyBuffer(device_, ubo_, nullptr);
    if (ubo_mem_) vkFreeMemory(device_, ubo_mem_, nullptr);
    if (cap_buf_) vkDestroyBuffer(device_, cap_buf_, nullptr);
    if (cap_mem_) vkFreeMemory(device_, cap_mem_, nullptr);
    if (cmd_pool_) vkDestroyCommandPool(device_, cmd_pool_, nullptr);
    for (int i = 0; i < kMaxFrames; ++i) {
        if (sem_image_[i]) vkDestroySemaphore(device_, sem_image_[i], nullptr);
        if (sem_render_[i]) vkDestroySemaphore(device_, sem_render_[i], nullptr);
        if (fences_[i]) vkDestroyFence(device_, fences_[i], nullptr);
    }
    vkDestroyDevice(device_, nullptr);
    device_ = VK_NULL_HANDLE;
    if (surface_) vkDestroySurfaceKHR(instance_, surface_, nullptr);
    if (instance_) vkDestroyInstance(instance_, nullptr);
}

}  // namespace

RenderDevice* create_vulkan_device() { return new VulkanDevice(); }
