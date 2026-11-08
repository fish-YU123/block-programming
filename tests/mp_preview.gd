extends SceneTree
## 生成 docs/preview-mp.png：联机面板打开的样子

var _frames := 0
var _main: Node


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	var rig = _main.get_node("CameraRig")
	if _frames == 5:
		rig.position = Vector3(34.0, float(_main.world.surface_height(34, 128)) + 9.0, 122.0)
		rig.yaw = -2.2
		rig.pitch = -0.18
	elif _frames == 20:
		_main.mp_panel.toggle()
		_main.mp_panel.set_status("房间已开：端口 27015，等别人加入（你是蓝方）")
	elif _frames == 60:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-mp.png")
		print("SAVED")
		quit(0)
	return false
