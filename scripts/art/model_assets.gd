extends RefCounted
## 美术资产接入：**有 .glb 就用，没有就回退程序化模型**。
##
## 目录约定（按 unit_id / building id 命名，放好文件即生效，不需要改代码）：
##   res://assets/models/units/<unit_id>.glb      例：assets/models/units/feifei.glb
##   res://assets/models/buildings/<def_id>.glb   例：assets/models/buildings/miner.glb
## 也接受 .gltf（外部 .bin/贴图请放在同一目录）。找不到就返回 null，调用方继续用程序化造型。
##
## 自动适配：
##   - 单位：把整个模型（含所有 MeshInstance3D）等比缩放，最长边贴合参考方盒（悬浮单位 0.75 米、
##     地面单位 1.2 米，即数据里 size 的基准值），包围盒中心对齐原点，之后外部再按 unit_size 缩放。
##   - 建筑：等比缩放并让底面贴在 y=0、水平中心对齐原点，尺寸不超过数据里的占地（可以略小留边）。
##
## 队伍色（画风统一的关键）：
##   节点名 或 材质名 里带这些词就会按队伍染色（大小写不敏感，先匹配 team）：
##     `team`  → 主体队色（蓝方深蓝 / 红方赤红）
##     `trim`、`accent` → 识别色（蓝方青 / 红方橙）
##   染色是给材质 albedo_color 赋值：带贴图的资产会「贴图 × 队色」，纯白占位贴图效果最好。
##   其他材质（发光件、玻璃、装饰）原样保留，不做描边也不改颜色，画风交给美术定。
##
## 运行时加载：先查 Godot 导入资源（导出包里走这条），没有导入时退回 GLTFDocument 直接读原文件，
## 所以测试里现生成一个 .glb 也能立刻被用上。

const MatCache = preload("res://scripts/core/mat_cache.gd")

const UNIT_SUBDIR := "units"
const BUILDING_SUBDIR := "buildings"
const EXTENSIONS := [".glb", ".gltf"]

## 搜索根目录（按顺序找）。测试可以用 set_search_roots() 指到临时目录。
static var search_roots: PackedStringArray = ["res://assets/models"]

static var _scene_cache: Dictionary = {}
static var _missing: Dictionary = {}


## 改搜索根目录（测试/自定义资产包用）；传空数组恢复默认
static func set_search_roots(roots: Array) -> void:
	search_roots = PackedStringArray(roots) if not roots.is_empty() else PackedStringArray(["res://assets/models"])
	_scene_cache.clear()
	_missing.clear()


static func unit_asset_path(unit_id: String) -> String:
	return _find_asset(UNIT_SUBDIR, unit_id)


static func building_asset_path(def_id: String) -> String:
	return _find_asset(BUILDING_SUBDIR, def_id)


static func has_unit_asset(unit_id: String) -> bool:
	return unit_asset_path(unit_id) != ""


static func has_building_asset(def_id: String) -> bool:
	return building_asset_path(def_id) != ""


## 队伍配色（程序化模型和 glb 共用一套，保证换资产后还是同样的队伍色）
static func team_palette(team: int, for_building := false) -> Dictionary:
	if for_building:
		if team == 0:
			return {"body": Color(0.22, 0.38, 0.78), "trim": Color(0.35, 0.9, 1.0)}
		return {"body": Color(0.72, 0.2, 0.18), "trim": Color(1.0, 0.66, 0.22)}
	if team == 0:
		return {"body": Color(0.16, 0.28, 0.62), "trim": Color(0.28, 0.85, 0.95)}
	return {"body": Color(0.62, 0.15, 0.14), "trim": Color(0.98, 0.62, 0.18)}


## 单位造型：有资产就用资产（返回名为 Model 的 Node3D），没有返回 null
## reference_size 是数据里 size 的基准（悬浮单位 0.75、地面单位 1.2）
static func instantiate_unit(unit_id: String, reference_size: float, team: int) -> Node3D:
	var path := unit_asset_path(unit_id)
	if path == "":
		return null
	var asset := _instantiate(path)
	if asset == null:
		return null
	# 套一层 wrapper：缩放/对齐都作用在 wrapper 上，资产自己的变换原样保留
	var model := Node3D.new()
	model.name = "Model"
	model.add_child(asset)
	model.set_meta("asset_path", path)
	var box := _model_aabb(asset)
	if box.size.length() > 0.0001:
		var longest := maxf(box.size.x, maxf(box.size.y, box.size.z))
		var s := reference_size / maxf(longest, 0.0001)
		model.scale = Vector3(s, s, s)
		# 包围盒中心对齐原点（程序化模型都是原点居中的）
		model.position = -box.get_center() * s
	var palette := team_palette(team, false)
	_tint_by_names(asset, palette["body"], palette["trim"])
	return model


