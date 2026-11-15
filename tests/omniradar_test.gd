extends SceneTree
## 全景雷达：全图方块查询 + 全图单位（位置/种类/队伍，本方还给血量）

var _frames := 0
var _main: Node
var _passed := 0
var _failed := 0


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_main.world.build_all()
		_main._start_game()
		_main.skip_peace()
	if _frames == 3:
		_check()
		print("通过 %d 项，失败 %d 项" % [_passed, _failed])
		quit(0 if _failed == 0 else 1)
	return false


func _check() -> void:
	_main.economy.add("copper", 300)
	_main.economy.add("iron", 200)
	_main.economy.add("steel", 100)
	_main.power_pool[0] = 2000.0

	var spot := _flat(Vector2i(40, 128), 3, 3)
	_record("找到能放全景雷达的平地", spot != Vector3i(-1, -1, -1), str(spot))
	if spot == Vector3i(-1, -1, -1):
		return
	var err: String = _main.place_building_at("omniradar", spot, 0)
	_record("全景雷达能放下", err == "", err)
	# 直接跳到完工
	for entry in _main.buildings:
		entry["node"].build_left = 0.0
		entry["node"]._update_build_progress()
	_main._tick_buildings(1.5)
	_record("通电后本方全景雷达在线", _main.team_has_omniradar(0), "没在线")
	_record("敌方没有全景雷达", not _main.team_has_omniradar(1), "敌方也看到了")

	# 1) 全图方块查询
	var check_cell := Vector3i(spot.x + 1, spot.y - 1, spot.z + 1)
	var block_name: String = _main.omni_block_name_at(0, check_cell.x, check_cell.y, check_cell.z)
	_record("能查到地图上任意格子的方块", block_name != "", block_name)
	_main.world.set_block(Vector3i(check_cell.x, check_cell.y + 3, check_cell.z), _main.db.id_of("stone"))
	_record("查得到自己放的方块", _main.omni_block_name_at(0, check_cell.x, check_cell.y + 3, check_cell.z) == "stone", "")
	_record("敌方没有雷达就查不到", _main.omni_block_name_at(1, check_cell.x, check_cell.y, check_cell.z) == "", "")
	_record("越界返回空", _main.omni_block_name_at(0, -5, 10, 10) == "", "")

	# 2) 全图单位：位置/种类/队伍；本方有血量，敌方没有
	var seen: Array = _main.omni_units_for(0)
	_record("能看到所有单位", seen.size() >= 2, str(seen.size()))
	var saw_blue := false
	var saw_red := false
	var blue_has_hp := false
	var red_leaks_hp := false
	for u in seen:
		if int(u["team"]) == 0:
			saw_blue = true
			if u.has("hp") and u.has("hp_max"):
				blue_has_hp = true
		else:
			saw_red = true
			if u.has("hp"):
				red_leaks_hp = true
		_record("每个单位都有位置与种类", u.has("x") and u.has("y") and u.has("z") and u.has("type"), str(u))
	_record("看得到本方单位", saw_blue, "")
	_record("看得到敌方单位", saw_red, "")
	_record("本方单位带血量与最大血量", blue_has_hp, "")
	_record("敌方单位不暴露血量", not red_leaks_hp, "")

	# 3) 传感器真的注入到单位代码里
	var entry: Dictionary = _main.units[0]
	var controller = entry["controller"]
	controller.omni_enabled = true
	controller.omni_units = _main.omni_units_for(0)
	controller.block_at_provider = func(x: int, y: int, z: int) -> String:
		return _main.omni_block_name_at(0, x, y, z)
	var payload: Dictionary = controller._sensor_payload(true)
	_record("传感器 units 里有单位", (payload["units"] as Array).size() >= 2, str((payload["units"] as Array).size()))

	# 4) 玩家代码里能直接调 block_at()
	controller.bind(entry["unit"], "def loop():\n    team_set(\"看到的方块\", block_at(%d, %d, %d))\n    team_set(\"单位数\", len(units))\n" % [check_cell.x, check_cell.y, check_cell.z, ], int(entry["revision"]) + 1)
	for i in range(20):
		controller.tick(0.1)
	_record("单位代码里能查方块", str(_main._board_for(0).get("看到的方块", "")) == block_name, str(_main._board_for(0).get("看到的方块", "")))
	_record("单位代码里能数单位", int(_main._board_for(0).get("单位数", 0)) >= 2, str(_main._board_for(0).get("单位数", 0)))

	# 5) 雷达被打掉后当帧失效
	_main.buildings.clear()
	_main.power_pool[0] = 0.0
	# 走一帧完整的物理帧：主循环会先清空「在线」标记，再由还在的雷达重新上报
	_main._physics_process(1.0 / 60.0)
	_record("没有雷达后全图视野立刻失效", not _main.team_has_omniradar(0), "还在线")


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
			if flat and w.get_block(Vector3i(x, h, z)) == _main.db.id_of("air"):
				return Vector3i(x, h, z)
	return Vector3i(-1, -1, -1)


func _record(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ✓ ", name)
	else:
		_failed += 1
		print("  ✗ ", name, "：", detail)
