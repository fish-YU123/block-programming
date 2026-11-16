extends SceneTree
## VM 性能基准（不参与回归：只有 tests/*_test.gd 会被 run_tests.sh 自动发现）
##   godot --headless --path . --script res://tests/vm_bench.gd
##
## 负载贴近真实 unit_controller.tick()：
##   每帧 inject(传感器) → 按 60 行/秒预算跑 1 次 step(1) → 段边界 call_function(loop)
## 另加两组纯解释器吞吐：密集型 while 算术、预设 feifei.py 的编译 + 单步。
##
## 输出行带 [bench] 前缀，方便前后对比（数字越小越好）。

const VM = preload("res://scripts/lang/py_vm.gd")

const UNITS := 100
const FRAMES := 60

const MIXED_SRC := """if "n" in mem:
    n = mem["n"]
else:
    n = 0
mem["n"] = n + 1
total = 0
for i in range(8):
    total += i * 2
xs = [1, 2, 3]
xs[1] = total % 7
d = {"a": 1, "b": 2}
d["c"] = xs[1] + d["a"]
if total > 100:
    set_drive(0.5)
else:
    set_drive(total * 0.01)
set_spin(0, n * 0.1)
"""

const HOT_SRC := """i = 0
s = 0
while i < 1000:
    s += i * 2 - 1
    i += 1
set_drive(s)
"""

var _payload: Dictionary = {}
var _feifei: String = ""


func _initialize() -> void:
	_build_payload()
	_feifei = _read_text("res://data/presets/feifei.py")

	# 预热：让 GDScript 函数/类型缓存热起来
	_warmup()

	_bench_mixed()
	_bench_inject_only()
	_bench_preset()
	_bench_hot()
	_bench_compile()
	quit(0)


func _read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	return "" if f == null else f.get_as_text()


func _build_payload() -> void:
	var blocks: Array = []
	var heights: Array = []
	for x in 5:
		var col: Array = []
		var hcol: Array = []
		for z in 5:
			col.append("grass" if (x + z) % 3 != 0 else "stone")
			hcol.append(26.0 + float((x * 5 + z) % 2))
		blocks.append(col)
		heights.append(hcol)
	var blocks3: Array = []
	for x in 5:
		var layer: Array = []
		for y in 5:
			var row: Array = []
			for z in 5:
				row.append("stone" if (x + y + z) % 4 == 0 else "")
			layer.append(row)
		blocks3.append(layer)
	var enemies: Array = []
	for i in 3:
		enemies.append({
			"x": 60.0 + float(i) * 2.0, "y": 42.0, "z": 128.0 + float(i),
			"type": "feifei", "hp": 80.0 - float(i) * 7.0, "dist": 9.0 + float(i) * 4.0,
		})
	var marks: Array = [
		{"x": 64.0, "y": 42.0, "z": 126.0, "action": "mine", "id": "grass", "dist": 5.0},
	]
	_payload = {
		"pos": {"x": 60.0, "y": 40.0, "z": 128.0},
		"vel": {"x": 0.5, "y": 0.0, "z": -0.5},
		"cell": {"x": 60, "y": 40, "z": 128},
		"yaw": 0.3, "energy": 900.0, "energy_ratio": 0.8,
		"hp": 100.0, "hp_max": 100.0, "hp_ratio": 1.0, "team": 0,
		"thrust": 0.0, "drill_hits": 0,
		"blocks": blocks, "heights": heights, "blocks3": blocks3, "here": "grass",
		"enemies": enemies, "orders": [], "allies": [], "team_mem": {"敌情": 1},
		"marks": marks, "cmd": {}, "ore": {}, "below": {"x": 60, "y": 39, "z": 128},
		"res": {"copper": 120, "coal": 60, "iron": 30, "gold": 0},
		"peace": 0.0, "t": 12.5, "water": 0.0, "submerged": 0,
		"uid": 1, "leader": 0, "sudden": 0, "moving": true,
	}


func _warmup() -> void:
	var vm = VM.new()
	vm.load_source(MIXED_SRC)
	for i in 30:
		vm.inject(_payload)
		var r: Dictionary = vm.step(1)
		if bool(r.get("done", false)):
			vm.restart()


func _new_vm(src: String) -> RefCounted:
	var vm = VM.new()
	vm.load_source(src)
	if vm.error != "":
		push_error("[bench] 基准代码编译失败: " + vm.error)
	return vm


# ---------------------------------------------------------------- 基准项

