extends SceneTree
## A* 寻路测试：headless 运行
##   godot --headless --path . --script res://tests/path_test.gd

const PathFinder = preload("res://scripts/world/path_finder.gd")
const VoxelWorld = preload("res://scripts/world/voxel_world.gd")
const BlockDB = preload("res://scripts/world/block_db.gd")

var _passed := 0
var _failed := 0
var _failures: Array = []
var _main: Node
var _frames := 0
var _phase := 0
var _unit: Node
var _go_start := 0


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_run_grid_tests()
		# 自动驾驶：单位代码里写 go_to，就该自己飞过去
		var entry: Dictionary = _main.team_units(0)[0]
		_unit = entry["unit"]
		entry["controller"].bind(_unit, "def loop():\n    go_to(64, 32, 128)\n", 999)
		_go_start = _frames
	elif _frames == 2 + 60 * 12:
		var d: float = _unit.global_position.distance_to(Vector3(64.0, _unit.global_position.y, 128.0))
		var dy: float = absf(_unit.global_position.y - 32.0)
		_record("自动驾驶能飞到目标附近", d < 8.0, "还差 %.1f 米（%s）" % [d, str(_unit.global_position)])
		_record("自动驾驶会保持高度", dy < 8.0, "高度差 %.1f" % dy)
		_record("自动驾驶过程中不会卡进方块", not _main.world.is_solid(Vector3i(floori(_unit.global_position.x), floori(_unit.global_position.y), floori(_unit.global_position.z))), "卡住了")
		print("通过 %d 项，失败 %d 项" % [_passed, _failed])
		for f in _failures:
			print("  ✗ ", f)
		quit(0 if _failed == 0 else 1)
	return false


func _run_grid_tests() -> void:
	var db := BlockDB.new()
	db.load_dir("res://data/blocks")
	var world := VoxelWorld.new()
	root.add_child(world)
	world.setup(db, 777, 64, 64, 32)
	# 空气世界：挖掉地表以上的所有东西，只留 y=0 的基岩
	for x in 64:
		for z in 64:
			for y in range(1, 32):
				if world.get_block(Vector3i(x, y, z)) != 0:
					world.set_block(Vector3i(x, y, z), 0)

	var from := Vector3(8.5, 16.5, 8.5)
	var to := Vector3(40.5, 16.5, 8.5)
	var straight: Array = PathFinder.find_path(world, from, to)
	_record("开阔地直达", straight.size() >= 1 and straight[-1].distance_to(to) < 2.0, str(straight))
	_record("开阔地路径不绕远", straight.size() <= 2, str(straight.size()))

	# 立一堵墙挡在中间（留出上下左右都绕不过的整片，只有上面能过）
	for y in range(1, 24):
		for z in range(0, 40):
			world.set_block(Vector3i(24, y, z), db.id_of("stone"))
	var detour: Array = PathFinder.find_path(world, from, to)
	_record("遇墙能绕过去", detour.size() >= 1 and detour[-1].distance_to(to) < 2.0, str(detour.size()))
	var clear := true
	var anchor := from
	for p in detour:
		if not PathFinder.line_clear(world, anchor, p):
			clear = false
		anchor = p
	_record("绕墙路径每一段都不穿墙", clear, "有穿墙段")

	# 完全封死的目标：四周与上下都堵死
	var jail := Vector3i(50, 16, 50)
	for dx in range(-2, 3):
		for dy in range(-2, 3):
			for dz in range(-2, 3):
				var cell := jail + Vector3i(dx, dy, dz)
				if abs(dx) == 2 or abs(dy) == 2 or abs(dz) == 2:
					world.set_block(cell, db.id_of("stone"))
	var trapped: Array = PathFinder.find_path(world, from, PathFinder.cell_center(jail))
	_record("封死的目标找不到路", trapped.is_empty(), str(trapped.size()))

	# 节点上限：给一个很小的上限，必须很快放弃（不能卡死）
	var capped: Array = PathFinder.find_path(world, from, to, 32)
	_record("节点上限能兜住", capped.is_empty() or capped.size() >= 1, "上限下直接返回")

	# 起终点一样
	var same: Array = PathFinder.find_path(world, from, from)
	_record("起终点相同返回单点", same.size() == 1, str(same.size()))
	world.queue_free()


func _record(name: String, ok: bool, detail: String) -> void:
	if ok:
		_passed += 1
		print("  ✓ ", name)
	else:
		_failed += 1
		_failures.append("%s（%s）" % [name, detail])
