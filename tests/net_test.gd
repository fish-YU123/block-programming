extends SceneTree
## M6 联机基础框架回归测试：headless 运行
##   godot --headless --path . --script res://tests/net_test.gd
##
## 覆盖：协议帧/各消息往返、坏帧健壮性、快照量化与边界、
##       UDP 双实例 loopback（环境不允许时记为“跳过”而不是失败）。

const Protocol = preload("res://scripts/net/protocol.gd")
const Snapshot = preload("res://scripts/net/snapshot.gd")
const NetSession = preload("res://scripts/net/net_session.gd")

var _passed := 0
var _failed := 0
var _skipped := 0
var _failures: Array = []
var _skips: Array = []


func _initialize() -> void:
	_test_protocol_messages()
	_test_protocol_framing_errors()
	_test_payload_decode_errors()
	_test_snapshot_roundtrip()
	_test_snapshot_edge_cases()
	_test_net_guards()
	_test_net_loopback()
	print("通过 %d 项，失败 %d 项" % [_passed, _failed])
	if _skipped > 0:
		print("跳过 %d 项" % _skipped)
		for item in _skips:
			print("  - " + str(item))
	for item in _failures:
		print("  ✗ " + str(item))
	quit(0 if _failed == 0 else 1)


# ---------------------------------------------------------------- 协议：各消息往返

func _test_protocol_messages() -> void:
	_expect_eq("消息名 SNAPSHOT", Protocol.message_name(Protocol.MSG_SNAPSHOT), "SNAPSHOT")
	_expect_eq("未知消息名", Protocol.message_name(250), "UNKNOWN")

	# HELLO
	var hello_payload := _roundtrip("HELLO", Protocol.MSG_HELLO, Protocol.encode_hello("飞飞玩家", 2))
	var hello := Protocol.decode_hello(hello_payload)
	_expect_eq("HELLO ok", hello["ok"], true)
	_expect_eq("HELLO team", hello["team"], 2)
	_expect_eq("HELLO 中文名", hello["player_name"], "飞飞玩家")
	var long_hello := Protocol.decode_hello(Protocol.encode_hello("名".repeat(100), 1))
	_expect_le("HELLO 名字按字节截断", float(str(long_hello["player_name"]).to_utf8_buffer().size()), float(Protocol.MAX_NAME_BYTES))
	_expect_eq("HELLO 截断后仍是合法 UTF-8", long_hello["ok"], true)

	# WELCOME
	var welcome_payload := _roundtrip("WELCOME", Protocol.MSG_WELCOME, Protocol.encode_welcome(7, 1, 20, 123456, 424242))
	var welcome := Protocol.decode_welcome(welcome_payload)
	_expect_eq("WELCOME session", welcome["session_id"], 7)
	_expect_eq("WELCOME team", welcome["team"], 1)
	_expect_eq("WELCOME tick_rate", welcome["tick_rate"], 20)
	_expect_eq("WELCOME server_tick", welcome["server_tick"], 123456)
	_expect_eq("WELCOME map_seed", welcome["map_seed"], 424242)

	# CODE
	var source := "def tick():\n    set_lift(0.8)\n# 中文注释：悬停\n"
	var code_payload := _roundtrip("CODE", Protocol.MSG_CODE, Protocol.encode_code(42, 3, source))
	var code := Protocol.decode_code(code_payload)
	_expect_eq("CODE ok", code["ok"], true)
	_expect_eq("CODE uid", code["unit_uid"], 42)
	_expect_eq("CODE revision", code["revision"], 3)
	_expect_eq("CODE 源码一致", code["source"], source)
	var big_code := Protocol.decode_code(Protocol.encode_code(1, 1, "x".repeat(Protocol.MAX_CODE_BYTES + 100)))
	_expect_eq("CODE 超长被截断", str(big_code["source"]).length(), Protocol.MAX_CODE_BYTES)

	# SNAPSHOT
	var snap_bytes := Snapshot.capture(_make_units(), 888)
	var snap_payload := _roundtrip("SNAPSHOT", Protocol.MSG_SNAPSHOT, Protocol.encode_snapshot(snap_bytes))
	var snap := Protocol.decode_snapshot(snap_payload)
	_expect_eq("SNAPSHOT ok", snap["ok"], true)
	_expect_eq("SNAPSHOT tick", snap["tick"], 888)
	_expect_eq("SNAPSHOT count", snap["count"], 3)
	_expect_eq("SNAPSHOT 单位数", (snap["units"] as Array).size(), 3)

	# INPUT
	var controls := {"lift": 0.37, "pitch": -0.5, "roll": 1.0, "turn": -1.0, "forward": 0.0, "drill": true}
	var input_payload := _roundtrip("INPUT", Protocol.MSG_INPUT, Protocol.encode_input(555, 9, controls))
	var input := Protocol.decode_input(input_payload)
	_expect_eq("INPUT ok", input["ok"], true)
	_expect_eq("INPUT tick", input["tick"], 555)
	_expect_eq("INPUT uid", input["unit_uid"], 9)
	_expect_eq("INPUT drill", input["drill"], true)
	var decoded_controls: Dictionary = input["controls"]
	_expect_le("INPUT lift 量化", absf(float(decoded_controls["lift"]) - 0.37), 0.011)
	_expect_le("INPUT pitch 量化", absf(float(decoded_controls["pitch"]) - -0.5), 0.011)
	_expect_le("INPUT roll 量化", absf(float(decoded_controls["roll"]) - 1.0), 0.011)

	# PING / PONG
	var ping_payload := _roundtrip("PING", Protocol.MSG_PING, Protocol.encode_ping(123456, 9876543210))
	var ping := Protocol.decode_ping(ping_payload)
	_expect_eq("PING ok", ping["ok"], true)
	_expect_eq("PING nonce", ping["nonce"], 123456)
	_expect_eq("PING 时间戳", ping["client_time_ms"], 9876543210)

	var pong_payload := _roundtrip("PONG", Protocol.MSG_PONG, Protocol.encode_pong(123456, 9876543210, 777))
	var pong := Protocol.decode_pong(pong_payload)
	_expect_eq("PONG ok", pong["ok"], true)
	_expect_eq("PONG nonce", pong["nonce"], 123456)
	_expect_eq("PONG 时间戳", pong["client_time_ms"], 9876543210)
	_expect_eq("PONG server_tick", pong["server_tick"], 777)

	# ERROR
	var error_payload := _roundtrip("ERROR", Protocol.MSG_ERROR, Protocol.encode_error(Protocol.ERR_CODE_REJECTED, "代码太长：请精简到 64KB 以内"))
	var error := Protocol.decode_error(error_payload)
	_expect_eq("ERROR ok", error["ok"], true)
	_expect_eq("ERROR code", error["code"], Protocol.ERR_CODE_REJECTED)
	_expect_eq("ERROR 中文文本", error["message"], "代码太长：请精简到 64KB 以内")


