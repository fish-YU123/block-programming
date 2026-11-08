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

signal status_changed(text: String)
## 主机：收到某个客户端上报的单位代码
signal code_from_client(uid: int, revision: int, source: String)
## 客户端：加入了房间（参数是主机分配的队伍）
signal joined(team: int)

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
	elif mode == MODE_CLIENT:
		_client_poll()
		_client_timer += delta
		if _client_timer > CLIENT_TIMEOUT:
			_set_status("连接超时（%d 秒没收到主机快照）" % int(CLIENT_TIMEOUT))
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
				session.send_to(session_id, Protocol.MSG_WELCOME,
					Protocol.encode_welcome(session_id, team, int(SNAPSHOT_HZ), _tick, 20261108))
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


func _send_snapshot() -> void:
	_tick += 1
	if not units_provider.is_valid():
		return
	var units: Array = units_provider.call()
	var snap := Snapshot.capture(units, _tick)
	session.broadcast(Protocol.MSG_SNAPSHOT, Protocol.encode_snapshot(snap))


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
					joined.emit(my_team)
			Protocol.MSG_SNAPSHOT:
				var snap := Protocol.decode_snapshot(payload)
				if bool(snap.get("ok", false)):
					_client_timer = 0.0
					_apply_snapshot(snap)
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


# ================================================================ 内部

func _set_status(text: String) -> void:
	_status = text
	status_changed.emit(text)
