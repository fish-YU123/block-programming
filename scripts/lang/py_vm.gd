extends RefCounted
## 沙箱虚拟机：执行编译后的字节码。
##
## 设计要点（相对原 Python 子进程方案）：
## 1) 纯 GDScript，无子进程/无网络 -> 可上架、天然沙箱，玩家代码碰不到文件系统和系统调用；
## 2) 指令级预算 -> 死循环可被掐断，不会卡住物理帧；
## 3) 固定的浮点运算路径 -> 同一台机器上行为可复现，为以后联机确定性打底；
## 4) 每条语句一个 LINE 指令 -> 保持"每秒执行 N 行"的原有节奏。

const Op = preload("res://scripts/lang/py_opcodes.gd")
const Parser = preload("res://scripts/lang/py_parser.gd")
const Compiler = preload("res://scripts/lang/py_compiler.gd")

const MAX_REPEAT := 1000000

const BUILTINS := [
	"print", "set_drive", "set_spin", "set_steer", "set_thrust", "get_link",
	"set_lift", "set_tilt", "set_rcs", "drill", "laser", "laser_off", "shoot", "go_to", "stop", "find_path", "set_velocity", "set_altitude",
	"build", "build_here", "place", "transfer",
	"team_set", "team_get", "mark", "command", "produce", "block_at",
	"range", "len", "abs", "min", "max", "int", "float", "str", "round", "bool",
]

const DEFAULT_CONTROLS := {
	"lift": 0.0, "pitch": 0.0, "roll": 0.0, "turn": 0.0, "forward": 0.0, "drill": false,
	"laser": false, "laser_x": 0.0, "laser_y": 0.0, "laser_z": 0.0,
	"shoot": false, "shoot_x": 0.0, "shoot_y": 0.0, "shoot_z": 0.0,
	"go": false, "go_x": 0.0, "go_y": 0.0, "go_z": 0.0,
	"vel_mode": false, "vx": 0.0, "vz": 0.0, "transfer": false,
	"alt_mode": false, "alt_target": 0.0,
}

var globals: Dictionary = {}
var state: Dictionary = {"drive": 0.0, "spin": {}, "steer": {}, "thrust": {}, "mem": {}, "controls": DEFAULT_CONTROLS.duplicate()}
## 由控制器塞进来：给 find_path(x,y,z) 用，返回 Array[Vector3]
var path_provider: Callable = Callable()
## 建筑：build(id, x, y, z) 与 build_here(id)，返回错误字符串（空串表示成功）
var build_provider: Callable = Callable()
## block_at(x, y, z)：全景雷达提供的「查整张地图某格是什么方块」
var block_at_provider: Callable = Callable()
var build_here_provider: Callable = Callable()
var place_provider: Callable = Callable()
## 协同：队伍共享黑板与标点
var team_set_provider: Callable = Callable()
var team_get_provider: Callable = Callable()
var mark_provider: Callable = Callable()
## 跨单位直接下指令：command(uid, 动作, x, y, z)
var command_provider: Callable = Callable()
## 让旁边的厂房改生产：produce(单位id)
var produce_provider: Callable = Callable()
var logs: Array = []
var error := ""
var finished := false

var _chunks: Array = []
var _funcs: Array = []
var _main: Dictionary = {}
var _frames: Array = []
var _parts: Array = []
var _line := 0
## 传感器不再每帧复制进 globals（真实负载 ~40 个键 × 每单位每帧，是 inject 的主要成本）：
## 直接持有 readings 字典，LOAD 时按 locals -> readings -> globals -> builtin 顺序查。
var _readings: Dictionary = {}
## 玩家代码给"传感器同名变量"赋值时会写 globals；这里记下被遮蔽的键，下次 inject 时清掉
var _shadowed: Dictionary = {}
## 名字查找加速：内置函数表、函数名 -> 下标
var _builtin_map: Dictionary = {}
var _func_by_name: Dictionary = {}
## 复用的结果字典：真实主循环里每个单位每帧至少调一次 step()，不再每步 new 4 个 Dictionary
var _result_cache: Dictionary = {}
var _spin_out: Dictionary = {}
var _steer_out: Dictionary = {}
var _thrust_out: Dictionary = {}
var _controls_out: Dictionary = {}
var _controls_dirty := true
var _spin_dirty := true
var _steer_dirty := true
var _thrust_dirty := true


func _init() -> void:
	for name in BUILTINS:
		_builtin_map[str(name)] = true


func load_source(src: String) -> void:
	_reset_runtime()
	var parser := Parser.new()
	var parsed := parser.parse(src)
	if not bool(parsed.get("ok", false)):
		error = str(parsed.get("error", "语法错误"))
		finished = true
		return
	var compiler := Compiler.new()
	var compiled := compiler.compile(parsed["body"])
	if not bool(compiled.get("ok", false)):
		error = str(compiled.get("error", "编译错误"))
		finished = true
		return
	_main = compiled["main"]
	_funcs = compiled["funcs"]
	_build_func_index()
	_normalize_chunks()
	_frames = []
	_frames.append(_new_frame(_main))


## 把字节码里的字符串运算符（"+"/"<"/"not" 等）改写成整数 id。
## 运行时按整数分支，避免每步对字符串做线性 match；写回 PackedInt32Array 因为它是值类型。
func _normalize_chunks() -> void:
	_normalize_chunk(_main)
	for chunk in _funcs:
		_normalize_chunk(chunk)


func _normalize_chunk(chunk: Dictionary) -> void:
	var code: PackedInt32Array = chunk["code"]
	var args: PackedInt32Array = chunk["arg"]
	var args2: PackedInt32Array = chunk["arg2"]
	var names: PackedStringArray = chunk["names"]
	for i in code.size():
		match code[i]:
			Op.BIN:
				args[i] = int(Op.BIN_OPS.get(names[args[i]], 0))
			Op.CMP:
				args[i] = int(Op.CMP_OPS.get(names[args[i]], 0))
			Op.UNARY:
				args[i] = int(Op.UN_OPS.get(names[args[i]], 0))
			Op.AUG_ATTR:
				args2[i] = int(Op.BIN_OPS.get(names[args2[i]], 0))
			Op.AUG_ITEM:
				args[i] = int(Op.BIN_OPS.get(names[args[i]], 0))
	chunk["arg"] = args
	chunk["arg2"] = args2


func _bin_name(op_id: int) -> String:
	return str(Op.BIN_NAMES.get(op_id, "?"))


func _cmp_name(op_id: int) -> String:
	return str(Op.CMP_NAMES.get(op_id, "?"))


func _un_name(op_id: int) -> String:
	return str(Op.UN_NAMES.get(op_id, "?"))


func _reset_runtime() -> void:
	globals = {"mem": state["mem"], "PI": PI, "E": 2.718281828459045}
	state = {"drive": 0.0, "spin": {}, "steer": {}, "thrust": {}, "mem": state.get("mem", {}), "controls": DEFAULT_CONTROLS.duplicate()}
	_apply_part_names()
	logs = []
	error = ""
	finished = false
	_frames = []
	_readings = {}
	_shadowed.clear()
	_line = 0
	_mark_all_dirty()


