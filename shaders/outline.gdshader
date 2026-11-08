shader_type spatial;
render_mode unshaded, cull_front, depth_draw_opaque;

uniform vec3 outline_color : source_color = vec3(1.0, 0.78, 0.2);

void vertex() {
	VERTEX += NORMAL * 0.05;
}

void fragment() {
	ALBEDO = outline_color;
}
