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
		_main.skip_peace()
	elif _f % 120 == 0 and _f <= 600:
		for e in _main.units:
			var u = e["unit"]
			var c = e["controller"]
			var vm = c._vm
			print("f=", _f, " id=", e.get("def", {}).get("id", "?"), " gh=", u.has_goal,
				" go=", vm.state["controls"].get("go", false),
				" vel=", vm.state["controls"].get("vel_mode", false),
				" pos=", u.global_position.snapped(Vector3(1,1,1)),
				" err=", vm.error.left(40))
	elif _f == 620:
		quit(0)
	return false
