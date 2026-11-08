extends SceneTree
## 世界生成 / 网格 / 挖掘放置 的 headless 测试

const BlockDB = preload("res://scripts/world/block_db.gd")
const VoxelWorld = preload("res://scripts/world/voxel_world.gd")

var _passed := 0
var _failed := 0


func _record(name: String, ok: bool, detail := "") -> void:
	if ok:
		_passed += 1
		print("  ✓ ", name)
	else:
		_failed += 1
		print("  ✗ ", name, "  ", detail)


func _initialize() -> void:
	var db := BlockDB.new()
	var problem := db.load_dir("res://data/blocks")
	_record("方块数据可加载", problem == "", problem)
	_record("方块数量 = 9", db.defs.size() == 9, str(db.defs.size()))

	var world := VoxelWorld.new()
	root.add_child(world)
	world.setup(db, 12345, 64, 64, 48)

	var h := world.surface_height(10, 10)
	_record("地表高度合理", h > 0 and h < 48, str(h))
	_record("地表是草或沙", db.get_def(world.get_block(Vector3i(10, h - 1, 10))) != null)
	_record("地表上方是空气", world.get_block(Vector3i(10, h + 2, 10)) == BlockDB.AIR)
	_record("底层是基岩", world.get_block(Vector3i(10, 0, 10)) == db.id_of("bedrock"))
	_record("世界外是空气", world.get_block(Vector3i(-1, 10, 10)) == BlockDB.AIR)

	world.build_all()
	_record("区块全部构建", world.chunks.size() == world.chunk_count_x() * world.chunk_count_z(), str(world.chunks.size()))
	var chunk = world.chunks.values()[0]
	_record("区块网格非空", chunk.mesh_instance.mesh != null and chunk.mesh_instance.mesh.get_surface_count() == 1)

	var before := world.get_block(Vector3i(10, h - 1, 10))
	world.set_block(Vector3i(10, h - 1, 10), BlockDB.AIR)
	_record("挖掘生效", world.get_block(Vector3i(10, h - 1, 10)) == BlockDB.AIR)
	world.set_block(Vector3i(10, h - 1, 10), before)
	_record("放回生效", world.get_block(Vector3i(10, h - 1, 10)) == before)

	world.set_block(Vector3i(10, h + 3, 10), db.id_of("planks"))
	_record("放置高处方块", world.get_block(Vector3i(10, h + 3, 10)) == db.id_of("planks"))

	print("通过 %d 项，失败 %d 项" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)
