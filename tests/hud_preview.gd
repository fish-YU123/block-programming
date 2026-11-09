extends SceneTree
## 生成 docs/preview-hud.png：新的 HUD 面板 + 发育进度条

var _frames := 0
var _main: Node


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_main.world.build_all()
		_main._start_game()
	elif _frames == 200:
		var rig = _main.get_node("CameraRig")
		rig.input_enabled = false
		var ground: float = float(_main.world.surface_height(34, 128))
		rig.position = Vector3(22.0, ground + 9.0, 118.0)
		var target := Vector3(44.0, ground + 1.0, 130.0)
		var d: Vector3 = target - rig.position
		rig.yaw = atan2(-d.x, -d.z)
		rig.pitch = -0.24
	elif _frames == 240:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-hud.png")
		print("SAVED")
		quit(0)
	return false
