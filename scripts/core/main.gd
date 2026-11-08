extends Node3D
## 游戏入口：搭建世界、相机、HUD 与方块交互。

const BlockDB = preload("res://scripts/world/block_db.gd")
const VoxelWorld = preload("res://scripts/world/voxel_world.gd")
const CameraRig = preload("res://scripts/player/camera_rig.gd")
const Hud = preload("res://scripts/ui/hud.gd")
const UnitDB = preload("res://scripts/units/unit_db.gd")
const Flyer = preload("res://scripts/units/flyer.gd")
const UnitController = preload("res://scripts/units/unit_controller.gd")
const DefaultCode = preload("res://scripts/units/unit_code_default.gd")

const WORLD_SIZE_X := 256
const WORLD_SIZE_Z := 256
const WORLD_HEIGHT := 64
const WORLD_SEED := 20261108
const REACH := 8.0

var db: BlockDB
var world: VoxelWorld
var rig: CameraRig
var hud: Hud
var block_options: Array[int] = []
var selected := 0

var unit_db: UnitDB
var units: Array = []          ## [{unit: Flyer, controller: UnitController}]
var units_root: Node3D
## 预设单位 + 玩家代码（现在还没有编辑器，先用默认代码）
const MAX_UNITS := 20
const START_UNITS := [{"id": "feifei", "x": 34.0, "z": 128.0, "code": DefaultCode.FLYER_SOURCE}]

var _highlight: MeshInstance3D
var _highlight_material: StandardMaterial3D
var _highlight_array := ArrayMesh.new()
var _last_cell := Vector3i(999999, 999999, 999999)


func _ready() -> void:
	db = BlockDB.new()
	var problem := db.load_dir("res://data/blocks")
	if problem != "":
		push_error(problem)
		return
	for def in db.defs:
		if def.id != BlockDB.AIR:
			block_options.append(def.id)
	selected = 0

	world = VoxelWorld.new()
	world.name = "World"
	add_child(world)
	world.setup(db, WORLD_SEED, WORLD_SIZE_X, WORLD_SIZE_Z, WORLD_HEIGHT)
	_install_environment()

	rig = CameraRig.new()
	rig.name = "CameraRig"
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.far = 400.0
	camera.near = 0.05
	camera.current = true
	rig.add_child(camera)
	add_child(rig)
	rig.primary_click.connect(_on_primary_click)

	var spawn := Vector3(30.0, 0.0, WORLD_SIZE_Z * 0.5)
	var h := world.surface_height(int(spawn.x), int(spawn.z))
	rig.position = Vector3(spawn.x, float(h) + 16.0, spawn.z)
	rig.yaw = -1.5708
	world.prefetch(rig.position, 20)

	units_root = Node3D.new()
	units_root.name = "Units"
	add_child(units_root)
	_setup_units()

	hud = Hud.new()
	hud.name = "Hud"
	add_child(hud)
	_highlight = MeshInstance3D.new()
	_highlight.name = "BlockHighlight"
	_highlight_material = StandardMaterial3D.new()
	_highlight_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_highlight_material.albedo_color = Color(0.1, 0.1, 0.1, 0.9)
	_highlight_material.no_depth_test = false
	_highlight.mesh = _highlight_array
	_highlight.material_override = _highlight_material
	add_child(_highlight)
	_refresh_hud()


func _setup_units() -> void:
	unit_db = UnitDB.new()
	var problem := unit_db.load_dir("res://data/units")
	if problem != "":
		push_error(problem)
		return
	for spec in START_UNITS:
		var def: Dictionary = unit_db.get_def(str(spec["id"]))
		if def.is_empty():
			push_error("找不到预设单位：%s" % spec["id"])
			continue
		_spawn_unit(def, Vector3(float(spec["x"]), 0.0, float(spec["z"])), str(spec["code"]))


func _spawn_unit(def: Dictionary, at: Vector3, code: String) -> void:
	var flyer := Flyer.new()
	flyer.name = "%s_%d" % [str(def.get("id", "unit")), units.size() + 1]
	units_root.add_child(flyer)
	var ground := world.surface_height(int(at.x), int(at.z))
	flyer.global_position = Vector3(at.x, float(ground) + 6.0, at.z)
	flyer.setup(world, def)
	var controller := UnitController.new()
	controller.bind(flyer, code, 1)
	units.append({"unit": flyer, "controller": controller})


func _physics_process(delta: float) -> void:
	for entry in units:
		var controller: UnitController = entry["controller"]
		controller.tick(delta)


func _install_environment() -> void:
	var env := Environment.new()
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.32, 0.55, 0.86)
	sky_mat.sky_horizon_color = Color(0.72, 0.82, 0.92)
	sky_mat.ground_bottom_color = Color(0.55, 0.63, 0.72)
	sky_mat.ground_horizon_color = Color(0.72, 0.82, 0.92)
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.32
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Color(0.72, 0.82, 0.92)
	env.fog_depth_begin = 150.0
	env.fog_depth_end = 340.0
	env.fog_depth_curve = 1.4
	env.fog_density = 1.0
	env.fog_sky_affect = 0.0
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation = Vector3(-0.9, 0.7, 0.0)
	sun.light_energy = 0.95
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 90.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	add_child(sun)


