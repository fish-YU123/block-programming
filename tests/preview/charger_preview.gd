extends SceneTree
## 生成 docs/preview-ore-charger.png：新矿种展示墙 + 充电站

var _f := 0
var _main: Node
const WALL_X := 33
const WALL_Z := 128


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_d: float) -> bool:
	_f += 1
	if _f == 2:
		_main.world.build_all()
		_main._start_game()
	elif _f == 8:
		var w = _main.world
		var db = _main.db
		var h: int = w.surface_height(WALL_X, WALL_Z)
		# 3 层展示墙：铜矿 / 铁矿 / 金矿
		for dz in range(-2, 3):
			var ids := [db.id_of("copper_ore"), db.id_of("iron_ore"), db.id_of("gold_ore")]
			for y in range(3):
				w.set_block(Vector3i(WALL_X, int(h) + 1 + y, WALL_Z + dz), ids[y])
		# 充电站：先在旁边铺一块 3×3 石台，再放上去（地形太碎，直接找平地常常跑很远）
		var stone: int = db.id_of("stone")
		var pad_x := WALL_X - 4
		var pad_z := WALL_Z - 5
		var pad_h: int = int(w.surface_height(pad_x, pad_z))
		for dx in range(3):
			for dz in range(3):
				for dy in range(4):
					w.set_block(Vector3i(pad_x + dx, int(pad_h) + 1 + dy, pad_z + dz), 0)
				w.set_block(Vector3i(pad_x + dx, int(pad_h), pad_z + dz), stone)
		var spot: Vector3i = Vector3i(pad_x, pad_h + 1, pad_z)
		print("充电站位置 ", spot, " 结果 [", _main.place_building_at("charger", spot, 0), "]")
	elif _f == 220:
		var rig = _main.get_node("CameraRig")
		rig.input_enabled = false
		var ground := float(_main.world.surface_height(WALL_X - 8, WALL_Z - 6))
		var eye := Vector3(float(WALL_X - 8), ground + 9.0, float(WALL_Z - 9))
		rig.position = eye
		var look := Vector3(float(WALL_X - 1), ground + 3.0, float(WALL_Z - 1))
		var d: Vector3 = look - eye
		rig.yaw = atan2(-d.x, -d.z)
		rig.pitch = -0.34
	elif _f == 260:
		root.get_viewport().get_texture().get_image().save_png("res://docs/preview-ore-charger.png")
		print("SAVED")
		quit(0)
	return false


func _flat_spot(near: Vector2i) -> Vector3i:
	var world = _main.world
	for dx in range(-16, 17):
		for dz in range(-16, 17):
			var x: int = near.x + dx
			var z: int = near.y + dz
			if x < 2 or z < 2 or x > 96 or z > 253:
				continue
			var h: int = world.surface_height(x, z)
			var flat := true
			for ox in 2:
				for oz in 2:
					if int(world.surface_height(x + ox, z + oz)) != h:
						flat = false
			if flat:
				return Vector3i(x, int(h) + 1, z)
	return Vector3i(-1, -1, -1)
