extends Node
## M6 联机接入：把 scripts/net 的协议/快照/会话层接到游戏里。
##
## 设计（服务端权威）：
##   - 主机（host）跑真正的游戏模拟，20Hz 把单位快照广播给所有客户端；
##   - 客户端（client）不跑模拟，只按快照插值显示单位；
##   - 玩家写的"单位代码"在客户端编辑后通过 CODE 消息发给主机，由主机绑定执行。
##
## 用法：
##   主机：mp.host_game(27015)
##   客户端：mp.join_game("192.168.1.10", 27015)

const Protocol = preload("res://scripts/net/protocol.gd")
const Snapshot = preload("res://scripts/net/snapshot.gd")
const NetSession = preload("res://scripts/net/net_session.gd")
const Flyer = preload("res://scripts/units/flyer.gd")
const Building = preload("res://scripts/buildings/building.gd")

signal status_changed(text: String)
## 主机：收到某个客户端上报的单位代码
signal code_from_client(uid: int, revision: int, source: String)
## 客户端：加入了房间（参数是主机分配的队伍）
signal joined(team: int)
## 客户端：收到主机的世界种子/尺寸，需要按它重建本地地形后再接方块同步
signal map_seed_received(map_seed: int)
## 客户端：主机同步过来的虚影指令（全量）
signal orders_synced(order_list: Array)
## 客户端：主机同步过来的建筑列表（全量），节点已经在 mp 里建好/更新
signal buildings_synced(count: int)
## 主机：客户端点了某个格子上的虚影，需要主机去真正增删
signal order_from_client(cell: Vector3i, action: String, id: String)

const MODE_NONE := 0
const MODE_HOST := 1
const MODE_CLIENT := 2

## 服务端快照频率
const SNAPSHOT_HZ := 20.0
## 客户端把单位插值到快照位置的速度
const REPLICA_LERP := 12.0
## 多久没收到快照就算断线
const CLIENT_TIMEOUT := 5.0

var mode := MODE_NONE
## 客户端：主机分配的队伍；主机：固定 TEAM_BLUE(0)
var my_team := -1
var session: NetSession = NetSession.new()

## 客户端：根节点由外部塞进来（一般就是主场景）
var world: Node = null
var replicas_root: Node3D = null
## 单位定义（客户端造替身用）
var unit_def: Dictionary = {}

## 主机：给快照用的单位数据提供者，返回 [{uid, team, pos, vel, yaw, energy}, ...]
var units_provider: Callable = Callable()

## 主机：本局地图种子，客户端收到后按它重建地形（main 开局时塞进来）
var world_seed := 0

var _snap_accum := 0.0
var _tick := 0
var _status := ""
var _last_error := ""
var _client_timer := 0.0
## 主机：session_id -> 队伍（第一个加入的打红方，之后交替）
var _teams: Dictionary = {}

## 客户端：uid -> Flyer（替身）
var _replicas: Dictionary = {}
## 客户端：uid -> {pos, yaw, team}
var _targets: Dictionary = {}

## ---------------- 世界/虚影/建筑同步（M6.5）----------------
## 同步频率：方块按需（有改动就发），虚影/建筑 10Hz 全量（内容变了才发）
const SYNC_HZ := 10.0
## 主机：方块改动日志，下标 0 对应 revision 1
var _world_log: Array = []
## 主机：session_id -> 客户端已经应用到哪个 revision
var _client_world_rev: Dictionary = {}
## 主机：虚影指令供应商，返回 orders 数组（跟 main.orders 同构）
var orders_provider: Callable = Callable()
## 主机：建筑列表供应商，返回 [{id, x, y, z, team, hp_ratio, build_ratio, alive, stalled}, ...]
var buildings_provider: Callable = Callable()
## 客户端：已应用的方块 revision
var _world_rev := 0
## 客户端：每 0.5 秒告诉主机自己的进度，主机据此补发丢掉的改动
const WORLD_ACK_INTERVAL := 0.5
var _world_ack_timer := 0.0
var _sync_accum := 0.0
## 上一次广播的虚影/建筑原始字节，内容没变就不重复发
var _last_orders_bytes := PackedByteArray()
var _last_buildings_bytes := PackedByteArray()
## 客户端：建筑定义表与节点根（由外部塞进来）
var building_db = null   # BuildingDB（RefCounted），客户端建建筑节点时查定义用
var buildings_root: Node3D = null
## 客户端：key -> Building 节点
var _remote_buildings: Dictionary = {}
## 客户端：最近一次收到的虚影（测试/UI 用）
var _synced_orders: Array = []


