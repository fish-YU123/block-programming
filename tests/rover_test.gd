extends SceneTree
## 车车（地面车）测试：数据表、落地、开起来、钻头挖方块、耗电

var _main: Node
var _rover: Node
var _frames := 0
var _passed := 0
var _failed := 0
var _start_pos := Vector3.ZERO
var _phase := 0


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _record(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ✓ ", name)
	else:
		_failed += 1
		print("  ✗ ", name, "：", detail)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_main.world.build_all()
		_main._start_game()
	if _frames == 3:
		var def: Dictionary = _main.unit_db.get_def("rover")
		_record("单位表里有车车", not def.is_empty(), str(def.get("display_name", "")))
		_record("车车质量", absf(float(def.get("mass", 0.0)) - 90.0) < 0.01, str(def.get("mass", 0.0)))
		# 找一块平地放车
		var x := 40
		var z := 120
		var ground: int = _main.world.surface_height(x, z)
		_main._spawn_unit(def, Vector3(float(x), float(ground), float(z)), "def loop():\n    set_rcs(0, 1.0)\n", 0)
		var entry: Dictionary = _main.team_units(0).back()
		_rover = entry["unit"]
		_record("生成的是车车节点", _rover.get("unit_id") == "rover", str(_rover.get("unit_id")))
		_record("生成是刚体", _rover is RigidBody3D, _rover.get_class())
		_start_pos = _rover.global_position
	if _frames == 240:
		var moved: float = _rover.global_position.distance_to(_start_pos)
		_record("车能跑起来", moved > 2.0, "位移 %.2f 米" % moved)
		var ground = _main.world.surface_height(floori(_rover.global_position.x), floori(_rover.global_position.z))
		_record("车贴地不掉坑", absf(_rover.global_position.y - float(ground)) < 2.5, "y=%.2f 地面=%d" % [_rover.global_position.y, ground])
		_record("开车会耗电", _rover.energy_j < _rover.energy_max, "%.0f/%.0f" % [_rover.energy_j, _rover.energy_max])
		# 正前方放一块石头，让它钻
		var basis: Basis = _rover.global_transform.basis
		var ahead: Vector3 = _rover.global_position + (-basis.z) * 1.6
		var cell := Vector3i(floori(ahead.x), floori(ahead.y), floori(ahead.z))
		_main.world.set_block(cell, _main.db.id_of("stone"))
		_phase = 1
	if _phase == 1 and _frames == 250:
		var entry: Dictionary = _main.team_units(0).back()
		entry["controller"].bind(_rover, "def loop():\n    drill(True)\n", 2)
	if _phase == 1 and _frames >= 400:
		var basis: Basis = _rover.global_transform.basis
		var ahead: Vector3 = _rover.global_position + (-basis.z) * 1.6
		var cell := Vector3i(floori(ahead.x), floori(ahead.y), floori(ahead.z))
		_record("钻头挖过方块", _rover.drill_hits > 0, "drill_hits=%d 前方=%s" % [_rover.drill_hits, _main.db.name_of(_main.world.get_block(cell))])
		print("通过 %d 项，失败 %d 项" % [_passed, _failed])
		quit(0 if _failed == 0 else 1)
	return false
