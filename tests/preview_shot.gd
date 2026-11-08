extends SceneTree
## 生成文档用截图：docs/preview.png（蓝方看中立区边界）与 docs/preview-boundary.png（中立区俯视）

var _frames := 0
var _main: Node


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _shoot(path: String) -> void:
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png(path)


func _process(_delta: float) -> bool:
	_frames += 1
	var rig = _main.get_node("CameraRig")
	if _frames == 6:
		rig.position = Vector3(58.0, 78.0, 128.0)
		rig.yaw = -1.5708
		rig.pitch = -0.55
		_main.get_node("World").prefetch(rig.position, 4)
	elif _frames == 70:
		_shoot("res://docs/preview.png")
		rig.position = Vector3(118.0, 30.0, 128.0)
		rig.yaw = -1.5708
		rig.pitch = -0.1
		_main.get_node("World").prefetch(rig.position, 7)
	elif _frames == 140:
		_shoot("res://docs/preview-boundary.png")
		print("SAVED")
		quit(0)
	return false
