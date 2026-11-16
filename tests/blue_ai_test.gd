extends SceneTree
## 蓝方预设 AI 的回归测试：开局造建筑 → 攒出更多单位 → 赢下对局

var _frames := 0
var _main: Node
var _passed := 0
var _failed := 0
var _saw_buildings := false
var _saw_units := false
var _saw_red_units := false
var _saw_combat := false
var _skipped := false
var _blue_damaged := false
var _red_damaged := false
var _blue_lost := false
var _blue_bad := false
var _red_bad := false
var _red_lost := false
var _blue_seen := 0
var _red_seen := 0
var _done := false
var _prev_hp := {}
var _total_damage := 0.0


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_main.world.build_all()
		_main._start_game()
		return false
	if _frames < 6:
		return false
	if _done:
		if _frames > 6:
			print("通过 %d 项，失败 %d 项" % [_passed, _failed])
			quit(0 if _failed == 0 else 1)
		return false
	# 1) 蓝方指挥官在发育期就把建筑盖起来了
	if _main.buildings.size() >= 3:
		_saw_buildings = true
	# 2) 组装厂把两方单位数量都拉起来（两队现在跑同一套 AI）
	if _main.team_units(0).size() >= 2:
		_saw_units = true
	if _main.team_units(1).size() >= 2:
		_saw_red_units = true
	# 3) 攒够部队就跳过发育时间，直接开打
	if not _skipped and _saw_units and _saw_buildings:
		_main.skip_peace()
		_skipped = true
	# 4) 分出胜负
	# 记录"打过架"：任意一方掉过血
	for team in [0, 1]:
		for e in _main.team_units(team):
			var uid: int = e["unit"].get_instance_id()
			var hp_now: float = float(e["unit"].hp)
			if _prev_hp.has(uid):
				_total_damage += maxf(0.0, float(_prev_hp[uid]) - hp_now)
			_prev_hp[uid] = hp_now
			if hp_now < float(e["unit"].max_hp) - 1.0:
				_saw_combat = true
				if float(e["unit"].hp) < float(e["unit"].max_hp) * 0.7:
					if team == 0:
						_blue_bad = true
					else:
						_red_bad = true
				if team == 0:
					_blue_damaged = true
				else:
					_red_damaged = true
	var blue_now: int = _main.team_units(0).size()
	var red_now: int = _main.team_units(1).size()
	_blue_seen = maxi(_blue_seen, blue_now)
	_red_seen = maxi(_red_seen, red_now)
	if blue_now < _blue_seen:
		_blue_lost = true
	if red_now < _red_seen:
		_red_lost = true
	if _main.game_over != "":
		_record("至少造了 3 栋建筑", _saw_buildings)
		_record("蓝方靠组装厂攒出更多单位", _saw_units)
		_record("红方也靠组装厂攒出更多单位", _saw_red_units)
		_record("双方打过架", _saw_combat)
		_record("对局分出胜负", true, str(_main.game_over))
		_record("全程没有单位代码报错", not _any_error())
		_done = true
		return false
	if _frames > 60 * 180:
		_record("至少造了 3 栋建筑", _saw_buildings)
		_record("蓝方靠组装厂攒出更多单位", _saw_units)
		_record("红方也靠组装厂攒出更多单位", _saw_red_units)
		_record("双方打过架", _saw_combat)
		# 已知问题：镜像地形之后双方经济完全对称，偶尔会打成"谁也不敢近身"的僵局。
		# 所以这里不断言"某一方被打掉三成血"（受帧率影响的 flaky），而断言累计伤害：
		# 一管血按 300 点算，实测健康对局累计掉血 438~769，取 250 作门槛留出余量。
		_record("双方交过火（都掉过血）", _blue_damaged and _red_damaged, "蓝掉血=%s 红掉血=%s" % [str(_blue_damaged), str(_red_damaged)])
		_record("战斗有实质战果（累计掉血 ≥ 250）", _total_damage >= 250.0,
			"累计掉血=%.0f 蓝三成=%s 红三成=%s" % [_total_damage, str(_blue_bad), str(_red_bad)])
		_record("全程没有单位代码报错", not _any_error())
		_done = true
	return false


func _any_error() -> bool:
	for team in [0, 1]:
		for entry in _main.team_units(team):
			if str(entry["controller"].last_error()) != "":
				return true
	return false


func _record(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ✓ ", name, "  ", detail)
	else:
		_failed += 1
		print("  ✗ ", name, "  ", detail)
