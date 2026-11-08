extends SceneTree
## 生成 docs/preview-buildings.png：采矿机 + 组装厂
var _f := 0
var _main: Node


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _flat(near_x: int, near_z: int) -> Vector3i:
	var world = _main.world
	for dx in range(-20, 21):
		for dz in range(-20, 21):
			var x: int = near_x + dx
			var z: int = near_z + dz
			if x < 2 or z < 2 or x > 96 or z > 253:
				continue
			var h: int = world.surface_height(x, z)
			var flat := true
			for ox in 3:
				for oz in 3:
					if int(world.surface_height(x + ox, z + oz)) != h:
						flat = false
			if flat:
				return Vector3i(x, h + 1, z)
	return Vector3i(-1, -1, -1)


func _process(_delta: float) -> bool:
	_f += 1
	var rig = _main.get_node("CameraRig")
	if _f == 8:
		var a := _flat(36, 124)
		_main.place_building_at("miner", a)
		var b := _flat(44, 132)
		_main.place_building_at("factory", b)
		# 让矿机脚下真的有一片矿
		var center: Vector3i = _main.buildings[0]["node"].center_cell()
		_main.world.set_block(Vector3i(center.x, a.y - 1, center.z), _main.db.id_of("copper_ore"))
		_main.world.set_block(Vector3i(center.x, a.y - 2, center.z), _main.db.id_of("coal_ore"))
		rig.input_enabled = false
		var target: Vector3 = _main.buildings[0]["node"].center_world()
		var eye := target + Vector3(-7.0, 6.0, -7.0)
		rig.position = eye
		var d := target - eye
		rig.yaw = atan2(-d.x, -d.z)
		rig.pitch = -0.42
	elif _f == 90:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-buildings.png")
		print("SAVED")
		quit(0)
	return false