func _new_frame(chunk: Dictionary) -> Dictionary:
	return {"chunk": chunk, "ip": 0, "stack": [], "locals": {}}


# ---------------------------------------------------------------- 外部接口

func set_parts(rows: Array) -> void:
	_parts = []
	for row in rows:
		if not (row is Dictionary):
			continue
		var item: Dictionary = row
		var part := {
			"__type": "part",
			"kind": str(item.get("kind", "")),
			"slot": int(item.get("slot", 0)),
			"name": str(item.get("name", "")),
		}
		_parts.append(part)
	_apply_part_names()


## 程序跑完后自动重跑（保留 mem），行为与旧 Python 版一致。
## 源码里是否定义了某个无参函数（用于 start / loop 这种框架回调）
func has_function(fname: String) -> bool:
	return _find_function(fname) >= 0


func _find_function(fname: String) -> int:
	return int(_func_by_name.get(fname, -1))


func _build_func_index() -> void:
	_func_by_name.clear()
	for i in _funcs.size():
		_func_by_name[str(_funcs[i].get("name", ""))] = i


## 直接调用一个无参函数（start / loop）；有参数或不存在则返回 false
func call_function(fname: String) -> bool:
	var index := _find_function(fname)
	if index < 0:
		return false
	var chunk: Dictionary = _funcs[index]
	if not Array(chunk.get("params", [])).is_empty():
		return false
	error = ""
	finished = false
	_frames = [_new_frame(chunk)]
	return true


func restart() -> void:
	if _main.is_empty():
		return
	finished = false
	_frames = [_new_frame(_main)]
	globals = {"mem": state["mem"], "PI": PI, "E": 2.718281828459045}
	_readings = {}
	_shadowed.clear()
	_apply_part_names()
	_mark_all_dirty()


func _mark_all_dirty() -> void:
	_controls_dirty = true
	_spin_dirty = true
	_steer_dirty = true
	_thrust_dirty = true


func _apply_part_names() -> void:
	for part in _parts:
		if str(part["name"]) != "":
			globals[str(part["name"])] = part


func inject(readings: Dictionary) -> void:
	# O(1)：只换引用。上一帧玩家给传感器同名变量赋过值的，先清掉那段遮蔽
	if not _shadowed.is_empty():
		for key in _shadowed:
			globals.erase(key)
		_shadowed.clear()
	# "mem" 是 VM 自己维护的全局量，不允许被传感器盖掉（旧实现同样跳过这个键）
	if readings.has("mem"):
		var filtered := readings.duplicate()
		filtered.erase("mem")
		_readings = filtered
	else:
		_readings = readings


