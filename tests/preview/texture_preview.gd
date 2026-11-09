extends SceneTree
## 生成文档用截图：docs/preview-texture.png（近距离看方块贴图与顶点 AO）
##
## 运行时会在镜头前搭一小面"材质墙"，把泥土/沙/石头/矿石/木板/基岩一次展示出来，
## 方便人眼检查 UV 是否对齐、贴图有没有错位或上下颠倒。

var _frames := 0
var _main: Node
var _world: Node
var _base_y := 0


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _shoot(path: String) -> void:
	var img: Image = root.get_viewport().get_texture().get_image()
	img.save_png(path)


func _build_showcase() -> void:
	# 一面 4 格宽、6 格高的材质墙，正对镜头（镜头朝 +X，墙的正面在 x=96）
	var materials := ["bedrock", "copper_ore", "coal_ore", "stone", "sand", "planks"]
	for row in materials.size():
		var block_id: int = _world.db.id_of(materials[row])
		for w in 4:
			for d in 2:
				_world.set_block(Vector3i(96 + d, _base_y + row, 126 + w), block_id)
	# 墙前放一级台阶，制造拐角让 AO 看得出来
	var plank_id: int = _world.db.id_of("planks")
	for w in 4:
		_world.set_block(Vector3i(95, _base_y, 126 + w), plank_id)
	# 墙边放两个草方块，看草侧面的"泥土+草边"过渡
	var grass_id: int = _world.db.id_of("grass")
	_world.set_block(Vector3i(94, _base_y, 126), grass_id)
	_world.set_block(Vector3i(94, _base_y + 1, 126), grass_id)


func _process(_delta: float) -> bool:
	_frames += 1
	var rig = _main.get_node("CameraRig")
	if _frames == 6:
		rig.position = Vector3(58.0, 78.0, 128.0)
		rig.yaw = -1.5708
		rig.pitch = -0.55
		_world = _main.get_node("World")
		_world.prefetch(rig.position, 4)
	elif _frames == 40:
		# 先把世界全部建完，材质墙落地才不会有区块还没生成
		_world.build_all()
		_base_y = _world.surface_height(96, 128) + 1
		_build_showcase()
		rig.position = Vector3(84.0, _base_y + 4.0, 128.5)
		rig.yaw = -1.5708
		rig.pitch = -0.10
		_world.prefetch(rig.position, 6)
	elif _frames == 130:
		_shoot("res://docs/preview-texture.png")
		print("SAVED")
		quit(0)
	return false
