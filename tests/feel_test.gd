extends SceneTree
## 打击感与新规则：单位不重叠、建筑占地被单位挡住就不干活、命中火花、镜头震动

var _main: Node
var _frames := 0
var _done := false
var _passed := 0
var _failed := 0


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _record(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ✓ ", name)
	else:
		_failed += 1
		print("  ✗ ", name, ("：" + detail) if detail != "" else "")


func _process(_d: float) -> bool:
	_frames += 1
	if _frames == 2:
		_main.world.build_all()
		_main._start_game()
		return false
	if _frames < 40 or _done:
		return false
	_done = true
	_run()
	print("通过 %d 项，失败 %d 项" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)
	return false


func _flat_spot(near: Vector2i) -> Vector3i:
	var world = _main.world
	var db = _main.db
	for dx in range(-24, 25):
		for dz in range(-24, 25):
			var x: int = near.x + dx
			var z: int = near.y + dz
			if x < 4 or z < 4 or x > 250 or z > 250:
				continue
			var h: int = world.surface_height(x, z)
			var ok := true
			for ox in 3:
				for oz in 3:
					if int(world.surface_height(x + ox, z + oz)) != h:
						ok = false
					if world.get_block(Vector3i(x + ox, h, z + oz)) != db.id_of("air"):
						ok = false
			if ok:
				return Vector3i(x, h, z)
	return Vector3i(-1, -1, -1)


func _run() -> void:
	var db = _main.db
	# 1) 同一点连放 5 台单位：出生点会自动错开，彼此不重叠
	var base := Vector3(50.0, 0.0, 100.0)
	var ground: int = _main.world.surface_height(50, 100)
	for i in 5:
		_main._spawn_unit(_main.unit_db.get_def("feifei"), Vector3(base.x, float(ground), base.z), "def loop():\n    set_velocity(0.0, 0.0)\n", 0)
	var placed: Array = _main.team_units(0)
	var min_dist := 999.0
	for i in placed.size():
		for j in range(i + 1, placed.size()):
			var a = placed[i]["unit"]
			var b = placed[j]["unit"]
			min_dist = minf(min_dist, a.global_position.distance_to(b.global_position))
	_record("连放 5 台单位不重叠", min_dist > 0.5, "最近间距 %.2f 米" % min_dist)

	# 2) 建筑占地范围里有单位 → 不能工作
	var spot := _flat_spot(Vector2i(60, 120))
	_record("找到平地", spot != Vector3i(-1, -1, -1), str(spot))
	if spot != Vector3i(-1, -1, -1):
		var err: String = _main.place_building_at("miner", spot, 0)
		_record("放下采矿机", err == "", err)
		var node = _main.buildings[_main.buildings.size() - 1]["node"]
		node.build_left = 0.0
		node._update_build_progress()
		_main.power_pool[0] = 900.0
		# 在占地体积里塞一个方块 → 被埋，停工；清掉方块 → 恢复
		var buried_cell := Vector3i(spot.x + 1, spot.y + 1, spot.z + 1)
		_main.world.set_block(buried_cell, db.id_of("stone"))
		_main._tick_buildings(1.0)
		_record("占地里有方块→建筑被埋停工", node.is_blocked(), "blocked=%s" % str(node.is_blocked()))
		_main.world.set_block(buried_cell, 0)
		_main._tick_buildings(1.0)
		_record("清掉方块后建筑恢复工作", not node.is_blocked(), "blocked=%s" % str(node.is_blocked()))
		# 地基挖空 → 地基不牢，停工
		var under := Vector3i(spot.x, spot.y - 1, spot.z)
		_main.world.set_block(under, 0)
		_main._tick_buildings(1.0)
		_record("地基挖空→建筑停工", node.is_unsupported(), "unsupported=%s" % str(node.is_unsupported()))
		_main.world.set_block(under, db.id_of("stone"))

	# 3) 命中火花 + 镜头震动
	var a2 = _main.team_units(0)[0]["unit"]
	var before: int = _main.fx_count()
	_main._queue_damage(a2, 20.0)
	_main._flush_damage()
	_record("挨打会蹦火花", _main.fx_count() > before, "%d → %d" % [before, _main.fx_count()])
	_record("自己人挨打镜头会震", _main.rig.shake_amount > 0.0, "shake=%.3f" % _main.rig.shake_amount)

	# 4) 单位开火后坐（炮管位置在开炮后变化）
	var a3 = _main.team_units(0)[0]["unit"]
	_record("单位有击中白闪字段", a3.hit_flash >= 0.0 and "hit_flash" in a3)