## 跑一步：最多 max_lines 条语句。返回本帧结果。
## 热点：指令分发全部内联在这里（不再每条指令一次 func 调用 + Dictionary 查表），
## 局部变量缓存 stack / ip / 指令数组，只有换帧时才写回 frame。
func step(max_lines: int = 1, max_ops: int = 20000) -> Dictionary:
	if not logs.is_empty():
		logs.clear()
	error = ""
	var done := false
	if finished:
		return _result(true)
	# 预算计数用局部变量（成员访问在每条指令上都要付出代价）
	var lines_left := maxi(1, max_lines)
	var ops_left := max_ops
	while true:
		if _frames.is_empty():
			done = true
			finished = true
			break
		var frame: Dictionary = _frames[_frames.size() - 1]
		var chunk: Dictionary = frame["chunk"]
		var code: PackedInt32Array = chunk["code"]
		var arg1: PackedInt32Array = chunk["arg"]
		var arg2: PackedInt32Array = chunk["arg2"]
		var code_lines: PackedInt32Array = chunk["lines"]
		var names: PackedStringArray = chunk["names"]
		var consts: Array = chunk["consts"]
		var stack: Array = frame["stack"]
		var locals: Dictionary = frame["locals"]
		var is_func := bool(chunk["is_func"])
		var ip := int(frame["ip"])
		var code_size := code.size()
		var budget_stop := false
		var frame_changed := false
		while ip < code_size:
			var at := ip
			var op := code[at]
			var cur_line := code_lines[at]
			if op == Op.LINE:
				if lines_left <= 0:
					frame["ip"] = at
					budget_stop = true
					break
				lines_left -= 1
				_line = cur_line
			ops_left -= 1
			if ops_left <= 0:
				_fail("RuntimeError", "代码跑得太久（死循环？）", cur_line)
				done = true
				finished = true
				budget_stop = true
				break
			ip = at + 1
			if op == Op.LINE:
					pass
			elif op == Op.CONST:
					stack.append(consts[arg1[at]])
			elif op == Op.LOAD:
					var load_name := names[arg1[at]]
					if locals.has(load_name):
						stack.append(locals[load_name])
					elif _readings.has(load_name):
						# 玩家代码给同名变量赋过值 -> 本次注入周期内以玩家赋值为准
						if not _shadowed.is_empty() and _shadowed.has(load_name):
							stack.append(globals[load_name])
						else:
							stack.append(_readings[load_name])
					elif globals.has(load_name):
						stack.append(globals[load_name])
					elif _builtin_map.has(load_name):
						stack.append({"__type": "builtin", "name": load_name})
					else:
						_fail("NameError", "名字未定义：%s" % load_name, cur_line)
						done = true
						finished = true
						budget_stop = true
						break
			elif op == Op.STORE:
					var store_name := names[arg1[at]]
					var store_value = stack.pop_back()
					if is_func:
						locals[store_name] = store_value
					else:
						globals[store_name] = store_value
						if _readings.has(store_name):
							_shadowed[store_name] = true
			elif op == Op.GET_ITEM:
					var item_index = stack.pop_back()
					var item_container = stack.pop_back()
					var item_type := typeof(item_container)
					if item_type == TYPE_DICTIONARY:
						var item_dict: Dictionary = item_container
						if not item_dict.has("__type") and item_dict.has(item_index):
							stack.append(item_dict[item_index])
						elif not _push_get_item(item_container, item_index, cur_line, stack):
							done = true
							finished = true
							budget_stop = true
							break
					elif item_type == TYPE_ARRAY and typeof(item_index) == TYPE_INT:
						var item_list: Array = item_container
						var item_pos := int(item_index)
						if item_pos < 0:
							item_pos += item_list.size()
						if item_pos >= 0 and item_pos < item_list.size():
							stack.append(item_list[item_pos])
						elif not _push_get_item(item_container, item_index, cur_line, stack):
							done = true
							finished = true
							budget_stop = true
							break
					elif not _push_get_item(item_container, item_index, cur_line, stack):
						done = true
						finished = true
						budget_stop = true
						break
			elif op == Op.BIN:
					var bin_right = stack.pop_back()
					var bin_left = stack.pop_back()
					var bin_op := arg1[at]
					var bin_lt := typeof(bin_left)
					var bin_rt := typeof(bin_right)
					var bin_done := false
					if bin_lt == TYPE_INT and bin_rt == TYPE_INT:
						if bin_op == Op.BIN_ADD:
							stack.append(int(bin_left) + int(bin_right))
							bin_done = true
						elif bin_op == Op.BIN_SUB:
							stack.append(int(bin_left) - int(bin_right))
							bin_done = true
						elif bin_op == Op.BIN_MUL:
							stack.append(int(bin_left) * int(bin_right))
							bin_done = true
					elif (bin_lt == TYPE_INT or bin_lt == TYPE_FLOAT) and (bin_rt == TYPE_INT or bin_rt == TYPE_FLOAT):
						if bin_op == Op.BIN_ADD:
							stack.append(float(bin_left) + float(bin_right))
							bin_done = true
						elif bin_op == Op.BIN_SUB:
							stack.append(float(bin_left) - float(bin_right))
							bin_done = true
						elif bin_op == Op.BIN_MUL:
							stack.append(float(bin_left) * float(bin_right))
							bin_done = true
					if not bin_done:
						var bin_result = _binop(_bin_name(bin_op), bin_left, bin_right, cur_line)
						if error != "":
							done = true
							finished = true
							budget_stop = true
							break
						stack.append(bin_result)
			elif op == Op.SET_ITEM:
					# 栈顺序（由编译器产生）：[值, 容器, 下标]
					var si_index = stack.pop_back()
					var si_obj = stack.pop_back()
					var si_value = stack.pop_back()
					var si_type := typeof(si_obj)
					var si_ok := false
					if si_type == TYPE_DICTIONARY:
						var si_dict: Dictionary = si_obj
						if not si_dict.has("__type"):
							si_dict[si_index] = si_value
							si_ok = true
					elif si_type == TYPE_ARRAY and typeof(si_index) == TYPE_INT:
						var si_list: Array = si_obj
						var si_pos := int(si_index)
						if si_pos < 0:
							si_pos += si_list.size()
						if si_pos >= 0 and si_pos < si_list.size():
							si_list[si_pos] = si_value
							si_ok = true
					if not si_ok:
						_set_item(si_obj, si_index, si_value, cur_line)
						if error != "":
							done = true
							finished = true
							budget_stop = true
							break
			elif op == Op.JUMP:
					ip = arg1[at]
			elif op == Op.JF:
					if not _is_true(stack.pop_back()):
						ip = arg1[at]
			elif op == Op.FOR_NEXT:
					if stack.is_empty():
						_fail("RuntimeError", "内部错误：缺少迭代器", cur_line)
						done = true
						finished = true
						budget_stop = true
						break
					var iterator: Dictionary = stack[stack.size() - 1]
					if not _step_iter(iterator, stack):
						stack.pop_back()
						ip = arg1[at]
			elif op == Op.CMP:
					var cmp_right = stack.pop_back()
					var cmp_left = stack.pop_back()
					var cmp_op := arg1[at]
					var cmp_lt := typeof(cmp_left)
					var cmp_rt := typeof(cmp_right)
					var cmp_done := false
					if (cmp_lt == TYPE_INT or cmp_lt == TYPE_FLOAT) and (cmp_rt == TYPE_INT or cmp_rt == TYPE_FLOAT):
						var cmp_a := float(cmp_left)
						var cmp_b := float(cmp_right)
						if cmp_op == Op.CMP_EQ:
							stack.append(cmp_a == cmp_b)
							cmp_done = true
						elif cmp_op == Op.CMP_NE:
							stack.append(cmp_a != cmp_b)
							cmp_done = true
						elif cmp_op == Op.CMP_LT:
							stack.append(cmp_a < cmp_b)
							cmp_done = true
						elif cmp_op == Op.CMP_GT:
							stack.append(cmp_a > cmp_b)
							cmp_done = true
						elif cmp_op == Op.CMP_LE:
							stack.append(cmp_a <= cmp_b)
							cmp_done = true
						elif cmp_op == Op.CMP_GE:
							stack.append(cmp_a >= cmp_b)
							cmp_done = true
					if not cmp_done:
						var cmp_result = _compare(_cmp_name(cmp_op), cmp_left, cmp_right, cur_line)
						if error != "":
							done = true
							finished = true
							budget_stop = true
							break
						stack.append(cmp_result)
			elif op == Op.CALL:
					var argc := arg1[at]
					var args: Array = []
					if argc > 0:
						args.resize(argc)
						for k in argc:
							args[argc - 1 - k] = stack.pop_back()
					var callable = stack.pop_back()
					frame["ip"] = ip
					if not _call(callable, args, cur_line):
						done = true
						finished = true
						budget_stop = true
						break
					frame_changed = true
					break
			elif op == Op.POP:
					stack.pop_back()
			elif op == Op.RETURN:
					var return_value = stack.pop_back()
					_frames.pop_back()
					if _frames.is_empty():
						finished = true
					else:
						_frames[_frames.size() - 1]["stack"].append(return_value)
					frame_changed = true
					break
			elif op == Op.FUNC:
					stack.append({"__type": "func", "idx": arg1[at]})
			elif op == Op.ITER:
					var iterable = stack.pop_back()
					var it = _make_iter(iterable, cur_line)
					if it == null:
						done = true
						finished = true
						budget_stop = true
						break
					stack.append(it)
			elif op == Op.BUILD_LIST:
					var count := arg1[at]
					var items: Array = []
					if count > 0:
						items.resize(count)
						for k in count:
							items[count - 1 - k] = stack.pop_back()
					stack.append(items)
			elif op == Op.BUILD_DICT:
					var pairs := arg1[at]
					var dict := {}
					for i in pairs:
						var pair_value = stack.pop_back()
						var pair_key = stack.pop_back()
						dict[pair_key] = pair_value
					stack.append(dict)
			elif op == Op.UNARY:
					var un_value = stack.pop_back()
					var un_op := arg1[at]
					var un_type := typeof(un_value)
					var un_done := false
					if un_op == Op.UN_NEG:
						if un_type == TYPE_INT:
							stack.append(-int(un_value))
							un_done = true
						elif un_type == TYPE_FLOAT:
							stack.append(-float(un_value))
							un_done = true
					elif un_op == Op.UN_NOT:
						stack.append(not _is_true(un_value))
						un_done = true
					if not un_done:
						var un_result = _unary(_un_name(un_op), un_value, cur_line)
						if error != "":
							done = true
							finished = true
							budget_stop = true
							break
						stack.append(un_result)
			elif op == Op.LOAD_ATTR:
					var attr_obj = stack.pop_back()
					var attr_value = _get_attr(attr_obj, names[arg1[at]], cur_line)
					if error != "":
						done = true
						finished = true
						budget_stop = true
						break
					stack.append(attr_value)
			elif op == Op.STORE_ATTR:
					var set_obj = stack.pop_back()
					var set_value = stack.pop_back()
					_set_attr(set_obj, names[arg1[at]], set_value, cur_line)
					if error != "":
						done = true
						finished = true
						budget_stop = true
						break
			elif op == Op.DUP:
					if stack.is_empty():
						_fail("RuntimeError", "内部错误：栈为空", cur_line)
						done = true
						finished = true
						budget_stop = true
						break
					stack.append(stack[stack.size() - 1])
			elif op == Op.JT:
					if _is_true(stack.pop_back()):
						ip = arg1[at]
			elif op == Op.AUG_ATTR:
					var aug_value = stack.pop_back()
					var aug_obj = stack.pop_back()
					var current = _get_attr(aug_obj, names[arg1[at]], cur_line)
					if error != "":
						done = true
						finished = true
						budget_stop = true
						break
					var updated = _binop(_bin_name(arg2[at]), current, aug_value, cur_line)
					if error != "":
						done = true
						finished = true
						budget_stop = true
						break
					_set_attr(aug_obj, names[arg1[at]], updated, cur_line)
					if error != "":
						done = true
						finished = true
						budget_stop = true
						break
			elif op == Op.AUG_ITEM:
					var aug_item_value = stack.pop_back()
					var aug_index = stack.pop_back()
					var aug_container = stack.pop_back()
					var current_item = _get_item(aug_container, aug_index, cur_line)
					if error != "":
						done = true
						finished = true
						budget_stop = true
						break
					var new_item = _binop(_bin_name(arg1[at]), current_item, aug_item_value, cur_line)
					if error != "":
						done = true
						finished = true
						budget_stop = true
						break
					_set_item(aug_container, aug_index, new_item, cur_line)
					if error != "":
						done = true
						finished = true
						budget_stop = true
						break
			elif op == Op.UNPACK:
					var unpack_count := arg1[at]
					var seq = stack.pop_back()
					if not (seq is Array):
						_fail("TypeError", "只能拆解列表，得到的是 %s" % _type_name(seq), cur_line)
						done = true
						finished = true
						budget_stop = true
						break
					var unpack_list: Array = seq
					if unpack_list.size() != unpack_count:
						_fail("ValueError", "需要 %d 个值，得到 %d 个" % [unpack_count, unpack_list.size()], cur_line)
						done = true
						finished = true
						budget_stop = true
						break
					for i in unpack_count:
						stack.append(unpack_list[i])
			elif op == Op.HALT:
					finished = true
					done = true
					budget_stop = true
					break
			elif op == Op.NOP:
					pass
			else:
					_fail("RuntimeError", "未知指令 %s" % Op.name_of(op), cur_line)
					done = true
					finished = true
					budget_stop = true
					break

		if frame_changed:
			continue
		if budget_stop:
			break
		# 这一段字节码执行完了：返回上一层，调用者栈上补 None
		frame["ip"] = ip
		_frames.pop_back()
		if not _frames.is_empty():
			_frames[_frames.size() - 1]["stack"].append(null)
		else:
			done = true
			finished = true
			break
	return _result(done)


