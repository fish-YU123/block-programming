extends SceneTree
## 建筑血量 / 能源网格 / 哨戒炮塔 的 headless 测试

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
	if _frames < 2:
		return false
	if _done:
		return false
	_done = true
	_main.world.build_all()
	_main._start_game()
	_main.skip_peace()
	# 冻结两边 AI 代码，免得它们乱动 / 乱造
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
	_record("建筑表读到 8 种", _main.building_db.order.size() == 8, str(_main.building_db.order.size()))
	_record("有发电站/储能站/炮塔", _main.building_db.has("powerplant") and _main.building_db.has("battery") and _main.building_db.has("turret"))

	# 1) 建筑血量与摧毁
	var spot := _flat(Vector2i(30, 120), 3, 3)
	var err: String = _main.place_building_at("miner", spot, 0)
	_record("放下采矿机", err == "", err)
	if err == "":
		var node = _main.buildings[_main.buildings.size() - 1]["node"]
		node.build_left = 0.0
		node._update_build_progress()
		var hp0: float = float(node.max_hp)
		_record("建筑有血量", hp0 > 100.0, str(hp0))
		_main._damage_building(node, 50.0)
		_record("扣血生效", node.hp < hp0)
		var before: int = _main.buildings.size()
		_main._damage_building(node, hp0)
		_record("血掉光后从列表移除", _main.buildings.size() == before - 1)

	# 2) 发电站产电（烧煤）
	_main.economy.add("coal", 10)
	_main.economy.add("copper", 200)
	_main.economy.add("iron", 100)
	var p_spot := _flat(Vector2i(50, 120), 3, 3)
	err = _main.place_building_at("powerplant", p_spot, 0)
	_record("放下发电站", err == "", err)
	var power0: float = _main.power_of(0)
	var coal0: int = _main.economy.amount("coal")
	if err == "":
		var plant = _main.buildings[_main.buildings.size() - 1]["node"]
		plant.build_left = 0.0
		plant._update_build_progress()
		_main._tick_buildings(5.0)
		_record("发电站产出电力", _main.power_of(0) > power0, "%.0f -> %.0f" % [power0, _main.power_of(0)])
		_record("发电站烧掉了煤", _main.economy.amount("coal") < coal0, "%d -> %d" % [coal0, _main.economy.amount("coal")])

	# 3) 储能站抬上限
	var cap0: float = _main.power_cap(0)
	var b_spot := _flat(Vector2i(60, 120), 2, 2)
	err = _main.place_building_at("battery", b_spot, 0)
	if err == "":
		var batt = _main.buildings[_main.buildings.size() - 1]["node"]
		batt.build_left = 0.0
		batt._update_build_progress()
	_record("储能站抬高电力上限", _main.power_cap(0) > cap0, "%.0f -> %.0f" % [cap0, _main.power_cap(0)])

	# 4) 充电站耗电
	var c_spot := _flat(Vector2i(70, 120), 2, 2)
	err = _main.place_building_at("charger", c_spot, 0)
	if err == "":
		var charger = _main.buildings[_main.buildings.size() - 1]["node"]
		charger.build_left = 0.0
		charger._update_build_progress()
		var unit = _main.team_units(0)[0]["unit"]
		unit.global_position = charger.center_world() + Vector3(0.0, 2.0, 0.0)
		unit.energy_j = unit.energy_max * 0.3
		_main.power_pool[0] = 100.0
		var e0: float = unit.energy_j
		_main._tick_buildings(0.6)
		_record("充电站给单位补电", unit.energy_j > e0, "%.0f -> %.0f" % [e0, unit.energy_j])
		_record("充电站消耗电力", _main.power_of(0) < 100.0, "%.1f" % _main.power_of(0))
		# 没电时罢工
		_main.power_pool[0] = 0.0
		_main._tick_buildings(0.6)
		_record("没电时充电站显示停机", charger.is_stalled())

	# 5) 哨戒炮塔
	var t_spot := _flat(Vector2i(80, 130), 2, 2)
	err = _main.place_building_at("turret", t_spot, 0)
	_record("放下炮塔", err == "", err)
	if err == "":
		var turret = _main.buildings[_main.buildings.size() - 1]["node"]
		turret.build_left = 0.0
		turret._update_build_progress()
		var red = _main.team_units(1)[0]["unit"]
		red.global_position = turret.center_world() + Vector3(0.0, 1.5, 3.0)
		var rhp: float = red.hp
		_main.power_pool[0] = 1000.0
		_main._tick_buildings(0.8)
		_record("炮塔打掉敌方血量", red.hp < rhp, "%.0f -> %.0f" % [rhp, red.hp])
		_main.power_pool[0] = 0.0
		_main._tick_buildings(0.8)
		_record("没电时炮塔停机", turret.is_stalled())

	# 6) 建筑可以被激光/炮弹打到（走 _building_ray_hit）
	var hit: Dictionary = _main._building_ray_hit(Vector3(t_spot) + Vector3(1.0, 1.0, -6.0), Vector3(0.0, 0.0, 1.0), 12.0, 1)
	_record("射线能打到敌方建筑", not hit.is_empty())
	var own: Dictionary = _main._building_ray_hit(Vector3(t_spot) + Vector3(1.0, 1.0, -6.0), Vector3(0.0, 0.0, 1.0), 12.0, 0)
	_record("射线不打自己人的建筑", own.is_empty())
