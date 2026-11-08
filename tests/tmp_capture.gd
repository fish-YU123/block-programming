extends SceneTree
var _f := 0
var _rig: Node
func _initialize() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_rig = main.get_node("CameraRig")
	_rig._pressing = true
	print("MODE0=", Input.mouse_mode)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
func _process(_d: float) -> bool:
	_f += 1
	if _f == 2:
		print("MODE_AFTER=", Input.mouse_mode, " pressing=", _rig._pressing)
	elif _f == 6:
		print("MODE_LATER=", Input.mouse_mode, " pressing=", _rig._pressing, " dragging=", _rig.dragging)
		# 模拟一段相对位移
		for i in range(5):
			var ev := InputEventMouseMotion.new()
			ev.relative = Vector2(20, 0)
			ev.position = Vector2(800, 450)
			root.push_input(ev)
	elif _f == 7:
		print("YAW=", _rig.yaw, " dragging=", _rig.dragging)
		quit(0)
	return false
