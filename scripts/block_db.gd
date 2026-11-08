extends RefCounted

const AIR_ID := 0

var props_by_id := {}
var id_by_name := {}
var ores: Array = []

class Ore:
	var block_id: int
	var replace_id: int
	var min_y: int
	var max_y: int
	var clusters: int
	var radius_min: int
	var radius_max: int
	var surface_clusters: int
	var surface_depth_min: int
	var surface_depth_max: int
	var seed_offset: int
	var priority: int


class Def:
	var id: int
	var name: String
	var display_name: String
	var solid: bool
	var opaque: bool
	var collidable: bool
	var hardness: float
	var light_emission: int
	var draws_boundary: bool
	var tags: PackedStringArray
	var props: Dictionary
	var color_top: Color
	var color_bottom: Color
	var color_side: Color
	var color_side_top: Color
	var color_side_bottom: Color
	var side_split: float


func load_dir(dir_path: String) -> void:
	props_by_id.clear()
	id_by_name.clear()
	ores.clear()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_error("打不开方块目录: %s" % dir_path)
		return
	var files := dir.get_files()
	var parsed: Array = []
	for file_name in files:
		if not str(file_name).ends_with(".json"):
			continue
		var path := dir_path.path_join(file_name)
		var data = _read_json(path)
		if data == null or not (data is Dictionary):
			push_error("方块 JSON 无法解析: %s" % path)
			continue
		parsed.append(data)
	for data in parsed:
		var def := _make_def(data)
		if props_by_id.has(def.id):
			push_error("方块 id 重复: %s (%s)" % [def.id, def.name])
			continue
		if id_by_name.has(def.name):
			push_error("方块 name 重复: %s" % def.name)
			continue
		props_by_id[def.id] = def
		id_by_name[def.name] = def.id
	if not props_by_id.has(AIR_ID):
		push_error("缺少 id 为 0 的空气方块")
	for data in parsed:
		var gen = data.get("generation", null)
		if gen == null or not (gen is Dictionary):
			continue
		if str(gen.get("type", "")) != "cluster":
			continue
		var ore := Ore.new()
		ore.block_id = id_of(str(data.get("name", "")))
		ore.replace_id = id_of(str(gen.get("replaces", "stone")))
		ore.min_y = int(gen.get("min_y", -490))
		ore.max_y = int(gen.get("max_y", 96))
		ore.clusters = int(gen.get("clusters_per_column", 8))
		ore.radius_min = int(gen.get("radius_min", 1))
		ore.radius_max = int(gen.get("radius_max", 2))
		ore.surface_clusters = int(gen.get("surface_clusters", 0))
		ore.surface_depth_min = int(gen.get("surface_depth_min", 1))
		ore.surface_depth_max = int(gen.get("surface_depth_max", 6))
		ore.seed_offset = int(gen.get("seed_offset", 1))
		ore.priority = int(gen.get("priority", 0))
		if ore.block_id < 0 or ore.replace_id < 0:
			push_error("矿物生成配置无效: %s" % str(data.get("name", "")))
			continue
		if ore.radius_min > ore.radius_max:
			var swap: int = ore.radius_min
			ore.radius_min = ore.radius_max
			ore.radius_max = swap
		if ore.surface_depth_min > ore.surface_depth_max:
			var swap_d: int = ore.surface_depth_min
			ore.surface_depth_min = ore.surface_depth_max
			ore.surface_depth_max = swap_d
		ores.append(ore)
	ores.sort_custom(func(a, b): return int(a.priority) < int(b.priority))


func id_of(block_name: String) -> int:
	if not id_by_name.has(block_name):
		push_error("找不到方块: %s" % block_name)
		return -1
	return int(id_by_name[block_name])


func get_def(id: int) -> Def:
	return props_by_id[id]


func has_id(id: int) -> bool:
	return props_by_id.has(id)


func display_name(id: int) -> String:
	if not props_by_id.has(id):
		return "?"
	return props_by_id[id].display_name


func names() -> PackedStringArray:
	var out := PackedStringArray()
	for block_name in id_by_name.keys():
		out.append(block_name)
	out.sort()
	return out


func _make_def(data: Dictionary) -> Def:
	var def := Def.new()
	def.id = int(data.get("id", -1))
	def.name = str(data.get("name", ""))
	def.display_name = str(data.get("display_name", def.name))
	def.solid = bool(data.get("solid", true))
	def.opaque = bool(data.get("opaque", true))
	def.collidable = bool(data.get("collidable", def.solid))
	def.hardness = float(data.get("hardness", 1.0))
	def.light_emission = int(data.get("light_emission", 0))
	def.draws_boundary = bool(data.get("draws_boundary", false))
	def.props = data
	var tag_list: Array = data.get("tags", [])
	def.tags = PackedStringArray()
	for tag in tag_list:
		def.tags.append(str(tag))
	var faces: Dictionary = data.get("faces", {})
	var base := _parse_color(data.get("color", [255, 0, 255]))
	def.color_top = _parse_color(faces["top"]) if faces.has("top") else base
	def.color_bottom = _parse_color(faces["bottom"]) if faces.has("bottom") else base
	def.color_side = _parse_color(faces["side"]) if faces.has("side") else base
	def.color_side_top = _parse_color(faces["side_top"]) if faces.has("side_top") else def.color_side
	def.color_side_bottom = _parse_color(faces["side_bottom"]) if faces.has("side_bottom") else def.color_side
	def.side_split = float(faces["side_split"]) if faces.has("side_split") else -1.0
	return def


func _parse_color(value) -> Color:
	if value is Array and value.size() >= 3:
		var r := float(value[0])
		var g := float(value[1])
		var b := float(value[2])
		var a := float(value[3]) if value.size() > 3 else 255.0
		if r > 1.0 or g > 1.0 or b > 1.0 or a > 1.0:
			return Color(r / 255.0, g / 255.0, b / 255.0, a / 255.0 if value.size() > 3 else 1.0)
		return Color(r, g, b, a if value.size() > 3 else 1.0)
	return Color.MAGENTA


func _read_json(path: String):
	if FileAccess.file_exists(path):
		var text := FileAccess.get_file_as_string(path)
		var parsed = JSON.parse_string(text)
		if parsed != null:
			return parsed
	var loaded = load(path)
	if loaded is JSON:
		return loaded.data
	return null
