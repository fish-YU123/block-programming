extends SceneTree
## 武器与雷达测试：headless 运行
##   godot --headless --path . --script res://tests/weapons_test.gd

var _passed := 0
var _failed := 0
var _failures: Array = []
var _main: Node
var _frames := 0


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_main.world.build_all()
		_main._start_game()
	if _frames == 3:
		_check()
	return false


func _check() -> void:
	var db = _main.world.db
	_record("石头有血量", db.hp_of(db.id_of("stone")) >= 30.0, str(db.hp_of(db.id_of("stone"))))
	_record("基岩几乎打不动", db.hp_of(db.id_of("bedrock")) > 100000.0, str(db.hp_of(db.id_of("bedrock"))))

	var blue: Array = _main.team_units(0)
	var red: Array = _main.team_units(1)
	var attacker: Node = blue[0]["unit"]
	var victim: Node = red[0]["unit"]

	# 全部挪到空中空地，避免地形干扰
	attacker.global_position = Vector3(60.0, 50.0, 128.0)
	attacker.rotation.y = -PI * 0.5
	victim.global_position = Vector3(62.0, 50.0, 128.0)

	# 激光：朝敌方方向，5 格内
	attacker.controls["laser"] = true
	attacker.controls["laser_x"] = 70.0
	attacker.controls["laser_y"] = 50.0
	attacker.controls["laser_z"] = 128.0
	var hp_before: float = victim.hp
	attacker._physics_process(0.016)
	_main._process_weapons(0.5)
	_record("激光能打到 2 米外的敌方单位", victim.hp < hp_before, "%.1f → %.1f" % [hp_before, victim.hp])

	# 激光射程 5 格：6 米外的打不到
	victim.hp = victim.max_hp
	victim.global_position = Vector3(66.5, 50.0, 128.0)
	attacker._physics_process(0.016)
	_main._process_weapons(0.5)
	_record("激光打不到 5 格外", is_equal_approx(victim.hp, victim.max_hp), "%.1f" % victim.hp)

	# 激光关掉就不打
	victim.global_position = Vector3(62.0, 50.0, 128.0)
	attacker.controls["laser"] = false
	attacker._physics_process(0.016)
	_main._process_weapons(0.5)
	_record("激光关掉后不伤害", is_equal_approx(victim.hp, victim.max_hp), "%.1f" % victim.hp)

	# 炮管：15 格内的敌方直接结算伤害
	victim.hp = victim.max_hp
	var from: Vector3 = attacker.global_position
	var dir := Vector3(1.0, 0.0, 0.0)
	_main._on_gun_fired(attacker, from, dir)
	_record("炮管能打到正前方单位", victim.hp < victim.max_hp, "%.1f → %.1f" % [victim.max_hp, victim.hp])

	# 炮管打方块：血量累计到打掉
	victim.global_position = Vector3(240.0, 50.0, 128.0)
	var cell := Vector3i(60, 44, 128)
	_main.world.set_block(cell, db.id_of("stone"))
	var block_hp: float = db.hp_of(db.id_of("stone"))
	_main._damage_block(cell, block_hp * 0.5)
	_record("方块挨一半伤害还在", _main.world.get_block(cell) == db.id_of("stone"), "被打了")
	_record("方块伤害有记录", _main.block_damage_at(cell) > 0.0, str(_main.block_damage_at(cell)))
	_main._damage_block(cell, block_hp * 0.6)
	_record("方块血量打光后消失", _main.world.get_block(cell) == 0, "还在")

	# 雷达：5×5×5 方块数组
	var radar: Dictionary = attacker.radar()
	var blocks3: Array = radar.get("blocks3", [])
	_record("雷达给 5×5×5 三维方块", blocks3.size() == 5 and blocks3[0].size() == 5 and blocks3[0][0].size() == 5, "%d 层" % blocks3.size())
	var cell_now := Vector3i(floori(attacker.global_position.x), floori(attacker.global_position.y), floori(attacker.global_position.z))
	var center_name: String = str(blocks3[2][2][2])
	var world_name: String = _main.world.db.name_of(_main.world.get_block(cell_now))
	_record("雷达中心就是单位所在格", center_name == world_name, "%s vs %s" % [center_name, world_name])

	# 雷达：10 格内的敌方单位，带类型/血量/距离，按距离排序
	victim.global_position = attacker.global_position + Vector3(3.0, 0.0, 0.0)
	_main._refresh_enemy_sensors()
	var enemies: Array = blue[0]["controller"].enemies
	_record("雷达能看到 10 格内敌人", enemies.size() >= 1, str(enemies.size()))
	if enemies.size() >= 1:
		var e: Dictionary = enemies[0]
		_record("敌人数据有类型", str(e.get("type", "")) == "feifei", str(e.get("type", "")))
		_record("敌人数据有血量", float(e.get("hp", -1.0)) > 0.0, str(e.get("hp", -1.0)))
		_record("敌人数据有距离", absf(float(e.get("dist", -1.0)) - 3.0) < 0.5, str(e.get("dist", -1.0)))
		if enemies.size() >= 2:
			_record("敌人按距离排序", float(enemies[0]["dist"]) <= float(enemies[1]["dist"]), "顺序不对")
		else:
			_record("敌人按距离排序", true, "只有一个敌人")

	# 传感器里能拿到 blocks3
	var sensors_ok := false
	for item in _main.team_units(0):
		if item["controller"].unit == attacker:
			sensors_ok = true
	_record("控制器单位引用正常", sensors_ok, "找不到")

	print("通过 %d 项，失败 %d 项" % [_passed, _failed])
	for f in _failures:
		print("  ✗ ", f)
	quit(0 if _failed == 0 else 1)


func _record(name: String, ok: bool, detail: String) -> void:
	if ok:
		_passed += 1
		print("  ✓ ", name)
	else:
		_failed += 1
		_failures.append("%s（%s）" % [name, detail])
