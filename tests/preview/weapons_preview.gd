extends SceneTree
## 生成 docs/preview-weapons.png：飞飞用激光切割石柱、炮管开火

var _frames := 0
var _main: Node
var _unit: Node


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	var rig = _main.get_node("CameraRig")
	if _frames == 4:
		_unit = _main.team_units(0)[0]["unit"]
		rig.input_enabled = false
		var db = _main.world.db
		var h: int = _main.world.surface_height(60, 128)
		_unit.global_position = Vector3(60.0, float(h) + 5.0, 128.0)
		_unit.rotation.y = -PI * 0.5
		# 正前方 4 格立一根石柱当靶子
		for y in range(h, h + 7):
			for dx in range(0, 2):
				for dz in range(-1, 2):
					_main.world.set_block(Vector3i(64 + dx, y, 128 + dz), db.id_of("stone"))
	elif _frames >= 100 and _frames < 180:
		# 相机跟着单位，保证机身与靶子在画面中间
		var eye: Vector3 = _unit.global_position + Vector3(-6.5, 2.4, 8.0)
		rig.position = eye
		var to_unit: Vector3 = _unit.global_position - eye
		rig.yaw = atan2(-to_unit.x, -to_unit.z)
		rig.pitch = -0.16
		if _frames < 120:
			return false
		_unit.laser_on = true
		_unit.laser_target = Vector3(63.0, _main.world.surface_height(60, 128) + 5.0, 128.0)
		_main._process_weapons(0.016)
		if _frames == 170:
			_main._on_gun_fired(_unit, _unit.muzzle_world(), _unit.forward_dir())
	elif _frames == 180:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-weapons.png")
		print("SAVED")
		quit(0)
	return false
