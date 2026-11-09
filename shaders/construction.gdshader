shader_type spatial;
// 施工中的建筑：从地面往上"切"出来（剖面之下才显示），切口带发光边
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never;

uniform vec4 tint : source_color = vec4(0.42, 0.84, 1.0, 1.0);
uniform float cut_y = 1000000.0;   // 世界坐标的切割高度：高于它的部分被切掉
uniform float alpha = 0.5;

varying float world_y;

void vertex() {
	world_y = (MODEL_MATRIX * vec4(VERTEX, 1.0)).y;
}

void fragment() {
	if (world_y > cut_y) {
		discard;
	}
	float edge = smoothstep(cut_y - 0.5, cut_y, world_y);
	ALBEDO = mix(tint.rgb, vec3(1.0), edge * 0.7);
	ALPHA = clamp(alpha + edge * 0.45, 0.0, 1.0);
	EMISSION = tint.rgb * (0.35 + edge * 3.0);
}
