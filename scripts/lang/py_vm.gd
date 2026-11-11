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
	"build", "build_here", "place",
	"range", "len", "abs", "min", "max", "int", "float", "str", "round", "bool",
]

const DEFAULT_CONTROLS := {
	"lift": 0.0, "pitch": 0.0, "roll": 0.0, "turn": 0.0, "forward": 0.0, "drill": false,
	"laser": false, "laser_x": 0.0, "laser_y": 0.0, "laser_z": 0.0,
	"shoot": false, "shoot_x": 0.0, "shoot_y": 0.0, "shoot_z": 0.0,
	"go": false, "go_x": 0.0, "go_y": 0.0, "go_z": 0.0,
	"vel_mode": false, "vx": 0.0, "vz": 0.0,
	"alt_mode": false, "alt_target": 0.0,
}

var globals: Dictionary = {}
var state: Dictionary = {"drive": 0.0, "spin": {}, "steer": {}, "thrust": {}, "mem": {}, "controls": DEFAULT_CONTROLS.duplicate()}
## 由控制器塞进来：给 find_path(x,y,z) 用，返回 Array[Vector3]
var path_provider: Callable = Callable()
## 建筑：build(id, x, y, z) 与 build_here(id)，返回错误字符串（空串表示成功）
var build_provider: Callable = Callable()
var build_here_provider: Callable = Callable()
var place_provider: Callable = Callable()
var logs: Array = []
var error := ""
var finished := false

var _chunks: Array = []
var _funcs: Array = []
var _main: Dictionary = {}
var _frames: Array = []
var _parts: Array = []
var _line := 0
var _lines_left := 1
var _ops_left := 20000
var _injected: Array = []


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
	_frames = []
	_frames.append(_new_frame(_main))


func _reset_runtime() -> void:
	globals = {"mem": state["mem"], "PI": PI, "E": 2.718281828459045}
	state = {"drive": 0.0, "spin": {}, "steer": {}, "thrust": {}, "mem": state.get("mem", {}), "controls": DEFAULT_CONTROLS.duplicate()}
	_apply_part_names()
	logs = []
	error = ""
	finished = false
	_frames = []
	_injected = []
	_line = 0


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
	for i in _funcs.size():
		if str(_funcs[i].get("name", "")) == fname:
			return i
	return -1


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
	_injected = []
	_apply_part_names()


func _apply_part_names() -> void:
	for part in _parts:
		if str(part["name"]) != "":
			globals[str(part["name"])] = part


func inject(readings: Dictionary) -> void:
	for key in _injected:
		if key != "mem":
			globals.erase(key)
	_injected = []
	for key in readings.keys():
		var name := str(key)
		if name == "mem":
			continue
		globals[name] = readings[key]
		_injected.append(name)


## 跑一步：最多 max_lines 条语句。返回本帧结果。
func step(max_lines: int = 1, max_ops: int = 20000) -> Dictionary:
	logs = []
	error = ""
	var done := false
	if finished:
		return _result(true)
	_lines_left = maxi(1, max_lines)
	_ops_left = max_ops
	while true:
		if _frames.is_empty():
			done = true
			finished = true
			break
		var frame: Dictionary = _frames[_frames.size() - 1]
		var chunk: Dictionary = frame["chunk"]
		var code: Array = chunk["code"]
		var ip := int(frame["ip"])
		if ip >= code.size():
			_frames.pop_back()
			if not _frames.is_empty():
				_frames[_frames.size() - 1]["stack"].append(null)
				continue
			done = true
			finished = true
			break
		var ins: Dictionary = code[ip]
		var op := int(ins["op"])
		if op == Op.LINE:
			if _lines_left <= 0:
				break
			_lines_left -= 1
			_line = int(ins.get("line", 0))
		_ops_left -= 1
		if _ops_left <= 0:
			_fail("RuntimeError", "代码跑得太久（死循环？）", op, ins)
			done = true
			finished = true
			break
		frame["ip"] = ip + 1
		if not _exec(op, ins, frame):
			done = true
			finished = true
			break
	return _result(done)


