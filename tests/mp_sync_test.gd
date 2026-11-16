extends SceneTree
## M6.5 联机同步端到端测试（真实 UDP 回环）：
##   1) 客户端按主机种子重建地形（客户端一开始用的是另一个种子）
##   2) 主机挖方块 → 客户端世界跟着变
##   3) 主机盖建筑 → 客户端生成对应建筑节点（位置/队伍/血量对得上）
##   4) 主机改虚影 → 客户端幽灵跟着变；客户端点虚影 → 主机上出现
##   5) 客户端断线重连 → 用 revision 补齐断线期间的所有方块改动

const MpManager = preload("res://scripts/net/mp_manager.gd")
const VoxelWorld = preload("res://scripts/world/voxel_world.gd")
const Building = preload("res://scripts/buildings/building.gd")

const TEST_PORT := 27202

var _main: Node
var host_mp: MpManager
var client_mp: MpManager
var client_world: Node3D
var client_buildings_root: Node3D

var _frames := 0
var _elapsed := 0.0
var _t0 := 0.0
var _phase := 0
var _passed := 0
var _failed := 0
var _map_rebuilt := false
var _map_seed_got := -1
var _client_orders: Array = []
var _dug_cell := Vector3i.ZERO
var _dug_cells: Array = []
var _placed_cell := Vector3i.ZERO
var _order_cell := Vector3i.ZERO
var _client_order_cell := Vector3i.ZERO


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _record(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ✓ ", name)
	else:
		_failed += 1
		print("  ✗ ", name, "：", detail)


func _flat_spot(near_x: int, near_z: int) -> Vector3i:
	var world = _main.world
	for dx in range(-20, 21):
		for dz in range(-20, 21):
			var x: int = near_x + dx
			var z: int = near_z + dz
			if x < 2 or z < 2 or x > 200 or z > 253:
				continue
			var h: int = world.surface_height(x, z)
			var flat := true
			for ox in 3:
				for oz in 3:
					if int(world.surface_height(x + ox, z + oz)) != h:
						flat = false
			if not flat:
				continue
			return Vector3i(x, int(h), z)
	return Vector3i(-1, -1, -1)


func _solid_cell_near(x: int, z: int) -> Vector3i:
	var world = _main.world
	var top: int = world.surface_height(x, z)
	for y in range(top - 1, 1, -1):
		var cell := Vector3i(x, y, z)
		if world.get_block(cell) != 0:
			return cell
	return Vector3i.ZERO


func _process(_delta: float) -> bool:
	_frames += 1
	_elapsed += _delta
	if _elapsed > 60.0:
		_record("测试没有卡死（60 秒内跑完）", false, "phase=%d my_team=%d" % [_phase, client_mp.my_team if client_mp != null else -1])
		print("通过 %d 项，失败 %d 项" % [_passed, _failed])
		quit(1)
		return false
	if _frames == 1:
		_main.world.build_all()
		_main._start_game()
		_t0 = _elapsed
		return false
	if _frames < 3:
		return false
	host_mp = _main.mp

	if _frames == 3:
		# 客户端用一个"错的"种子先建一张图，验证它会按主机种子重建
		client_world = VoxelWorld.new()
		client_world.name = "ClientWorld"
		root.add_child(client_world)
		client_world.setup(_main.world.db, 777, 256, 256, 64)
		client_world.build_all()
		client_buildings_root = Node3D.new()
		client_buildings_root.name = "ClientBuildings"
		root.add_child(client_buildings_root)
		client_mp = MpManager.new()
		client_mp.name = "ClientMp"
		root.add_child(client_mp)
		client_mp.world = client_world
		client_mp.replicas_root = client_buildings_root
		client_mp.building_db = _main.building_db
		client_mp.buildings_root = client_buildings_root
		client_mp.unit_def = _main.unit_db.get_def("feifei")
		client_mp.map_seed_received.connect(func(seed: int):
			_map_seed_got = seed
			client_world.rebuild_with_seed(seed)
			_map_rebuilt = true)
		client_mp.orders_synced.connect(func(order_list: Array):
			_client_orders = order_list)

		var err: String = host_mp.host_game(TEST_PORT)
		_record("主机开房间", err == "", err)
		var join_err: String = client_mp.join_game("127.0.0.1", TEST_PORT)
		_record("客户端发起连接", join_err == "", join_err)
		return false

	client_mp.tick(_delta)

	match _phase:
		0:
			if _elapsed - _t0 > 1.0 and client_mp.my_team == 1 and _map_rebuilt:
				_phase = 1
				_record("客户端收到主机地图种子", _map_seed_got == int(_main.world_seed), "seed=%d vs %d" % [_map_seed_got, int(_main.world_seed)])
				# 地形必须和主机一致：抽查几根柱子
				var same := 0
				for i in 6:
					var x := 20 + i * 17
					var z := 30 + i * 13
					var hh: int = _main.world.surface_height(x, z)
					if int(client_world.surface_height(x, z)) == hh:
						same += 1
				_record("重建后的地形和主机一致", same == 6, "一致 %d/6" % same)
				# 主机挖掉一格方块
				_dug_cell = _solid_cell_near(30, 100)
				_dug_cells.append(_dug_cell)
				_main.world.set_block(_dug_cell, 0)
		1:
			if _elapsed - _t0 > 2.0:
				_phase = 2
				_record("主机挖掉的方块同步到客户端", int(client_world.get_block(_dug_cell)) == 0,
					"客户端看到 %d" % int(client_world.get_block(_dug_cell)))
				# 主机盖一栋矿机
				var spot := _flat_spot(40, 128)
				var berr: String = _main.place_building_at("miner", spot)
				_record("主机放下采矿机", berr == "", berr)
				_placed_cell = spot
		2:
			if _elapsed - _t0 > 3.0:
				_phase = 3
				var remote: Array = client_mp.remote_buildings()
				_record("客户端建筑数量与主机一致", remote.size() == _main.buildings.size(),
					"客户端 %d 栋 / 主机 %d 栋" % [remote.size(), _main.buildings.size()])
				# 主机开局本来就有几栋（双方各一套），这里找刚放的那栋
				var placed_node = null
				var bases := []
				for r in remote:
					bases.append(str(r.base_cell))
					if r.base_cell == _placed_cell:
						placed_node = r
				_record("同步建筑类型/位置/队伍正确",
					placed_node != null and str(placed_node.kind) == "miner" and int(placed_node.team) == 0,
					"期望 @%s 实际=%s" % [str(_placed_cell), str(bases)])
				# 主机标一个挖掘虚影
				_order_cell = _solid_cell_near(34, 128)
				_main.toggle_order(_order_cell, "mine")
		3:
			if _elapsed - _t0 > 4.0:
				_phase = 4
				var found := false
				for o in _client_orders:
					if Vector3i(int(o["x"]), int(o["y"]), int(o["z"])) == _order_cell:
						found = true
				_record("主机标记的虚影同步到客户端", found, str(_client_orders))
				# 客户端点一个放置虚影，应出现在主机上
				_client_order_cell = _solid_cell_near(36, 128) + Vector3i(0, 1, 0)
				client_mp.send_order_toggle(_client_order_cell, "place", "stone")
		4:
			if _elapsed - _t0 > 5.0:
				_phase = 5
				_record("客户端标的虚影到了主机", _main.order_index_at(_client_order_cell, "place") >= 0,
					str(_main.orders))
				# 断线：断开后主机继续挖两格（客户端看不到）
				client_mp.stop()
				_client_orders.clear()
				for i in 2:
					var cell := _solid_cell_near(40 + i * 3, 120)
					_dug_cells.append(cell)
					_main.world.set_block(cell, 0)
				_map_rebuilt = false
		5:
			# 等主机把旧会话判超时（CLIENT_TIMEOUT=5 秒），再重连
			if _elapsed - _t0 > 10.0:
				_phase = 6
				var rejoin: String = client_mp.join_game("127.0.0.1", TEST_PORT)
				_record("断线后重新加入", rejoin == "", rejoin)
		6:
			if _elapsed - _t0 > 14.0 and client_mp.my_team >= 0:
				_phase = 7
				var all_ok := true
				var detail := ""
				for cell in _dug_cells:
					if int(client_world.get_block(cell)) != 0:
						all_ok = false
						detail += "%s=%d " % [str(cell), int(client_world.get_block(cell))]
				_record("重连后补齐断线期间的全部方块改动", all_ok, detail)
				_record("重连后世界 revision 追平主机", client_mp.client_world_rev() == host_mp.world_rev(),
					"客户端 %d / 主机 %d" % [client_mp.client_world_rev(), host_mp.world_rev()])
				_record("重连后地形仍是主机的", int(_map_seed_got) == int(_main.world_seed), str(_map_seed_got))
				client_mp.stop()
				host_mp.stop()
				print("通过 %d 项，失败 %d 项" % [_passed, _failed])
				quit(0 if _failed == 0 else 1)
	return false


func _exit_tree() -> void:
	if _main == null:
		return
	if _passed + _failed == 0:
		print("通过 %d 项，失败 %d 项" % [_passed, _failed])
