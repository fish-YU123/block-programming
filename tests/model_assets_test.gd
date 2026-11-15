extends SceneTree
## 美术资产接入回归：有 .glb 就用资产，没有就回退程序化模型。
##
## 测试会在 res://.test_art/ 里现生成两个最小 .glb（自建几何，无版权问题），
## 然后把 ModelAssets 的搜索根指过去，验证：
##   - 没资产时回退程序化造型；
##   - 有资产时单位/建筑都用上了资产；
##   - 自动缩放（单位最长边贴合 0.75 基准方盒、建筑贴合占地且底面贴地）；
##   - 队伍色按节点名/材质名里的 team / trim 关键词染色，其他材质不动；
##   - 跑完删掉临时资产目录，不污染仓库。

const ModelAssets = preload("res://scripts/art/model_assets.gd")

const ART_ROOT := "res://.test_art"

var _frames := 0
var _main: Node
var _passed := 0
var _failed := 0
var _done := false
var _unit_model: Node3D = null
var _building_checked := false


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _done:
		print("通过 %d 项，失败 %d 项" % [_passed, _failed])
		quit(0 if _failed == 0 else 1)
		return false
	if _frames == 2:
		_main.world.build_all()
		_main._start_game()
		_check_fallback()
		return false
	if _frames == 3:
		_write_test_assets()
		ModelAssets.set_search_roots([ART_ROOT + "/models"])
		_check_asset_detection()
		return false
	if _frames == 4:
		_check_unit_asset()
		return false
	if _frames == 5:
		_check_building_asset()
		_cleanup()
		_done = true
		return false
	return false


# ---------------------------------------------------------------- 无资产：回退

func _check_fallback() -> void:
	_record("默认没接任何资产", not ModelAssets.has_unit_asset("feifei"))
	var blue: Array = _main.team_units(0)
	_record("开局生成了单位", blue.size() > 0)
	if blue.size() > 0:
		var unit: Node = blue[0]["unit"]
		var model: Node = unit.get_node_or_null("Model")
		_record("单位有程序化模型", model != null)
		_record("没资产时不会出现资产节点", _count_named(model, "GlbRoot") == 0)
		var meshes := 0
		var stack: Array = [model]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			if n is MeshInstance3D:
				meshes += 1
			for c in n.get_children():
				stack.append(c)
		_record("程序化模型有多个零件", meshes >= 3, "%d 个 MeshInstance3D" % meshes)


# ---------------------------------------------------------------- 生成测试资产

func _write_test_assets() -> void:
	_make_glb(ART_ROOT + "/models/units/feifei.glb", "GlbRoot", [
		{"name": "team_body", "size": Vector3(1.0, 0.4, 2.0), "color": Color(1, 1, 1), "mat": "team"},
		{"name": "trim_wing", "size": Vector3(1.6, 0.06, 0.4), "color": Color(0.5, 0.5, 0.5), "mat": "trim"},
		{"name": "glow_lamp", "size": Vector3(0.2, 0.2, 0.2), "color": Color(1.0, 0.5, 0.1), "mat": "lamp"},
	])
	_make_glb(ART_ROOT + "/models/buildings/miner.glb", "GlbRoot2", [
		{"name": "team_body", "size": Vector3(2.0, 3.0, 2.0), "color": Color(1, 1, 1), "mat": "team"},
		{"name": "trim_band", "size": Vector3(2.2, 0.2, 2.2), "color": Color(1, 1, 1), "mat": "trim"},
	])


