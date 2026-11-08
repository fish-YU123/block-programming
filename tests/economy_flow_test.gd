extends SceneTree
## 资源链路（挖掘 → 造单位 → 收回退款）测试：headless 运行

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
	if _frames == 2:
		_main.world.build_all()
		_main._start_game()
	if _frames == 3:
		_check()
	return false


func _check() -> void:
	var economy = _main.economy
	_record("开局有铜", economy.amount("copper") == 120, str(economy.amount("copper")))
	_record("开局有煤", economy.amount("coal") == 60, str(economy.amount("coal")))

	# 直接挖一块煤矿（不靠鼠标），验证资源真的进账
	var world = _main.world
	var db = _main.db
	var ore_cell := Vector3i(-1, -1, -1)
	for x in range(2, 40):
		for z in range(2, 40):
			for y in range(1, 30):
				if db.name_of(world.get_block(Vector3i(x, y, z))) == "coal_ore":
					ore_cell = Vector3i(x, y, z)
					break
			if ore_cell.x >= 0:
				break
		if ore_cell.x >= 0:
			break
	_record("地图里能找到煤矿", ore_cell.x >= 0, "没找到")
	if ore_cell.x >= 0:
		var before: int = economy.amount("coal")
		economy.mine_block(world.get_block(ore_cell))
		_record("挖煤矿得到煤", economy.amount("coal") == before + 1, str(economy.amount("coal")))

	# 放单位扣资源
	var copper_before: int = economy.amount("copper")
	var coal_before: int = economy.amount("coal")
	_main._place_unit()
	_record("放置后蓝队单位数 +1", _main.team_units(0).size() == 2, str(_main.units.size()))
	_record("放置扣铜 25", economy.amount("copper") == copper_before - 25, str(economy.amount("copper")))
	_record("放置扣煤 10", economy.amount("coal") == coal_before - 10, str(economy.amount("coal")))

	# 收回退款
	_main._remove_last_unit()
	_record("收回后蓝队单位数 -1", _main.team_units(0).size() == 1, str(_main.units.size()))
	_record("收回退款铜", economy.amount("copper") == copper_before, str(economy.amount("copper")))
	_record("收回退款煤", economy.amount("coal") == coal_before, str(economy.amount("coal")))

	# 资源不足时放不下去
	economy.spend({"copper": economy.amount("copper"), "coal": economy.amount("coal")})
	_main._place_unit()
	_record("资源不足放不下单位", _main.team_units(0).size() == 1, str(_main.units.size()))

	# 生产链路：补资源后 tick 一段时间应该产出电池
	economy.add("coal", 3)
	economy.add("copper", 1)
	_main.production.add_building("battery")
	var battery_before: int = economy.amount("battery")
	for i in 40:
		_main.production.tick(1.0)
	_record("生产建筑产出电池", economy.amount("battery") > battery_before, str(economy.amount("battery")))

	# HUD 资源行
	_main._refresh_hud()
	_record("HUD 显示资源", _main.hud.resources_label.text.find("资源") >= 0, _main.hud.resources_label.text)

	print("通过 %d 项，失败 %d 项" % [_passed, _failed])
	for item in _failures:
		print("  ✗ " + item)
	quit(0 if _failed == 0 else 1)


func _record(name: String, ok: bool, detail: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append("%s：%s" % [name, detail])