func _bench_mixed() -> void:
	var vms: Array = []
	for i in UNITS:
		vms.append(_new_vm(MIXED_SRC))
	# 预热一轮
	for vm in vms:
		vm.inject(_payload)
		vm.step(1)
	var steps := 0
	var t0 := Time.get_ticks_usec()
	for frame in FRAMES:
		for vm in vms:
			vm.inject(_payload)
			# unit_controller：预算累积 1 行/帧，steps = int(budget)
			var r: Dictionary = vm.step(1)
			steps += 1
			if bool(r.get("done", false)):
				vm.restart()
	var us := Time.get_ticks_usec() - t0
	print("[bench] mixed  %d VM × %d 帧 = %.2f ms（%.2f µs/单元帧，%.2f µs/step，%d step）" % [
		UNITS, FRAMES, us / 1000.0, float(us) / float(UNITS * FRAMES), float(us) / float(steps), steps])


func _bench_inject_only() -> void:
	var vms: Array = []
	for i in UNITS:
		vms.append(_new_vm(MIXED_SRC))
	for vm in vms:
		vm.inject(_payload)
	var t0 := Time.get_ticks_usec()
	for frame in FRAMES:
		for vm in vms:
			vm.inject(_payload)
	var us := Time.get_ticks_usec() - t0
	print("[bench] inject %d VM × %d 帧 = %.2f ms（%.2f µs/inject）" % [
		UNITS, FRAMES, us / 1000.0, float(us) / float(UNITS * FRAMES)])


func _bench_preset() -> void:
	if _feifei == "":
		print("[bench] preset feifei.py 缺失，跳过")
		return
	var vms: Array = []
	for i in UNITS:
		vms.append(_new_vm(_feifei))
	# 预热：先跑一步模块段
	for vm in vms:
		vm.inject(_payload)
		vm.step(1)
	var steps := 0
	var advances := 0
	var started := {}
	var t0 := Time.get_ticks_usec()
	for frame in FRAMES:
		for idx in vms.size():
			var vm = vms[idx]
			vm.inject(_payload)
			var r: Dictionary = vm.step(1)
			steps += 1
			if not bool(r.get("ok", true)):
				continue
			if bool(r.get("done", false)):
				advances += 1
				var began: bool = started.get(idx, false)
				if not began and vm.has_function("start"):
					started[idx] = true
					vm.call_function("start")
				elif vm.has_function("loop"):
					vm.call_function("loop")
				else:
					vm.restart()
	var us := Time.get_ticks_usec() - t0
	print("[bench] preset %d VM × %d 帧 = %.2f ms（%.2f µs/step，段切换 %d 次）" % [
		UNITS, FRAMES, us / 1000.0, float(us) / float(steps), advances])
	# 模块段单步：一个 VM 从头跑完整个模块段
	var vm2 = _new_vm(_feifei)
	vm2.inject(_payload)
	var t1 := Time.get_ticks_usec()
	var loop_steps := 0
	while loop_steps < 2000 and not vm2.finished and vm2.error == "":
		vm2.step(1)
		loop_steps += 1
	var us2 := Time.get_ticks_usec() - t1
	print("[bench] preset-module 1 VM 跑完模块段 %d 步 = %.2f ms（%.2f µs/step）" % [
		loop_steps, us2 / 1000.0, float(us2) / float(maxi(1, loop_steps))])


func _bench_hot() -> void:
	var vms: Array = []
	for i in UNITS:
		vms.append(_new_vm(HOT_SRC))
	var t0 := Time.get_ticks_usec()
	for vm in vms:
		vm.inject(_payload)
		# 1000 次 while 迭代 + 初始化/收尾；max_ops 放宽，避免被死循环保护掐断
		vm.step(1000000, 100000000)
	var us := Time.get_ticks_usec() - t0
	var lines := UNITS * (1000 * 2 + 3)
	print("[bench] hot    %d VM × 1000 迭代 = %.2f ms（约 %d 行，%.3f µs/行）" % [
		UNITS, us / 1000.0, lines, float(us) / float(lines)])


func _bench_compile() -> void:
	var t0 := Time.get_ticks_usec()
	for i in UNITS:
		var vm = VM.new()
		vm.load_source(_feifei)
	var us := Time.get_ticks_usec() - t0
	print("[bench] compile %d × feifei.py = %.2f ms（%.2f µs/次）" % [
		UNITS, us / 1000.0, float(us) / float(UNITS)])