# ================================================================ 对外接口

func is_host() -> bool:
	return mode == MODE_HOST


func is_client() -> bool:
	return mode == MODE_CLIENT


func get_status() -> String:
	return _status


func get_last_error() -> String:
	return _last_error


## 开房间。成功返回空串。
func host_game(port: int = NetSession.DEFAULT_PORT) -> String:
	if mode != MODE_NONE:
		stop()
	var err := session.host(port)
	if err != "":
		_last_error = err
		_set_status("开房间失败：%s" % err)
		return err
	mode = MODE_HOST
	my_team = 0
	_world_log.clear()
	_client_world_rev.clear()
	_world_rev = 0
	_last_orders_bytes = PackedByteArray()
	_last_buildings_bytes = PackedByteArray()
	_set_status("房间已开：端口 %d，等待别人加入" % port)
	return ""


## 加入房间。成功返回空串。
func join_game(address: String, port: int = NetSession.DEFAULT_PORT) -> String:
	if mode != MODE_NONE:
		stop()
	var err := session.join(address, port)
	if err != "":
		_last_error = err
		_set_status("加入失败：%s" % err)
		return err
	mode = MODE_CLIENT
	my_team = -1
	_client_timer = 0.0
	_world_rev = 0
	_world_ack_timer = 0.0
	_sync_accum = 0.0
	_synced_orders = []
	_last_orders_bytes = PackedByteArray()
	_last_buildings_bytes = PackedByteArray()
	session.send_to(NetSession.SERVER_SESSION_ID, Protocol.MSG_HELLO,
		Protocol.encode_hello("玩家", -1))
	_set_status("正在连接 %s:%d …" % [address, port])
	return ""


func stop() -> void:
	session.close()
	mode = MODE_NONE
	my_team = -1
	_teams.clear()
	_targets.clear()
	_world_log.clear()
	_client_world_rev.clear()
	_world_rev = 0
	_synced_orders = []
	_last_orders_bytes = PackedByteArray()
	_last_buildings_bytes = PackedByteArray()
	for key in _remote_buildings.keys():
		var bnode: Node = _remote_buildings[key]
		if is_instance_valid(bnode):
			bnode.get_parent().remove_child(bnode)
			bnode.queue_free()
	_remote_buildings.clear()
	for uid in _replicas.keys():
		var node: Node = _replicas[uid]
		if is_instance_valid(node):
			node.get_parent().remove_child(node)
			node.queue_free()
	_replicas.clear()
	_set_status("已断开")


## 客户端：把玩家改好的单位代码上报给主机
func send_code(uid: int, revision: int, source: String) -> void:
	if mode != MODE_CLIENT:
		return
	session.send_to(NetSession.SERVER_SESSION_ID, Protocol.MSG_CODE,
		Protocol.encode_code(uid, revision, source))


## 主机：记一笔方块改动（由 main 接到 world.block_changed 后调用）
## revision 从 1 开始严格递增，客户端按顺序应用，断线/丢包时按 revision 补发。
func notify_block_changed(cell: Vector3i, block_id: int) -> void:
	if mode != MODE_HOST:
		return
	_world_log.append({"x": cell.x, "y": cell.y, "z": cell.z, "block": block_id})
	_world_rev = _world_log.size()


## 主机：已经记录了多少条方块改动（= 最新 revision）
func world_rev() -> int:
	return _world_rev if mode == MODE_HOST else _world_rev


## 客户端：本地已应用到哪个 revision（测试/状态显示用）
func client_world_rev() -> int:
	return _world_rev


## 客户端：点了某个格子上的虚影（挖/放/建/拆），交给主机决定增删
func send_order_toggle(cell: Vector3i, action: String, id: String = "") -> void:
	if mode != MODE_CLIENT:
		return
	session.send_to(NetSession.SERVER_SESSION_ID, Protocol.MSG_ORDER_TOGGLE,
		Protocol.encode_order_toggle(cell.x, cell.y, cell.z, action, id))


