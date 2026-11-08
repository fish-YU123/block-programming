shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx, cull_back;

varying vec3 albedo_color;
varying vec3 world_pos;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

void vertex() {
	albedo_color = COLOR.rgb;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float patch = value_noise(world_pos.xz * 0.18);
	float fine = value_noise(world_pos.xz * 1.7);
	float grit = value_noise(world_pos.xz * 5.5);
	vec3 tint = mix(vec3(0.9, 1.0, 0.84), vec3(1.06, 1.02, 0.9), patch);
	ALBEDO = albedo_color * tint * (0.92 + 0.06 * fine);
	ROUGHNESS = clamp(0.9 + 0.08 * grit, 0.86, 1.0);
	SPECULAR = 0.02;
}

void light() {
	float ndl = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);
	float wrap = clamp((dot(NORMAL, LIGHT) + 0.45) / 1.45, 0.0, 1.0);
	float extra = max(wrap - ndl, 0.0);
	DIFFUSE_LIGHT += LIGHT_COLOR * ALBEDO * extra * ATTENUATION * 0.28;
}
