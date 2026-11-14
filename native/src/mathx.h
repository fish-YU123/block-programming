// 极简 4x4 矩阵工具（列主序，与 OpenGL 一致；Vulkan 用负高度视口翻转 Y）
#pragma once
#include <cmath>
#include <cstring>

struct Mat4 {
    float m[16];

    Mat4() { identity(); }

    void identity() {
        std::memset(m, 0, sizeof(m));
        m[0] = m[5] = m[10] = m[15] = 1.0f;
    }

    static Mat4 multiply(const Mat4& a, const Mat4& b) {
        Mat4 r;
        for (int c = 0; c < 4; ++c) {
            for (int row = 0; row < 4; ++row) {
                float sum = 0.0f;
                for (int k = 0; k < 4; ++k) sum += a.m[k * 4 + row] * b.m[c * 4 + k];
                r.m[c * 4 + row] = sum;
            }
        }
        return r;
    }

    static Mat4 perspective(float fovy_rad, float aspect, float znear, float zfar) {
        Mat4 r;
        std::memset(r.m, 0, sizeof(r.m));
        float f = 1.0f / std::tan(fovy_rad * 0.5f);
        r.m[0] = f / aspect;
        r.m[5] = f;
        r.m[10] = (zfar + znear) / (znear - zfar);
        r.m[11] = -1.0f;
        r.m[14] = (2.0f * zfar * znear) / (znear - zfar);
        return r;
    }

    static Mat4 look_at(float ex, float ey, float ez, float cx, float cy, float cz,
                        float ux, float uy, float uz) {
        float fx = cx - ex, fy = cy - ey, fz = cz - ez;
        float fl = std::sqrt(fx * fx + fy * fy + fz * fz);
        if (fl > 0.0f) { fx /= fl; fy /= fl; fz /= fl; }

        float sx = fy * uz - fz * uy;
        float sy = fz * ux - fx * uz;
        float sz = fx * uy - fy * ux;
        float sl = std::sqrt(sx * sx + sy * sy + sz * sz);
        if (sl > 0.0f) { sx /= sl; sy /= sl; sz /= sl; }

        float tx = sy * fz - sz * fy;
        float ty = sz * fx - sx * fz;
        float tz = sx * fy - sy * fx;

        Mat4 r;
        r.m[0] = sx; r.m[4] = sy; r.m[8] = sz; r.m[12] = -(sx * ex + sy * ey + sz * ez);
        r.m[1] = tx; r.m[5] = ty; r.m[9] = tz; r.m[13] = -(tx * ex + ty * ey + tz * ez);
        r.m[2] = -fx; r.m[6] = -fy; r.m[10] = -fz; r.m[14] = (fx * ex + fy * ey + fz * ez);
        r.m[3] = 0.0f; r.m[7] = 0.0f; r.m[11] = 0.0f; r.m[15] = 1.0f;
        return r;
    }
};
