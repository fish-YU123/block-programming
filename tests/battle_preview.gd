extends SceneTree
## 生成 docs/preview-battle.png：红方无人机压到蓝方阵地时的画面
var _frames := 0
var _main: Node


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	var rig = _main.get_node("CameraRig")
	if _frames == 5960:
		rig.input_enabled = false
		rig.position = Vector3(8.0, 44.0, 128.0)
		rig.yaw = -1.5708
		rig.pitch = -0.05
	elif _frames == 6000:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-battle.png")
		print("SAVED")
		quit(0)
	return false
