extends RefCounted
## M6 联机会话：基于 Godot 的低层 PacketPeerUDP 实现一个最小 UDP 会话。
##
## 为什么不用 ENetMultiplayerPeer：
##   1) 本阶段只需要“收发带 id 的二进制消息”，不需要 SceneTree 的 multiplayer API；
##   2) PacketPeerUDP 是纯轮询、无反射依赖，headless 下最稳；
##   3) 服务端权威 20Hz 的丢包容忍策略（快照可丢、输入可丢）用裸 UDP 更好控制。
##
## 用法：
##   服务端：var s := NetSession.new(); s.host(27015)
##           var msgs := s.poll()  # -> [{id, payload, session_id, address, port}]
##           s.broadcast(Protocol.MSG_SNAPSHOT, snap)
##   客户端：var c := NetSession.new(); c.join("127.0.0.1", 27015)
##           c.send_to(NetSession.SERVER_SESSION_ID, Protocol.MSG_PING, ...)
##           var msgs := c.poll()
##
## 注意：本类不负责可靠性/重传/加密，只做数据报收发和消息拆帧。
## CODE 这类必须可靠送达的消息由上层做“重复发送 + ERROR/超时重试”。

const Protocol = preload("res://scripts/net/protocol.gd")

const DEFAULT_PORT := 27015
const SERVER_SESSION_ID := 1     # 客户端视角：服务端固定 session_id = 1
const MODE_NONE := 0
const MODE_HOST := 1
const MODE_CLIENT := 2

var _peer: PacketPeerUDP = null
var _mode := MODE_NONE
var _local_port := 0
var _server_address := ""
var _server_port := 0

var _sessions: Dictionary = {}       # "ip:port" -> {id:int, ip:String, port:int}
var _session_by_id: Dictionary = {}  # id -> "ip:port"
var _next_session_id := SERVER_SESSION_ID

var _last_error := ""
var _packets_sent := 0
var _packets_received := 0
var _packets_dropped := 0


# ================================================================ 生命周期

## 作为服务端绑定本机 UDP 端口。成功返回空串，失败返回中文错误信息（不崩溃）。
func host(port: int = DEFAULT_PORT) -> String:
	close()
	if port < 1 or port > 65535:
		return _set_error("端口非法：%d（应在 1..65535 之间）" % port)

	var peer := PacketPeerUDP.new()
	var err := peer.bind(port, "*")
	if err != OK:
		peer.close()
		return _set_error("绑定 UDP 端口 %d 失败（错误码 %d）" % [port, err])

	_peer = peer
	_mode = MODE_HOST
	_local_port = port
	_server_port = port
	return ""


## 作为客户端连接服务端。成功返回空串，失败返回中文错误信息（不崩溃）。
func join(address: String, port: int = DEFAULT_PORT) -> String:
	close()
	if port < 1 or port > 65535:
		return _set_error("端口非法：%d（应在 1..65535 之间）" % port)
	var target := address.strip_edges()
	if target.is_empty():
		return _set_error("服务器地址为空")
	if target == "localhost":
		target = "127.0.0.1"

	var peer := PacketPeerUDP.new()
	var err := peer.bind(0, "*")   # 先占一个临时本地端口，便于收服务端回包
	if err != OK:
		peer.close()
		return _set_error("绑定本地 UDP 端口失败（错误码 %d）" % err)
	err = peer.connect_to_host(target, port)
	if err != OK:
		peer.close()
		return _set_error("连接服务器 %s:%d 失败（错误码 %d）" % [target, port, err])

	_peer = peer
	_mode = MODE_CLIENT
	_server_address = target
	_server_port = port
	return ""


## 关闭会话并清空所有状态。可重复调用。
func close() -> void:
	if _peer != null:
		_peer.close()
	_peer = null
	_mode = MODE_NONE
	_local_port = 0
	_server_address = ""
	_server_port = 0
	_sessions.clear()
	_session_by_id.clear()
	_next_session_id = SERVER_SESSION_ID
	_last_error = ""
	_packets_sent = 0
	_packets_received = 0
	_packets_dropped = 0


# ================================================================ 收

