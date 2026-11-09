extends SceneTree
## 状态图标：没电 / 被埋 / 地基不牢

var _frames := 0
var _main: Node
var _passed := 0
var _failed := 0
var _done := false
const StatusBadges = preload("res://scripts/ui/status_badges.gd")


func _initialize() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_main.world.build_all()
		_main._start_game()
		return false
	if _frames < 8 or _done:
		if _done and _frames > 8:
			print("通过 %d 项，失败 %d 项" % [_passed, _failed])
			quit(0 if _failed == 0 else 1)
		return false

	# 1) 图标贴图能生成，而且不同状态不一样
	var tex_no_power: Texture2D = StatusBadges.texture(StatusBadges.Kind.NO_POWER)
	var tex_buried: Texture2D = StatusBadges.texture(StatusBadges.Kind.BURIED)
	var tex_foundation: Texture2D = StatusBadges.texture(StatusBadges.Kind.FOUNDATION)
	_record("三种图标贴图都生成了", tex_no_power != null and tex_buried != null and tex_foundation != null)
	_record("不同状态图标不同", tex_no_power != tex_buried and tex_buried != tex_foundation)

	# 2) 单位没电 → 头顶闪电图标
	var entry: Dictionary = _main.team_units(0)[0]
	var unit = entry["unit"]
	StatusBadges.set_kind(unit._badge, StatusBadges.Kind.NONE)
	unit.energy_j = unit.energy_max
	unit._physics_process(0.016)
	_record("有电时不显示图标", not unit._badge.visible)
	unit.energy_j = 0.0
	unit._physics_process(0.016)
	_record("没电时显示闪电图标", unit._badge.visible and StatusBadges.kind_of(unit._badge) == StatusBadges.Kind.NO_POWER)
	unit.energy_j = unit.energy_max
	unit._physics_process(0.016)
	_record("补电后图标消失", not unit._badge.visible)

	# 3) 建筑被埋住 → 棕色图标
	var base := _flat_spot(Vector2i(38, 126))
	var err: String = _main.place_building_at("miner", base, 0) if base != Vector3i(-1, -1, -1) else "找不到平地"
	_record("测试建筑放下成功", err == "", err)
	if err != "":
		_done = true
		return false
	var node = _main.buildings[_main.buildings.size() - 1]["node"]
	node.build_left = 0.0
	node._update_build_progress()
	_main._tick_buildings(0.1)
	_record("正常建筑没有图标", not node._badge.visible)
	_main.world.set_block(Vector3i(base.x, base.y + 1, base.z), _main.db.id_of("stone"))
	_main._tick_buildings(0.1)
	_record("被方块埋住显示图标", node._badge.visible and StatusBadges.kind_of(node._badge) == StatusBadges.Kind.BURIED)
	_main.world.set_block(Vector3i(base.x, base.y + 1, base.z), 0)
	_main._tick_buildings(0.1)
	_record("挖开后图标消失", not node._badge.visible)

	# 4) 地基被挖掉 → 警示三角
	_main.world.set_block(Vector3i(base.x, base.y - 1, base.z), 0)
	_main._tick_buildings(0.1)
	_record("缺地基显示警示三角", node._badge.visible and StatusBadges.kind_of(node._badge) == StatusBadges.Kind.FOUNDATION)
	_main.world.set_block(Vector3i(base.x, base.y - 1, base.z), _main.db.id_of("stone"))
	_main._tick_buildings(0.1)
	_record("补回地基后图标消失", not node._badge.visible)

	_done = true
	return false


func _record(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ✓ ", name, "" if detail == "" else "  " + detail)
	else:
		_failed += 1
		print("  ✗ ", name, "：", detail)


## 在附近找一块 3×3 同高度的平地（建筑要求地面平整）
func _flat_spot(near: Vector2i) -> Vector3i:
	var world = _main.world
	for dx in range(-20, 21):
		for dz in range(-20, 21):
			var x: int = near.x + dx
			var z: int = near.y + dz
			if x < 2 or z < 2 or x > 96 or z > 253:
				continue
			var h: int = int(world.surface_height(x, z))
			var flat := true
			for ox in 3:
				for oz in 3:
					if int(world.surface_height(x + ox, z + oz)) != h:
						flat = false
			if flat:
				return Vector3i(x, h, z)
	return Vector3i(-1, -1, -1)
