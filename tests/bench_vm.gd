extends SceneTree
## 粗略基准：100 个大脑各跑 60 步需要多少毫秒
func _initialize() -> void:
	const VM = preload("res://scripts/lang/py_vm.gd")
	var src := "n = mem[\"n\"] if \"n\" in mem else 0\nmem[\"n\"] = n + 1\nfor i in range(4):\n    set_drive(0.5)\n    set_spin(i, 1.0)\npx = n\n"
	var vms: Array = []
	for i in 100:
		var vm = VM.new()
		vm.load_source(src)
		vms.append(vm)
	var t0 := Time.get_ticks_usec()
	for frame in 60:
		for vm in vms:
			vm.inject({"px": 1.0, "energy": 100.0})
			vm.step(1)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	print("100 大脑 x 60 帧 = %.1f ms（每帧 %.3f ms）" % [ms, ms / 60.0])
	quit(0)
