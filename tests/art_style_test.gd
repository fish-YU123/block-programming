extends SceneTree
## 画风统一回归（2026-11）：
##   1) 方块贴图必须是「双色低噪」——普通面只用两种颜色、两色亮度差固定；矿石面最多 4 色；
##   2) 单位/建筑必须是「纯色 + 描边」——结构件材质挂 next_pass 描边着色器且整局共用同一个实例，
##      所有单位/建筑材质都不带贴图（纯色）。
## 数值断言，不截图。

const TextureAtlas = preload("res://scripts/world/texture_atlas.gd")
const MatCache = preload("res://scripts/core/mat_cache.gd")

var _frames := 0
var _main: Node
var _passed := 0
var _failed := 0
var _done := false


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
		return false
	if _frames < 10:
		return false
	_check_atlas()
	_check_outline_materials()
	_check_world_visuals()
	_done = true
	return false


# ---------------------------------------------------------------- 贴图

func _check_atlas() -> void:
	var db = _main.world.db
	var atlas := TextureAtlas.new()
	atlas.build(db)
	var air_id: int = db.id_of("air")
	for def in db.defs:
		if def.id == air_id:
			continue
		var is_ore := str(def.name).ends_with("_ore")
		for face in [TextureAtlas.FACE_TOP, TextureAtlas.FACE_BOTTOM, TextureAtlas.FACE_SIDE]:
			var cell: int = atlas.cell_index(def.id, face)
			var ox: int = (cell % TextureAtlas.COLS) * TextureAtlas.CELL
			var oy: int = (cell / TextureAtlas.COLS) * TextureAtlas.CELL
			var colors := {}
			var opaque := 0
			for y in TextureAtlas.CELL:
				for x in TextureAtlas.CELL:
					var c := atlas.image.get_pixel(ox + x, oy + y)
					if c.a < 0.99:
						continue
					opaque += 1
					colors["%d,%d,%d" % [roundi(c.r * 255.0), roundi(c.g * 255.0), roundi(c.b * 255.0)]] = c
			var face_name := "%s/%d" % [str(def.name), face]
			_record("%s 整面不透明（256 像素）" % face_name, opaque == TextureAtlas.CELL * TextureAtlas.CELL,
					"%d 像素" % opaque)
			if is_ore:
				_record("%s 矿石面 ≤ 4 色" % face_name, colors.size() <= 4, "%d 色" % colors.size())
			else:
				_record("%s 双色（≤ 2 色）" % face_name, colors.size() <= 2, "%d 色" % colors.size())
				# 草的侧面是「草色 + 泥土色」两种纯色，亮度差本来就大，不套双色档位
				if str(def.name) != "grass" and colors.size() >= 2:
					var lo := 1.0
					var hi := 0.0
					for c in colors.values():
						var lum: float = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
						lo = minf(lo, lum)
						hi = maxf(hi, lum)
					var ratio := lo / maxf(hi, 0.0001)
					_record("%s 两色亮度差约一档" % face_name, ratio > 0.76 and ratio < 0.92,
							"暗/亮 = %.3f" % ratio)


# ---------------------------------------------------------------- 描边材质