func _result(done: bool) -> Dictionary:
	# 复用字典：sub-dict 只在内容变化时重建（正常主循环里 spin/steer/thrust 基本不变）
	if _spin_dirty:
		_spin_out = {}
		for key in state["spin"]:
			_spin_out[str(key)] = float(state["spin"][key])
		_spin_dirty = false
	if _steer_dirty:
		_steer_out = {}
		for key in state["steer"]:
			_steer_out[str(key)] = float(state["steer"][key])
		_steer_dirty = false
	if _thrust_dirty:
		_thrust_out = {}
		for key in state["thrust"]:
			_thrust_out[str(key)] = float(state["thrust"][key])
		_thrust_dirty = false
	if _controls_dirty:
		_controls_out = state["controls"].duplicate()
		_controls_dirty = false
	_result_cache["ok"] = error == ""
	_result_cache["error"] = error
	if logs.is_empty():
		_result_cache["logs"] = logs
	else:
		_result_cache["logs"] = logs.duplicate()
	_result_cache["controls"] = _controls_out
	_result_cache["drive"] = float(state["drive"])
	_result_cache["spin"] = _spin_out
	_result_cache["steer"] = _steer_out
	_result_cache["thrust"] = _thrust_out
	_result_cache["done"] = done
	return _result_cache


func _fail(kind: String, message: String, line: int) -> bool:
	error = "第 %d 行 %s: %s" % [line, kind, message]
	_line = line
	return false


# ---------------------------------------------------------------- 取值语义

func _is_true(value) -> bool:
	match typeof(value):
		TYPE_NIL:
			return false
		TYPE_BOOL:
			return value
		TYPE_INT, TYPE_FLOAT:
			return float(value) != 0.0
		TYPE_STRING:
			return str(value) != ""
		TYPE_ARRAY, TYPE_DICTIONARY:
			return size_of(value) > 0
	return true


func size_of(value) -> int:
	if value is Array:
		return (value as Array).size()
	if value is Dictionary:
		return (value as Dictionary).size()
	if value is String:
		return str(value).length()
	return 0


func _type_name(value) -> String:
	match typeof(value):
		TYPE_NIL:
			return "None"
		TYPE_BOOL:
			return "bool"
		TYPE_INT:
			return "int"
		TYPE_FLOAT:
			return "float"
		TYPE_STRING:
			return "str"
		TYPE_ARRAY:
			return "list"
		TYPE_DICTIONARY:
			if value is Dictionary and (value as Dictionary).has("__type"):
				return str((value as Dictionary)["__type"])
			return "dict"
	return "object"


func _is_str(value) -> bool:
	return value is String


func _is_num(value) -> bool:
	var t := typeof(value)
	return t == TYPE_INT or t == TYPE_FLOAT


func _num(value) -> float:
	return float(value)


func _get_attr(obj, attr: String, line: int):
	if obj is Dictionary:
		var dict: Dictionary = obj
		if str(dict.get("__type", "")) == "part":
			return _part_get(dict, attr, line)
		if dict.has(attr):
			return dict[attr]
		return _fail("AttributeError", "字典里没有 %s，请用 [\"%s\"]" % [attr, attr], line)
	return _fail("AttributeError", "%s 没有属性 %s" % [_type_name(obj), attr], line)


func _set_attr(obj, attr: String, value, line: int) -> bool:
	if obj is Dictionary:
		var dict: Dictionary = obj
		if str(dict.get("__type", "")) == "part":
			return _part_set(dict, attr, value, line)
		dict[attr] = value
		return true
	return _fail("AttributeError", "%s 没有属性 %s" % [_type_name(obj), attr], line)


func _part_get(part: Dictionary, attr: String, line: int):
	var kind := str(part["kind"])
	var slot := int(part["slot"])
	var box := ""
	var known := true
	match attr:
		"speed":
			box = "thrust" if kind == "propeller" else "spin"
		"steer":
			box = "steer"
		"thrust":
			box = "thrust"
		"kind":
			return kind
		"name":
			return str(part["name"])
		_:
			known = false
	if not known:
		_fail("AttributeError", "部件没有属性 %s（可用：speed / steer / thrust）" % attr, line)
		return null
	var store: Dictionary = state[box]
	return float(store.get(slot, 0.0))