## 客户端：本地替身列表（供代码面板显示）：[{uid, node, team}]
func replicas() -> Array:
	var out: Array = []
	for uid in _replicas:
		var node = _replicas[uid]
		if is_instance_valid(node):
			out.append({"uid": int(uid), "node": node, "team": int(node.team)})
	out.sort_custom(func(a, b): return int(a["uid"]) < int(b["uid"]))
	return out


# ================================================================ 每帧驱动

func tick(delta: float) -> void:
	if mode == MODE_HOST:
		_host_poll()
		_snap_accum += delta
		if _snap_accum >= 1.0 / SNAPSHOT_HZ:
			_snap_accum = 0.0
			_send_snapshot()
		_sync_accum += delta
		if _sync_accum >= 1.0 / SYNC_HZ:
			_sync_accum = 0.0
			_send_world_catchup()
			_send_orders_if_changed()
			_send_buildings_if_changed()
	elif mode == MODE_CLIENT:
		_client_poll()
		_client_timer += delta
		if _client_timer > CLIENT_TIMEOUT:
			_set_status("连接超时（%d 秒没收到主机快照）" % int(CLIENT_TIMEOUT))
		_world_ack_timer += delta
		if _world_ack_timer >= WORLD_ACK_INTERVAL:
			_world_ack_timer = 0.0
			session.send_to(NetSession.SERVER_SESSION_ID, Protocol.MSG_WORLD_ACK,
				Protocol.encode_world_ack(_world_rev))
		_update_replicas(delta)


# ---------------- 主机侧

func _host_poll() -> void:
	var messages := session.poll()
	for msg in messages:
		var id := int(msg.get("id", 0))
		var payload: PackedByteArray = msg.get("payload", PackedByteArray())
		var session_id := int(msg.get("session_id", 0))
		match id:
			Protocol.MSG_HELLO:
				var hello := Protocol.decode_hello(payload)
				var team := int(_teams.get(session_id, -1))
				if team < 0:
					# 主机自己打蓝方(0)，第一个加入的打红方(1)，再来的人交替
					if _teams.is_empty():
						team = 1
					else:
						team = 0 if int(_teams.values()[0]) == 1 else 1
					_teams[session_id] = team
				_client_world_rev[session_id] = 0
				_last_buildings_bytes = PackedByteArray()
				_last_orders_bytes = PackedByteArray()
				session.send_to(session_id, Protocol.MSG_WELCOME,
					Protocol.encode_welcome(session_id, team, int(SNAPSHOT_HZ), _tick, world_seed))
				_set_status("有玩家加入（会话 %d，队伍 %d）" % [session_id, team])
			Protocol.MSG_CODE:
				var code_msg := Protocol.decode_code(payload)
				if bool(code_msg.get("ok", false)):
					code_from_client.emit(int(code_msg.get("unit_uid", 0)),
						int(code_msg.get("revision", 0)), str(code_msg.get("source", "")))
			Protocol.MSG_PING:
				var ping := Protocol.decode_ping(payload)
				if bool(ping.get("ok", false)):
					session.send_to(session_id, Protocol.MSG_PONG,
						Protocol.encode_pong(int(ping.get("nonce", 0)),
							int(ping.get("client_time_ms", -1)), _tick))
			Protocol.MSG_WORLD_ACK:
				var ack := Protocol.decode_world_ack(payload)
				if bool(ack.get("ok", false)):
					_client_world_rev[session_id] = int(ack.get("have_rev", 0))
					_send_world_to_session(session_id)
			Protocol.MSG_ORDER_TOGGLE:
				var toggle := Protocol.decode_order_toggle(payload)
				if bool(toggle.get("ok", false)):
					order_from_client.emit(
						Vector3i(int(toggle["x"]), int(toggle["y"]), int(toggle["z"])),
						str(toggle["action"]), str(toggle["id"]))


func _send_snapshot() -> void:
	_tick += 1
	if not units_provider.is_valid():
		return
	var units: Array = units_provider.call()
	var snap := Snapshot.capture(units, _tick)
	session.broadcast(Protocol.MSG_SNAPSHOT, Protocol.encode_snapshot(snap))