# ---------------------------------------------------------------- 协议：坏帧

func _test_protocol_framing_errors() -> void:
	var good := Protocol.encode_message(Protocol.MSG_PING, Protocol.encode_ping(1, 2))

	_expect_eq("空帧失败", Protocol.decode_message(PackedByteArray())["ok"], false)
	_expect_eq("短帧失败", Protocol.decode_message(good.slice(0, 3))["ok"], false)

	var wrong_version := good.duplicate()
	wrong_version[0] = 99
	_expect_eq("版本不符失败", Protocol.decode_message(wrong_version)["ok"], false)

	_expect_eq("负载截断失败", Protocol.decode_message(good.slice(0, good.size() - 1))["ok"], false)
	var extended := good.duplicate()
	extended.append(0)
	_expect_eq("尾部多余字节失败", Protocol.decode_message(extended)["ok"], false)

	var unknown := _craft_header(250, 1)
	unknown.append(0)
	_expect_eq("未知消息 id 失败", Protocol.decode_message(unknown)["ok"], false)

	var huge := _craft_header(Protocol.MSG_SNAPSHOT, 0xFFFFFFFF)
	_expect_eq("超大声明长度失败", Protocol.decode_message(huge)["ok"], false)

	_expect_eq("未知 id 无法编码", Protocol.encode_message(250, PackedByteArray()).is_empty(), true)
	_expect_eq("空负载正帧可解帧", Protocol.decode_message(Protocol.encode_message(Protocol.MSG_PING, PackedByteArray()))["ok"], true)
	_expect_eq("但 PING 空负载解码失败", Protocol.decode_ping(PackedByteArray())["ok"], false)


