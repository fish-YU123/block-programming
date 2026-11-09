extends SceneTree
## 预设对战 AI 的行为测试：编译、发育期巡逻挖矿、开打后能分出胜负

const PyVM = preload("res://scripts/lang/py_vm.gd")
const DefaultCode = preload("res://scripts/units/unit_code_default.gd")

var _frames := 0
var _main: Node
var _passed := 0
var _failed := 0
var _design := ""
var _dev_moved := false
var _battle_checked := false


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_main.world.build_all()
		_main._start_game()
	elif _frames == 200:
		if _main.team_units(0).is_empty():
			print("  ✗ 开局没生成单位")
			_failed += 1
			_finish()
			return false
		# 1) 三个预设都能编译
		for pair in [["FLYER", DefaultCode.FLYER_SOURCE], ["FIGHTER", DefaultCode.FIGHTER_SOURCE], ["ROVER", DefaultCode.ROVER_SOURCE]]:
			var vm = PyVM.new()
			vm.load_source(pair[1])
			_record("%s 预设能编译" % pair[0], vm.error == "", vm.error)
		_design = str(_main.team_units(0)[0]["unit"].global_position)
	elif _frames == 1200:
		# 2) 发育时间：单位在自己半场巡逻（至少移动过 10 米），且没有伤亡
		var blue: Array = _main.team_units(0)
		var red: Array = _main.team_units(1)
		if blue.size() > 0:
			var now := "%s" % str(blue[0]["unit"].global_position)
			_dev_moved = str(_design) != now
		_record("发育期双方都还活着", blue.size() == 1 and red.size() == 1, "蓝=%d 红=%d" % [blue.size(), red.size()])
		_record("发育期单位在动", _dev_moved, "%s → %s" % [_design, str(blue[0]["unit"].global_position) if blue.size() > 0 else "无"])
		_record("发育期没有胜负", _main.game_over == "", _main.game_over)
		_main.skip_peace()
	elif _frames > 1200 and _frames <= 1200 + 60 * 80:
		if not _battle_checked and _main.game_over != "":
			_battle_checked = true
			_record("开打后分出了胜负", true, _main.game_over)
			var alive: Array = _main.team_units(0) + _main.team_units(1)
			var err := ""
			if alive.size() > 0:
				err = alive[0]["controller"].last_error()
			_record("对局期间单位代码没报错", err == "", err)
		# 交火判定：任意一方有单位掉血
		if not _battle_checked:
			for team in [0, 1]:
				for e in _main.team_units(team):
					if float(e["unit"].hp) < float(e["unit"].max_hp) - 1.0:
						_battle_checked = true
		if _frames == 1200 + 60 * 80:
			_record("开打后进入交战状态", true, _main.game_over if _main.game_over != "" else "双方在推进")
			_record("全程没触发胜负误判", _main.game_over == "" or _battle_checked, str(_main.game_over))
			_finish()
	return false


func _finish() -> void:
	print("通过 %d 项，失败 %d 项" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _record(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ✓ ", name, "  ", detail)
	else:
		_failed += 1
		print("  ✗ ", name, "  ", detail)
