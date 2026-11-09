extends SceneTree
var _f := 0
var _main: Node
func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)
func _process(_delta: float) -> bool:
	_f += 1
	var rig = _main.get_node("CameraRig")
	if _f == 5:
		var w = _main.get_node("World")
		var h: int = w.surface_height(97, 128)
		rig.position = Vector3(94.0, float(h) + 3.5, 128.0)
		rig.yaw = -1.5708
		rig.pitch = -0.22
	elif _f == 45:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-neutral.png")
		print("SAVED")
		quit(0)
	return false
