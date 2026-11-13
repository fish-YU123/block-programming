extends SceneTree
## 玩家出生视角截图（试玩检查用）

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
	elif _f == 200:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-spawn.png")
		print("SAVED")
		quit(0)
	return false
