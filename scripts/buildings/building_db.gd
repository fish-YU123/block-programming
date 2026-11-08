extends RefCounted
## 建筑定义表：从 data/buildings/*.json 读入。

var defs: Dictionary = {}     ## id -> Dictionary
var order: Array[String] = [] ## 文件顺序


func load_dir(path: String) -> String:
	## 返回错误描述，空串表示成功
	defs.clear()
	order.clear()
	var dir := DirAccess.open(path)
	if dir == null:
		return "打不开建筑目录：%s" % path
	var names := dir.get_files()
	names.sort()
	for file_name in names:
		if not file_name.ends_with(".json"):
			continue
		var full := path.path_join(file_name)
		var text := FileAccess.get_file_as_string(full)
		if text == "":
			return "读不到建筑文件：%s" % full
		var parsed = JSON.parse_string(text)
		if typeof(parsed) != TYPE_DICTIONARY:
			return "建筑文件不是 JSON 对象：%s" % full
		var id := str(parsed.get("id", ""))
		if id == "":
			return "建筑缺少 id：%s" % full
		defs[id] = parsed
		order.append(id)
	return ""


func get_def(id: String) -> Dictionary:
	return defs.get(id, {})


func has(id: String) -> bool:
	return defs.has(id)


func size_of(id: String) -> Vector3i:
	var def: Dictionary = get_def(id)
	var raw: Array = def.get("size", [3, 2, 3])
	return Vector3i(int(raw[0]), int(raw[1]), int(raw[2]))


func kind_of(id: String) -> String:
	return str(get_def(id).get("kind", ""))


func period_of(id: String) -> float:
	return maxf(float(get_def(id).get("period", 1.0)), 0.01)


func cost_of(id: String) -> Dictionary:
	var raw: Dictionary = get_def(id).get("cost", {})
	var out: Dictionary = {}
	for key in raw:
		out[str(key)] = int(raw[key])
	return out