func _part_set(part: Dictionary, attr: String, value, line: int) -> bool:
	if not _is_num(value):
		return _fail("TypeError", "%s 需要数字，得到 %s" % [attr, _type_name(value)], line)
	var kind := str(part["kind"])
	var slot := int(part["slot"])
	if slot < 0:
		return true
	var box := ""
	match attr:
		"speed":
			box = "thrust" if kind == "propeller" else "spin"
		"steer":
			if kind != "wheel":
				return _fail("AttributeError", "只有轮子能设置 steer", line)
			box = "steer"
		"thrust":
			if kind != "propeller":
				return _fail("AttributeError", "只有螺旋桨能设置 thrust", line)
			box = "thrust"
		_:
			return _fail("AttributeError", "部件没有属性 %s（可用：speed / steer / thrust）" % attr, line)
	state[box][slot] = float(value)
	match box:
		"spin":
			_spin_dirty = true
		"steer":
			_steer_dirty = true
		_:
			_thrust_dirty = true
	return true


## GET_ITEM 慢路径：走完整语义检查，成功时把结果压栈并返回 true。
func _push_get_item(container, index, line: int, stack: Array) -> bool:
	var got = _get_item(container, index, line)
	if error != "":
		return false
	stack.append(got)
	return true


func _get_item(container, index, line: int):
	match typeof(container):
		TYPE_ARRAY:
			var list: Array = container
			if not (index is int):
				if index is float:
					index = int(index)
				else:
					_fail("TypeError", "列表下标必须是整数", line)
					return null
			var i := int(index)
			if i < 0:
				i += list.size()
			if i < 0 or i >= list.size():
				_fail("IndexError", "列表下标越界：%d（长度 %d）" % [int(index), list.size()], line)
				return null
			return list[i]
		TYPE_STRING:
			var text := str(container)
			var i2 := int(index) if _is_num(index) else 0
			if i2 < 0:
				i2 += text.length()
			if i2 < 0 or i2 >= text.length():
				_fail("IndexError", "字符串下标越界", line)
				return null
			return text.substr(i2, 1)
		TYPE_DICTIONARY:
			var dict: Dictionary = container
			if dict.has("__type"):
				_fail("TypeError", "不能用下标访问 %s" % _type_name(container), line)
				return null
			if not dict.has(index):
				_fail("KeyError", "字典里没有键 %s" % _to_str(index), line)
				return null
			return dict[index]
	_fail("TypeError", "%s 不能用下标访问" % _type_name(container), line)
	return null


func _set_item(container, index, value, line: int) -> bool:
	match typeof(container):
		TYPE_ARRAY:
			var list: Array = container
			var i := int(index) if _is_num(index) else -1
			if i < 0:
				i += list.size()
			if i < 0 or i >= list.size():
				return _fail("IndexError", "列表下标越界", line)
			list[i] = value
			return true
		TYPE_DICTIONARY:
			var dict: Dictionary = container
			if dict.has("__type"):
				return _fail("TypeError", "不能写入 %s" % _type_name(container), line)
			dict[index] = value
			return true
	return _fail("TypeError", "%s 不能用下标写入" % _type_name(container), line)


# ---------------------------------------------------------------- 运算

func _binop(op_name: String, left, right, line: int):
	if _is_num(left) and _is_num(right):
		return _num_op(op_name, left, right, line)
	match op_name:
		"+":
			if left is String and right is String:
				return str(left) + str(right)
			if left is Array and right is Array:
				var out: Array = (left as Array).duplicate()
				out.append_array(right)
				return out
		"*":
			if left is String and _is_num(right):
				if int(right) > MAX_REPEAT:
					_fail("MemoryError", "字符串重复次数太大", line)
					return null
				return str(left).repeat(maxi(0, int(right)))
			if _is_num(left) and right is String:
				if int(left) > MAX_REPEAT:
					_fail("MemoryError", "字符串重复次数太大", line)
					return null
				return str(right).repeat(maxi(0, int(left)))
			if left is Array and _is_num(right):
				if int(right) * (left as Array).size() > MAX_REPEAT:
					_fail("MemoryError", "列表重复后太长", line)
					return null
				var out2: Array = []
				for i in maxi(0, int(right)):
					out2.append_array(left)
				return out2
			if _is_num(left) and right is Array:
				if int(left) * (right as Array).size() > MAX_REPEAT:
					_fail("MemoryError", "列表重复后太长", line)
					return null
				var out3: Array = []
				for i in maxi(0, int(left)):
					out3.append_array(right)
				return out3
		"%":
			if left is String:
				return _format_string(str(left), right, line)
		_:
			pass
	_fail("TypeError", "不支持的运算：%s %s %s" % [_type_name(left), op_name, _type_name(right)], line)
	return null


func _num_op(op_name: String, left, right, line: int):
	var both_int := typeof(left) == TYPE_INT and typeof(right) == TYPE_INT
	var a := float(left)
	var b := float(right)
	match op_name:
		"+":
			return int(left) + int(right) if both_int else a + b
		"-":
			return int(left) - int(right) if both_int else a - b
		"*":
			return int(left) * int(right) if both_int else a * b
		"/":
			if b == 0.0:
				_fail("ZeroDivisionError", "除以零", line)
				return null
			return a / b
		"//":
			if b == 0.0:
				_fail("ZeroDivisionError", "除以零", line)
				return null
			var fl: float = floor(a / b)
			return int(fl) if both_int else fl
		"%":
			if b == 0.0:
				_fail("ZeroDivisionError", "取模的除数是零", line)
				return null
			var value: float = a - floor(a / b) * b
			return int(value) if both_int else value
		"**":
			if both_int and int(right) >= 0:
				var result := 1
				for i in int(right):
					result *= int(left)
				return result
			return pow(a, b)
	_fail("RuntimeError", "未知运算符 %s" % op_name, line)
	return null


func _unary(op_name: String, value, line: int):
	match op_name:
		"not":
			return not _is_true(value)
		"-":
			if _is_num(value):
				return -int(value) if typeof(value) == TYPE_INT else -float(value)
		"+":
			if _is_num(value):
				return value
		"~":
			if typeof(value) == TYPE_INT:
				return ~int(value)
	_fail("TypeError", "不支持的运算：%s %s" % [op_name, _type_name(value)], line)
	return null


func _compare(op_name: String, left, right, line: int):
	if op_name == "in" or op_name == "not in":
		var found := _contains(right, left)
		return found if op_name == "in" else not found
	if _is_num(left) and _is_num(right):
		var a := float(left)
		var b := float(right)
		match op_name:
			"==":
				return a == b
			"!=":
				return a != b
			"<":
				return a < b
			">":
				return a > b
			"<=":
				return a <= b
			">=":
				return a >= b
	if op_name == "==" or op_name == "!=":
		var same := false
		if typeof(left) == typeof(right):
			same = left == right
		# 列表/字典按值比较
		if left is Array and right is Array:
			same = _deep_equal(left, right)
		elif left is Dictionary and right is Dictionary:
			same = _deep_equal(left, right)
		return same if op_name == "==" else not same
	if left is String and right is String:
		match op_name:
			"<":
				return str(left) < str(right)
			">":
				return str(left) > str(right)
			"<=":
				return str(left) <= str(right)
			">=":
				return str(left) >= str(right)
	_fail("TypeError", "不能比较 %s 和 %s" % [_type_name(left), _type_name(right)], line)
	return null


