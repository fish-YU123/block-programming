extends SceneTree
## 放置 / 收回单位测试：headless 运行
##   godot --headless --path . --script res://tests/place_test.gd

var _passed := 0
var _failed := 0
var _failures: Array = []
var _main: Node
var _frames := 0


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_main.world.build_all()
		_main._start_game()
	if _frames == 3:
		_check()
	return false


func _check() -> void:
	_record("开局有一台蓝队飞飞", _main.team_units(0).size() == 1, str(_main.team_units(0).size()))
	_main._place_unit()
	_record("按 F 放下一台", _main.team_units(0).size() == 2, str(_main.team_units(0).size()))
	_main._place_unit()
	_record("可以继续放", _main.team_units(0).size() == 3, str(_main.team_units(0).size()))
	_main._remove_last_unit()
	_record("按 G 收回一台", _main.team_units(0).size() == 2, str(_main.team_units(0).size()))
	var units: Array = _main.team_units(0)
	_record("剩余单位仍然有效", units.size() == 2 and is_instance_valid(units[1]["unit"]), "节点无效")

	var flyer: Node3D = units[0]["unit"]
	var controller = units[0]["controller"]
	for i in 30:
		controller.tick(0.016)
	_record("放下的单位能跑代码", not controller.halted(), controller.last_error())
	_record("放下的单位有位置", flyer.global_position.y > 0.0, str(flyer.global_position))
	_record("单位不会落到地下", flyer.global_position.y > float(_main.world.surface_height(floori(flyer.global_position.x), floori(flyer.global_position.z))), "y=%.2f" % flyer.global_position.y)

	print("通过 %d 项，失败 %d 项" % [_passed, _failed])
	for item in _failures:
		print("  ✗ " + item)
	quit(0 if _failed == 0 else 1)


func _record(name: String, ok: bool, detail: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append("%s：%s" % [name, detail])
