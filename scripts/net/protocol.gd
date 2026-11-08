extends RefCounted
## M6 联机协议：二进制帧 + 各消息负载编解码。
##
## 帧格式（小端，无 JSON）：
##   偏移 0     u8   协议版本 PROTOCOL_VERSION
##   偏移 1     u8   消息 id MSG_*
##   偏移 2..5  u32  负载长度（字节）
##   偏移 6..   payload
##
## 设计约束：
## 1) 固定布局：带宽可预估，解析不会因为文本格式把内存撑爆；
## 2) 每个字符串都带长度前缀，解码前先校验长度与剩余字节，越界一律返回失败；
## 3) 所有 decode_* 都返回 Dictionary，坏数据只返回 {"ok": false}，绝不崩溃；
## 4) 未知消息 id 视为协议错误，方便早期发现版本不一致（新增消息时两边一起升级）。

const SnapshotCodec = preload("res://scripts/net/snapshot.gd")

# ---------------------------------------------------------------- 帧头

const PROTOCOL_VERSION := 1
const HEADER_BYTES := 6
const MAX_PAYLOAD_BYTES := 1048576          # 单帧负载上限 1 MiB
const MAX_CODE_BYTES := 65536               # 玩家代码源码上限 64 KiB
const MAX_NAME_BYTES := 64                  # 玩家名 UTF-8 上限
const MAX_ERROR_BYTES := 512                # 错误文本 UTF-8 上限
const MAX_SNAPSHOT_BYTES := 7 + 512 * 23    # snapshot.gd 的最大快照（头 + 512 单位）

# ---------------------------------------------------------------- 消息 id

const MSG_HELLO := 1        # 客户端 -> 服务端：加入房间
const MSG_WELCOME := 2      # 服务端 -> 客户端：分配 session/队伍/时间基准
const MSG_CODE := 3         # 客户端 -> 服务端：上报单位代码
const MSG_SNAPSHOT := 4     # 服务端 -> 客户端：20Hz 世界快照
const MSG_INPUT := 5        # 客户端 -> 服务端：单位控制输入
const MSG_PING := 6         # 双向：心跳 / RTT 探测
const MSG_PONG := 7         # 双向：心跳应答
const MSG_ERROR := 8        # 服务端 -> 客户端：拒绝/错误

const MSG_NAMES := {
	1: "HELLO",
	2: "WELCOME",
	3: "CODE",
	4: "SNAPSHOT",
	5: "INPUT",
	6: "PING",
	7: "PONG",
	8: "ERROR",
}

# ---------------------------------------------------------------- 错误码（ERROR 消息）

const ERR_BAD_PROTOCOL := 1     # 版本/帧格式不对
const ERR_CODE_REJECTED := 2    # 代码语法检查或长度检查失败
const ERR_NOT_AUTHORIZED := 3   # 没加入房间 / 无权操作该单位
const ERR_ROOM_FULL := 4        # 房间已满
const ERR_RATE_LIMITED := 5     # 消息频率超限
const ERR_SERVER_BUSY := 6      # 服务端内部错误


# ================================================================ 帧

## 给负载加上 6 字节帧头。msg_id 未知或负载过大时返回空数组（调用方应丢弃）。
static func encode_message(msg_id: int, payload: PackedByteArray) -> PackedByteArray:
	if not MSG_NAMES.has(msg_id):
		return PackedByteArray()
	if payload.size() > MAX_PAYLOAD_BYTES:
		return PackedByteArray()
	var buf := StreamPeerBuffer.new()
	buf.put_u8(PROTOCOL_VERSION)
	buf.put_u8(msg_id)
	buf.put_u32(payload.size())
	buf.put_data(payload)
	return buf.data_array


