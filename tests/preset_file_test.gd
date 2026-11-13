extends SceneTree
## 预设代码从本地文件读：data/presets/<单位id>.py

var _main: Node
var _frames := 0
var _passed := 0
var _failed := 0
var _done := false


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_d: float) -> bool:
	_frames += 1
	if _frames < 2 or _done:
		return false
	_done = true
	_run()
	print("通过 %d 项，失败 %d 项" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)
	return false


func _record(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ✓ ", name)
	else:
		_failed += 1
		print("  ✗ ", name, ("： " + detail) if detail != "" else "")


func _read_file_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	return "" if f == null else f.get_as_text()


func _run() -> void:
	var dir := "res://data/presets"
	_record("预设目录里有 feifei.py", FileAccess.file_exists("%s/feifei.py" % dir))
	_record("预设目录里有 commander.py", FileAccess.file_exists("%s/commander.py" % dir))

	var file_text := _read_file_text("%s/feifei.py" % dir)
	var loaded: String = _main._preset_for_unit(_main.unit_db.get_def("feifei"))
	_record("飞飞预设确实从文件读", loaded == file_text and loaded.length() > 100, "len=%d" % loaded.length())
	_record("文件里是新版僚机代码", loaded.contains("僚机") or loaded.contains("飞飞就位"), loaded.substr(0, 40))

	# 直接从文件读的代码能被 VM 编译并跑出控制量
	var py_vm_script = load("res://scripts/lang/py_vm.gd")
	var machine = py_vm_script.new()
	machine.load_source(_main._preset_for_unit(_main.unit_db.get_def("feifei")))
	_record("飞飞代码能编译", str(machine.error) == "", str(machine.error))
	machine.inject({
		"pos": {"x": 60.0, "y": 40.0, "z": 128.0},
		"vel": {"x": 0.0, "y": 0.0, "z": 0.0},
		"cell": Vector3i(60, 40, 128),
		"yaw": 0.0, "energy": 1000.0, "energy_ratio": 0.8,
		"hp": 100.0, "hp_max": 100.0, "hp_ratio": 1.0, "team": 0,
		"blocks": [], "heights": [[40.0, 40.0, 40.0], [40.0, 38.0, 40.0], [40.0, 40.0, 40.0]],
		"blocks3": [], "here": "grass", "enemies": [], "orders": [], "allies": [],
		"marks": [], "team_mem": {}, "cmd": {}, "ore": {}, "below": {}, "res": {}, "peace": 0.0,
		"moving": false, "t": 1.0, "uid": 1, "water": 0.0, "submerged": 0, "sudden": 0, "leader": 0,
	})
	var steps := 0
	var res: Dictionary = {}
	while steps < 200:
		res = machine.step(1)
		steps += 1
		if not bool(res.get("ok", true)):
			break
		if bool(res.get("done", false)):
			machine.restart()
	_record("飞飞代码实际跑起来没报错", bool(res.get("ok", true)), str(res.get("error", "")))

	# 没有对应文件时回退到内置常量
	var fake_def := {"id": "not_a_unit"}
	var fallback: String = _main._preset_for_unit(fake_def)
	_record("没有文件时回退到内置预设", fallback == str(_main.DefaultCode.COMMANDER_SOURCE), "len=%d" % fallback.length())

	# 指挥官支持按队伍覆盖文件，没有 _blue 文件就退回 commander.py
	var blue_code: String = _main._preset_code_for(0)
	var common := _read_file_text("%s/commander.py" % dir)
	_record("指挥官预设从文件读", blue_code == common and blue_code.length() > 100, "len=%d" % blue_code.length())