func _result(done: bool) -> Dictionary:
	var spin := {}
	for key in state["spin"].keys():
		spin[str(key)] = float(state["spin"][key])
	var steer := {}
	for key in state["steer"].keys():
		steer[str(key)] = float(state["steer"][key])
	var thrust := {}
	for key in state["thrust"].keys():
		thrust[str(key)] = float(state["thrust"][key])
	return {
		"ok": error == "",
		"error": error,
		"logs": logs.duplicate(),
		"controls": state["controls"].duplicate(),
		"drive": float(state["drive"]),
		"spin": spin,
		"steer": steer,
		"thrust": thrust,
		"done": done,
	}


# ---------------------------------------------------------------- 指令执行

func _exec(op: int, ins: Dictionary, frame: Dictionary) -> bool:
	var stack: Array = frame["stack"]
	match op:
		Op.CONST:
			var consts: Array = frame["chunk"]["consts"]
			stack.append(consts[int(ins["a"])])
			return true
		Op.LOAD:
			var name := str(ins["a"])
			var locals: Dictionary = frame["locals"]
			if locals.has(name):
				stack.append(locals[name])
				return true
			if globals.has(name):
				stack.append(globals[name])
				return true
			if BUILTINS.has(name):
				stack.append({"__type": "builtin", "name": name})
				return true
			if name == "buffer":
				# 保留名字，避免玩家代码意外覆盖
				return _fail("NameError", "名字未定义：%s" % name, op, ins)
			return _fail("NameError", "名字未定义：%s" % name, op, ins)
		Op.STORE:
			var target := str(ins["a"])
			var value = _pop(stack)
			if bool(frame["chunk"].get("is_func", false)):
				frame["locals"][target] = value
			else:
				globals[target] = value
			return true
		Op.LOAD_ATTR:
			var obj = _pop(stack)
			stack.append(_get_attr(obj, str(ins["a"]), op, ins))
			return error == ""
		Op.STORE_ATTR:
			var target_obj = _pop(stack)
			var target_value = _pop(stack)
			_set_attr(target_obj, str(ins["a"]), target_value, op, ins)
			return error == ""
		Op.GET_ITEM:
			var index = _pop(stack)
			var container = _pop(stack)
			stack.append(_get_item(container, index, op, ins))
			return error == ""
		Op.SET_ITEM:
			# 栈顺序（由编译器产生）：[值, 容器, 下标]
			var item_index = _pop(stack)
			var item_obj = _pop(stack)
			var item_value = _pop(stack)
			_set_item(item_obj, item_index, item_value, op, ins)
			return error == ""
		Op.CALL:
			var argc := int(ins["a"])
			var args: Array = []
			for i in argc:
				args.append(_pop(stack))
			args.reverse()
			var callable = _pop(stack)
			return _call(callable, args, op, ins)
		Op.BIN:
			var right = _pop(stack)
			var left = _pop(stack)
			stack.append(_binop(str(ins["a"]), left, right, op, ins))
			return error == ""
		Op.UNARY:
			var operand = _pop(stack)
			stack.append(_unary(str(ins["a"]), operand, op, ins))
			return error == ""
		Op.CMP:
			var cmp_right = _pop(stack)
			var cmp_left = _pop(stack)
			stack.append(_compare(str(ins["a"]), cmp_left, cmp_right, op, ins))
			return error == ""
		Op.JUMP:
			frame["ip"] = int(ins["a"])
			return true
		Op.JF:
			if not _is_true(_pop(stack)):
				frame["ip"] = int(ins["a"])
			return true
		Op.JT:
			if _is_true(_pop(stack)):
				frame["ip"] = int(ins["a"])
			return true
		Op.DUP:
			if stack.is_empty():
				return _fail("RuntimeError", "内部错误：栈为空", op, ins)
			stack.append(stack[stack.size() - 1])
			return true
		Op.POP:
			_pop(stack)
			return true
		Op.LINE:
			return true
		Op.RETURN:
			var result = _pop(stack)
			_frames.pop_back()
			if _frames.is_empty():
				finished = true
			else:
				_frames[_frames.size() - 1]["stack"].append(result)
			return true
		Op.FUNC:
			stack.append({"__type": "func", "idx": int(ins["a"])})
			return true
		Op.ITER:
			var iterable = _pop(stack)
			var it = _make_iter(iterable, op, ins)
			if it == null:
				return false
			stack.append(it)
			return true
		Op.FOR_NEXT:
			if stack.is_empty():
				return _fail("RuntimeError", "内部错误：缺少迭代器", op, ins)
			var iterator: Dictionary = stack[stack.size() - 1]
			var has_next := _step_iter(iterator)
			if not has_next:
				stack.pop_back()
				frame["ip"] = int(ins["a"])
			return true
		Op.BUILD_LIST:
			var count := int(ins["a"])
			var items: Array = []
			for i in count:
				items.append(_pop(stack))
			items.reverse()
			stack.append(items)
			return true
		Op.BUILD_DICT:
			var pairs := int(ins["a"])
			var dict := {}
			for i in pairs:
				var value = _pop(stack)
				var key = _pop(stack)
				dict[key] = value
			stack.append(dict)
			return true
		Op.AUG_ATTR:
			var aug_value = _pop(stack)
			var aug_obj = _pop(stack)
			var current = _get_attr(aug_obj, str(ins["a"]), op, ins)
			if error != "":
				return false
			var updated = _binop(str(ins["b"]), current, aug_value, op, ins)
			if error != "":
				return false
			_set_attr(aug_obj, str(ins["a"]), updated, op, ins)
			return error == ""
		Op.AUG_ITEM:
			var aug_item_value = _pop(stack)
			var aug_index = _pop(stack)
			var aug_container = _pop(stack)
			var current_item = _get_item(aug_container, aug_index, op, ins)
			if error != "":
				return false
			var new_item = _binop(str(ins["a"]), current_item, aug_item_value, op, ins)
			if error != "":
				return false
			_set_item(aug_container, aug_index, new_item, op, ins)
			return error == ""
		Op.UNPACK:
			var count := int(ins["a"])
			var seq = _pop(stack)
			if not (seq is Array):
				return _fail("TypeError", "只能拆解列表，得到的是 %s" % _type_name(seq), op, ins)
			var list: Array = seq
			if list.size() != count:
				return _fail("ValueError", "需要 %d 个值，得到 %d 个" % [count, list.size()], op, ins)
			for i in count:
				stack.append(list[i])
			return true
		Op.HALT:
			finished = true
			return false
		Op.NOP:
			return true
	return _fail("RuntimeError", "未知指令 %s" % Op.name_of(op), op, ins)


