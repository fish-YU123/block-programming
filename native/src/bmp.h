// 把 RGBA 像素写成 24 位 BMP（无第三方依赖，方便肉眼验证渲染结果）。
#pragma once

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

inline bool write_bmp_rgba(const std::string& path, const std::vector<uint8_t>& rgba, int w, int h) {
    if (w <= 0 || h <= 0 || rgba.size() < size_t(w) * size_t(h) * 4) return false;

    const int row_bytes = ((w * 3 + 3) / 4) * 4;
    const uint32_t pixel_bytes = uint32_t(row_bytes) * uint32_t(h);
    const uint32_t file_size = 54 + pixel_bytes;

    FILE* f = fopen(path.c_str(), "wb");
    if (!f) return false;

    uint8_t header[54] = {0};
    header[0] = 'B';
    header[1] = 'M';
    header[2] = uint8_t(file_size);
    header[3] = uint8_t(file_size >> 8);
    header[4] = uint8_t(file_size >> 16);
    header[5] = uint8_t(file_size >> 24);
    header[10] = 54;
    header[14] = 40;
    header[18] = uint8_t(w);
    header[19] = uint8_t(w >> 8);
    header[20] = uint8_t(w >> 16);
    header[21] = uint8_t(w >> 24);
    header[22] = uint8_t(h);
    header[23] = uint8_t(h >> 8);
    header[24] = uint8_t(h >> 16);
    header[25] = uint8_t(h >> 24);
    header[26] = 1;   // planes
    header[28] = 24;  // bpp
    header[34] = uint8_t(pixel_bytes);
    header[35] = uint8_t(pixel_bytes >> 8);
    header[36] = uint8_t(pixel_bytes >> 16);
    header[37] = uint8_t(pixel_bytes >> 24);
    fwrite(header, 1, 54, f);

    std::vector<uint8_t> row(size_t(row_bytes), 0);
    for (int y = h - 1; y >= 0; --y) {   // BMP 自下而上
        const uint8_t* src = &rgba[size_t(y) * size_t(w) * 4];
        for (int x = 0; x < w; ++x) {
            row[size_t(x) * 3 + 0] = src[size_t(x) * 4 + 2];  // B
            row[size_t(x) * 3 + 1] = src[size_t(x) * 4 + 1];  // G
            row[size_t(x) * 3 + 2] = src[size_t(x) * 4 + 0];  // R
        }
        fwrite(row.data(), 1, row.size(), f);
    }
    fclose(f);
    return true;
}