# ---------------------------------------------------------------- 各消息负载的截断/损坏

func _test_payload_decode_errors() -> void:
	_expect_eq("HELLO 空负载失败", Protocol.decode_hello(PackedByteArray())["ok"], false)
	_expect_eq("HELLO 名字长度不符失败", Protocol.decode_hello(PackedByteArray([1, 5, 65]))["ok"], false)

	_expect_eq("WELCOME 短负载失败", Protocol.decode_welcome(PackedByteArray([0, 0, 0, 0]))["ok"], false)
	var welcome_payload := Protocol.encode_welcome(1, 1, 20, 2, 3)
	_expect_eq("WELCOME 截断失败", Protocol.decode_welcome(welcome_payload.slice(0, welcome_payload.size() - 1))["ok"], false)

	_expect_eq("CODE 空负载失败", Protocol.decode_code(PackedByteArray())["ok"], false)
	var code_payload := Protocol.encode_code(1, 1, "abc")
	_expect_eq("CODE 源码截断失败", Protocol.decode_code(code_payload.slice(0, code_payload.size() - 1))["ok"], false)
	var code_bad_len := StreamPeerBuffer.new()
	code_bad_len.put_u32(1)
	code_bad_len.put_u32(1)
	code_bad_len.put_u32(9999)
	_expect_eq("CODE 声明长度超限失败", Protocol.decode_code(code_bad_len.data_array)["ok"], false)

	_expect_eq("INPUT 短负载失败", Protocol.decode_input(PackedByteArray([0, 0, 0, 0]))["ok"], false)
	_expect_eq("PING 短负载失败", Protocol.decode_ping(PackedByteArray([0, 0, 0, 0]))["ok"], false)
	_expect_eq("PONG 短负载失败", Protocol.decode_pong(PackedByteArray([0, 0, 0, 0]))["ok"], false)
	_expect_eq("ERROR 短负载失败", Protocol.decode_error(PackedByteArray([0, 1]))["ok"], false)
	var error_payload := Protocol.encode_error(1, "x")
	_expect_eq("ERROR 文本截断失败", Protocol.decode_error(error_payload.slice(0, error_payload.size() - 1))["ok"], false)

	# SNAPSHOT 消息层：空/损坏负载
	_expect_eq("SNAPSHOT 空负载失败", Protocol.decode_snapshot(PackedByteArray())["ok"], false)
	_expect_eq("SNAPSHOT 编码空数组失败", Protocol.encode_snapshot(PackedByteArray()).is_empty(), true)
	var snap := Snapshot.capture(_make_units(), 1)
	_expect_eq("SNAPSHOT 负载截断失败", Protocol.decode_snapshot(snap.slice(0, snap.size() - 1))["ok"], false)


# ---------------------------------------------------------------- 快照：往返与量化

func _test_snapshot_roundtrip() -> void:
	var units := _make_units()
	var bytes := Snapshot.capture(units, 123456)
	_expect_eq("快照长度固定", bytes.size(), Snapshot.payload_size(units.size()))

	var parsed := Snapshot.parse(bytes)
	_expect_eq("快照 ok", parsed["ok"], true)
	_expect_eq("快照 tick", parsed["tick"], 123456)
	_expect_eq("快照 count", parsed["count"], units.size())
	var out_units: Array = parsed["units"]
	_expect_eq("快照单位数", out_units.size(), units.size())

	for i in units.size():
		var src: Dictionary = units[i]
		var dst: Dictionary = out_units[i]
		var label := "单位%d" % i
		_expect_eq(label + " uid", dst["uid"], src["uid"])
		_expect_eq(label + " team", dst["team"], src["team"])
		var sp: Vector3 = src["pos"]
		var dp: Vector3 = dst["pos"]
		_expect_le(label + " pos.x 误差", absf(dp.x - sp.x), 0.02)
		_expect_le(label + " pos.y 误差", absf(dp.y - sp.y), 0.02)
		_expect_le(label + " pos.z 误差", absf(dp.z - sp.z), 0.02)
		var sv: Vector3 = src["vel"]
		var dv: Vector3 = dst["vel"]
		_expect_le(label + " vel.x 误差", absf(dv.x - sv.x), 0.02)
		_expect_le(label + " vel.y 误差", absf(dv.y - sv.y), 0.02)
		_expect_le(label + " vel.z 误差", absf(dv.z - sv.z), 0.02)
		_expect_le(label + " yaw 误差", _angle_diff(float(dst["yaw"]), float(src["yaw"])), 0.001)
		_expect_le(label + " energy 误差", absf(float(dst["energy"]) - float(src["energy"])), 0.5)

	# apply() 与 parse() 等价
	_expect_eq("apply 等价 parse", Snapshot.apply(bytes), parsed)