func _pop(stack: Array):
	if stack.is_empty():
		return null
	return stack.pop_back()


func _fail(kind: String, message: String, op: int, ins: Dictionary) -> bool:
	var line := int(ins.get("line", _line))
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


func _get_attr(obj, attr: String, op: int, ins: Dictionary):
	if obj is Dictionary:
		var dict: Dictionary = obj
		if str(dict.get("__type", "")) == "part":
			return _part_get(dict, attr, op, ins)
		if dict.has(attr):
			return dict[attr]
		return _fail("AttributeError", "字典里没有 %s，请用 [\"%s\"]" % [attr, attr], op, ins)
	return _fail("AttributeError", "%s 没有属性 %s" % [_type_name(obj), attr], op, ins)


func _set_attr(obj, attr: String, value, op: int, ins: Dictionary) -> bool:
	if obj is Dictionary:
		var dict: Dictionary = obj
		if str(dict.get("__type", "")) == "part":
			return _part_set(dict, attr, value, op, ins)
		dict[attr] = value
		return true
	return _fail("AttributeError", "%s 没有属性 %s" % [_type_name(obj), attr], op, ins)


func _part_get(part: Dictionary, attr: String, op: int, ins: Dictionary):
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
		_fail("AttributeError", "部件没有属性 %s（可用：speed / steer / thrust）" % attr, op, ins)
		return null
	var store: Dictionary = state[box]
	return float(store.get(slot, 0.0))


func _part_set(part: Dictionary, attr: String, value, op: int, ins: Dictionary) -> bool:
	if not _is_num(value):
		return _fail("TypeError", "%s 需要数字，得到 %s" % [attr, _type_name(value)], op, ins)
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
				return _fail("AttributeError", "只有轮子能设置 steer", op, ins)
			box = "steer"
		"thrust":
			if kind != "propeller":
				return _fail("AttributeError", "只有螺旋桨能设置 thrust", op, ins)
			box = "thrust"
		_:
			return _fail("AttributeError", "部件没有属性 %s（可用：speed / steer / thrust）" % attr, op, ins)
	state[box][slot] = float(value)
	return true


