extends RefCounted
## 共享材质缓存：同一种材质只创建一次。
##
## 为什么需要：Metal/MoltenVK 下每新增一个材质变体都会触发一次渲染管线编译，
## 运行时"按需 new StandardMaterial3D()"会在生成单位/建筑/虚影时造成明显卡顿。
## 这里按 key 缓存，整局只创建有限几个材质。
##
## 画风统一（2026-11）：单位/建筑走「纯色 + 描边」。
## 描边不是另建节点，而是给材质挂一个 next_pass 着色器（shaders/outline.gdshader）：
## 反向外壳沿法线外扩 1.6 厘米、只画背面，整局只创建一个 ShaderMaterial 共用，
## 所以不会按物体数量触发管线编译，draw call 也只是结构件数量再翻一倍（发光件不加）。

const OutlineShader = preload("res://shaders/outline.gdshader")
## 描边外扩宽度（米）。单位整体按 unit_size/0.75 缩放，描边会跟着一起缩放。
const OUTLINE_WIDTH := 0.016

static var _cache: Dictionary = {}
static var _outline_material: ShaderMaterial = null
## 关掉可以对比有/无描边的画面（测试和排查用）
static var outline_enabled := true


## 取一个纯色标准材质（可选自发光、无光照、双面、透明、描边）
static func solid(key: String, color: Color, unshaded := false, emission := 0.0,
		cull_disabled := false, alpha := 1.0, outline := false) -> StandardMaterial3D:
	# 描边材质和普通材质是两种东西，缓存 key 必须区分开
	var cache_key := key + ("|o" if outline else "")
	if _cache.has(cache_key):
		return _cache[cache_key]
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
	if outline and outline_enabled:
		mat.next_pass = outline_material()
	_cache[cache_key] = mat
	return mat


## 纯色 + 描边：单位/建筑结构件的标准写法
static func outlined(key: String, color: Color) -> StandardMaterial3D:
	return solid(key, color, false, 0.0, false, 1.0, true)


## 取一个纯色材质（自动生成 key，按颜色/参数区分）
static func of(color: Color, unshaded := false, emission := 0.0,
		cull_disabled := false, alpha := 1.0) -> StandardMaterial3D:
	var key := "%s|%s|%.2f|%s|%.2f" % [color.to_html(), str(unshaded), emission, str(cull_disabled), alpha]
	return solid(key, color, unshaded, emission, cull_disabled, alpha)


## 全体共用的描边材质（next_pass）
static func outline_material() -> ShaderMaterial:
	if _outline_material == null:
		_outline_material = ShaderMaterial.new()
		_outline_material.shader = OutlineShader
		_outline_material.set_shader_parameter("outline_color", Color(0.04, 0.05, 0.07))
		_outline_material.set_shader_parameter("outline_width", OUTLINE_WIDTH)
	return _outline_material