## 解析一帧。返回 {ok, version, id, payload, error}。
## 数据不完整、版本不符、长度不符、未知 id 时 ok=false，不抛异常。
static func decode_message(bytes: PackedByteArray) -> Dictionary:
	var result := {
		"ok": false,
		"version": 0,
		"id": 0,
		"payload": PackedByteArray(),
		"error": "",
	}
	if bytes.size() < HEADER_BYTES:
		result["error"] = "数据长度不足帧头：%d < %d" % [bytes.size(), HEADER_BYTES]
		return result

	var buf := StreamPeerBuffer.new()
	buf.data_array = bytes
	var version := int(buf.get_u8())
	var msg_id := int(buf.get_u8())
	var length := int(buf.get_u32())
	result["version"] = version
	result["id"] = msg_id

	if version != PROTOCOL_VERSION:
		result["error"] = "协议版本不符：%d != %d" % [version, PROTOCOL_VERSION]
		return result
	if not MSG_NAMES.has(msg_id):
		result["error"] = "未知消息 id：%d" % msg_id
		return result
	if length > MAX_PAYLOAD_BYTES:
		result["error"] = "负载长度超限：%d > %d" % [length, MAX_PAYLOAD_BYTES]
		return result
	if length != bytes.size() - HEADER_BYTES:
		result["error"] = "负载长度不符：声明 %d，实际 %d" % [length, bytes.size() - HEADER_BYTES]
		return result

	var payload := PackedByteArray()
	if length > 0:
		var got: Array = buf.get_data(length)
		if int(got[0]) != OK:
			result["error"] = "读取负载失败（错误码 %d）" % int(got[0])
			return result
		payload = got[1]

	result["ok"] = true
	result["payload"] = payload
	return result


## 消息 id 对应的可读名字，未知返回 "UNKNOWN"。
static func message_name(msg_id: int) -> String:
	return str(MSG_NAMES.get(msg_id, "UNKNOWN"))


static func is_known_message(msg_id: int) -> bool:
	return MSG_NAMES.has(msg_id)


# ================================================================ HELLO
# payload: u8 team | u8 name_len | name(UTF-8)

static func encode_hello(player_name: String, team: int) -> PackedByteArray:
	var name_bytes := _truncate_utf8(player_name, MAX_NAME_BYTES)
	var buf := StreamPeerBuffer.new()
	buf.put_u8(clampi(team, 0, 2))
	buf.put_u8(name_bytes.size())
	buf.put_data(name_bytes)
	return buf.data_array


static func decode_hello(payload: PackedByteArray) -> Dictionary:
	var result := {"ok": false, "player_name": "", "team": 0}
	if payload.size() < 2:
		return result
	var buf := StreamPeerBuffer.new()
	buf.data_array = payload
	var team := int(buf.get_u8())
	var name_len := int(buf.get_u8())
	if name_len > MAX_NAME_BYTES or buf.get_available_bytes() != name_len:
		return result
	var name := ""
	if name_len > 0:
		var got: Array = buf.get_data(name_len)
		if int(got[0]) != OK:
			return result
		var name_bytes: PackedByteArray = got[1]
		name = name_bytes.get_string_from_utf8()
	result["ok"] = true
	result["team"] = team
	result["player_name"] = name
	return result


# ================================================================ WELCOME
# payload: u32 session_id | u8 team | u8 tick_rate | u32 server_tick | u32 map_seed

