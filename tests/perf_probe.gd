extends SceneTree
## 性能探针：跑一段，打印帧时间与渲染统计

var _frames := 0
var _t0 := 0
var _main: Node
var _accum := 0.0
var _worst := 0.0
var _worst_at := 0


func _initialize() -> void:
	_t0 = Time.get_ticks_usec()
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(delta: float) -> bool:
	if _frames == 0:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_frames += 1
	if _frames == 2:
		print("启动耗时（含 256 区块构建）: %.0f ms" % ((Time.get_ticks_usec() - _t0) / 1000.0))
		_t0 = Time.get_ticks_usec()
	elif _frames > 30:
		_accum += delta
		if delta * 1000.0 > _worst:
			_worst = delta * 1000.0
			_worst_at = _frames
		if _frames == 330:
			var ms := _accum / 300.0 * 1000.0
			print("平均帧时间: %.2f ms（帧率 %.0f）" % [ms, 1000.0 / ms])
			print("最慢帧: %.2f ms @ 第 %d 帧" % [_worst, _worst_at])
			print("draw calls: ", RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
			print("primitives: ", RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME))
			print("objects: ", RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME))
			quit(0)
	return false
