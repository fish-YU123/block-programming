extends SceneTree
## 生成 docs/preview-codepanel.png：右侧代码面板
var _f := 0
var _main: Node


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_f += 1
	if _f == 30:
		var mine: Array = _main.team_units(0)
		_main._open_code_for(int(mine[0]["uid"]))
	elif _f == 45:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-codepanel.png")
		print("SAVED")
		quit(0)
	return false
