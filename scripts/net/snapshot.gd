extends RefCounted
## M6 快照序列化：把单位状态压成定长二进制，供 20Hz 广播。
##
## 快照格式（小端）：
##   u8  version（SNAPSHOT_VERSION）
##   u32 tick（服务端 tick 序号，20Hz 下约 6.8 年回绕）
##   u16 unit_count（<= MAX_UNITS）
##   然后 unit_count 条固定 23 字节的单位记录：
##     u32 uid
##     u8  team
##     i16 pos.x, pos.y, pos.z    （厘米）
##     i16 vel.x, vel.y, vel.z    （厘米/秒）
##     i16 yaw                    （弧度 x 10000）
##     i32 energy                 （焦耳）
##
## 量化与范围：
##   - 位置 int16 厘米 => ±327.67 米，覆盖 256x256 地图；量化误差 <= 0.005 米。
##   - 速度 int16 厘米/秒 => ±327.67 米/秒；量化误差 <= 0.005 米/秒。
##   - yaw 先 wrap 到 [-PI, PI) 再乘 10000；量化误差 <= 0.00005 弧度。
##   - 能量 int32 焦耳，量化误差 <= 0.5 焦耳。
##   - NAN/INF 等非有限值统一写 0，避免服务端物理异常把整包弄坏。
##
## 健壮性：parse() 对空数组、截断、版本不符、数量超限、长度不符一律返回
## {"ok": false, "tick": 0, "count": 0, "units": []}，绝不越界读取。

const SNAPSHOT_VERSION := 1
const HEADER_BYTES := 7          # u8 version + u32 tick + u16 count
const UNIT_BYTES := 23           # 每个单位固定 23 字节
const MAX_UNITS := 512           # 单帧单位上限保护

const POS_SCALE := 100.0         # 米 -> 厘米
const VEL_SCALE := 100.0         # 米/秒 -> 厘米/秒
const YAW_SCALE := 10000.0       # 弧度 -> 1/10000 弧度

const I16_MIN := -32767
const I16_MAX := 32767
const I32_MIN := -2147483647
const I32_MAX := 2147483647


## 序列化一帧快照。tick 与单位数超出范围时截断/回绕，不会失败。
## units: [{uid:int, team:int, pos:Vector3, vel:Vector3, yaw:float, energy:float}]
static func capture(units: Array, tick: int) -> PackedByteArray:
	var count := mini(units.size(), MAX_UNITS)
	var buf := StreamPeerBuffer.new()
	buf.put_u8(SNAPSHOT_VERSION)
	buf.put_u32(tick & 0xFFFFFFFF)
	buf.put_u16(count)

	for i in count:
		var raw: Variant = units[i]
		var unit: Dictionary = {}
		if raw is Dictionary:
			unit = raw

		var pos := _as_vector3(unit.get("pos", Vector3.ZERO))
		var vel := _as_vector3(unit.get("vel", Vector3.ZERO))
		var yaw := wrapf(_as_float(unit.get("yaw", 0.0)), -PI, PI)
		var energy := _as_float(unit.get("energy", 0.0))

		buf.put_u32(_as_int(unit.get("uid", 0)) & 0xFFFFFFFF)
		buf.put_u8(_as_int(unit.get("team", 0)) & 0xFF)
		buf.put_16(_quantize_i16(pos.x * POS_SCALE))
		buf.put_16(_quantize_i16(pos.y * POS_SCALE))
		buf.put_16(_quantize_i16(pos.z * POS_SCALE))
		buf.put_16(_quantize_i16(vel.x * VEL_SCALE))
		buf.put_16(_quantize_i16(vel.y * VEL_SCALE))
		buf.put_16(_quantize_i16(vel.z * VEL_SCALE))
		buf.put_16(_quantize_i16(yaw * YAW_SCALE))
		buf.put_32(_quantize_i32(energy))

	return buf.data_array


## 反序列化。成功返回 {ok:true, tick, count, units}；
## 任何损坏都返回 {ok:false, tick:0, count:0, units:[]}。
static func parse(bytes: PackedByteArray) -> Dictionary:
	var empty := {"ok": false, "tick": 0, "count": 0, "units": []}
	if bytes.size() < HEADER_BYTES:
		return empty

	var buf := StreamPeerBuffer.new()
	buf.data_array = bytes
	var version := int(buf.get_u8())
	var tick := int(buf.get_u32())
	var count := int(buf.get_u16())

	if version != SNAPSHOT_VERSION:
		return empty
	if count > MAX_UNITS:
		return empty
	if bytes.size() != HEADER_BYTES + count * UNIT_BYTES:
		return empty

	var units: Array = []
	units.resize(count)
	for i in count:
		var uid := int(buf.get_u32())
		var team := int(buf.get_u8())
		var px := int(buf.get_16())
		var py := int(buf.get_16())
		var pz := int(buf.get_16())
		var vx := int(buf.get_16())
		var vy := int(buf.get_16())
		var vz := int(buf.get_16())
		var yaw_raw := int(buf.get_16())
		var energy_raw := int(buf.get_32())
		units[i] = {
			"uid": uid,
			"team": team,
			"pos": Vector3(float(px) / POS_SCALE, float(py) / POS_SCALE, float(pz) / POS_SCALE),
			"vel": Vector3(float(vx) / VEL_SCALE, float(vy) / VEL_SCALE, float(vz) / VEL_SCALE),
			"yaw": float(yaw_raw) / YAW_SCALE,
			"energy": float(energy_raw),
		}

	return {"ok": true, "tick": tick, "count": count, "units": units}


## apply() 是 parse() 的别名，方便调用方按“应用快照”语义阅读。
static func apply(bytes: PackedByteArray) -> Dictionary:
	return parse(bytes)


## 快速判断一帧快照是否可解析（只做结构校验，不做语义校验）。
static func is_valid(bytes: PackedByteArray) -> bool:
	return bool(parse(bytes).get("ok", false))


## 给定单位数时快照的字节数（用于带宽估算/测试）。
static func payload_size(unit_count: int) -> int:
	return HEADER_BYTES + clampi(unit_count, 0, MAX_UNITS) * UNIT_BYTES


# ---------------------------------------------------------------- 内部工具

static func _as_int(value) -> int:
	var kind := typeof(value)
	if kind == TYPE_INT or kind == TYPE_FLOAT:
		return int(value)
	return 0


static func _as_float(value) -> float:
	var kind := typeof(value)
	if kind == TYPE_FLOAT or kind == TYPE_INT:
		return float(value)
	return 0.0


static func _as_vector3(value) -> Vector3:
	if value is Vector3:
		return value
	return Vector3.ZERO


## 浮点 -> 有符号 16 位；非有限值写 0，超范围夹紧。
static func _quantize_i16(value: float) -> int:
	if not is_finite(value):
		return 0
	return clampi(roundi(value), I16_MIN, I16_MAX)


## 浮点 -> 有符号 32 位；非有限值写 0，超范围夹紧。
static func _quantize_i32(value: float) -> int:
	if not is_finite(value):
		return 0
	return clampi(roundi(value), I32_MIN, I32_MAX)
