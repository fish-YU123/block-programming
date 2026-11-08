extends Node3D
## 游戏入口：搭建世界、相机、HUD 与方块交互。

const BlockDB = preload("res://scripts/world/block_db.gd")
const VoxelWorld = preload("res://scripts/world/voxel_world.gd")
const CameraRig = preload("res://scripts/player/camera_rig.gd")
const Hud = preload("res://scripts/ui/hud.gd")

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
	if not world.is_buildable(cell):
		hud.show_message("中立区不能建造或破坏")
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
		if not world.is_buildable(cell):
			hud.show_message("中立区不能建造或破坏")
			return
		world.set_block(cell, block_options[selected])


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	var index := -1
	if event.keycode >= KEY_1 and event.keycode <= KEY_9:
		index = event.keycode - KEY_1
	if index >= 0 and index < block_options.size():
		selected = index
		_refresh_hud()


func _refresh_hud() -> void:
	if hud == null:
		return
	var def := db.get_def(block_options[selected])
	hud.set_block_name("手持：%s（%d/%d）" % [def.display_name if def != null else "?", selected + 1, block_options.size()])