## 主机：把某个客户端落后的方块改动补发过去（每包最多 MAX_WORLD_ENTRIES_PER_MSG 条）
## 每个同步 tick 调一次，保证新客户端能在 1 秒内追平；丢包靠客户端 0.5 秒一次的 ack 触发补发。
func _send_world_to_session(session_id: int) -> void:
	var rev := int(_client_world_rev.get(session_id, 0))
	var sent_chunks := 0
	while rev < _world_rev and sent_chunks < 8:
		var start := rev
		var count := mini(_world_rev - start, Protocol.MAX_WORLD_ENTRIES_PER_MSG)
		var entries: Array = _world_log.slice(start, start + count)
		session.send_to(session_id, Protocol.MSG_WORLD_EDIT,
			Protocol.encode_world_edit(start, entries))
		rev = start + count
		sent_chunks += 1
	# 先乐观地认为发出去的都到了，客户端 ack 会把它拉回真实进度（丢包时下一轮重发）
	_client_world_rev[session_id] = rev


func _send_world_catchup() -> void:
	for session_id in _teams.keys():
		_send_world_to_session(int(session_id))


func _send_orders_if_changed() -> void:
	if not orders_provider.is_valid():
		return
	var bytes := Protocol.encode_orders(orders_provider.call())
	if bytes == _last_orders_bytes:
		return
	_last_orders_bytes = bytes
	session.broadcast(Protocol.MSG_ORDERS, bytes)


func _send_buildings_if_changed() -> void:
	if not buildings_provider.is_valid():
		return
	var bytes := Protocol.encode_buildings(buildings_provider.call())
	if bytes == _last_buildings_bytes:
		return
	_last_buildings_bytes = bytes
	session.broadcast(Protocol.MSG_BUILDINGS, bytes)


# ---------------- 客户端侧

func _client_poll() -> void:
	var messages := session.poll()
	for msg in messages:
		var id := int(msg.get("id", 0))
		var payload: PackedByteArray = msg.get("payload", PackedByteArray())
		match id:
			Protocol.MSG_WELCOME:
				var welcome := Protocol.decode_welcome(payload)
				if bool(welcome.get("ok", false)):
					my_team = int(welcome.get("team", 0))
					_tick = int(welcome.get("server_tick", 0))
					_client_timer = 0.0
					_set_status("已加入房间：你是%s方" % ("蓝" if my_team == 0 else "红"))
					map_seed_received.emit(int(welcome.get("map_seed", 0)))
					joined.emit(my_team)
					# 地形重建完再要全量方块改动（主机按 revision 从 1 补发）
					_world_rev = 0
					session.send_to(NetSession.SERVER_SESSION_ID, Protocol.MSG_WORLD_ACK,
						Protocol.encode_world_ack(0))
			Protocol.MSG_SNAPSHOT:
				var snap := Protocol.decode_snapshot(payload)
				if bool(snap.get("ok", false)):
					_client_timer = 0.0
					_apply_snapshot(snap)
			Protocol.MSG_WORLD_EDIT:
				var edit := Protocol.decode_world_edit(payload)
				if bool(edit.get("ok", false)):
					_apply_world_edit(int(edit.get("base_rev", 0)), edit.get("entries", []))
			Protocol.MSG_ORDERS:
				var orders_msg := Protocol.decode_orders(payload)
				if bool(orders_msg.get("ok", false)):
					_synced_orders = orders_msg.get("orders", [])
					orders_synced.emit(_synced_orders)
			Protocol.MSG_BUILDINGS:
				var buildings_msg := Protocol.decode_buildings(payload)
				if bool(buildings_msg.get("ok", false)):
					_apply_buildings(buildings_msg.get("buildings", []))
					buildings_synced.emit(_remote_buildings.size())
			Protocol.MSG_ERROR:
				var err := Protocol.decode_error(payload)
				var text := str(err.get("message", "未知错误"))
				_set_status("主机报错：%s" % text)
			Protocol.MSG_PONG:
				_client_timer = 0.0


func _apply_snapshot(snap: Dictionary) -> void:
	_tick = int(snap.get("tick", _tick))
	var seen := {}
	if not bool(snap.get("ok", false)):
		return
	for unit in snap.get("units", []):
		var uid := int(unit["uid"])
		seen[uid] = true
		_targets[uid] = {
			"pos": unit["pos"],
			"yaw": float(unit["yaw"]),
			"team": int(unit["team"]),
		}
	# 快照里没有的就是已经没了
	for uid in _targets.keys():
		if not seen.has(uid):
			_targets.erase(uid)
			var node = _replicas.get(uid)
			if is_instance_valid(node):
				node.get_parent().remove_child(node)
				node.queue_free()
			_replicas.erase(uid)


