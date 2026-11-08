extends SceneTree
var _f := 0
var _main: Node
func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)
func _process(_d: float) -> bool:
	_f += 1
	if _f == 2:
		_main.world.build_all()
		_main._start_game()
	elif _f == 60 or _f == 200:
		for t in [0, 1]:
			var list: Array = _main.team_units(t)
			var info := []
			for e in list:
				var u = e["unit"]
				info.append("%s alive=%s pos=%s hp=%.0f err='%s'" % [u.name, str(u.alive), str(u.global_position.snapped(Vector3(0.1,0.1,0.1))), u.hp, str(u.runtime_error)])
			print("frame", _f, " team", t, " 数量=", list.size(), " ", info)
		print("game_over='", _main.game_over, "' peace=", _main.peace_left)
	if _f == 210:
		quit(0)
	return false