func _get_item(container, index, op: int, ins: Dictionary):
	match typeof(container):
		TYPE_ARRAY:
			var list: Array = container
			if not (index is int):
				if index is float:
					index = int(index)
				else:
					_fail("TypeError", "列表下标必须是整数", op, ins)
					return null
			var i := int(index)
			if i < 0:
				i += list.size()
			if i < 0 or i >= list.size():
				_fail("IndexError", "列表下标越界：%d（长度 %d）" % [int(index), list.size()], op, ins)
				return null
			return list[i]
		TYPE_STRING:
			var text := str(container)
			var i2 := int(index) if _is_num(index) else 0
			if i2 < 0:
				i2 += text.length()
			if i2 < 0 or i2 >= text.length():
				_fail("IndexError", "字符串下标越界", op, ins)
				return null
			return text.substr(i2, 1)
		TYPE_DICTIONARY:
			var dict: Dictionary = container
			if dict.has("__type"):
				_fail("TypeError", "不能用下标访问 %s" % _type_name(container), op, ins)
				return null
			if not dict.has(index):
				_fail("KeyError", "字典里没有键 %s" % _to_str(index), op, ins)
				return null
			return dict[index]
	_fail("TypeError", "%s 不能用下标访问" % _type_name(container), op, ins)
	return null


func _set_item(container, index, value, op: int, ins: Dictionary) -> bool:
	match typeof(container):
		TYPE_ARRAY:
			var list: Array = container
			var i := int(index) if _is_num(index) else -1
			if i < 0:
				i += list.size()
			if i < 0 or i >= list.size():
				return _fail("IndexError", "列表下标越界", op, ins)
			list[i] = value
			return true
		TYPE_DICTIONARY:
			var dict: Dictionary = container
			if dict.has("__type"):
				return _fail("TypeError", "不能写入 %s" % _type_name(container), op, ins)
			dict[index] = value
			return true
	return _fail("TypeError", "%s 不能用下标写入" % _type_name(container), op, ins)


# ---------------------------------------------------------------- 运算

func _binop(op_name: String, left, right, op: int, ins: Dictionary):
	if _is_num(left) and _is_num(right):
		return _num_op(op_name, left, right, op, ins)
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
					_fail("MemoryError", "字符串重复次数太大", op, ins)
					return null
				return str(left).repeat(maxi(0, int(right)))
			if _is_num(left) and right is String:
				if int(left) > MAX_REPEAT:
					_fail("MemoryError", "字符串重复次数太大", op, ins)
					return null
				return str(right).repeat(maxi(0, int(left)))
			if left is Array and _is_num(right):
				if int(right) * (left as Array).size() > MAX_REPEAT:
					_fail("MemoryError", "列表重复后太长", op, ins)
					return null
				var out2: Array = []
				for i in maxi(0, int(right)):
					out2.append_array(left)
				return out2
			if _is_num(left) and right is Array:
				if int(left) * (right as Array).size() > MAX_REPEAT:
					_fail("MemoryError", "列表重复后太长", op, ins)
					return null
				var out3: Array = []
				for i in maxi(0, int(left)):
					out3.append_array(right)
				return out3
		"%":
			if left is String:
				return _format_string(str(left), right, op, ins)
		_:
			pass
	_fail("TypeError", "不支持的运算：%s %s %s" % [_type_name(left), op_name, _type_name(right)], op, ins)
	return null


func _num_op(op_name: String, left, right, op: int, ins: Dictionary):
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
				_fail("ZeroDivisionError", "除以零", op, ins)
				return null
			return a / b
		"//":
			if b == 0.0:
				_fail("ZeroDivisionError", "除以零", op, ins)
				return null
			var fl: float = floor(a / b)
			return int(fl) if both_int else fl
		"%":
			if b == 0.0:
				_fail("ZeroDivisionError", "取模的除数是零", op, ins)
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
	_fail("RuntimeError", "未知运算符 %s" % op_name, op, ins)
	return null


func _unary(op_name: String, value, op: int, ins: Dictionary):
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
	_fail("TypeError", "不支持的运算：%s %s" % [op_name, _type_name(value)], op, ins)
	return null


func _compare(op_name: String, left, right, op: int, ins: Dictionary):
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
	_fail("TypeError", "不能比较 %s 和 %s" % [_type_name(left), _type_name(right)], op, ins)
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

