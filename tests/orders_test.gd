extends SceneTree
## 玩家标记（虚影指令）测试：headless 运行
##   godot --headless --path . --script res://tests/orders_test.gd

var _passed := 0
var _failed := 0
var _failures: Array = []
var _main: Node
var _frames := 0


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 3:
		_check()
	return false


func _check() -> void:
	var cell := Vector3i(50, 40, 128)
	_main.world.set_block(cell, _main.db.id_of("stone"))

	# 1) 标记 / 取消
	_main.toggle_order(cell, _main.ORDER_MINE)
	_record("标记后有一条指令", _main.orders.size() == 1, str(_main.orders.size()))
	var found: Dictionary = _main.order_at(cell)
	_record("能按格查到指令", str(found.get("action", "")) == "mine", str(found))
	_record("虚影节点已生成", _main.orders_root.get_child_count() >= 2, str(_main.orders_root.get_child_count()))
	_main.toggle_order(cell, _main.ORDER_MINE)
	_record("再点一次取消标记", _main.orders.is_empty(), str(_main.orders.size()))
	_record("取消后虚影清空", _main.orders_root.get_child_count() == 0, str(_main.orders_root.get_child_count()))

	# 2) 单位代码能读到的指令列表（按距离排序）
	_main.toggle_order(Vector3i(52, 40, 128), _main.ORDER_MINE)
	_main.toggle_order(Vector3i(56, 40, 128), _main.ORDER_PLACE, "stone")
	var list: Array = _main.orders_for(Vector3(55.0, 40.0, 128.0))
	_record("指令列表有条目", list.size() == 2, str(list.size()))
	_record("按距离排序", float(list[0]["dist"]) <= float(list[1]["dist"]), "顺序不对")
	_record("指令带动作名", str(list[0]["action"]) != "", str(list[0]))

	# 3) 格子挖空后指令自动消失
	_main.world.set_block(Vector3i(52, 40, 128), 0)
	_main._prune_orders()
	_record("挖掘完成后指令自动清掉", _main.order_at(Vector3i(52, 40, 128)).is_empty(), str(_main.orders.size()))

	# 4) 建筑虚影尺寸按建筑大小
	_main.clear_orders()
	_main.toggle_order(Vector3i(50, 40, 128), _main.ORDER_BUILD, "factory")
	_record("建筑指令记下了 id", str(_main.order_at(Vector3i(50, 40, 128)).get("id", "")) == "factory", "")
	var ghost_sizes: Array = []
	for node in _main.orders_root.get_children():
		if node is MeshInstance3D and node.mesh is BoxMesh:
			ghost_sizes.append(node.mesh.size)
	_record("建筑虚影是 3×3×3", ghost_sizes.size() > 0 and ghost_sizes[0].y >= 3.0, str(ghost_sizes))

	# 5) 飞飞挖掉方块给资源
	_main.clear_orders()
	var unit = _main.team_units(0)[0]["unit"]
	var copper_before: int = _main.economy.amount("copper")
	_main._on_block_dug(unit, Vector3i(60, 40, 128), _main.db.id_of("copper_ore"))
	_record("飞飞挖铜矿给铜", _main.economy.amount("copper") == copper_before + 1, str(_main.economy.amount("copper")))
	var red_unit = _main.team_units(1)[0]["unit"]
	var before2: int = _main.economy.amount("copper")
	_main._on_block_dug(red_unit, Vector3i(61, 40, 128), _main.db.id_of("copper_ore"))
	_record("红方挖的不给蓝方资源", _main.economy.amount("copper") == before2, str(_main.economy.amount("copper")))

	# 6) 玩家点击不再直接改方块，只留虚影
	var block_before: int = _main.world.get_block(Vector3i(50, 41, 128))
	_main.world.set_block(Vector3i(50, 41, 128), _main.db.id_of("stone"))
	_main.toggle_order(Vector3i(50, 41, 128), _main.ORDER_MINE)
	_record("标记挖掘不会挖掉方块", _main.world.get_block(Vector3i(50, 41, 128)) == _main.db.id_of("stone"), "被直接挖了")
	_main.clear_orders()
	_main.world.set_block(Vector3i(50, 41, 128), block_before)

	print("通过 %d 项，失败 %d 项" % [_passed, _failed])
	for f in _failures:
		print("  ✗ ", f)
	quit(0 if _failed == 0 else 1)


func _record(name: String, ok: bool, detail: String) -> void:
	if ok:
		_passed += 1
		print("  ✓ ", name)
	else:
		_failed += 1
		_failures.append("%s（%s）" % [name, detail])