# ---------------------------------------------------------------- 快照：边界与损坏

func _test_snapshot_edge_cases() -> void:
	var empty_bytes := Snapshot.capture([], 7)
	_expect_eq("空快照长度", empty_bytes.size(), Snapshot.HEADER_BYTES)
	var empty_parsed := Snapshot.parse(empty_bytes)
	_expect_eq("空快照 ok", empty_parsed["ok"], true)
	_expect_eq("空快照 tick", empty_parsed["tick"], 7)
	_expect_eq("空快照单位数", (empty_parsed["units"] as Array).size(), 0)

	_expect_eq("空字节失败", Snapshot.parse(PackedByteArray())["ok"], false)
	_expect_eq("垃圾字节失败", Snapshot.parse(PackedByteArray([1, 2, 3, 4, 5]))["ok"], false)

	var wrong_version := empty_bytes.duplicate()
	wrong_version[0] = 99
	_expect_eq("快照版本不符失败", Snapshot.parse(wrong_version)["ok"], false)

	var too_many := StreamPeerBuffer.new()
	too_many.put_u8(Snapshot.SNAPSHOT_VERSION)
	too_many.put_u32(1)
	too_many.put_u16(Snapshot.MAX_UNITS + 1)
	_expect_eq("单位数超限失败", Snapshot.parse(too_many.data_array)["ok"], false)

	var valid := Snapshot.capture(_make_units(), 1)
	_expect_eq("快照截断失败", Snapshot.parse(valid.slice(0, valid.size() - 1))["ok"], false)
	var trailing := valid.duplicate()
	trailing.append(0)
	_expect_eq("快照尾部多余失败", Snapshot.parse(trailing)["ok"], false)

	# 上限保护：超过 MAX_UNITS 时只保留前 MAX_UNITS 个
	var many: Array = []
	for i in Snapshot.MAX_UNITS + 40:
		many.append({"uid": i + 1, "team": 1, "pos": Vector3.ZERO, "vel": Vector3.ZERO, "yaw": 0.0, "energy": 1.0})
	var capped_bytes := Snapshot.capture(many, 2)
	_expect_eq("快照单位数上限", capped_bytes.size(), Snapshot.payload_size(Snapshot.MAX_UNITS))
	var capped := Snapshot.parse(capped_bytes)
	_expect_eq("上限快照 ok", capped["ok"], true)
	_expect_eq("上限快照 count", capped["count"], Snapshot.MAX_UNITS)

	# 非有限值不能把包写坏
	var bad_unit := {
		"uid": 5, "team": 1,
		"pos": Vector3(NAN, INF, -INF),
		"vel": Vector3(NAN, 0.0, 0.0),
		"yaw": NAN,
		"energy": INF,
	}
	var bad_parsed := Snapshot.parse(Snapshot.capture([bad_unit], 3))
	_expect_eq("非有限值快照 ok", bad_parsed["ok"], true)
	var bad_out: Dictionary = (bad_parsed["units"] as Array)[0]
	var bad_pos: Vector3 = bad_out["pos"]
	_expect_eq("NAN 位置写 0", bad_pos, Vector3.ZERO)
	_expect_eq("NAN yaw 写 0", bad_out["yaw"], 0.0)
	_expect_eq("INF 能量写 0", bad_out["energy"], 0.0)
	_expect_eq("非有限值全部有限", is_finite(float(bad_out["energy"])), true)

	# 缺字段字典不应崩溃
	var missing := Snapshot.parse(Snapshot.capture([{}], 4))
	_expect_eq("缺字段单位 ok", missing["ok"], true)
	_expect_eq("缺字段 uid", (missing["units"] as Array)[0]["uid"], 0)

	# 范围夹紧：位置超过 int16 厘米上限
	var far := Snapshot.parse(Snapshot.capture([{"uid": 8, "team": 2, "pos": Vector3(400.0, -400.0, 0.0)}], 5))
	var far_pos: Vector3 = (far["units"] as Array)[0]["pos"]
	_expect_le("位置超范围被夹紧", far_pos.x, 327.68)
	_expect_le("负位置超范围被夹紧", absf(far_pos.y), 327.68)