func _contains(container, needle) -> bool:
	match typeof(container):
		TYPE_ARRAY:
			for item in (container as Array):
				if _deep_equal(item, needle):
					return true
			return false
		TYPE_STRING:
			return str(container).find(_to_str(needle)) >= 0
		TYPE_DICTIONARY:
			var dict: Dictionary = container
			if dict.has(needle):
				return true
			for key in dict.keys():
				if _deep_equal(key, needle):
					return true
			return false
	return false


func _deep_equal(a, b) -> bool:
	if typeof(a) != typeof(b):
		if _is_num(a) and _is_num(b):
			return float(a) == float(b)
		return false
	if a is Array and b is Array:
		if (a as Array).size() != (b as Array).size():
			return false
		for i in (a as Array).size():
			if not _deep_equal((a as Array)[i], (b as Array)[i]):
				return false
		return true
	if a is Dictionary and b is Dictionary:
		var da: Dictionary = a
		var db: Dictionary = b
		if da.size() != db.size():
			return false
		for key in da.keys():
			if not db.has(key):
				return false
			if not _deep_equal(da[key], db[key]):
				return false
		return true
	return a == b


# ---------------------------------------------------------------- 调用

func _call(callable, args: Array, line: int) -> bool:
	if not (callable is Dictionary):
		return _fail("TypeError", "%s 不能被调用" % _type_name(callable), line)
	var kind := str((callable as Dictionary).get("__type", ""))
	if kind == "builtin":
		return _call_builtin(str(callable["name"]), args, line)
	if kind == "func":
		var index := int(callable["idx"])
		if index < 0 or index >= _funcs.size():
			return _fail("RuntimeError", "内部错误：函数索引越界", line)
		var chunk: Dictionary = _funcs[index]
		var params: Array = chunk["params"]
		var defaults: Array = chunk["defaults"]
		if args.size() > params.size():
			return _fail("TypeError", "%s() 最多接受 %d 个参数，给了 %d 个" % [str(chunk["name"]), params.size(), args.size()], line)
		var locals := {}
		for i in params.size():
			if i < args.size():
				locals[params[i]] = args[i]
			elif i < defaults.size():
				locals[params[i]] = defaults[i]
			else:
				return _fail("TypeError", "%s() 缺少参数 %s" % [str(chunk["name"]), str(params[i])], line)
		var frame := _new_frame(chunk)
		frame["locals"] = locals
		_frames.append(frame)
		return true
	return _fail("TypeError", "这个值不能被调用", line)


