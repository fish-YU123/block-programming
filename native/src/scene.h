// 体素小世界网格生成：只生成暴露在外的面，和图里那套方块配色对齐。
#pragma once

#include "rhi.h"

struct VoxelScene {
    int size_x = 32;
    int size_z = 32;
    int height = 0;   // 生成后的最高点（米）
};

// 生成一块 32x32 的起伏地形（草/土/石/矿），返回可直接上传的网格。
MeshData build_voxel_mesh(const VoxelScene& cfg);
