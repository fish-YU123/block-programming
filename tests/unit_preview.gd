extends SceneTree
## 生成 docs/preview-unit.png：飞飞悬停截图

var _f := 0
var _main: Node


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_f += 1
	if _f == 150:
		var rig = _main.get_node("CameraRig")
		var units = _main.get_node("Units")
		if units.get_child_count() > 0:
			var u: Node3D = units.get_child(0)
			rig.position = u.global_position + Vector3(-2.3, 0.85, -2.1)
			rig.yaw = -2.35
			rig.pitch = -0.14
	if _f == 185:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-unit.png")
		print("SAVED")
		quit(0)
	return false
