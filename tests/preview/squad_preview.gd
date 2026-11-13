extends SceneTree
## 生成 docs/preview-squad.png：队伍面板（Tab）

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
	elif _f == 400:
		_main.hud.toggle_squad()
		_main.hud.set_squad("飞飞_1  HP 82%  电 64%  飞行中\n车车_2  HP 95%  电 90%  待命\n炮艇_3  HP 100% 电 71% 指令 attack\n建筑工_4  HP 100% 电 88% 涉水")
	elif _f == 440:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-squad.png")
		print("SAVED")
		quit(0)
	return false
