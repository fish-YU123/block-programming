extends SceneTree
## 生成 docs/preview-blue-base.png：蓝方基地（矿机 / 组装厂 / 充电站 + 一堆飞飞）

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
	elif _frames == 1200:
		# 悬停在基地正上方，看一眼蓝方攒出来的家底
		var rig = _main.get_node("CameraRig")
		rig.input_enabled = false
		var blue: Array = _main.team_units(0)
		var center := Vector3(34.0, 0.0, 128.0)
		if blue.size() > 0:
			center = blue[0]["unit"].global_position
			for e in blue:
				center += e["unit"].global_position
			center /= float(blue.size() + 1)
		var ground: float = float(_main.world.surface_height(int(center.x), int(center.z)))
		var eye := Vector3(center.x - 17.0, ground + 13.0, center.z - 15.0)
		rig.position = eye
		var d: Vector3 = Vector3(center.x, ground + 2.0, center.z) - eye
		rig.yaw = atan2(-d.x, -d.z)
		rig.pitch = -0.32
	elif _frames == 1260:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-blue-base.png")
		print("SAVED")
		quit(0)
	return false