static func encode_welcome(session_id: int, team: int, tick_rate: int, server_tick: int, map_seed: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u32(session_id & 0xFFFFFFFF)
	buf.put_u8(clampi(team, 0, 2))
	buf.put_u8(clampi(tick_rate, 0, 255))
	buf.put_u32(server_tick & 0xFFFFFFFF)
	buf.put_u32(map_seed & 0xFFFFFFFF)
	return buf.data_array


static func decode_welcome(payload: PackedByteArray) -> Dictionary:
	var result := {"ok": false, "session_id": 0, "team": 0, "tick_rate": 0, "server_tick": 0, "map_seed": 0}
	if payload.size() != 14:
		return result
	var buf := StreamPeerBuffer.new()
	buf.data_array = payload
	result["session_id"] = int(buf.get_u32())
	result["team"] = int(buf.get_u8())
	result["tick_rate"] = int(buf.get_u8())
	result["server_tick"] = int(buf.get_u32())
	result["map_seed"] = int(buf.get_u32())
	result["ok"] = true
	return result


# ================================================================ CODE
# payload: u32 unit_uid | u32 revision | u32 source_len | source(UTF-8)

static func encode_code(unit_uid: int, revision: int, source: String) -> PackedByteArray:
	var source_bytes := _truncate_utf8(source, MAX_CODE_BYTES)
	var buf := StreamPeerBuffer.new()
	buf.put_u32(unit_uid & 0xFFFFFFFF)
	buf.put_u32(revision & 0xFFFFFFFF)
	buf.put_u32(source_bytes.size())
	buf.put_data(source_bytes)
	return buf.data_array


static func decode_code(payload: PackedByteArray) -> Dictionary:
	var result := {"ok": false, "unit_uid": 0, "revision": 0, "source": ""}
	if payload.size() < 12:
		return result
	var buf := StreamPeerBuffer.new()
	buf.data_array = payload
	var unit_uid := int(buf.get_u32())
	var revision := int(buf.get_u32())
	var source_len := int(buf.get_u32())
	if source_len > MAX_CODE_BYTES:
		return result
	if buf.get_available_bytes() != source_len:
		return result
	var source := ""
	if source_len > 0:
		var got: Array = buf.get_data(source_len)
		if int(got[0]) != OK:
			return result
		var source_bytes: PackedByteArray = got[1]
		source = source_bytes.get_string_from_utf8()
	result["ok"] = true
	result["unit_uid"] = unit_uid
	result["revision"] = revision
	result["source"] = source
	return result


# ================================================================ SNAPSHOT
# payload 就是 snapshot.gd 产出的完整字节流（内部自带版本、tick、单位数），
# 这里不再套一层，避免每个快照重复 4 字节 tick。

static func encode_snapshot(snapshot_bytes: PackedByteArray) -> PackedByteArray:
	if snapshot_bytes.size() < SnapshotCodec.HEADER_BYTES:
		return PackedByteArray()
	if snapshot_bytes.size() > MAX_SNAPSHOT_BYTES:
		return PackedByteArray()
	return snapshot_bytes.duplicate()


static func decode_snapshot(payload: PackedByteArray) -> Dictionary:
	var parsed: Dictionary = SnapshotCodec.parse(payload)
	if not bool(parsed.get("ok", false)):
		return {"ok": false, "tick": 0, "count": 0, "units": []}
	return {
		"ok": true,
		"tick": int(parsed["tick"]),
		"count": int(parsed["count"]),
		"units": parsed["units"],
	}


# ================================================================ INPUT
# payload: u32 tick | u32 unit_uid | u8 flags(bit0=drill) | 5 x i8 控制量（-100..100，对应 -1..1）

const INPUT_CONTROL_KEYS := ["lift", "pitch", "roll", "turn", "forward"]

static func encode_input(tick: int, unit_uid: int, controls: Dictionary) -> PackedByteArray:
	var flags := 0
	if bool(controls.get("drill", false)):
		flags |= 1
	var buf := StreamPeerBuffer.new()
	buf.put_u32(tick & 0xFFFFFFFF)
	buf.put_u32(unit_uid & 0xFFFFFFFF)
	buf.put_u8(flags)
	for key in INPUT_CONTROL_KEYS:
		buf.put_8(_quantize_i8(_as_float(controls.get(key, 0.0)) * 100.0))
	return buf.data_array


static func decode_input(payload: PackedByteArray) -> Dictionary:
	var result := {
		"ok": false,
		"tick": 0,
		"unit_uid": 0,
		"drill": false,
		"controls": {"lift": 0.0, "pitch": 0.0, "roll": 0.0, "turn": 0.0, "forward": 0.0},
	}
	if payload.size() != 14:
		return result
	var buf := StreamPeerBuffer.new()
	buf.data_array = payload
	result["tick"] = int(buf.get_u32())
	result["unit_uid"] = int(buf.get_u32())
	var flags := int(buf.get_u8())
	var controls := {}
	for key in INPUT_CONTROL_KEYS:
		controls[key] = float(buf.get_8()) / 100.0
	result["drill"] = (flags & 1) != 0
	result["controls"] = controls
	result["ok"] = true
	return result


# ================================================================ PING / PONG

## client_time_ms < 0 时自动填本机单调时钟，便于直接发心跳。
static func encode_ping(nonce: int, client_time_ms: int = -1) -> PackedByteArray:
	if client_time_ms < 0:
		client_time_ms = Time.get_ticks_msec()
	var buf := StreamPeerBuffer.new()
	buf.put_u32(nonce & 0xFFFFFFFF)
	buf.put_u64(client_time_ms)
	return buf.data_array


static func decode_ping(payload: PackedByteArray) -> Dictionary:
	var result := {"ok": false, "nonce": 0, "client_time_ms": 0}
	if payload.size() != 12:
		return result
	var buf := StreamPeerBuffer.new()
	buf.data_array = payload
	result["nonce"] = int(buf.get_u32())
	result["client_time_ms"] = int(buf.get_u64())
	result["ok"] = true
	return result


static func encode_pong(nonce: int, client_time_ms: int, server_tick: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u32(nonce & 0xFFFFFFFF)
	buf.put_u64(client_time_ms)
	buf.put_u32(server_tick & 0xFFFFFFFF)
	return buf.data_array


static func decode_pong(payload: PackedByteArray) -> Dictionary:
	var result := {"ok": false, "nonce": 0, "client_time_ms": 0, "server_tick": 0}
	if payload.size() != 16:
		return result
	var buf := StreamPeerBuffer.new()
	buf.data_array = payload
	result["nonce"] = int(buf.get_u32())
	result["client_time_ms"] = int(buf.get_u64())
	result["server_tick"] = int(buf.get_u32())
	result["ok"] = true
	return result


# ================================================================ ERROR
# payload: u16 code | u16 msg_len | msg(UTF-8)

static func encode_error(code: int, message: String) -> PackedByteArray:
	var msg_bytes := _truncate_utf8(message, MAX_ERROR_BYTES)
	var buf := StreamPeerBuffer.new()
	buf.put_u16(clampi(code, 0, 65535))
	buf.put_u16(msg_bytes.size())
	buf.put_data(msg_bytes)
	return buf.data_array


static func decode_error(payload: PackedByteArray) -> Dictionary:
	var result := {"ok": false, "code": 0, "message": ""}
	if payload.size() < 4:
		return result
	var buf := StreamPeerBuffer.new()
	buf.data_array = payload
	var code := int(buf.get_u16())
	var msg_len := int(buf.get_u16())
	if msg_len > MAX_ERROR_BYTES or buf.get_available_bytes() != msg_len:
		return result
	var message := ""
	if msg_len > 0:
		var got: Array = buf.get_data(msg_len)
		if int(got[0]) != OK:
			return result
		var message_bytes: PackedByteArray = got[1]
		message = message_bytes.get_string_from_utf8()
	result["ok"] = true
	result["code"] = code
	result["message"] = message
	return result


# ================================================================ 内部工具

## 把字符串截断到不超过 max_bytes 的 UTF-8 字节数，且不切坏多字节字符。
static func _truncate_utf8(text: String, max_bytes: int) -> PackedByteArray:
	var bytes := text.to_utf8_buffer()
	if bytes.size() <= max_bytes:
		return bytes
	var length := text.length()
	while length > 0 and bytes.size() > max_bytes:
		length -= 1
		bytes = text.substr(0, length).to_utf8_buffer()
	return bytes


static func _as_float(value) -> float:
	var kind := typeof(value)
	if kind == TYPE_FLOAT or kind == TYPE_INT:
		return float(value)
	return 0.0


static func _quantize_i8(value: float) -> int:
	if not is_finite(value):
		return 0
	return clampi(roundi(value), -100, 100)
