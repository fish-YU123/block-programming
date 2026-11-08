shader_type spatial;
render_mode diffuse_burley, cull_back;

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
	float flow = value_noise(world_pos.xz * 0.45 + vec2(TIME * 0.03, TIME * 0.017));
	float crust = value_noise(world_pos.xz * 1.7);
	vec3 hot = albedo_color * (0.75 + 0.45 * flow);
	vec3 cool = albedo_color * vec3(0.35, 0.12, 0.05);
	vec3 alb = mix(hot, cool, smoothstep(0.45, 0.8, crust));
	ALBEDO = alb * 0.35;
	EMISSION = alb * (1.6 + flow * 0.8);
	ROUGHNESS = 0.42;
	SPECULAR = 0.45;
}
