extends SceneTree
## 生成 docs/preview-peace.png：开局发育时间倒计时

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
	elif _f == 120:
		# 往中间空地看一眼：能同时看到倒计时和地形
		var rig = _main.get_node("CameraRig")
		var h: int = int(_main.world.surface_height(60, 128))
		rig.position = Vector3(52.0, float(h) + 14.0, 128.0)
		rig.yaw = -1.5708
		rig.pitch = -0.18
	elif _f == 160:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-peace.png")
		print("SAVED")
		quit(0)
	return false