## 建筑造型：有资产就用资产，没有返回 null。footprint 是数据里的占地（格数，1 格 = 1 米）
static func instantiate_building(def_id: String, footprint: Vector3, team: int) -> Node3D:
	var path := building_asset_path(def_id)
	if path == "":
		return null
	var asset := _instantiate(path)
	if asset == null:
		return null
	var model := Node3D.new()
	model.name = "Asset"
	model.add_child(asset)
	model.set_meta("asset_path", path)
	var box := _model_aabb(asset)
	if box.size.length() > 0.0001:
		var s := minf(footprint.x / maxf(box.size.x, 0.0001),
				minf(footprint.y / maxf(box.size.y, 0.0001),
						footprint.z / maxf(box.size.z, 0.0001)))
		s = minf(s, 1.0)  # 不放大：小资产就让它小一点，留出边角，避免糊满整个占地
		s *= 0.98
		model.scale = Vector3(s, s, s)
		# 底面贴地、水平居中
		model.position = Vector3(-box.get_center().x * s, -box.position.y * s, -box.get_center().z * s)
	var palette := team_palette(team, true)
	_tint_by_names(asset, palette["body"], palette["trim"])
	return model


## 清缓存（测试用）
static func clear_cache() -> void:
	_scene_cache.clear()
	_missing.clear()


# ---------------------------------------------------------------- 内部

static func _find_asset(subdir: String, id: String) -> String:
	if id == "":
		return ""
	for root in search_roots:
		for ext in EXTENSIONS:
			var path := "%s/%s/%s%s" % [str(root).trim_suffix("/"), subdir, id, ext]
			if path in _missing:
				continue
			if FileAccess.file_exists(path) or ResourceLoader.exists(path):
				return path
			_missing[path] = true
	return ""


static func _instantiate(path: String) -> Node3D:
	var scene := _load_scene(path)
	if scene == null:
		return null
	var node := scene.instantiate()
	if node is Node3D:
		return node as Node3D
	node.queue_free()
	return null


static func _load_scene(path: String) -> PackedScene:
	if _scene_cache.has(path):
		return _scene_cache[path]
	var scene: PackedScene = null
	if ResourceLoader.exists(path):
		var res = load(path)
		if res is PackedScene:
			scene = res
	if scene == null:
		# 没被 Godot 导入过的原始 .glb（测试里现生成的、或运行时热加载的资产）
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		if doc.append_from_file(path, state) == OK:
			var root := doc.generate_scene(state)
			if root != null:
				scene = PackedScene.new()
				if scene.pack(root) != OK:
					scene = null
				root.queue_free()
	if scene == null:
		push_warning("美术资产读取失败，回退程序化模型：%s" % path)
		return null
	_scene_cache[path] = scene
	return scene


## 模型在自己父空间里的包围盒（含每个 MeshInstance3D 的变换）
static func model_aabb(root: Node3D) -> AABB:
	return _model_aabb(root)


static func _model_aabb(root: Node3D) -> AABB:
	var box := AABB()
	var first := true
	var stack: Array = [[root, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var item: Array = stack.pop_back()
		var node: Node = item[0]
		var xf: Transform3D = item[1] * (node as Node3D).transform
		if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
			var mb: AABB = xf * (node as MeshInstance3D).mesh.get_aabb()
			if first:
				box = mb
				first = false
			else:
				box = box.merge(mb)
		for child in node.get_children():
			stack.append([child, xf])
	return box


## 按节点名/材质名里的 team、trim 关键词染色
static func _tint_by_names(root: Node3D, body: Color, trim: Color) -> void:
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
			_tint_mesh(node as MeshInstance3D, body, trim)
		for child in node.get_children():
			stack.append(child)


static func _tint_mesh(mi: MeshInstance3D, body: Color, trim: Color) -> void:
	var node_token := str(mi.name).to_lower()
	for i in mi.mesh.get_surface_count():
		var src: Material = mi.get_active_material(i)
		var token := node_token
		if src != null:
			token += " " + str(src.resource_name).to_lower()
		var tint := Color(0, 0, 0, 0)
		if token.contains("team"):
			tint = body
		elif token.contains("trim") or token.contains("accent"):
			tint = trim
		var has_tint := tint.a > 0.0
		if not has_tint:
			continue
		if src is StandardMaterial3D:
			# 带贴图的资产：albedo_color 会乘到贴图上，白色占位贴图最准
			var dup := (src as StandardMaterial3D).duplicate() as StandardMaterial3D
			dup.albedo_color = tint
			mi.set_surface_override_material(i, dup)
		else:
			var key := "asset_%s_%s" % ["body" if tint == body else "trim", tint.to_html(false)]
			mi.set_surface_override_material(i, MatCache.solid(key, tint))