## 轮询本帧收到的所有消息。每条：
##   {id:int, payload:PackedByteArray, session_id:int, address:String, port:int}
## 坏帧/未知 id 被静默丢弃并计入 dropped，不影响后续消息。
func poll() -> Array:
	var messages: Array = []
	if _peer == null:
		return messages

	var pending := _peer.get_available_packet_count()
	while pending > 0:
		pending -= 1
		var bytes := _peer.get_packet()
		if _peer.get_packet_error() != OK:
			_packets_dropped += 1
			continue
		_packets_received += 1

		var decoded: Dictionary = Protocol.decode_message(bytes)
		if not bool(decoded.get("ok", false)):
			_packets_dropped += 1
			continue

		var session_id := SERVER_SESSION_ID
		var address := _peer.get_packet_ip()
		var remote_port := _peer.get_packet_port()
		if _mode == MODE_HOST:
			var info := _ensure_session(address, remote_port)
			session_id = int(info["id"])

		messages.append({
			"id": int(decoded["id"]),
			"payload": decoded["payload"],
			"session_id": session_id,
			"address": address,
			"port": remote_port,
		})
	return messages


# ================================================================ 发

## 发给指定会话。服务端按 session_id 查地址；客户端忽略 session_id（始终发给服务端）。
## 失败只记录在 get_last_error()，不抛异常。
func send_to(session_id: int, msg_id: int, payload: PackedByteArray) -> void:
	if _peer == null or _mode == MODE_NONE:
		_set_error("会话未启动，无法发送消息")
		return

	var frame := Protocol.encode_message(msg_id, payload)
	if frame.is_empty():
		_set_error("消息编码失败：id=%d，payload=%d 字节" % [msg_id, payload.size()])
		return

	if _mode == MODE_HOST:
		var key := str(_session_by_id.get(session_id, ""))
		if key.is_empty():
			_set_error("未知 session_id：%d" % session_id)
			return
		var info: Dictionary = _sessions[key]
		var err := _peer.set_dest_address(str(info["ip"]), int(info["port"]))
		if err != OK:
			_set_error("设置目标地址失败（错误码 %d）" % err)
			return
		if _peer.put_packet(frame) != OK:
			_set_error("发送数据包失败")
			return
		_packets_sent += 1
		return

	# 客户端：connect_to_host 已经记住目标地址
	if _peer.put_packet(frame) != OK:
		_set_error("发送数据包失败")
		return
	_packets_sent += 1


## 广播给所有已见过面的客户端；客户端模式下等价于发给服务端。
func broadcast(msg_id: int, payload: PackedByteArray) -> void:
	if _peer == null or _mode == MODE_NONE:
		_set_error("会话未启动，无法广播")
		return
	if _mode == MODE_CLIENT:
		send_to(SERVER_SESSION_ID, msg_id, payload)
		return

	var frame := Protocol.encode_message(msg_id, payload)
	if frame.is_empty():
		_set_error("消息编码失败：id=%d，payload=%d 字节" % [msg_id, payload.size()])
		return

	for key in _sessions.keys():
		var info: Dictionary = _sessions[key]
		if _peer.set_dest_address(str(info["ip"]), int(info["port"])) != OK:
			continue
		if _peer.put_packet(frame) == OK:
			_packets_sent += 1


# ================================================================ 查询

func is_hosting() -> bool:
	return _mode == MODE_HOST


func is_joined() -> bool:
	return _mode == MODE_CLIENT


func get_mode() -> int:
	return _mode


func get_last_error() -> String:
	return _last_error


func get_local_port() -> int:
	return _local_port


## 服务端视角的在线会话列表：[{id, address, port}]
func get_sessions() -> Array:
	var list: Array = []
	if _mode != MODE_HOST:
		return list
	for key in _session_by_id.keys():
		var info: Dictionary = _sessions[str(_session_by_id[key])]
		list.append({"id": int(info["id"]), "address": str(info["ip"]), "port": int(info["port"])})
	list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["id"]) < int(b["id"]))
	return list


func get_stats() -> Dictionary:
	return {
		"mode": _mode,
		"sent": _packets_sent,
		"received": _packets_received,
		"dropped": _packets_dropped,
		"sessions": _sessions.size(),
	}


## 仅供上层做“服务端首次看到的客户端地址”调试。
func get_server_address() -> String:
	if _mode != MODE_CLIENT:
		return ""
	return "%s:%d" % [_server_address, _server_port]


# ================================================================ 内部

func _ensure_session(ip: String, port: int) -> Dictionary:
	var key := "%s:%d" % [ip, port]
	if _sessions.has(key):
		var existing: Dictionary = _sessions[key]
		return existing
	var info := {"id": _next_session_id, "ip": ip, "port": port}
	_next_session_id += 1
	_sessions[key] = info
	_session_by_id[int(info["id"])] = key
	return info


func _set_error(message: String) -> String:
	_last_error = message
	return message