func _process(_delta: float) -> void:
	if world == null or rig == null:
		return
	world.update_streaming(rig.position)
	_update_highlight()
	_update_unit_hud()


func _update_highlight() -> void:
	var hit := _aim()
	if hit.is_empty():
		_highlight.visible = false
		return
	var cell: Vector3i = hit["cell"]
	_highlight.visible = true
	_highlight.global_position = Vector3(cell) + Vector3(0.5, 0.5, 0.5)
	if cell != _last_cell:
		_last_cell = cell
		_build_wire_box(Vector3.ONE * 1.006)


func _build_wire_box(scale: Vector3) -> void:
	var corners := [
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1),
		Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(0, 1, 1),
	]
	var edges := [
		[0, 1], [1, 2], [2, 3], [3, 0],
		[4, 5], [5, 6], [6, 7], [7, 4],
		[0, 4], [1, 5], [2, 6], [3, 7],
	]
	var verts := PackedVector3Array()
	for edge in edges:
		for index in edge:
			var p: Vector3 = corners[index] - Vector3(0.5, 0.5, 0.5)
			verts.append(Vector3(p.x * scale.x, p.y * scale.y, p.z * scale.z))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	_highlight_array.clear_surfaces()
	_highlight_array.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)


func _aim() -> Dictionary:
	if rig == null or world == null:
		return {}
	var from := rig.camera.global_position
	var to := from + rig.look_direction() * REACH
	return world.raycast(from, to)


func _on_primary_click() -> void:
	var hit := _aim()
	if hit.is_empty():
		return
	var cell: Vector3i = hit["cell"]
	if world.get_block(cell) == BlockDB.AIR:
		return
	world.set_block(cell, BlockDB.AIR)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	if event.button_index == MOUSE_BUTTON_WHEEL_UP:
		selected = (selected + 1) % block_options.size()
		_refresh_hud()
	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		selected = (selected - 1 + block_options.size()) % block_options.size()
		_refresh_hud()
	elif event.button_index == MOUSE_BUTTON_RIGHT and rig != null:
		var hit := _aim()
		if hit.is_empty():
			return
		var cell: Vector3i = hit["cell"] + hit["normal"]
		if not world.in_bounds(cell):
			return
		if db.is_solid(world.get_block(cell)):
			return
		var place_at := Vector3(cell) + Vector3(0.5, 0.5, 0.5)
		if place_at.distance_to(rig.camera.global_position) < 0.9:
			return
		world.set_block(cell, block_options[selected])


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if event.keycode == KEY_F:
		_place_unit()
		return
	if event.keycode == KEY_G:
		_remove_last_unit()
		return
	var index := -1
	if event.keycode >= KEY_1 and event.keycode <= KEY_9:
		index = event.keycode - KEY_1
	if index >= 0 and index < block_options.size():
		selected = index
		_refresh_hud()


## 在准星指到的地方（或眼前空地上方）放一台预设单位
func _place_unit() -> void:
	if unit_db == null:
		return
	if units.size() >= MAX_UNITS:
		hud.show_message("单位数量上限 %d" % MAX_UNITS)
		return
	var def: Dictionary = unit_db.get_def("feifei")
	if def.is_empty():
		return
	var at := Vector3.ZERO
	var hit := _aim()
	if not hit.is_empty():
		at = (Vector3(hit["cell"]) + Vector3(0.5, 0.5, 0.5)) + Vector3(0, 1.2, 0)
	else:
		at = rig.camera.global_position + rig.look_direction() * 5.0
	at.x = clampf(at.x, 1.0, float(world.size_x) - 2.0)
	at.z = clampf(at.z, 1.0, float(world.size_z) - 2.0)
	var ground := world.surface_height(floori(at.x), floori(at.z))
	_spawn_unit(def, Vector3(at.x, float(ground), at.z), DefaultCode.FLYER_SOURCE)
	hud.show_message("放下飞飞（共 %d 台）" % units.size())


func _remove_last_unit() -> void:
	if units.is_empty():
		return
	var entry: Dictionary = units.pop_back()
	var node: Node3D = entry["unit"]
	node.queue_free()
	hud.show_message("收回一台飞飞（剩 %d 台）" % units.size())


func _update_unit_hud() -> void:
	if hud == null or units.is_empty():
		return
	var entry: Dictionary = units[units.size() - 1]
	var flyer: Flyer = entry["unit"]
	var controller: UnitController = entry["controller"]
	var text := "单位 %d 台 ｜ %s  高度 %.1f 米  电量 %.0f%%" % [units.size(), flyer.display_name, flyer.global_position.y - float(world.surface_height(floori(flyer.global_position.x), floori(flyer.global_position.z))), flyer.energy_j / flyer.energy_max * 100.0]
	if controller.halted():
		text += "\n代码出错：%s" % controller.last_error()
	hud.set_info(text)


func _refresh_hud() -> void:
	if hud == null:
		return
	var def := db.get_def(block_options[selected])
	hud.set_block_name("手持：%s（%d/%d）" % [def.display_name if def != null else "?", selected + 1, block_options.size()])