func _call(callable, args: Array, op: int, ins: Dictionary) -> bool:
	if not (callable is Dictionary):
		return _fail("TypeError", "%s 不能被调用" % _type_name(callable), op, ins)
	var kind := str((callable as Dictionary).get("__type", ""))
	if kind == "builtin":
		return _call_builtin(str(callable["name"]), args, op, ins)
	if kind == "func":
		var index := int(callable["idx"])
		if index < 0 or index >= _funcs.size():
			return _fail("RuntimeError", "内部错误：函数索引越界", op, ins)
		var chunk: Dictionary = _funcs[index]
		var params: Array = chunk["params"]
		var defaults: Array = chunk["defaults"]
		if args.size() > params.size():
			return _fail("TypeError", "%s() 最多接受 %d 个参数，给了 %d 个" % [str(chunk["name"]), params.size(), args.size()], op, ins)
		var locals := {}
		for i in params.size():
			if i < args.size():
				locals[params[i]] = args[i]
			elif i < defaults.size():
				locals[params[i]] = defaults[i]
			else:
				return _fail("TypeError", "%s() 缺少参数 %s" % [str(chunk["name"]), str(params[i])], op, ins)
		var frame := _new_frame(chunk)
		frame["locals"] = locals
		_frames.append(frame)
		return true
	return _fail("TypeError", "这个值不能被调用", op, ins)


