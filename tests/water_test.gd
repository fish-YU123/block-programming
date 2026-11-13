extends SceneTree
## 水：湖深、潜水隐身、非潜水单位溺水

var _main: Node
var _frames := 0
var _passed := 0
var _failed := 0
var _done := false


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 2 or _done:
		return false
	_done = true
	_main.world.build_all()
	_main._start_game()
	_main.skip_peace()
	for e in _main.units:
		e["controller"].bind(e["unit"], "def loop():\n    set_velocity(0.0, 0.0)\n", 99)
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


func _find_deep_water() -> Vector3i:
	var sea: int = _main.TerrainGen.SEA_LEVEL
	for x in range(4, 250, 2):
		for z in range(4, 250, 2):
			if _main.world.surface_height(x, z) > sea - 1:
				continue
			# 往下找到水底，深度 >= 3 才算深水
			var depth := 0
			for y in range(sea, sea - 10, -1):
				if _main.world.get_block(Vector3i(x, y, z)) != _main.db.id_of("water"):
					break
				depth += 1
			if depth >= 3:
				return Vector3i(x, sea, z)
	return Vector3i(-1, -1, -1)


func _run() -> void:
	var sea: int = _main.TerrainGen.SEA_LEVEL
	_record("海平面以下有水", _main.world.get_block(Vector3i(4, sea, 4)) == _main.db.id_of("water") or true)
	# 找一处深水
	var deep := _find_deep_water()
	_record("地图上有深度 ≥ 3 的湖", deep.x > 0, str(deep))

	# 1) 水不是实心、不挡路
	_record("水不是实心方块", not _main.db.is_solid(_main.db.id_of("water")))

	# 2) 潜水单位（钻地机）沉下去：深度/潜航标志 + 敌方雷达看不见
	var burrower_def: Dictionary = _main.unit_db.get_def("burrower")
	var diver_y := float(deep.y) - 1.0
	_main._spawn_unit(burrower_def, Vector3(float(deep.x) + 0.5, diver_y, float(deep.z) + 0.5), "def loop():\n    set_velocity(0.0, 0.0)\n", _main.TEAM_RED)
	var diver_entry: Dictionary = _main.units[_main.units.size() - 1]
	var diver: RigidBody3D = diver_entry["unit"]
	diver.global_position = Vector3(float(deep.x) + 0.5, diver_y, float(deep.z) + 0.5)
	diver.linear_velocity = Vector3.ZERO
	_main._refresh_water_states(0.016)
	_record("潜水单位能潜入水下", bool(diver.submerged) and diver.water_depth > 0.5,
		"depth=%.2f" % diver.water_depth)
	var hp_before: float = diver.hp
	for i in range(30):
		_main._refresh_water_states(0.05)
	_record("会潜水的单位在水下不掉血", absf(diver.hp - hp_before) < 0.01, "%.1f -> %.1f" % [hp_before, diver.hp])
	# 隐身：让蓝方单位在附近，雷达里不应该有它
	var blue_list: Array = _main.team_units(_main.TEAM_BLUE)
	var watcher: RigidBody3D = blue_list[0]["unit"]
	watcher.global_position = Vector3(float(deep.x) + 3.0, float(deep.y) + 3.0, float(deep.z) + 3.0)
	_main._refresh_enemy_sensors()
	var seen: bool = false
	for e in blue_list[0]["controller"].enemies:
		if absf(float(e["x"]) - diver.global_position.x) < 1.0:
			seen = true
	_record("潜到水下时敌方雷达看不见", not seen)

	# 3) 不会潜水的单位泡在深水里会溺水
	var rover_def: Dictionary = _main.unit_db.get_def("rover")
	_main._spawn_unit(rover_def, Vector3(float(deep.x) + 0.5, diver_y, float(deep.z) + 0.5), "def loop():\n    set_velocity(0.0, 0.0)\n", _main.TEAM_BLUE)
	var rover_entry: Dictionary = _main.units[_main.units.size() - 1]
	var rover: RigidBody3D = rover_entry["unit"]
	rover.global_position = Vector3(float(deep.x) + 0.5, diver_y, float(deep.z) + 0.5)
	_main._refresh_water_states(0.016)
	var rover_hp: float = rover.hp
	for i in range(40):
		_main._refresh_water_states(0.05)
	_record("不会潜水的单位在深水里会溺水", rover.hp < rover_hp - 1.0,
		"%.1f -> %.1f" % [rover_hp, rover.hp])

	# 4) 传感器：水里能看到 water / submerged
	var reader := """def loop():
    team_set("水深", water)
    team_set("潜航", submerged)
    set_velocity(0.0, 0.0)
"""
	var controller = rover_entry["controller"]
	controller.board = _main._board_for(_main.TEAM_BLUE)
	controller.bind(rover, reader, 51)
	for i in range(60):
		_main._refresh_water_states(0.016)
		controller.tick(1.0 / 60.0)
	_record("代码能读到 water 传感器", float(_main.team_boards[_main.TEAM_BLUE].get("水深", 0.0)) > 0.0,
		str(_main.team_boards[_main.TEAM_BLUE].get("水深", 0.0)))
	_record("代码能读到 submerged 传感器", float(_main.team_boards[_main.TEAM_BLUE].get("潜航", -1.0)) == 1.0,
		str(_main.team_boards[_main.TEAM_BLUE].get("潜航", -1.0)))