## 用 GLTFDocument 现生成一个最小 .glb（节点名/材质名会原样保留，方便验证命名约定）
func _make_glb(path: String, root_name: String, parts: Array) -> void:
	var scene_root := Node3D.new()
	scene_root.name = root_name
	for part in parts:
		var mi := MeshInstance3D.new()
		mi.name = str(part["name"])
		var mesh := BoxMesh.new()
		mesh.size = part["size"]
		mi.mesh = mesh
		var mat := StandardMaterial3D.new()
		mat.resource_name = str(part["mat"])
		mat.albedo_color = part["color"]
		mi.material_override = mat
		scene_root.add_child(mi)
	var dir := path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_scene(scene_root, state) != OK:
		_record("生成测试资产 %s" % path, false, "append_from_scene 失败")
		scene_root.free()
		return
	var err := doc.write_to_filesystem(state, path)
	_record("生成测试资产 %s" % path.get_file(), err == OK, error_string(err))
	scene_root.free()


func _check_asset_detection() -> void:
	_record("搜到单位资产", ModelAssets.has_unit_asset("feifei"), ModelAssets.unit_asset_path("feifei"))
	_record("搜到建筑资产", ModelAssets.has_building_asset("miner"), ModelAssets.building_asset_path("miner"))
	_record("没有的单位仍然回退", not ModelAssets.has_unit_asset("scout"))


# ---------------------------------------------------------------- 单位资产

func _check_unit_asset() -> void:
	_unit_model = ModelAssets.instantiate_unit("feifei", 0.75, 0)
	_record("能实例化单位资产", _unit_model != null)
	if _unit_model == null:
		return
	_record("资产模型包在 Model 节点里", _unit_model.name == "Model")
	_record("模型记录资产路径", str(_unit_model.get_meta("asset_path", "")).ends_with("feifei.glb"))
	_record("资产节点在场景树里", _count_named(_unit_model, "GlbRoot") == 1)

	# 自动缩放：原始模型最长边 2 米，应缩到 0.75 基准
	var box := ModelAssets.model_aabb(_unit_model)
	var longest := maxf(box.size.x, maxf(box.size.y, box.size.z))
	_record("单位资产缩放到 0.75 基准", absf(longest - 0.75) < 0.01, "最长边 %.3f" % longest)
	_record("单位资产包围盒居中", box.get_center().length() < 0.01, str(box.get_center()))
	_record("单位资产不出基准方盒", box.size.y <= 0.75 + 0.01, "高度 %.3f" % box.size.y)

	# 队伍染色
	var palette := ModelAssets.team_palette(0, false)
	var body_mat := _surface_material(_find_mesh(_unit_model, "team_body"), 0)
	_record("team 部件染成蓝方主色",
			body_mat is StandardMaterial3D
			and (body_mat as StandardMaterial3D).albedo_color.is_equal_approx(palette["body"]),
			_color_text(body_mat))
	var trim_mat := _surface_material(_find_mesh(_unit_model, "trim_wing"), 0)
	_record("trim 部件染成蓝方识别色",
			trim_mat is StandardMaterial3D
			and (trim_mat as StandardMaterial3D).albedo_color.is_equal_approx(palette["trim"]),
			_color_text(trim_mat))
	var lamp_mat := _surface_material(_find_mesh(_unit_model, "glow_lamp"), 0)
	_record("发光件不被染色",
			lamp_mat is StandardMaterial3D
			and (lamp_mat as StandardMaterial3D).albedo_color.is_equal_approx(Color(1.0, 0.5, 0.1)),
			_color_text(lamp_mat))
	var red_palette := ModelAssets.team_palette(1, false)
	_record("红方主色与蓝方不同", not red_palette["body"].is_equal_approx(palette["body"]))

	# 真实单位也走资产：新生成一台飞飞，模型里应该有 GlbRoot
	var def: Dictionary = _main.unit_db.get_def("feifei")
	if def.is_empty():
		_record("单位表里有飞飞", false)
		return
	_main._spawn_unit(def, Vector3(40.0, 0.0, 120.0), _main._preset_for_unit(def), 0)
	var found := false
	var model_ok := false
	for entry in _main.team_units(0):
		var unit: Node = entry["unit"]
		if str(unit.get("unit_id")) != "feifei":
			continue
		var model: Node = unit.get_node_or_null("Model")
		if model != null and _count_named(model, "GlbRoot") > 0:
			found = true
			model_ok = true
	_record("游戏里新生成的飞飞用上了资产", found)
	_record("飞飞资产模型挂在 Model 节点下", model_ok)


