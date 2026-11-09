extends SceneTree
## 生成 docs/preview-rover.png：车车在地面上

var _f := 0
var _main: Node
var _rover: Node


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_d: float) -> bool:
	_f += 1
	if _f == 2:
		_main.world.build_all()
		_main._start_game()
	elif _f == 4:
		var def: Dictionary = _main.unit_db.get_def("rover")
		var x := 42
		var z := 126
		var g: int = int(_main.world.surface_height(x, z))
		_main._spawn_unit(def, Vector3(float(x), float(g), float(z)), "def loop():\n    set_rcs(0, 0.0)\n", 0)
		_rover = _main.team_units(0).back()["unit"]
	elif _f == 200:
		var rig = _main.get_node("CameraRig")
		rig.input_enabled = false
		var p: Vector3 = _rover.global_position
		var eye := p + Vector3(-3.2, 2.0, 3.2)
		rig.position = eye
		var d: Vector3 = p + Vector3(0, 0.3, 0) - eye
		rig.yaw = atan2(-d.x, -d.z)
		rig.pitch = -0.24
	elif _f == 240:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-rover.png")
		print("SAVED")
		quit(0)
	return false
