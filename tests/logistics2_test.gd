extends SceneTree
## 仓库上限 / 精炼厂 / 车辆厂 / 货运飞飞 的 headless 测试

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
	_record("单位表里有货运飞飞", _main.unit_db.has("cargo"))
	_record("建筑表有 14 种", _main.building_db.order.size() == 14, str(_main.building_db.order.size()))
	_record("建筑表含仓库/精炼厂/车辆厂", _main.building_db.has("storage") and _main.building_db.has("refinery") and _main.building_db.has("vehiclefactory"))
	_main.economy.add("copper", 400)
	_main.economy.add("iron", 200)
	_main.economy.add("coal", 300)

	# 1) 仓库抬高资源上限
	_main._tick_buildings(0.1)
	var cap0: int = _main.storage_cap(0)
	var spot := _flat(Vector2i(30, 126), 2, 2)
	var err: String = _main.place_building_at("storage", spot, 0)
	_record("放下仓库", err == "", err)
	if err == "":
		var st = _main.buildings[_main.buildings.size() - 1]["node"]
		st.build_left = 0.0
		st._update_build_progress()
		_main._tick_buildings(0.1)
		_record("仓库抬高上限", _main.storage_cap(0) > cap0, "%d -> %d" % [cap0, _main.storage_cap(0)])
		# 上限真的会截断资源
		_main.economy.add("copper", 100000)
		_record("资源会被上限截断", _main.economy.amount("copper") <= _main.storage_cap(0), str(_main.economy.amount("copper")))

	# 2) 精炼厂炼钢
	var r_spot := _flat(Vector2i(38, 126), 3, 3)
	var errr: String = _main.place_building_at("refinery", r_spot, 0)
	_record("放下精炼厂", errr == "", errr)
	if errr == "":
		var ref = _main.buildings[_main.buildings.size() - 1]["node"]
		ref.build_left = 0.0
		ref._update_build_progress()
		_main.power_pool[0] = 500.0
		var steel0: int = _main.economy.amount("steel")
		_main._tick_buildings(6.0)
		_record("精炼厂产出钢", _main.economy.amount("steel") > steel0, "%d -> %d" % [steel0, _main.economy.amount("steel")])

	# 3) 车辆厂产车车
	_main.economy.add("steel", 100)
	_main.economy.add("copper", 500)
	var v_spot := _flat(Vector2i(46, 126), 3, 3)
	var errv: String = _main.place_building_at("vehiclefactory", v_spot, 0)
	_record("放下车辆厂", errv == "", errv)
	if errv == "":
		var vf = _main.buildings[_main.buildings.size() - 1]["node"]
		vf.build_left = 0.0
		vf._update_build_progress()
		var before: int = _main.team_units(0).size()
		_main.power_pool[0] = 500.0
		_main._tick_buildings(15.0)
		var kinds := []
		for e in _main.team_units(0):
			kinds.append(str(e["unit"].unit_id))
		_record("车辆厂产出一台车车", _main.team_units(0).size() == before + 1 and "rover" in kinds, str(kinds))

	# 4) 货运飞飞输送电力
	var cdef: Dictionary = _main.unit_db.get_def("cargo")
	_main._spawn_unit(cdef, Vector3(60.0, 0.0, 126.0), _main._preset_for_unit(cdef), 0)
	var cargo_entry: Dictionary = _main.units[_main.units.size() - 1]
	var cargo = cargo_entry["unit"]
	var ally = _main.team_units(0)[0]["unit"]
	ally.global_position = cargo.global_position + Vector3(2.0, 0.0, 0.0)
	cargo.global_position = Vector3(60.0, ally.global_position.y, 126.0)
	ally.energy_j = 1000.0
	cargo.energy_j = cargo.energy_max * 0.9
	cargo.controls["transfer"] = true
	var before_j: float = ally.energy_j
	for i in 10:
		_main._process_cargo_transfers(1.0)
	_record("货运飞飞给友军补电", ally.energy_j > before_j, "%.0f -> %.0f" % [before_j, ally.energy_j])
	_record("货运飞飞自己掉电", cargo.energy_j < cargo.energy_max * 0.9)
