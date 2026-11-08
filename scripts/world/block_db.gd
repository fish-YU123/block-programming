extends RefCounted
## 方块定义表：从 data/blocks/*.json 读取。

class BlockDef:
	extends RefCounted
	var id: int
	var name: String
	var display_name: String
	var color: Color
	var top_color: Color
	var has_top := false
	var solid := true
	var opaque := true
	var hardness := 1.0
	var drop := ""

	func face_color(face_up: bool) -> Color:
		return top_color if face_up and has_top else color


var defs: Array[BlockDef] = []
var _by_id := {}
var _by_name := {}

const AIR := 0


func load_dir(path: String) -> String:
	defs.clear()
	_by_id.clear()
	_by_name.clear()
	var dir := DirAccess.open(path)
	if dir == null:
		return "打不开方块目录：%s" % path
	for file_name in dir.get_files():
		if not str(file_name).ends_with(".json"):
			continue
		var text := FileAccess.get_file_as_string(path.path_join(str(file_name)))
		var data = JSON.parse_string(text)
		if not (data is Dictionary):
			return "方块 JSON 解析失败：%s" % file_name
		var def := BlockDef.new()
		def.id = int(data.get("id", -1))
		def.name = str(data.get("name", ""))
		def.display_name = str(data.get("display_name", def.name))
		def.color = _to_color(data.get("color", [255, 0, 255]))
		if data.has("top_color"):
			def.top_color = _to_color(data["top_color"])
			def.has_top = true
		else:
			def.top_color = def.color
		def.solid = bool(data.get("solid", true))
		def.opaque = bool(data.get("opaque", true))
		def.hardness = float(data.get("hardness", 1.0))
		def.drop = str(data.get("drop", ""))
		if def.id < 0 or def.name == "":
			return "方块定义无效：%s" % file_name
		if _by_id.has(def.id):
			return "方块 id 重复：%s" % file_name
		defs.append(def)
		_by_id[def.id] = def
		_by_name[def.name] = def
	defs.sort_custom(func(a: BlockDef, b: BlockDef): return a.id < b.id)
	return ""


func get_def(block_id: int) -> BlockDef:
	return _by_id.get(block_id, null)


func id_of(name: String) -> int:
	var def = _by_name.get(name, null)
	return def.id if def != null else AIR


func name_of(block_id: int) -> String:
	var def = _by_id.get(block_id, null)
	return def.name if def != null else ""


func has_block(block_id: int) -> bool:
	return _by_id.has(block_id)


## 方块血量：硬度越高越硬（基岩极硬，基本打不动）
func hp_of(block_id: int) -> float:
	var d := get_def(block_id)
	if d == null:
		return 0.0
	if d.name == "bedrock":
		return 999999.0
	return maxf(1.0, d.hardness * 30.0)


func is_solid(block_id: int) -> bool:
	var def = _by_id.get(block_id, null)
	return def != null and def.solid


func is_opaque(block_id: int) -> bool:
	var def = _by_id.get(block_id, null)
	return def != null and def.opaque


func color_of(block_id: int, face_up: bool) -> Color:
	var def = _by_id.get(block_id, null)
	return def.face_color(face_up) if def != null else Color.MAGENTA


func _to_color(value) -> Color:
	if value is Array and value.size() >= 3:
		return Color(float(value[0]) / 255.0, float(value[1]) / 255.0, float(value[2]) / 255.0)
	return Color.MAGENTA
