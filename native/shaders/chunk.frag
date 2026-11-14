#version 450
// 顶点色 + 距离雾，顺带把天空色和地平线拉开层次。

layout(location = 0) in vec3 v_color;
layout(location = 1) in float v_dist;

layout(location = 0) out vec4 out_color;

void main() {
    const vec3 sky = vec3(0.55, 0.72, 0.92);
    float fog = clamp((v_dist - 30.0) / 90.0, 0.0, 0.75);
    out_color = vec4(mix(v_color, sky, fog), 1.0);
}