func _check_outline_materials() -> void:
	var outlined: StandardMaterial3D = MatCache.outlined("art_test_outlined", Color(0.4, 0.5, 0.6))
	var plain: StandardMaterial3D = MatCache.solid("art_test_plain", Color(0.4, 0.5, 0.6))
	_record("outlined() 挂了 next_pass", outlined.next_pass != null)
	_record("outlined() 的 next_pass 是着色器材质", outlined.next_pass is ShaderMaterial)
	if outlined.next_pass is ShaderMaterial:
		var shader: Shader = (outlined.next_pass as ShaderMaterial).shader
		_record("描边着色器是 outline.gdshader",
				shader != null and str(shader.resource_path).ends_with("shaders/outline.gdshader"),
				str(shader.resource_path) if shader != null else "<null>")
		var width: float = (outlined.next_pass as ShaderMaterial).get_shader_parameter("outline_width")
		_record("描边宽度 = %.3f" % MatCache.OUTLINE_WIDTH, is_equal_approx(width, MatCache.OUTLINE_WIDTH),
				"%.4f" % width)
		var col: Color = (outlined.next_pass as ShaderMaterial).get_shader_parameter("outline_color")
		_record("描边是深色（亮度 < 0.2）", col.r + col.g + col.b < 0.6, col.to_html(false))
	_record("普通纯色材质没有描边", plain.next_pass == null)
	_record("描边材质整局共用一个实例", is_same(MatCache.outline_material(), outlined.next_pass))
	_record("描边材质带缓存（同 key 同实例）",
			is_same(MatCache.outlined("art_test_outlined", Color(0.4, 0.5, 0.6)), outlined), "")


# ---------------------------------------------------------------- 单位/建筑

func _check_world_visuals() -> void:
	var meshes := 0
	var outlined_count := 0
	var passes := {}
	var textured := 0
	for team in [0, 1]:
		for entry in _main.team_units(team):
			var unit: Node = entry["unit"]
			if unit == null:
				continue
			var mats: Array = []
			_collect_materials(unit, mats)
			var unit_outlined := 0
			for m in mats:
				if not (m is StandardMaterial3D):
					continue
				meshes += 1
				if (m as StandardMaterial3D).albedo_texture != null:
					textured += 1
				if (m as StandardMaterial3D).next_pass != null:
					outlined_count += 1
					unit_outlined += 1
					passes[(m as StandardMaterial3D).next_pass] = true
			_record("单位 %s 有描边结构件" % str(unit.get("unit_id")), unit_outlined > 0,
					"%d 个材质带描边" % unit_outlined)
	_record("单位材质都是纯色（无贴图）", textured == 0, "%d 个材质带贴图" % textured)
	_record("单位材质里有描边件", outlined_count > 0, "%d / %d" % [outlined_count, meshes])
	_record("所有单位为同一个描边材质实例", passes.size() == 1, "共 %d 个 next_pass 实例" % passes.size())

	# 开局没有建筑，测试里先放一栋再检查
	var spot := _flat_spot(40, 128)
	_record("找到建筑平地", spot.x > 0, str(spot))
	var err: String = _main.place_building_at("miner", spot) if spot.x > 0 else "no spot"
	_record("放下一栋采矿机", err == "", err)
	var building_checked := 0
	var building_outlined := 0
	var building_textured := 0
	for entry in _main.buildings:
		var bnode: Node = entry["node"]
		if bnode == null:
			continue
		# 刚放下的楼在施工态：整栋套半透明青色轮廓（非纯色材质），先建完再查正式外观
		bnode.build_left = 0.0
		bnode._update_build_progress()
		var mats: Array = []
		_collect_materials(bnode, mats)
		for m in mats:
			if not (m is StandardMaterial3D):
				continue
			building_checked += 1
			if (m as StandardMaterial3D).next_pass != null:
				building_outlined += 1
			if (m as StandardMaterial3D).albedo_texture != null:
				building_textured += 1
		break
	_record("建筑结构件带描边", building_outlined > 0, "%d / %d" % [building_outlined, building_checked])
	_record("建筑材质都是纯色（无贴图）", building_textured == 0, "%d 个材质带贴图" % building_textured)


## 找一块 3×3 平、上方无方块的建筑底格（同 buildings_test 的写法）
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


## 递归收集节点树下所有 MeshInstance3D 的覆盖材质
func _collect_materials(node: Node, out: Array) -> void:
	if node is MeshInstance3D and node.material_override != null:
		out.append(node.material_override)
	for child in node.get_children():
		_collect_materials(child, out)


func _record(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ✓ ", name, "  ", detail)
	else:
		_failed += 1
		print("  ✗ ", name, "  ", detail)
