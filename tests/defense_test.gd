extends SceneTree
## 指挥中心 / 护盾发生器 / 干扰塔 / 炮艇 的 headless 测试

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


func _run() -> void:
	_record("建筑表有 14 种", _main.building_db.order.size() == 15, str(_main.building_db.order.size()))
	_record("单位表里有炮艇", _main.unit_db.has("gunship"))
	_main.economy.add("copper", 900)
	_main.economy.add("iron", 400)
	_main.economy.add("coal", 600)
	_main.economy.add("steel", 300)
	_main.economy_red.add("copper", 900)
	_main.economy_red.add("iron", 400)
	_main.economy_red.add("coal", 600)
	_main.economy_red.add("steel", 300)

	# 1) 指挥中心被毁 = 直接判负
	var cp_spot := _flat(Vector2i(200, 130), 3, 3)
	var errcp: String = _main.place_building_at("commandpost", cp_spot, 1)
	_record("放下红方指挥中心", errcp == "", errcp)
	if errcp == "":
		var cp = _main.buildings[_main.buildings.size() - 1]["node"]
		cp.build_left = 0.0
		cp._update_build_progress()
		_main._damage_building(cp, 100000.0)
		_record("红方指挥中心被拆后记录判负", _main.command_lost[1])
		# 触发胜负结算
		_main.game_over = ""
		_main._physics_frames = 999
		_main._check_victory()
		_record("胜负结算为蓝方胜利", _main.game_over == "蓝方胜利", _main.game_over)
		_main.game_over = ""

	# 2) 护盾吸收伤害（耗电）
	var sh_spot := _flat(Vector2i(30, 132), 2, 2)
	var errsh: String = _main.place_building_at("shield", sh_spot, 0)
	_record("放下护盾发生器", errsh == "", errsh)
	if errsh == "":
		var sh = _main.buildings[_main.buildings.size() - 1]["node"]
		sh.build_left = 0.0
		sh._update_build_progress()
		_main.power_pool[0] = 500.0
		var u = _main.team_units(0)[0]["unit"]
		u.global_position = sh.center_world() + Vector3(2.0, 0.0, 0.0)
		var power0: float = _main.power_of(0)
		var blocked: bool = _main.shield_absorbs(0, u.global_position)
		_record("护盾罩住的单位能吸收伤害", blocked)
		_record("吸收伤害会耗电", _main.power_of(0) < power0)
		var far: Vector3 = sh.center_world() + Vector3(40.0, 0.0, 0.0)
		_record("护盾罩不到的地方不吸收", not _main.shield_absorbs(0, far))

	# 3) 干扰塔让敌方代码变慢
	var jt_spot := _flat(Vector2i(46, 136), 2, 2)
	var errjt: String = _main.place_building_at("jammertower", jt_spot, 0)
	_record("放下干扰塔", errjt == "", errjt)
	if errjt == "":
		var jt = _main.buildings[_main.buildings.size() - 1]["node"]
		jt.build_left = 0.0
		jt._update_build_progress()
		_main.power_pool[1] = 500.0
		_main._tick_buildings(1.0)
		var blue = _main.team_units(0)[0]
		var red = _main.team_units(1)[0]
		red["unit"].global_position = jt.center_world() + Vector3(3.0, 0.0, 0.0)
		blue["unit"].global_position = jt.center_world() + Vector3(3.0, 0.0, 0.0)
		_main._refresh_jamming()
		_record("干扰塔压制敌方代码速度", red["controller"].line_rate < 1.0, str(red["controller"].line_rate))
		_record("干扰塔不影响自己人", is_equal_approx(blue["controller"].line_rate, 1.0), str(blue["controller"].line_rate))

	# 4) 炮艇预设能编译
	var gdef: Dictionary = _main.unit_db.get_def("gunship")
	_record("炮艇预设能编译", _main._preset_for_unit(gdef) != "")