func _call_builtin(name: String, args: Array, op: int, ins: Dictionary) -> bool:
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
				return _fail("TypeError", "set_drive(数值)", op, ins)
			state["drive"] = float(args[0])
			stack.append(null)
			return true
		"set_spin":
			if args.size() != 2 or not _is_num(args[1]):
				return _fail("TypeError", "set_spin(序号, 弧度每秒)", op, ins)
			state["spin"][int(args[0])] = float(args[1])
			stack.append(null)
			return true
		"set_steer":
			if args.size() != 2 or not _is_num(args[1]):
				return _fail("TypeError", "set_steer(序号, 角度)", op, ins)
			state["steer"][int(args[0])] = float(args[1])
			stack.append(null)
			return true
		"set_thrust":
			if args.size() != 2 or not _is_num(args[1]):
				return _fail("TypeError", "set_thrust(序号, 牛顿)", op, ins)
			state["thrust"][int(args[0])] = float(args[1])
			stack.append(null)
			return true
		"set_lift":
			if args.size() != 1 or not _is_num(args[0]):
				return _fail("TypeError", "set_lift(0~1 的升力)", op, ins)
			state["controls"]["lift"] = clampf(float(args[0]), 0.0, 1.0)
			stack.append(null)
			return true
		"set_tilt":
			if args.size() != 2 or not _is_num(args[0]) or not _is_num(args[1]):
				return _fail("TypeError", "set_tilt(前后倾, 左右倾) 各 -1~1", op, ins)
			state["controls"]["pitch"] = clampf(float(args[0]), -1.0, 1.0)
			state["controls"]["roll"] = clampf(float(args[1]), -1.0, 1.0)
			stack.append(null)
			return true
		"set_rcs":
			if args.size() != 2 or not _is_num(args[0]) or not _is_num(args[1]):
				return _fail("TypeError", "set_rcs(转向, 前后) 各 -1~1", op, ins)
			state["controls"]["turn"] = clampf(float(args[0]), -1.0, 1.0)
			state["controls"]["forward"] = clampf(float(args[1]), -1.0, 1.0)
			stack.append(null)
			return true
		"drill":
			if args.size() > 1:
				return _fail("TypeError", "drill(开关) 只接受 0 或 1 个参数", op, ins)
			var on := true
			if args.size() == 1:
				on = _is_true(args[0])
			state["controls"]["drill"] = on
			stack.append(null)
			return true
		"laser":
			if args.size() != 3 or not _is_num(args[0]) or not _is_num(args[1]) or not _is_num(args[2]):
				return _fail("TypeError", "laser(x, y, z)：朝这个方块坐标打激光", op, ins)
			state["controls"]["laser"] = true
			state["controls"]["laser_x"] = float(args[0])
			state["controls"]["laser_y"] = float(args[1])
			state["controls"]["laser_z"] = float(args[2])
			stack.append(null)
			return true
		"laser_off":
			if args.size() != 0:
				return _fail("TypeError", "laser_off() 不接受参数", op, ins)
			state["controls"]["laser"] = false
			stack.append(null)
			return true
		"shoot":
			if args.size() != 3 or not _is_num(args[0]) or not _is_num(args[1]) or not _is_num(args[2]):
				return _fail("TypeError", "shoot(x, y, z)：朝这个方块坐标开炮", op, ins)
			state["controls"]["shoot"] = true
			state["controls"]["shoot_x"] = float(args[0])
			state["controls"]["shoot_y"] = float(args[1])
			state["controls"]["shoot_z"] = float(args[2])
			stack.append(null)
			return true
		"go_to":
			if args.size() != 3 or not _is_num(args[0]) or not _is_num(args[1]) or not _is_num(args[2]):
				return _fail("TypeError", "go_to(x, y, z)：自动寻路飞到这个坐标", op, ins)
			state["controls"]["go"] = true
			state["controls"]["go_x"] = float(args[0])
			state["controls"]["go_y"] = float(args[1])
			state["controls"]["go_z"] = float(args[2])
			stack.append(null)
			return true
		"stop":
			if args.size() != 0:
				return _fail("TypeError", "stop() 不接受参数", op, ins)
			state["controls"]["go"] = false
			stack.append(null)
			return true
		"set_velocity":
			if args.size() != 2 or not _is_num(args[0]) or not _is_num(args[1]):
				return _fail("TypeError", "set_velocity(水平x速度, 水平z速度)：米/秒", op, ins)
			state["controls"]["vel_mode"] = true
			state["controls"]["vx"] = float(args[0])
			state["controls"]["vz"] = float(args[1])
			stack.append(null)
			return true
		"set_altitude":
			if args.size() != 1 or not _is_num(args[0]):
				return _fail("TypeError", "set_altitude(y)：想稳定的世界高度", op, ins)
			state["controls"]["alt_mode"] = true
			state["controls"]["alt_target"] = float(args[0])
			stack.append(null)
			return true
		"build":
			if args.size() != 4 or not _is_str(args[0]) or not _is_num(args[1]) or not _is_num(args[2]) or not _is_num(args[3]):
				return _fail("TypeError", "build(id, x, y, z)：在指定格子盖一栋建筑", op, ins)
			var err := ""
			if build_provider.is_valid():
				err = str(build_provider.call(str(args[0]), Vector3i(int(args[1]), int(args[2]), int(args[3]))))
			stack.append(err)
			return true
		"build_here":
			if args.size() != 1 or not _is_str(args[0]):
				return _fail("TypeError", "build_here(id)：在自己旁边找块平地把建筑盖起来", op, ins)
			var err2 := ""
			if build_here_provider.is_valid():
				err2 = str(build_here_provider.call(str(args[0])))
			stack.append(err2)
			return true
		"place":
			if args.size() != 4 or not _is_str(args[0]) or not _is_num(args[1]) or not _is_num(args[2]) or not _is_num(args[3]):
				return _fail("TypeError", "place(方块名, x, y, z)：在指定格子放一块方块", op, ins)
			var place_err := ""
			if place_provider.is_valid():
				place_err = str(place_provider.call(str(args[0]), Vector3i(int(args[1]), int(args[2]), int(args[3]))))
			stack.append(place_err)
			return true
		"find_path":
			if args.size() != 3 or not _is_num(args[0]) or not _is_num(args[1]) or not _is_num(args[2]):
				return _fail("TypeError", "find_path(x, y, z)：算出到这个世界坐标的航路", op, ins)
			var waypoints: Array = []
			if path_provider.is_valid():
				var pts: Array = path_provider.call(Vector3(float(args[0]), float(args[1]), float(args[2])))
				for point in pts:
					waypoints.append({"x": float(point.x), "y": float(point.y), "z": float(point.z)})
			stack.append(waypoints)
			return true
		"get_link":
			if args.size() != 1 or not _is_num(args[0]):
				return _fail("TypeError", "get_link(序号) 从 1 开始", op, ins)
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
						return _fail("TypeError", "range 的步长必须是整数", op, ins)
					stepn = int(args[2])
			else:
				return _fail("TypeError", "range(终点) 或 range(起点, 终点[, 步长])", op, ins)
			if stepn == 0:
				return _fail("ValueError", "range 的步长不能是 0", op, ins)
			stack.append({"__type": "range", "start": start, "stop": stop, "step": stepn})
			return true
		"len":
			if args.size() != 1:
				return _fail("TypeError", "len(值)", op, ins)
			var value = args[0]
			if _is_num(value) or value == null or value is bool:
				return _fail("TypeError", "%s 没有长度" % _type_name(value), op, ins)
			stack.append(size_of(value))
			return true
		"abs":
			if args.size() != 1 or not _is_num(args[0]):
				return _fail("TypeError", "abs(数值)", op, ins)
			stack.append(abs(int(args[0])) if typeof(args[0]) == TYPE_INT else absf(float(args[0])))
			return true
		"min", "max":
			var values: Array = []
			if args.size() == 1 and args[0] is Array:
				values = args[0]
			else:
				values = args
			if values.is_empty():
				return _fail("ValueError", "%s() 需要至少一个值" % name, op, ins)
			var best = values[0]
			for i in range(1, values.size()):
				var candidate = values[i]
				var better := false
				if _is_num(best) and _is_num(candidate):
					better = float(candidate) < float(best) if name == "min" else float(candidate) > float(best)
				elif best is String and candidate is String:
					better = str(candidate) < str(best) if name == "min" else str(candidate) > str(best)
				else:
					return _fail("TypeError", "%s() 的参数类型不一致" % name, op, ins)
				if better:
					best = candidate
			stack.append(best)
			return true
		"int":
			if args.size() != 1:
				return _fail("TypeError", "int(值)", op, ins)
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
			return _fail("ValueError", "不能把 %s 转成整数" % _to_str(v), op, ins)
		"float":
			if args.size() != 1:
				return _fail("TypeError", "float(值)", op, ins)
			var v2 = args[0]
			if _is_num(v2):
				stack.append(float(v2))
				return true
			if v2 is String and str(v2).strip_edges().is_valid_float():
				stack.append(float(str(v2).strip_edges()))
				return true
			return _fail("ValueError", "不能把 %s 转成小数" % _to_str(v2), op, ins)
		"str":
			if args.size() != 1:
				return _fail("TypeError", "str(值)", op, ins)
			stack.append(_to_str(args[0]))
			return true
		"bool":
			if args.size() != 1:
				return _fail("TypeError", "bool(值)", op, ins)
			stack.append(_is_true(args[0]))
			return true
		"round":
			if args.is_empty() or args.size() > 2:
				return _fail("TypeError", "round(数值[, 位数])", op, ins)
			if not _is_num(args[0]):
				return _fail("TypeError", "round() 的第一个参数必须是数字", op, ins)
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
	return _fail("NameError", "未知内置函数 %s" % name, op, ins)


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