func _update_replicas(delta: float) -> void:
	if replicas_root == null:
		return
	var t := clampf(REPLICA_LERP * delta, 0.0, 1.0)
	for uid in _targets:
		var target: Dictionary = _targets[uid]
		var node = _replicas.get(uid)
		if not is_instance_valid(node):
			node = _make_replica(int(uid), int(target["team"]))
			if node == null:
				continue
			_replicas[uid] = node
			node.global_position = target["pos"]
			node.rotation.y = float(target["yaw"])
			continue
		node.global_position = node.global_position.lerp(target["pos"], t)
		node.rotation.y = lerp_angle(node.rotation.y, float(target["yaw"]), t)


func _make_replica(uid: int, team: int) -> Node3D:
	if unit_def.is_empty() or world == null:
		return null
	var flyer := Flyer.new()
	flyer.name = "remote_%d" % uid
	replicas_root.add_child(flyer)
	flyer.setup(world, unit_def)
	flyer.team = team
	# 客户端不跑模拟：关掉物理与控制，只当可视化的替身
	flyer.set_physics_process(false)
	flyer.freeze = true
	flyer.set_collision_layer_value(1, false)
	flyer.set_collision_layer_value(2, false)
	flyer.name = "remote_%d" % uid
	return flyer


# ---------------- 客户端：应用主机同步过来的世界/建筑

## 应用一批方块改动。revision 对不上就丢掉（旧包）或立刻让主机重发（中间丢包）。
func _apply_world_edit(base_rev: int, entries: Array) -> void:
	if base_rev < _world_rev:
		return
	if base_rev > _world_rev:
		session.send_to(NetSession.SERVER_SESSION_ID, Protocol.MSG_WORLD_ACK,
			Protocol.encode_world_ack(_world_rev))
		return
	if world != null:
		for e in entries:
			var cell := Vector3i(int(e["x"]), int(e["y"]), int(e["z"]))
			world.set_block(cell, int(e["block"]))
	_world_rev = base_rev + entries.size()


## 把主机的全量建筑列表同步到本地节点：多退少补，位置/血量/建造进度/罢工都对上。
func _apply_buildings(items: Array) -> void:
	if buildings_root == null or building_db == null:
		return
	var seen := {}
	for item in items:
		var def_id := str(item.get("id", ""))
		var cell := Vector3i(int(item.get("x", 0)), int(item.get("y", 0)), int(item.get("z", 0)))
		var team := int(item.get("team", 0))
		var key := "%s:%d:%d:%d" % [def_id, cell.x, cell.y, cell.z]
		seen[key] = true
		var bnode = _remote_buildings.get(key)
		if not is_instance_valid(bnode):
			if not building_db.has(def_id):
				continue
			bnode = Building.new()
			bnode.name = "remote_%s" % key.replace(":", "_")
			buildings_root.add_child(bnode)
			bnode.setup(world, building_db.get_def(def_id), cell, team)
			_remote_buildings[key] = bnode
		_update_remote_building(bnode, item)
	for key in _remote_buildings.keys():
		if seen.has(key):
			continue
		var old = _remote_buildings[key]
		if is_instance_valid(old):
			old.get_parent().remove_child(old)
			old.queue_free()
		_remote_buildings.erase(key)


func _update_remote_building(bnode, item: Dictionary) -> void:
	var ratio := clampf(float(item.get("hp_ratio", 1.0)), 0.0, 1.0)
	bnode.hp = bnode.max_hp * ratio
	bnode.alive = bool(item.get("alive", true))
	var build_ratio := clampf(float(item.get("build_ratio", 1.0)), 0.0, 1.0)
	bnode.build_left = (1.0 - build_ratio) * bnode.build_total
	bnode._update_build_progress()
	if bnode.alive:
		bnode.set_stalled_look(bool(item.get("stalled", false)))
	bnode._refresh_badge()


## 客户端：当前同步到的建筑节点（测试/小地图用）
func remote_buildings() -> Array:
	var out: Array = []
	for key in _remote_buildings:
		var bnode = _remote_buildings[key]
		if is_instance_valid(bnode):
			out.append(bnode)
	return out


## 客户端：最近一次同步到的虚影指令
func synced_orders() -> Array:
	return _synced_orders


# ================================================================ 内部

func _set_status(text: String) -> void:
	_status = text
	status_changed.emit(text)