# ---------------------------------------------------------------- 网络会话：参数与空转保护

func _test_net_guards() -> void:
	var session := NetSession.new()
	_expect_eq("未启动 poll 返回空", session.poll().size(), 0)
	_expect_eq("未启动 send 不崩溃", _send_on_empty(session), true)
	_expect_eq("未启动有错误信息", session.get_last_error() != "", true)
	_expect_eq("未启动模式", session.get_mode(), NetSession.MODE_NONE)
	session.close()
	session.close()
	_expect_eq("重复 close 安全", session.get_mode(), NetSession.MODE_NONE)

	var bad_port := NetSession.new()
	_expect_eq("端口 0 被拒绝", bad_port.host(0) != "", true)
	_expect_eq("端口 70000 被拒绝", bad_port.join("127.0.0.1", 70000) != "", true)
	_expect_eq("空地址被拒绝", bad_port.join("   ", 27015) != "", true)
	bad_port.close()


func _send_on_empty(session) -> bool:
	session.send_to(1, Protocol.MSG_PING, Protocol.encode_ping(1, 1))
	return true


# ---------------------------------------------------------------- UDP 双实例回环

func _test_net_loopback() -> void:
	var port := 0
	var err := ""
	var server := NetSession.new()
	# 共享工作区里可能有别的进程占用端口；多试几个，全部失败才跳过。
	for attempt in 8:
		port = 28000 + ((OS.get_process_id() + attempt * 97) % 700)
		err = server.host(port)
		if err == "":
			break
	if err != "":
		_skip("UDP 回环（无法绑定端口）", err)
		server.close()
		return
	_expect_eq("服务端 host 成功", server.is_hosting(), true)

	# 同一端口二次绑定应返回错误串而不是崩溃
	var duplicate := NetSession.new()
	var duplicate_err := duplicate.host(port)
	_record("重复绑定返回错误串", duplicate_err != "", "实际返回「%s」" % duplicate_err)
	duplicate.close()

	var client := NetSession.new()
	err = client.join("127.0.0.1", port)
	if err != "":
		_skip("UDP 回环（客户端无法加入）", err)
		client.close()
		server.close()
		return
	_expect_eq("客户端 join 成功", client.is_joined(), true)

	var nonce := 424242
	var client_time := 123456
	client.send_to(NetSession.SERVER_SESSION_ID, Protocol.MSG_PING, Protocol.encode_ping(nonce, client_time))

	var pings: Array = []
	for i in 300:
		for message in server.poll():
			if int(message["id"]) == Protocol.MSG_PING:
				pings.append(message)
		if not pings.is_empty():
			break
		OS.delay_msec(2)

	if pings.is_empty():
		_skip("UDP 回环（300 次轮询内未收到 PING）", "本机 UDP 回环可能被沙箱/防火墙拦截")
		client.close()
		server.close()
		return

	_expect_eq("服务端收到 PING", pings.size(), 1)
	var ping_message: Dictionary = pings[0]
	var server_session := int(ping_message["session_id"])
	_expect_eq("服务端分配 session_id", server_session >= NetSession.SERVER_SESSION_ID, true)
	var ping := Protocol.decode_ping(ping_message["payload"])
	_expect_eq("回环 PING nonce", ping["nonce"], nonce)
	_expect_eq("回环 PING 时间戳", ping["client_time_ms"], client_time)

	# 单播 PONG + 广播 ERROR，验证 send_to / broadcast 两条路径
	server.send_to(server_session, Protocol.MSG_PONG, Protocol.encode_pong(nonce, client_time, 4321))
	server.broadcast(Protocol.MSG_ERROR, Protocol.encode_error(Protocol.ERR_BAD_PROTOCOL, "回环测试"))
	_expect_eq("服务端 send_to 无错误", server.get_last_error(), "")
	_expect_eq("服务端会话列表", server.get_sessions().size(), 1)

	var pongs: Array = []
	var errors: Array = []
	for i in 300:
		for message in client.poll():
			var msg_id := int(message["id"])
			if msg_id == Protocol.MSG_PONG:
				pongs.append(message)
			elif msg_id == Protocol.MSG_ERROR:
				errors.append(message)
		if not pongs.is_empty() and not errors.is_empty():
			break
		OS.delay_msec(2)

	if pongs.is_empty() or errors.is_empty():
		_record("回环 PONG/ERROR 收到", false, "pong=%d error=%d（PING 已通，判定为传输实现问题而非环境跳过）" % [pongs.size(), errors.size()])
		client.close()
		server.close()
		return

	var pong := Protocol.decode_pong(pongs[0]["payload"])
	_expect_eq("回环 PONG ok", pong["ok"], true)
	_expect_eq("回环 PONG nonce", pong["nonce"], nonce)
	_expect_eq("回环 PONG server_tick", pong["server_tick"], 4321)
	_expect_eq("客户端视角 session_id", int(pongs[0]["session_id"]), NetSession.SERVER_SESSION_ID)

	var error := Protocol.decode_error(errors[0]["payload"])
	_expect_eq("回环广播 ERROR ok", error["ok"], true)
	_expect_eq("回环广播 ERROR code", error["code"], Protocol.ERR_BAD_PROTOCOL)
	_expect_eq("回环广播 ERROR 文本", error["message"], "回环测试")

	_expect_eq("服务端统计收到包", server.get_stats()["received"] > 0, true)
	_expect_eq("客户端统计收到包", client.get_stats()["received"] > 0, true)

	client.close()
	server.close()
	_expect_eq("关闭后回到 NONE", server.get_mode(), NetSession.MODE_NONE)


