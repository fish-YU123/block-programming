extends RefCounted
## 预设单位表：从 data/units/*.json 读取（玩家不能自己拼单位，只用预设）

var defs: Dictionary = {}   ## id -> Dictionary
var order: Array = []       ## 按文件名排序的 id 列表


func load_dir(path: String) -> String:
	defs.clear()
	order.clear()
	var dir := DirAccess.open(path)
	if dir == null:
		return "打不开单位目录：%s" % path
	var files: Array = []
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.ends_with(".json"):
			files.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	files.sort()
	for file in files:
		var text := FileAccess.get_file_as_string(path.path_join(str(file)))
		if text == "":
			return "读不到单位文件：%s" % file
		var parsed = JSON.parse_string(text)
		if not (parsed is Dictionary):
			return "单位文件不是合法 JSON：%s" % file
		var def: Dictionary = parsed
		var id := str(def.get("id", ""))
		if id == "":
			return "单位缺少 id：%s" % file
		defs[id] = def
		order.append(id)
	return ""


func get_def(id: String) -> Dictionary:
	return defs.get(id, {})


func has(id: String) -> bool:
	return defs.has(id)
