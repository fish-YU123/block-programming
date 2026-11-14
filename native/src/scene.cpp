#include "scene.h"

#include <cmath>
#include <cstdint>
#include <vector>

namespace {

// 与 data/blocks/*.json 里的观感对齐（真值以后接 JSON 读取）
struct Rgb { float r, g, b; };
const Rgb GRASS {0.32f, 0.62f, 0.26f};
const Rgb DIRT  {0.45f, 0.33f, 0.22f};
const Rgb STONE {0.52f, 0.52f, 0.55f};
const Rgb COAL  {0.18f, 0.18f, 0.20f};
const Rgb COPPER{0.72f, 0.45f, 0.26f};
const Rgb IRON  {0.75f, 0.62f, 0.50f};

uint32_t hash2(int x, int z, uint32_t seed) {
    uint32_t h = (uint32_t)x * 374761393u + (uint32_t)z * 668265263u + seed * 2246822519u;
    h = (h ^ (h >> 13)) * 1274126177u;
    return h ^ (h >> 16);
}

float value_at(int x, int z, uint32_t seed) {
    return float(hash2(x, z, seed) & 0xFFFFu) / 65535.0f;
}

// 双线性插值的粗糙高度场：起伏不大，保证相机能看得舒服
int height_at(int x, int z, int size_x, int size_z) {
    const int cell = 8;
    int gx = x / cell, gz = z / cell;
    float fx = float(x % cell) / float(cell);
    float fz = float(z % cell) / float(cell);
    auto sample = [&](int cx, int cz) {
        cx = cx % ((size_x + cell - 1) / cell);
        cz = cz % ((size_z + cell - 1) / cell);
        return value_at(cx, cz, 1337u) * 7.0f;
    };
    float h00 = sample(gx, gz), h10 = sample(gx + 1, gz);
    float h01 = sample(gx, gz + 1), h11 = sample(gx + 1, gz + 1);
    float h = (h00 * (1 - fx) + h10 * fx) * (1 - fz) + (h01 * (1 - fx) + h11 * fx) * fz;
    return 1 + int(h + 0.5f);
}

Rgb block_color(int world_x, int world_z, int y, int surface_y) {
    if (y == surface_y) {
        // 地表：草为主，偶尔露矿
        uint32_t h = hash2(world_x, world_z, 77u);
        if ((h % 23u) == 0) return COPPER;
        if ((h % 31u) == 0) return IRON;
        return GRASS;
    }
    if (y >= surface_y - 2) return DIRT;
    uint32_t h = hash2(world_x, world_z * 7 + y, 991u);
    if ((h % 17u) == 0) return COAL;
    return STONE;
}

void push_face(MeshData& mesh, float x, float y, float z, float du_x, float du_z,
               int axis, float sign, Rgb c) {
    // 每个面两个三角形；法线方向的明暗做一点手调，让体素看起来有体积
    float shade = 1.0f;
    if (axis == 1) shade = 1.0f;            // 顶面
    else if (axis == 0) shade = 0.78f;      // 东西面
    else shade = 0.62f;                     // 南北面

    const uint32_t base = uint32_t(mesh.vertices.size());
    const float cr = c.r * shade, cg = c.g * shade, cb = c.b * shade;

    // 四个角（逆时针，从外侧看）
    float p[4][3];
    if (axis == 1) {           // 顶面 (y)
        p[0][0] = x;         p[0][1] = y; p[0][2] = z;
        p[1][0] = x + du_x;  p[1][1] = y; p[1][2] = z;
        p[2][0] = x + du_x;  p[2][1] = y; p[2][2] = z + du_z;
        p[3][0] = x;         p[3][1] = y; p[3][2] = z + du_z;
    } else if (axis == 0) {    // X 方向的面
        p[0][0] = x + sign; p[0][1] = y;     p[0][2] = z;
        p[1][0] = x + sign; p[1][1] = y + 1; p[1][2] = z;
        p[2][0] = x + sign; p[2][1] = y + 1; p[2][2] = z + du_z;
        p[3][0] = x + sign; p[3][1] = y;     p[3][2] = z + du_z;
    } else {                   // Z 方向的面
        p[0][0] = x;        p[0][1] = y;     p[0][2] = z + sign;
        p[1][0] = x;        p[1][1] = y + 1; p[1][2] = z + sign;
        p[2][0] = x + du_x; p[2][1] = y + 1; p[2][2] = z + sign;
        p[3][0] = x + du_x; p[3][1] = y;     p[3][2] = z + sign;
    }

    for (int i = 0; i < 4; ++i) {
        mesh.vertices.push_back(Vertex{p[i][0], p[i][1], p[i][2], cr, cg, cb});
    }
    if (sign > 0.0f) {
        mesh.indices.insert(mesh.indices.end(), {base + 0, base + 1, base + 2, base + 0, base + 2, base + 3});
    } else {
        mesh.indices.insert(mesh.indices.end(), {base + 0, base + 2, base + 1, base + 0, base + 3, base + 2});
    }
}

}  // namespace

MeshData build_voxel_mesh(const VoxelScene& cfg) {
    MeshData mesh;
    const int sx = cfg.size_x;
    const int sz = cfg.size_z;

    std::vector<int> heights(size_t(sx * sz));
    int max_h = 0;
    for (int z = 0; z < sz; ++z) {
        for (int x = 0; x < sx; ++x) {
            int h = height_at(x, z, sx, sz);
            heights[size_t(z * sx + x)] = h;
            if (h > max_h) max_h = h;
        }
    }

    for (int z = 0; z < sz; ++z) {
        for (int x = 0; x < sx; ++x) {
            int top = heights[size_t(z * sx + x)];
            // 每一列从地表往下画 3 格（顶 + 侧），够看出体积又不至于几十万面
            for (int y = top - 2; y <= top; ++y) {
                Rgb c = block_color(x, z, y, top);
                float fx = float(x);
                float fz = float(z);

                // 顶面
                if (y == top) push_face(mesh, fx, float(y) + 1.0f, fz, 1.0f, 1.0f, 1, 1.0f, c);

                // 四面：邻居更低才露出来
                auto neighbor_top = [&](int nx, int nz) -> int {
                    if (nx < 0 || nz < 0 || nx >= sx || nz >= sz) return -1000;
                    return heights[size_t(nz * sx + nx)];
                };
                if (neighbor_top(x + 1, z) < y) push_face(mesh, fx, float(y), fz, 1.0f, 1.0f, 0, 1.0f, c);
                if (neighbor_top(x - 1, z) < y) push_face(mesh, fx, float(y), fz, 1.0f, 1.0f, 0, -1.0f, c);
                if (neighbor_top(x, z + 1) < y) push_face(mesh, fx, float(y), fz, 1.0f, 1.0f, 2, 1.0f, c);
                if (neighbor_top(x, z - 1) < y) push_face(mesh, fx, float(y), fz, 1.0f, 1.0f, 2, -1.0f, c);
            }
        }
    }
    return mesh;
}