# ---------------------------------------------------------------- 建筑资产

func _check_building_asset() -> void:
	var spot := _flat_spot(40, 128)
	_record("找到建筑平地", spot.x > 0, str(spot))
	if spot.x <= 0:
		return
	var err: String = _main.place_building_at("miner", spot)
	_record("放下采矿机", err == "", err)
	for entry in _main.buildings:
		var bnode: Node = entry["node"]
		if bnode == null:
			continue
		# 刚放下时是施工态（整栋套 _construction_mat），先建完再看正式外观
		bnode.build_left = 0.0
		bnode._update_build_progress()
		var asset: Node = bnode.get_node_or_null("Asset")
		_record("建筑用上了资产", asset != null)
		if asset == null:
			continue
		var box := ModelAssets.model_aabb(asset)
		_record("建筑资产贴地（底面 y≈0）", absf(box.position.y) < 0.05, "y=%.3f" % box.position.y)
		var size: Vector3i = _main.building_db.size_of("miner")
		_record("建筑资产不超出占地",
				box.size.x <= float(size.x) + 0.02 and box.size.z <= float(size.z) + 0.02,
				"%s vs %s" % [str(box.size), str(size)])
		_record("建筑资产水平居中", absf(box.get_center().x) < 0.02 and absf(box.get_center().z) < 0.02)
		var palette := ModelAssets.team_palette(0, true)
		var body_mat := _surface_material(_find_mesh(asset, "team_body"), 0)
		_record("建筑 team 部件染成队色",
				body_mat is StandardMaterial3D
				and (body_mat as StandardMaterial3D).albedo_color.is_equal_approx(palette["body"]),
				_color_text(body_mat))
		_building_checked = true
		break
	_record("至少检查到一栋建筑", _building_checked)


# ---------------------------------------------------------------- 收尾

func _cleanup() -> void:
	ModelAssets.set_search_roots([])
	ModelAssets.clear_cache()
	_remove_dir(ART_ROOT)
	_record("临时资产目录已清理", not DirAccess.dir_exists_absolute(ART_ROOT))


func _remove_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not name.begins_with("."):
			if dir.current_is_dir():
				_remove_dir(path + "/" + name)
			else:
				DirAccess.remove_absolute(path + "/" + name)
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)


# ---------------------------------------------------------------- 小工具

func _find_mesh(root: Node, mesh_name: String) -> MeshInstance3D:
	if root == null:
		return null
	return root.find_child(mesh_name, true, false) as MeshInstance3D


func _surface_material(mi: MeshInstance3D, surface: int) -> Material:
	if mi == null:
		return null
	return mi.get_active_material(surface)


func _count_named(root: Node, node_name: String) -> int:
	if root == null:
		return 0
	var found := root.find_child(node_name, true, false)
	return 1 if found != null else 0


func _color_text(mat: Material) -> String:
	if mat is StandardMaterial3D:
		return (mat as StandardMaterial3D).albedo_color.to_html(false)
	return "<null>"


func _flat_spot(near_x: int, near_z: int) -> Vector3i:
	var world = _main.world
	for dx in range(-20, 21):
		for dz in range(-20, 21):
			var x: int = near_x + dx
			var z: int = near_z + dz
			if x < 2 or z < 2 or x > 96 or z > 253:
				continue
			var h: int = world.surface_height(x, z)
			var flat := true
			for ox in 3:
				for oz in 3:
					if int(world.surface_height(x + ox, z + oz)) != h:
						flat = false
						break
				if not flat:
					break
			if flat:
				return Vector3i(x, h, z)
	return Vector3i(-1, -1, -1)


func _record(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ✓ ", name, "  ", detail)
	else:
		_failed += 1
		print("  ✗ ", name, "  ", detail)