# ---------------------------------------------------------------- 工具

func _make_units() -> Array:
	return [
		{
			"uid": 1, "team": 1,
			"pos": Vector3(12.345, 4.567, 200.999),
			"vel": Vector3(-3.21, 0.5, 15.75),
			"yaw": 1.2345,
			"energy": 98765.4,
		},
		{
			"uid": 2, "team": 2,
			"pos": Vector3(255.99, 63.5, 0.01),
			"vel": Vector3.ZERO,
			"yaw": -3.0,
			"energy": 0.0,
		},
		{
			"uid": 3, "team": 0,
			"pos": Vector3(100.0, 20.25, 155.5),
			"vel": Vector3(0.123, -0.456, 2.0),
			"yaw": 0.0,
			"energy": -5.0,
		},
	]


func _roundtrip(name: String, msg_id: int, payload: PackedByteArray) -> PackedByteArray:
	_record(name + " 负载非空", not payload.is_empty(), "编码结果为空")
	var frame := Protocol.encode_message(msg_id, payload)
	_record(name + " 帧非空", not frame.is_empty(), "帧为空")
	var decoded: Dictionary = Protocol.decode_message(frame)
	var out: PackedByteArray = decoded["payload"]
	var header_ok := bool(decoded["ok"]) \
		and int(decoded["version"]) == Protocol.PROTOCOL_VERSION \
		and int(decoded["id"]) == msg_id \
		and out == payload
	_record(name + " 帧头与负载往返", header_ok, "decode=%s 负载相等=%s" % [str(decoded["ok"]), str(out == payload)])
	return out


func _craft_header(msg_id: int, length: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(Protocol.PROTOCOL_VERSION)
	buf.put_u8(msg_id)
	buf.put_u32(length)
	return buf.data_array


func _angle_diff(a: float, b: float) -> float:
	return absf(wrapf(a - b, -PI, PI))


func _expect_eq(name: String, actual, expected) -> void:
	_record(name, actual == expected, "期望 %s 实际 %s" % [str(expected), str(actual)])


func _expect_le(name: String, actual: float, limit: float) -> void:
	_record(name, actual <= limit, "期望 <= %s 实际 %s" % [str(limit), str(actual)])


func _skip(name: String, detail: String) -> void:
	_skipped += 1
	_skips.append("%s：%s" % [name, detail])


func _record(name: String, ok: bool, detail: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append("%s：%s" % [name, detail])