func _format_string(template: String, value, op: int, ins: Dictionary) -> String:
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
						_fail("TypeError", "% 格式化的参数不够", op, ins)
						return out
					out += _to_str(args[index])
					index += 1
					i += 2
					continue
				_fail("TypeError", "不支持的格式化符号 %%%s" % spec, op, ins)
				return out
			out += ch
			i += 1
		return out
	return _to_str(value)


# ---------------------------------------------------------------- 迭代器

func _make_iter(iterable, op: int, ins: Dictionary):
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
	_fail("TypeError", "%s 不能用来 for 循环" % _type_name(iterable), op, ins)
	return null


func _step_iter(iterator: Dictionary) -> bool:
	var kind := str(iterator.get("kind", ""))
	if kind == "range":
		var cur := int(iterator["cur"])
		var stop := int(iterator["stop"])
		var stepn := int(iterator["step"])
		if (stepn > 0 and cur >= stop) or (stepn < 0 and cur <= stop):
			return false
		var stack: Array = _frames[_frames.size() - 1]["stack"]
		stack.append(cur)
		iterator["cur"] = cur + stepn
		return true
	var seq: Array = iterator["seq"]
	var i := int(iterator["i"])
	if seq.is_empty() or i >= seq.size():
		return false
	var stack2: Array = _frames[_frames.size() - 1]["stack"]
	stack2.append(seq[i])
	iterator["i"] = i + 1
	return true
