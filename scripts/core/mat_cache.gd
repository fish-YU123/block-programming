extends RefCounted
## 共享材质缓存：同一种材质只创建一次。
##
## 为什么需要：Metal/MoltenVK 下每新增一个材质变体都会触发一次渲染管线编译，
## 运行时"按需 new StandardMaterial3D()"会在生成单位/建筑/虚影时造成明显卡顿。
## 这里按 key 缓存，整局只创建有限几个材质。

static var _cache: Dictionary = {}


## 取一个纯色标准材质（可选自发光、无光照、双面、透明）
static func solid(key: String, color: Color, unshaded := false, emission := 0.0,
		cull_disabled := false, alpha := 1.0) -> StandardMaterial3D:
	if _cache.has(key):
		return _cache[key]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, alpha)
	if unshaded:
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	else:
		mat.roughness = 0.85
	if emission > 0.0:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = emission
	if cull_disabled:
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if alpha < 1.0:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_cache[key] = mat
	return mat


## 取一个纯色材质（自动生成 key，按颜色/参数区分）
static func of(color: Color, unshaded := false, emission := 0.0,
		cull_disabled := false, alpha := 1.0) -> StandardMaterial3D:
	var key := "%s|%s|%.2f|%s|%.2f" % [color.to_html(), str(unshaded), emission, str(cull_disabled), alpha]
	return solid(key, color, unshaded, emission, cull_disabled, alpha)
