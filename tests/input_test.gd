extends SceneTree
## 相机输入测试：拖动转视角、单击判定、滚轮调视野、输入禁用

var _frames := 0
var _main: Node
var _rig: Node
var _clicks: Array = []
var _passed := 0
var _failed := 0


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _button(pos: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	root.push_input(ev)


func _wheel(up: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_WHEEL_UP if up else MOUSE_BUTTON_WHEEL_DOWN
	ev.pressed = true
	ev.position = Vector2(800, 450)
	root.push_input(ev)


var _mouse := Vector2(800, 450)


func _motion(rel: Vector2) -> void:
	_mouse += rel
	var ev := InputEventMouseMotion.new()
	ev.relative = rel
	ev.position = _mouse
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(ev)


func _record(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ✓ ", name)
	else:
		_failed += 1
		print("  ✗ ", name, "：", detail)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 2:
		return false
	_rig = _main.get_node("CameraRig")
	_rig.primary_click.connect(func(at): _clicks.append(at))
	var yaw0: float = _rig.yaw
	var fov0: float = _rig.fov

	# 1) 按住左键拖动 → 视角转动
	_button(_mouse, true)
	for i in range(10):
		_motion(Vector2(12.0, 0.0))
	_record("拖动会转动视角", absf(_rig.yaw - yaw0) > 0.2, "yaw %.3f → %.3f" % [yaw0, _rig.yaw])

	# 2) 拖动后松手不发出单击
	_button(_mouse, false)
	_record("拖动后不算单击", _clicks.is_empty(), str(_clicks))

	# 3) 只按不拖 → 松手发出单击（用按下点）
	_mouse = Vector2(300, 200)
	_button(_mouse, true)
	_motion(Vector2(1.0, 0.0))
	_button(_mouse, false)
	_record("单击会发出标记点", _clicks.size() == 1, str(_clicks))
	if _clicks.size() == 1:
		_record("标记点用按下的位置", Vector2(_clicks[0]).distance_to(Vector2(300, 200)) < 1.0, str(_clicks[0]))

	# 4) 滚轮调视野
	_wheel(true)
	_record("滚轮调视野", _rig.fov < fov0, "fov %.1f → %.1f" % [fov0, _rig.fov])

	# 5) 鼠标在面板上时滚轮不调视野
	var fov1: float = _rig.fov
	_rig.wheel_blocked = true
	_wheel(false)
	_record("面板上滚轮不调视野", is_equal_approx(_rig.fov, fov1), "fov %.1f → %.1f" % [fov1, _rig.fov])
	_rig.wheel_blocked = false

	# 6) 输入禁用时拖动不转视角
	_rig.input_enabled = false
	var yaw1: float = _rig.yaw
	_button(_mouse, true)
	for i in range(10):
		_motion(Vector2(20.0, 0.0))
	_button(_mouse, false)
	_record("输入禁用时不转视角", is_equal_approx(_rig.yaw, yaw1), "yaw %.3f → %.3f" % [yaw1, _rig.yaw])
	_rig.input_enabled = true

	print("通过 %d 项，失败 %d 项" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)
	return false
