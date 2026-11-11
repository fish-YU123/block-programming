extends SceneTree
## 新单位技能（自爆 / 布雷 / 维修 / 供电 / 干扰 / 钻地）与传送带

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
			if x < 2 or z < 2 or x > 250 or z > 250:
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


func _spawn(unit_id: String, at: Vector3, team: int) -> RigidBody3D:
	var def: Dictionary = _main.unit_db.get_def(unit_id)
	_main._spawn_unit(def, at, "def loop():\n    set_velocity(0.0, 0.0)\n", team)
	return _main.team_units(team)[_main.team_units(team).size() - 1]["unit"]


func _run() -> void:
	# 每种单位的预设代码都能编译
	var preset_bad: Array = []
	for uid in _main.unit_db.order:
		var udef: Dictionary = _main.unit_db.get_def(str(uid))
		var code: String = str(_main._preset_for_unit(udef))
		var vm_script = load("res://scripts/lang/py_vm.gd")
		var perr := ""
		if vm_script != null and code != "":
			var vm = vm_script.new()
			vm.load_source(code)
			perr = str(vm.error)
		if perr != "":
			preset_bad.append("%s:%s" % [str(uid), perr])
	_record("12 种单位的预设都能编译", preset_bad.is_empty(), str(preset_bad))

	_record("单位表 12 种", _main.unit_db.order.size() == 12, str(_main.unit_db.order.size()))
	_record("建筑表 15 种", _main.building_db.order.size() == 15, str(_main.building_db.order.size()))

	var red = _main.team_units(1)[0]["unit"]
	var blue = _main.team_units(0)[0]["unit"]
	var ground: float = float(_main.world.surface_height(60, 128))

	# 自爆无人机
	var kami := _spawn("kamikaze", Vector3(60.0, ground + 6.0, 128.0), 0)
	red.global_position = Vector3(61.0, ground + 6.0, 128.0)
	var red_hp0: float = red.hp
	_main._process_unit_abilities(0.016)
	_record("自爆无人机炸到敌人", red.hp < red_hp0, "%.0f -> %.0f" % [red_hp0, red.hp])
	_record("自爆后自己消失", not kami.alive)

	# 让红方单位复活，继续当靶子
	red.alive = true
	red.hp = red.max_hp
	red.visible = true
	red.set_physics_process(true)

	# 布雷车
	red.global_position = Vector3(200.0, ground + 6.0, 200.0)
	var minelayer := _spawn("minelayer", Vector3(64.0, ground + 1.0, 128.0), 0)
	_main._process_unit_abilities(2.1)
	_record("布雷车埋下地雷", _main.mines.size() > 0, str(_main.mines.size()))
	if _main.mines.size() > 0:
		var mine_pos: Vector3 = _main.mines[0]["pos"]
		red.global_position = mine_pos + Vector3(0.0, 0.6, 0.0)
		red.hp = red.max_hp
		var hp_before: float = red.hp
		_main._process_unit_abilities(2.0)
		_record("敌人踩雷受伤", red.hp < hp_before, "%.0f -> %.0f" % [hp_before, red.hp])
		_record("踩过之后这颗雷消失", _main.mines.size() <= 1, str(_main.mines.size()))

	# 维修无人机
	red.global_position = Vector3(220.0, ground + 6.0, 220.0)
	blue.global_position = Vector3(66.0, ground + 6.0, 128.0)
	blue.hp = blue.max_hp * 0.4
	var repair := _spawn("repair", Vector3(66.0, ground + 7.0, 128.0), 0)
	var blue_hp0: float = blue.hp
	_main._process_unit_abilities(1.0)
	_record("维修无人机给友军回血", blue.hp > blue_hp0, "%.0f -> %.0f" % [blue_hp0, blue.hp])

	# 平台无人机
	blue.energy_j = blue.energy_max * 0.2
	var carrier := _spawn("carrier", Vector3(66.0, ground + 12.0, 128.0), 0)
	var e0: float = blue.energy_j
	_main._process_unit_abilities(1.0)
	_record("平台无人机给友军回电", blue.energy_j > e0, "%.0f -> %.0f" % [e0, blue.energy_j])

	# 干扰机（飞行单位）压制敌方速度
	_main.power_pool[0] = 500.0
	var jammer := _spawn("jammer", Vector3(240.0, ground + 8.0, 240.0), 1)
	jammer.global_position = Vector3(70.0, ground + 8.0, 128.0)
	red.global_position = Vector3(70.0, ground + 8.0, 128.0)
	_main._refresh_jamming()
	_record("干扰机压制敌方", _main.team_units(0)[0]["controller"].line_rate < 1.0)

	# 钻地机钻头更长
	var bdef: Dictionary = _main.unit_db.get_def("burrower")
	var fdef: Dictionary = _main.unit_db.get_def("feifei")
	_record("钻地机钻头比飞飞长", float(bdef["drill"]["reach"]) > float(fdef["drill"]["reach"]))

	# 传送带加速矿机
	var spot := _flat(Vector2i(40, 130), 3, 3)
	if spot != Vector3i(-1, -1, -1):
		_main.economy.add("copper", 500)
		_main.economy.add("coal", 500)
		var err: String = _main.place_building_at("miner", spot, 0)
		# 把矿机旁边 3×3 的地面整平，再放传送带
		var stone: int = _main.db.id_of("stone")
		for dx in range(3):
			for dz in range(3):
				for dy in range(4):
					_main.world.set_block(Vector3i(spot.x + 3 + dx, int(spot.y) + dy, spot.z + dz), 0)
				_main.world.set_block(Vector3i(spot.x + 3 + dx, int(spot.y) - 1, spot.z + dz), stone)
		var con_spot := Vector3i(spot.x + 3, int(spot.y), spot.z)
		var err2: String = _main.place_building_at("conveyor", con_spot, 0)
		_record("放下矿机与传送带", err == "" and err2 == "", err + "|" + err2)
		if err == "" and err2 == "":
			var miner = _main.buildings[0]["node"]
			for entry in _main.buildings:
				entry["node"].build_left = 0.0
				entry["node"]._update_build_progress()
				if str(entry["id"]) == "miner":
					miner = entry["node"]
			_record("传送带给矿机加成", _main.conveyor_boost(miner) > 0.0, str(_main.conveyor_boost(miner)))