func _call_builtin(name: String, args: Array, line: int) -> bool:
	var stack: Array = _frames[_frames.size() - 1]["stack"]
	match name:
		"print":
			var parts: Array = []
			for arg in args:
				parts.append(_to_str(arg))
			logs.append(" ".join(parts))
			stack.append(null)
			return true
		"set_drive":
			if args.size() != 1 or not _is_num(args[0]):
				return _fail("TypeError", "set_drive(数值)", line)
			state["drive"] = float(args[0])
			stack.append(null)
			return true
		"set_spin":
			if args.size() != 2 or not _is_num(args[1]):
				return _fail("TypeError", "set_spin(序号, 弧度每秒)", line)
			state["spin"][int(args[0])] = float(args[1])
			_spin_dirty = true
			stack.append(null)
			return true
		"set_steer":
			if args.size() != 2 or not _is_num(args[1]):
				return _fail("TypeError", "set_steer(序号, 角度)", line)
			state["steer"][int(args[0])] = float(args[1])
			_steer_dirty = true
			stack.append(null)
			return true
		"set_thrust":
			if args.size() != 2 or not _is_num(args[1]):
				return _fail("TypeError", "set_thrust(序号, 牛顿)", line)
			state["thrust"][int(args[0])] = float(args[1])
			_thrust_dirty = true
			stack.append(null)
			return true
		"set_lift":
			if args.size() != 1 or not _is_num(args[0]):
				return _fail("TypeError", "set_lift(0~1 的升力)", line)
			state["controls"]["lift"] = clampf(float(args[0]), 0.0, 1.0)
			_controls_dirty = true
			stack.append(null)
			return true
		"set_tilt":
			if args.size() != 2 or not _is_num(args[0]) or not _is_num(args[1]):
				return _fail("TypeError", "set_tilt(前后倾, 左右倾) 各 -1~1", line)
			state["controls"]["pitch"] = clampf(float(args[0]), -1.0, 1.0)
			_controls_dirty = true
			state["controls"]["roll"] = clampf(float(args[1]), -1.0, 1.0)
			_controls_dirty = true
			stack.append(null)
			return true
		"set_rcs":
			if args.size() != 2 or not _is_num(args[0]) or not _is_num(args[1]):
				return _fail("TypeError", "set_rcs(转向, 前后) 各 -1~1", line)
			state["controls"]["turn"] = clampf(float(args[0]), -1.0, 1.0)
			_controls_dirty = true
			state["controls"]["forward"] = clampf(float(args[1]), -1.0, 1.0)
			_controls_dirty = true
			stack.append(null)
			return true
		"drill":
			if args.size() > 1:
				return _fail("TypeError", "drill(开关) 只接受 0 或 1 个参数", line)
			var on := true
			if args.size() == 1:
				on = _is_true(args[0])
			state["controls"]["drill"] = on
			_controls_dirty = true
			stack.append(null)
			return true
		"laser":
			if args.size() != 3 or not _is_num(args[0]) or not _is_num(args[1]) or not _is_num(args[2]):
				return _fail("TypeError", "laser(x, y, z)：朝这个方块坐标打激光", line)
			state["controls"]["laser"] = true
			_controls_dirty = true
			state["controls"]["laser_x"] = float(args[0])
			_controls_dirty = true
			state["controls"]["laser_y"] = float(args[1])
			_controls_dirty = true
			state["controls"]["laser_z"] = float(args[2])
			_controls_dirty = true
			stack.append(null)
			return true
		"laser_off":
			if args.size() != 0:
				return _fail("TypeError", "laser_off() 不接受参数", line)
			state["controls"]["laser"] = false
			_controls_dirty = true
			stack.append(null)
			return true
		"shoot":
			if args.size() != 3 or not _is_num(args[0]) or not _is_num(args[1]) or not _is_num(args[2]):
				return _fail("TypeError", "shoot(x, y, z)：朝这个方块坐标开炮", line)
			state["controls"]["shoot"] = true
			_controls_dirty = true
			state["controls"]["shoot_x"] = float(args[0])
			_controls_dirty = true
			state["controls"]["shoot_y"] = float(args[1])
			_controls_dirty = true
			state["controls"]["shoot_z"] = float(args[2])
			_controls_dirty = true
			stack.append(null)
			return true
		"go_to":
			if args.size() != 3 or not _is_num(args[0]) or not _is_num(args[1]) or not _is_num(args[2]):
				return _fail("TypeError", "go_to(x, y, z)：自动寻路飞到这个坐标", line)
			state["controls"]["go"] = true
			_controls_dirty = true
			state["controls"]["go_x"] = float(args[0])
			_controls_dirty = true
			state["controls"]["go_y"] = float(args[1])
			_controls_dirty = true
			state["controls"]["go_z"] = float(args[2])
			_controls_dirty = true
			stack.append(null)
			return true
		"stop":
			if args.size() != 0:
				return _fail("TypeError", "stop() 不接受参数", line)
			state["controls"]["go"] = false
			_controls_dirty = true
			stack.append(null)
			return true
		"set_velocity":
			if args.size() != 2 or not _is_num(args[0]) or not _is_num(args[1]):
				return _fail("TypeError", "set_velocity(水平x速度, 水平z速度)：米/秒", line)
			state["controls"]["vel_mode"] = true
			_controls_dirty = true
			state["controls"]["vx"] = float(args[0])
			_controls_dirty = true
			state["controls"]["vz"] = float(args[1])
			_controls_dirty = true
			stack.append(null)
			return true
		"set_altitude":
			if args.size() != 1 or not _is_num(args[0]):
				return _fail("TypeError", "set_altitude(y)：想稳定的世界高度", line)
			state["controls"]["alt_mode"] = true
			_controls_dirty = true
			state["controls"]["alt_target"] = float(args[0])
			_controls_dirty = true
			stack.append(null)
			return true
		"build":
			if args.size() != 4 or not _is_str(args[0]) or not _is_num(args[1]) or not _is_num(args[2]) or not _is_num(args[3]):
				return _fail("TypeError", "build(id, x, y, z)：在指定格子盖一栋建筑", line)
			var err := ""
			if build_provider.is_valid():
				err = str(build_provider.call(str(args[0]), Vector3i(int(args[1]), int(args[2]), int(args[3]))))
			stack.append(err)
			return true
		"build_here":
			if args.size() != 1 or not _is_str(args[0]):
				return _fail("TypeError", "build_here(id)：在自己旁边找块平地把建筑盖起来", line)
			var err2 := ""
			if build_here_provider.is_valid():
				err2 = str(build_here_provider.call(str(args[0])))
			stack.append(err2)
			return true
		"transfer":
			if args.size() != 1:
				return _fail("TypeError", "transfer(开/关)：开启后把电输送给附近友军", line)
			var flag = args[0]
			var on := false
			if flag is bool:
				on = flag
			elif _is_num(flag):
				on = float(flag) != 0.0
			state["controls"]["transfer"] = on
			_controls_dirty = true
			stack.append(null)
			return true
		"produce":
			if args.size() != 1 or not _is_str(args[0]):
				return _fail("TypeError", "produce(单位id)：让附近自己的厂房改生产这种单位", line)
			var produce_err := ""
			if produce_provider.is_valid():
				produce_err = str(produce_provider.call(str(args[0])))
			stack.append(produce_err)
			return true
		"block_at":
			if args.size() != 3 or not _is_num(args[0]) or not _is_num(args[1]) or not _is_num(args[2]):
				return _fail("TypeError", "block_at(x, y, z)：查这个格子是什么方块（需要自家的全景雷达在线）", line)
			var block_name := ""
			if block_at_provider.is_valid():
				block_name = str(block_at_provider.call(int(args[0]), int(args[1]), int(args[2])))
			stack.append(block_name)
			return true
		"command":
			if args.size() < 2 or not _is_num(args[0]) or not _is_str(args[1]):
				return _fail("TypeError", "command(uid, 动作, x, y, z)：给某个队友下指令，动作是 goto / attack / hold", line)
			var cx := 0.0
			var cy := 0.0
			var cz := 0.0
			if args.size() >= 5:
				cx = float(args[2])
				cy = float(args[3])
				cz = float(args[4])
			var cmd_err := ""
			if command_provider.is_valid():
				cmd_err = str(command_provider.call(int(args[0]), str(args[1]), cx, cy, cz))
			stack.append(cmd_err)
			return true
		"team_set":
			if args.size() != 2 or not _is_str(args[0]):
				return _fail("TypeError", "team_set(名字, 值)：往全队共享的黑板写一个值（值只能是数字/文字/真假）", line)
			var tv = args[1]
			if not (tv is float or tv is int or tv is String or tv is bool):
				return _fail("TypeError", "team_set(名字, 值)：值只能是数字、文字或真/假", line)
			if team_set_provider.is_valid():
				team_set_provider.call(str(args[0]), tv)
			stack.append(null)
			return true
		"team_get":
			if args.size() < 1 or not _is_str(args[0]):
				return _fail("TypeError", "team_get(名字, 默认值)：读全队共享黑板上的值", line)
			var fallback = args[1] if args.size() > 1 else 0.0
			var got = fallback
			if team_get_provider.is_valid():
				got = team_get_provider.call(str(args[0]), fallback)
			stack.append(got)
			return true
		"mark":
			if args.size() < 3 or not _is_num(args[0]) or not _is_num(args[1]) or not _is_num(args[2]):
				return _fail("TypeError", "mark(x, y, z, 标签)：给全队标一个点，别人在 marks 里能看到", line)
			var tag := ""
			if args.size() > 3 and args[3] is String:
				tag = str(args[3])
			if mark_provider.is_valid():
				mark_provider.call(float(args[0]), float(args[1]), float(args[2]), tag)
			stack.append(null)
			return true
		"place":
			if args.size() != 4 or not _is_str(args[0]) or not _is_num(args[1]) or not _is_num(args[2]) or not _is_num(args[3]):
				return _fail("TypeError", "place(方块名, x, y, z)：在指定格子放一块方块", line)
			var place_err := ""
			if place_provider.is_valid():
				place_err = str(place_provider.call(str(args[0]), Vector3i(int(args[1]), int(args[2]), int(args[3]))))
			stack.append(place_err)
			return true
		"find_path":
			if args.size() != 3 or not _is_num(args[0]) or not _is_num(args[1]) or not _is_num(args[2]):
				return _fail("TypeError", "find_path(x, y, z)：算出到这个世界坐标的航路", line)
			var waypoints: Array = []
			if path_provider.is_valid():
				var pts: Array = path_provider.call(Vector3(float(args[0]), float(args[1]), float(args[2])))
				for point in pts:
					waypoints.append({"x": float(point.x), "y": float(point.y), "z": float(point.z)})
			stack.append(waypoints)
			return true
		"get_link":
			if args.size() != 1 or not _is_num(args[0]):
				return _fail("TypeError", "get_link(序号) 从 1 开始", line)
			var index := int(args[0]) - 1
			if index < 0 or index >= _parts.size():
				stack.append(null)
				return true
			stack.append(_parts[index])
			return true
		"range":
			var start := 0
			var stop := 0
			var stepn := 1
			if args.size() == 1 and _is_num(args[0]):
				stop = int(args[0])
			elif args.size() >= 2 and _is_num(args[0]) and _is_num(args[1]):
				start = int(args[0])
				stop = int(args[1])
				if args.size() >= 3:
					if not _is_num(args[2]):
						return _fail("TypeError", "range 的步长必须是整数", line)
					stepn = int(args[2])
			else:
				return _fail("TypeError", "range(终点) 或 range(起点, 终点[, 步长])", line)
			if stepn == 0:
				return _fail("ValueError", "range 的步长不能是 0", line)
			stack.append({"__type": "range", "start": start, "stop": stop, "step": stepn})
			return true
		"len":
			if args.size() != 1:
				return _fail("TypeError", "len(值)", line)
			var value = args[0]
			if _is_num(value) or value == null or value is bool:
				return _fail("TypeError", "%s 没有长度" % _type_name(value), line)
			stack.append(size_of(value))
			return true
		"abs":
			if args.size() != 1 or not _is_num(args[0]):
				return _fail("TypeError", "abs(数值)", line)
			stack.append(abs(int(args[0])) if typeof(args[0]) == TYPE_INT else absf(float(args[0])))
			return true
		"min", "max":
			var values: Array = []
			if args.size() == 1 and args[0] is Array:
				values = args[0]
			else:
				values = args
			if values.is_empty():
				return _fail("ValueError", "%s() 需要至少一个值" % name, line)
			var best = values[0]
			for i in range(1, values.size()):
				var candidate = values[i]
				var better := false
				if _is_num(best) and _is_num(candidate):
					better = float(candidate) < float(best) if name == "min" else float(candidate) > float(best)
				elif best is String and candidate is String:
					better = str(candidate) < str(best) if name == "min" else str(candidate) > str(best)
				else:
					return _fail("TypeError", "%s() 的参数类型不一致" % name, line)
				if better:
					best = candidate
			stack.append(best)
			return true
		"int":
			if args.size() != 1:
				return _fail("TypeError", "int(值)", line)
			var v = args[0]
			if v is bool:
				stack.append(1 if v else 0)
				return true
			if _is_num(v):
				stack.append(int(v))
				return true
			if v is String:
				var text := str(v).strip_edges()
				if text.is_valid_int():
					stack.append(int(text))
					return true
				if text.is_valid_float():
					stack.append(int(float(text)))
					return true
			return _fail("ValueError", "不能把 %s 转成整数" % _to_str(v), line)
		"float":
			if args.size() != 1:
				return _fail("TypeError", "float(值)", line)
			var v2 = args[0]
			if _is_num(v2):
				stack.append(float(v2))
				return true
			if v2 is String and str(v2).strip_edges().is_valid_float():
				stack.append(float(str(v2).strip_edges()))
				return true
			return _fail("ValueError", "不能把 %s 转成小数" % _to_str(v2), line)
		"str":
			if args.size() != 1:
				return _fail("TypeError", "str(值)", line)
			stack.append(_to_str(args[0]))
			return true
		"bool":
			if args.size() != 1:
				return _fail("TypeError", "bool(值)", line)
			stack.append(_is_true(args[0]))
			return true
		"round":
			if args.is_empty() or args.size() > 2:
				return _fail("TypeError", "round(数值[, 位数])", line)
			if not _is_num(args[0]):
				return _fail("TypeError", "round() 的第一个参数必须是数字", line)
			if args.size() == 1:
				stack.append(int(roundf(float(args[0]))))
			else:
				var digits := int(args[1])
				var factor := pow(10.0, digits)
				if digits <= 0:
					stack.append(int(roundf(float(args[0]) / factor) * factor))
				else:
					stack.append(roundf(float(args[0]) * factor) / factor)
			return true
	return _fail("NameError", "未知内置函数 %s" % name, line)


