extends SceneTree
## M5 战斗与胜负测试：headless 运行
##   godot --headless --path . --script res://tests/combat_test.gd

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
	var blue: Array = _main.team_units(0)
	var red: Array = _main.team_units(1)
	_record("开局有蓝队单位", blue.size() == 1, str(blue.size()))
	_record("开局有红队单位", red.size() == 1, str(red.size()))
	_record("蓝队单位队伍标记正确", int(blue[0]["team"]) == 0, str(blue[0]["team"]))
	_record("红队单位队伍标记正确", int(red[0]["team"]) == 1, str(red[0]["team"]))

	var attacker: Node3D = blue[0]["unit"]
	var victim: Node3D = red[0]["unit"]
	# 把红队一台挪到蓝队正前方 1 米
	attacker.global_position = Vector3(60.0, 40.0, 128.0)
	attacker.rotation.y = -PI * 0.5  # 朝 +X
	victim.global_position = Vector3(60.9, 40.0, 128.0)
	attacker.controls["drill"] = true
	var hp_before: float = victim.hp
	_main._process_combat(0.5)
	_record("钻头能打到敌方单位", victim.hp < hp_before, "%.1f → %.1f" % [hp_before, victim.hp])

	# 离远了就打不到
	var old_pos: Vector3 = victim.global_position
	victim.global_position = attacker.global_position + Vector3(6.0, 0.0, 0.0)
	victim.hp = hp_before
	_main._process_combat(0.5)
	_record("距离太远打不到", is_equal_approx(victim.hp, hp_before), "%.1f" % victim.hp)
	victim.global_position = old_pos

	# 打不死自己人
	var friend: Node3D = _main.team_units(0)[0]["unit"]
	_main._process_combat(0.5)
	_record("不会误伤队友", is_equal_approx(friend.hp, friend.max_hp), "%.1f" % friend.hp)

	# 打死之后从场上移除
	victim.take_damage(victim.hp)
	_record("血量归零后失去战斗能力", not victim.alive, "还活着")
	_main._purge_dead()
	_record("死亡单位被清理", _main.team_units(1).size() == 0, str(_main.team_units(1).size()))

	# 红方全灭 → 蓝方胜利
	for entry in _main.team_units(1):
		var unit: Node3D = entry["unit"]
		unit.take_damage(unit.hp)
	_main._purge_dead()
	_main._physics_frames = 100
	_main._check_victory()
	_record("红方全灭蓝方胜利", _main.game_over == "蓝方胜利", _main.game_over)
	_record("胜利时显示结算文字", _main.hud.overlay_label.text.find("蓝方胜利") >= 0, _main.hud.overlay_label.text)

	print("通过 %d 项，失败 %d 项" % [_passed, _failed])
	for item in _failures:
		print("  ✗ " + item)
	quit(0 if _failed == 0 else 1)


func _record(name: String, ok: bool, detail: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append("%s：%s" % [name, detail])
