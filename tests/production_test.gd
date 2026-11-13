extends SceneTree
## 生产建筑：选择生产哪种单位 + 下线单位用对应预设代码

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
	for dx in range(-16, 17):
		for dz in range(-16, 17):
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


func _run() -> void:
	var def: Dictionary = _main.building_db.get_def("factory")
	_record("组装厂有生产选项", def.has("options") and (def["options"] as Array).size() >= 3, str(def.get("options", [])))
	var spots: Array = _main.building_db.get_def("factory").get("options", [])
	_record("组装厂能产炮艇", spots.has("gunship"))

	_main.economy.add("copper", 600)
	_main.economy.add("coal", 600)
	_main.economy.add("iron", 200)
	_main.economy.add("steel", 200)
	var spot := _flat(Vector2i(40, 120), 3, 3)
	var err: String = _main.place_building_at("factory", spot, 0)
	_record("放下组装厂", err == "", err)
	var entry: Dictionary = _main.buildings[_main.buildings.size() - 1]
	var node = entry["node"]
	# 直接跳过施工，方便测生产
	node.build_left = 0.0
	node._update_build_progress()
	_record("默认产物是飞飞", node.produce_id == "feifei", node.produce_id)

	# 循环切换
	var first: String = node.cycle_production(1)
	_record("cycle 切到下一个", first != "feifei" and node.produce_id == first, first)
	for i in range(20):
		node.cycle_production(1)
	_record("cycle 能绕回选项里", (node.production_options() as Array).has(node.produce_id), node.produce_id)

	# 指定生产
	_record("能指定生产炮艇", node.set_production("gunship") == "", node.produce_id)
	var bad: String = node.set_production("不存在的单位")
	_record("不在选项里的单位被拒绝", bad != "" and node.produce_id == "gunship", bad)

	# 下线一台炮艇：应该用炮艇的预设代码
	var before: int = _main.team_units(0).size()
	_main._produce_unit(node)
	var after_units: Array = _main.team_units(0)
	_record("组装厂产出一台单位", after_units.size() == before + 1, "%d -> %d" % [before, after_units.size()])
	var fresh: Dictionary = after_units[after_units.size() - 1]
	_record("产出的确实是炮艇", str(fresh["unit"].unit_id) == "gunship", str(fresh["unit"].unit_id))
	_record("新单位用的是炮艇预设代码", str(fresh["code"]) == _main._preset_for_unit(_main.unit_db.get_def("gunship")), "len=%d" % str(fresh["code"]).length())

	# 单位代码里 produce("scout") 能改旁边厂的生产
	var reader := """def start():
    mem["试过"] = 0

def loop():
    if mem["试过"] == 0:
        team_set("改生产结果", produce("scout"))
        mem["试过"] = 1
    set_velocity(0.0, 0.0)
"""
	var controller = fresh["controller"]
	controller.board = _main._board_for(0)
	# 把新单位挪到厂房旁边，才能找到这座厂
	fresh["unit"].global_position = node.center_world() + Vector3(0.0, 3.0, 0.0)
	controller.bind(fresh["unit"], reader, 61)
	for i in range(80):
		controller.tick(1.0 / 60.0)
	_record("代码里 produce() 能改生产", str(node.produce_id) == "scout", node.produce_id)
	_record("produce() 返回空串表示成功", str(_main.team_boards[0].get("改生产结果", "x")) == "", str(_main.team_boards[0].get("改生产结果", "x")))
	_record("改生产的代码没报错", not controller.halted(), controller.last_error())
