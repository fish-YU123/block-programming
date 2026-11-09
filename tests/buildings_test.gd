extends SceneTree
## 建筑测试：数据表、放置校验、矿机采矿、组装厂产单位、拆除退款。

var _passed := 0
var _failed := 0
var _done := false
var _main: Node


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


func _flat_spot(near_x: int, near_z: int) -> Vector3i:
	## 找一块 3×3 都平、上方无方块的地方，返回建筑底部格
	var world = _main.world
	for dx in range(-20, 21):
		for dz in range(-20, 21):
			var x: int = near_x + dx
			var z: int = near_z + dz
			if x < 2 or z < 2 or x > 96 or z > 253:
				continue
			var h: int = world.surface_height(x, z)
			var flat := true
			for ox in 3:
				for oz in 3:
					if int(world.surface_height(x + ox, z + oz)) != h:
						flat = false
			if not flat:
				continue
			return Vector3i(x, int(h), z)
	return Vector3i(-1, -1, -1)


func _process(_delta: float) -> bool:
	if _done:
		return false
	_done = true
	var world = _main.world
	var economy = _main.economy
	var db = _main.db

	# 1) 建筑数据表
	_record("建筑表加载 3 种", _main.building_db.order.size() == 3, str(_main.building_db.order))
	_record("采矿机尺寸 3×2×3", _main.building_db.size_of("miner") == Vector3i(3, 2, 3))
	_record("组装厂尺寸 3×3×3", _main.building_db.size_of("factory") == Vector3i(3, 3, 3))
	_record("采矿机周期 1.2 秒", is_equal_approx(_main.building_db.period_of("miner"), 1.2))

	# 2) 放置采矿机
	economy.add("copper", 200)
	economy.add("coal", 200)
	var copper_after_start: int = economy.amount("copper")
	var spot := _flat_spot(40, 128)
	_record("找到平地", spot.x > 0, str(spot))
	var err: String = _main.place_building_at("miner", spot)
	_record("放下采矿机", err == "", err)
	_record("建筑数量 1", _main.buildings.size() == 1)
	_record("扣了建造费", economy.amount("copper") == copper_after_start - 20, "%d" % economy.amount("copper"))

	var miner_entry: Dictionary = _main.buildings[0]
	var miner = miner_entry["node"]
	# 建造要花时间：刚放下时应该在施工中
	_record("刚放下时在施工", miner.is_under_construction(), "剩余 %.1f 秒" % miner.build_left)
	_record("施工中模型是矮的", miner.scale.y < 0.6, "%.2f" % miner.scale.y)
	_main._tick_buildings(11.0)
	_record("10 秒后建好", not miner.is_under_construction() and is_equal_approx(miner.scale.y, 1.0))

	# 3) 矿机在脚下放一块铜矿，应当挖掉并进账
	var center: Vector3i = miner.center_cell()
	var ore_cell := Vector3i(center.x, int(spot.y) - 1, center.z)
	world.set_block(ore_cell, db.id_of("copper_ore"))
	var copper_before: int = economy.amount("copper")
	_main._tick_buildings(1.5)
	_record("矿机挖掉矿石", world.get_block(ore_cell) == 0 or economy.amount("copper") > copper_before, str(world.get_block(ore_cell)))
	_record("矿机产出铜 +1", economy.amount("copper") == copper_before + 1, "%d -> %d" % [copper_before, economy.amount("copper")])

	# 4) 重叠放置被拒绝
	var err2: String = _main.place_building_at("miner", spot)
	_record("重叠放置被拒绝", err2 != "", err2)

	# 5) 敌方半场放置被拒绝
	var err3: String = _main.place_building_at("miner", Vector3i(230, spot.y, 128))
	_record("敌方半场不能建", err3.contains("半场"), err3)

	# 6) 组装厂：资源够 → 周期后产出一台单位
	var spot2 := _flat_spot(60, 128)
	var err4: String = _main.place_building_at("factory", spot2)
	_record("放下组装厂", err4 == "", err4)
	var factory_node = _main.buildings[_main.buildings.size() - 1]["node"]
	factory_node.build_left = 0.0
	factory_node._update_build_progress()
	var units_before: int = _main.units.size()
	var copper_pre: int = economy.amount("copper")
	_main._tick_buildings(19.0)
	_record("组装厂产出一台单位", _main.units.size() == units_before + 1, "%d -> %d" % [units_before, _main.units.size()])
	# 同一帧里采矿机也可能挖到一块铜，所以扣款数额允许 22~26 的浮动（标称 25）
	var spent: int = copper_pre - economy.amount("copper")
	_record("产生时扣了资源", spent >= 22 and spent <= 26, "扣了 %d（%d -> %d）" % [spent, copper_pre, economy.amount("copper")])

	# 7) 资源不足时组装厂不产单位
	economy.spend({"copper": economy.amount("copper"), "coal": economy.amount("coal")})
	var units_before2: int = _main.units.size()
	_main._tick_buildings(19.0)
	_record("没资源就不产单位", _main.units.size() == units_before2)

	# 8) 拆除退款
	var copper_pre2: int = economy.amount("copper")
	var count_before: int = _main.buildings.size()
	_main._remove_last_building()
	_record("拆掉一栋建筑", _main.buildings.size() == count_before - 1)
	_record("拆除退回资源", economy.amount("copper") > copper_pre2, "%d -> %d" % [copper_pre2, economy.amount("copper")])

	# 充电站：给半径内的己方单位补电
	var charger_base := _flat_spot(24, 96)
	if charger_base != Vector3i(-1, -1, -1):
		var charger_err: String = _main.place_building_at("charger", charger_base, 0)
		_record("充电站能放置", charger_err == "", charger_err)
		if _main.buildings.size() > 0:
			var cn = _main.buildings[_main.buildings.size() - 1]["node"]
			cn.build_left = 0.0
			cn._update_build_progress()
		var unit = _main.team_units(0)[0]["unit"]
		unit.global_position = _main.buildings[-1]["node"].center_world() + Vector3(3.0, 0.0, 0.0)
		unit.energy_j = 1000.0
		_main._tick_buildings(1.0)
		_record("充电站给单位充电", unit.energy_j > 1000.0, "电量 %.0f" % unit.energy_j)
		unit.energy_j = unit.energy_max
		_main._tick_buildings(1.0)
		_record("充满后不再升", unit.energy_j <= unit.energy_max + 0.1, "电量 %.0f" % unit.energy_j)

	print("通过 %d 项，失败 %d 项" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)
	return false