# ---------------------------------------------------------------- 字符串

func _to_str(value) -> String:
	match typeof(value):
		TYPE_NIL:
			return "None"
		TYPE_BOOL:
			return "True" if value else "False"
		TYPE_INT:
			return str(int(value))
		TYPE_FLOAT:
			var f := float(value)
			if is_finite(f) and f == floor(f) and absf(f) < 1e16:
				return "%d.0" % int(f)
			return str(f)
		TYPE_STRING:
			return str(value)
		TYPE_ARRAY:
			var parts: Array = []
			for item in (value as Array):
				parts.append(_repr(item))
			return "[" + ", ".join(parts) + "]"
		TYPE_DICTIONARY:
			var dict: Dictionary = value
			if dict.has("__type"):
				var kind := str(dict["__type"])
				if kind == "part":
					return "<部件 %s>" % str(dict.get("name", ""))
				if kind == "range":
					return "<range>"
				if kind == "func":
					return "<函数>"
				if kind == "builtin":
					return "<内置函数 %s>" % str(dict["name"])
				if kind == "iter":
					return "<迭代器>"
			var pieces: Array = []
			for key in dict.keys():
				pieces.append("%s: %s" % [_repr(key), _repr(dict[key])])
			return "{" + ", ".join(pieces) + "}"
	return "<对象>"


func _repr(value) -> String:
	if value is String:
		return "'" + str(value) + "'"
	return _to_str(value)


func _format_string(template: String, value, line: int) -> String:
	if value is Array:
		var args: Array = value
		var out := ""
		var index := 0
		var i := 0
		while i < template.length():
			var ch := template.substr(i, 1)
			if ch == "%" and i + 1 < template.length():
				var spec := template.substr(i + 1, 1)
				if spec == "%":
					out += "%"
					i += 2
					continue
				if spec == "d" or spec == "s" or spec == "f":
					if index >= args.size():
						_fail("TypeError", "% 格式化的参数不够", line)
						return out
					out += _to_str(args[index])
					index += 1
					i += 2
					continue
				_fail("TypeError", "不支持的格式化符号 %%%s" % spec, line)
				return out
			out += ch
			i += 1
		return out
	return _to_str(value)


# ---------------------------------------------------------------- 迭代器

func _make_iter(iterable, line: int):
	match typeof(iterable):
		TYPE_ARRAY:
			return {"__type": "iter", "kind": "list", "seq": iterable, "i": 0}
		TYPE_STRING:
			return {"__type": "iter", "kind": "str", "seq": str(iterable), "i": 0}
		TYPE_DICTIONARY:
			var dict: Dictionary = iterable
			var kind := str(dict.get("__type", ""))
			if kind == "range":
				return {"__type": "iter", "kind": "range", "cur": int(dict["start"]), "stop": int(dict["stop"]), "step": int(dict["step"])}
			if kind == "":
				return {"__type": "iter", "kind": "dict", "seq": dict.keys(), "i": 0}
	_fail("TypeError", "%s 不能用来 for 循环" % _type_name(iterable), line)
	return null


func _step_iter(iterator: Dictionary, stack: Array) -> bool:
	var kind := str(iterator.get("kind", ""))
	if kind == "range":
		var cur := int(iterator["cur"])
		var stop := int(iterator["stop"])
		var stepn := int(iterator["step"])
		if (stepn > 0 and cur >= stop) or (stepn < 0 and cur <= stop):
			return false
		stack.append(cur)
		iterator["cur"] = cur + stepn
		return true
	var seq: Array = iterator["seq"]
	var i := int(iterator["i"])
	if seq.is_empty() or i >= seq.size():
		return false
	stack.append(seq[i])
	iterator["i"] = i + 1
	return true
