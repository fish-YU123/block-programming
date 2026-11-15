shader_type spatial;
// 描边：把网格沿法线外扩一圈，只画背面（cull_front），形成「反向外壳」轮廓。
//
// 用法：当作任意 StandardMaterial3D 的 next_pass（脚本见 scripts/core/mat_cache.gd 的 outlined()）。
// 只给单位/建筑的纯色结构件用，发光件、方块、水面、虚影都不加，避免画面变脏、也避免多一倍 draw call。
render_mode unshaded, cull_front, depth_draw_opaque;

uniform vec4 outline_color : source_color = vec4(0.04, 0.05, 0.07, 1.0);
uniform float outline_width = 0.016;   // 外扩宽度，模型局部单位（米）

void vertex() {
	VERTEX += NORMAL * outline_width;
}

void fragment() {
	ALBEDO = outline_color.rgb;
}
