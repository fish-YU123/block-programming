extends SceneTree
## 建筑工放方块 / 侦察机 / 雷达共享视野 / 维修厂 的 headless 测试

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


func _flat(near: Vector2i, sx: int, sz: int) -> Vector3i:
	var w = _main.world
	for dx in range(-14, 15):
		for dz in range(-14, 15):
			var x: int = near.x + dx
			var z: int = near.y + dz
			if x < 2 or z < 2 or x > 96 or z > 240:
				continue
			var h: int = int(w.surface_height(x, z))
			var flat := true
			for ox in range(sx):
				for oz in range(sz):
					if int(w.surface_height(x + ox, z + oz)) != h:
						flat = false
			if flat:
				return Vector3i(x, h, z)
	return Vector3i(-1, -1, -1)


func _run() -> void:
	var db = _main.db
	_record("单位表里有建筑工与侦察机", _main.unit_db.has("builder") and _main.unit_db.has("scout"), str(_main.unit_db.order))
	_record("建筑表里有雷达站与维修厂", _main.building_db.has("radar") and _main.building_db.has("repairbay"))

	# 1) 建筑工放方块
	var unit = _main.team_units(0)[0]["unit"]
	var spot := _flat(Vector2i(30, 128), 1, 1)
	var cell := Vector3i(spot.x, spot.y + 3, spot.z)
	var copper0: int = _main.economy.amount("copper")
	var energy0: float = unit.energy_j
	var err: String = _main.place_block_for(unit, "stone", cell)
	_record("建筑工能放方块", err == "" and _main.world.get_block(cell) == db.id_of("stone"), err)
	_record("放方块扣铜", _main.economy.amount("copper") < copper0)
	_record("放方块耗电", unit.energy_j < energy0)
	var err2: String = _main.place_block_for(unit, "stone", cell)
	_record("同一格不能重复放", err2 != "", err2)
	var err3: String = _main.place_block_for(unit, "不存在的方块", cell)
	_record("不认识方块名会报错", err3 != "", err3)
	_record("建筑工预设能编译", _main._preset_for_unit(_main.unit_db.get_def("builder")) != "")
	_record("侦察机预设能编译", _main._preset_for_unit(_main.unit_db.get_def("scout")) != "")

	# 2) 建筑工代码真的能放方块（走 VM 的 place 内置）
	_main._spawn_unit(_main.unit_db.get_def("builder"), Vector3(spot.x, 0.0, spot.z), _main._preset_for_unit(_main.unit_db.get_def("builder")), 0)
	var b_entry: Dictionary = _main.units[_main.units.size() - 1]
	var b_unit = b_entry["unit"]
	b_unit.global_position = Vector3(spot.x + 0.5, float(spot.y) + 3.0, spot.z + 0.5)
	var target := Vector3i(spot.x + 2, spot.y + 3, spot.z)
	_main.economy.add("copper", 50)
	var code := "def loop():\n    place(\"stone\", %d, %d, %d)\n" % [target.x, target.y, target.z]
	b_entry["controller"].bind(b_unit, code, 1)
	for i in 6:
		b_entry["controller"].tick(0.5)
	_record("单位代码里的 place 能落地", _main.world.get_block(target) == db.id_of("stone"), str(_main.world.get_block(target)))

	# 3) 雷达站共享视野
	var enemy = _main.team_units(1)[0]["unit"]
	var radar_spot := _flat(Vector2i(40, 120), 2, 2)
	_main.economy.add("copper", 200)
	_main.economy.add("iron", 80)
	var errr: String = _main.place_building_at("radar", radar_spot, 0)
	_record("放下雷达站", errr == "", errr)
	if errr == "":
		var radar = _main.buildings[_main.buildings.size() - 1]["node"]
		radar.build_left = 0.0
		radar._update_build_progress()
		_main.power_pool[0] = 500.0
		_main._tick_buildings(1.0)
		_record("通电后队伍有雷达覆盖", _main.team_has_radar(0), "")
		_record("雷达覆盖距离大于单位自带视野", _main.team_radar_range(0) > _main.team_units(0)[0]["unit"].radar_unit_range)
		# 把敌人挪到 20 米外：单位自己看不见，但雷达站能看见
		var watcher = _main.team_units(0)[0]["unit"]
		enemy.global_position = watcher.global_position + Vector3(20.0, 0.0, 0.0)
		_main._refresh_enemy_sensors()
		var seen: Array = _main.units[0]["controller"].enemies
		_record("雷达站让单位看到 20 米外的敌人", seen.size() > 0, str(seen.size()))
		# 断电后失去共享视野
		_main.power_pool[0] = 0.0
		_main._tick_buildings(1.0)
		_record("没电时雷达站停机", radar.is_stalled())

	# 4) 维修厂补血
	var bay_spot := _flat(Vector2i(50, 128), 2, 2)
	var errb: String = _main.place_building_at("repairbay", bay_spot, 0)
	_record("放下维修厂", errb == "", errb)
	if errb == "":
		var bay = _main.buildings[_main.buildings.size() - 1]["node"]
		bay.build_left = 0.0
		bay._update_build_progress()
		var hurt = _main.team_units(0)[0]["unit"]
		hurt.hp = 30.0
		hurt.global_position = bay.center_world() + Vector3(1.0, 1.0, 1.0)
		_main.power_pool[0] = 500.0
		_main._tick_buildings(1.0)
		_record("维修厂给友军补血", hurt.hp > 30.0, "%.0f" % hurt.hp)
