extends Node3D

const BlockDB = preload("res://scripts/block_db.gd")
const TerrainGenerator = preload("res://scripts/terrain_generator.gd")
const VoxelChunk = preload("res://scripts/chunk.gd")
const SidePanelUi = preload("res://scripts/side_panel.gd")

const LOAD_R := 4
const LOAD_V := 3
const UNLOAD_R := 6
const UNLOAD_V := 5
const FRAME_BUDGET_MS := 12
const MAX_BUILDS_PER_FRAME := 6

var db: BlockDB = null
var terrain: TerrainGenerator = null
var chunks_root: Node3D
var machines: Node3D
var _grounds := {}
var loaded := {}
var queue: Array[Vector3i] = []
var chunks_loaded := 0
var chunks_queued := 0
var _center := Vector3i(999999, 999999, 999999)
var _player: Node3D
var _env: Environment
var _announced := false
var _block_cursor: MeshInstance3D


func _ready() -> void:
	db = BlockDB.new()
	db.load_dir("res://data/blocks")
	terrain = TerrainGenerator.new()
	terrain.setup(db, "res://data/world.json")
	print("已加载方块: ", ", ".join(db.names()))
	_build_environment()
	_build_sun()
	chunks_root = Node3D.new()
	chunks_root.name = "Chunks"
	add_child(chunks_root)
	_player = get_node("Player")
	var spawn_h := terrain.height_at(8, 8)
	_player.position = Vector3(8.5, spawn_h + 14.0, 8.5)
	_refresh_queue(true)
	_preload_around_player()
	machines = Node3D.new()
	machines.name = "Machines"
	add_child(machines)
	var charges := preload("res://scripts/charge_net.gd").new()
	charges.name = "ChargeNet"
	add_child(charges)
	_block_cursor = _make_block_cursor()
	add_child(_block_cursor)
	var panel := SidePanelUi.new()
	panel.name = "SidePanel"
	panel.setup(terrain, _player)
	add_child(panel)


func _process(_delta: float) -> void:
	_refresh_queue(false)
	var started := Time.get_ticks_msec()
	var built := 0
	while not queue.is_empty() and built < MAX_BUILDS_PER_FRAME and (built == 0 or Time.get_ticks_msec() - started < FRAME_BUDGET_MS):
		var coord: Vector3i = queue.pop_front()
		if loaded.has(coord):
			continue
		if not _in_range(coord, _center, LOAD_R, LOAD_V):
			continue
		_build_chunk(coord)
		built += 1
	chunks_loaded = loaded.size()
	chunks_queued = queue.size()
	_update_sky()
	if queue.is_empty() and chunks_loaded > 0 and not _announced:
		_announced = true
		print("周围地形已生成，区块 ", chunks_loaded)


func _preload_around_player() -> void:
	var center := _player_chunk()
	var immediate: Array[Vector3i] = []
	for dy in range(-1, 2):
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				var coord := center + Vector3i(dx, dy, dz)
				if _chunk_y_ok(coord.y):
					immediate.append(coord)
	immediate.sort_custom(func(a, b): return a.distance_squared_to(center) < b.distance_squared_to(center))
	for coord in immediate:
		if not loaded.has(coord):
			_build_chunk(coord)
		var idx := queue.find(coord)
		if idx >= 0:
			queue.remove_at(idx)
	chunks_loaded = loaded.size()
	chunks_queued = queue.size()


func _refresh_queue(force: bool) -> void:
	var center := _player_chunk()
	if not force and center == _center:
		return
	_center = center
	var remove: Array[Vector3i] = []
	for key in loaded.keys():
		if not _in_range(key, center, UNLOAD_R, UNLOAD_V):
			remove.append(key)
	for key in remove:
		var dropped: Vector3i = key
		loaded[key].queue_free()
		loaded.erase(key)
		_drop_ground(dropped.x, dropped.z)
	var needed: Array[Vector3i] = []
	for dy in range(-LOAD_V, LOAD_V + 1):
		for dz in range(-LOAD_R, LOAD_R + 1):
			for dx in range(-LOAD_R, LOAD_R + 1):
				var coord := center + Vector3i(dx, dy, dz)
				if _chunk_y_ok(coord.y) and not loaded.has(coord):
					needed.append(coord)
	needed.sort_custom(func(a, b): return a.distance_squared_to(center) < b.distance_squared_to(center))
	queue = needed


func _build_chunk(coord: Vector3i) -> void:
	var chunk = VoxelChunk.new()
	chunk.setup(coord, terrain.build_chunk(coord))
	chunks_root.add_child(chunk)
	loaded[coord] = chunk
	_ensure_ground(coord.x, coord.z)


func _ensure_ground(cx: int, cz: int) -> void:
	var key := Vector2i(cx, cz)
	if _grounds.has(key):
		return
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 3
	var ground_mat := PhysicsMaterial.new()
	ground_mat.friction = 1.0
	ground_mat.rough = false
	ground_mat.bounce = 0.0
	body.physics_material_override = ground_mat
	body.position = Vector3.ZERO
	var mesh_shape := ConcavePolygonShape3D.new()
	mesh_shape.data = terrain.collision_faces(cx, cz)
	var mesh_col := CollisionShape3D.new()
	mesh_col.shape = mesh_shape
	body.add_child(mesh_col)
	chunks_root.add_child(body)
	_grounds[key] = body


func _drop_ground(cx: int, cz: int) -> void:
	for key in loaded.keys():
		var coord: Vector3i = key
		if coord.x == cx and coord.z == cz:
			return
	var column := Vector2i(cx, cz)
	if not _grounds.has(column):
		return
	var body: StaticBody3D = _grounds[column]
	body.queue_free()
	_grounds.erase(column)


func _player_chunk() -> Vector3i:
	var p := _player.global_position
	return Vector3i(
		floori(p.x / float(TerrainGenerator.CHUNK_SIZE)),
		floori(p.y / float(TerrainGenerator.CHUNK_SIZE)),
		floori(p.z / float(TerrainGenerator.CHUNK_SIZE))
	)


func _chunk_y_ok(cy: int) -> bool:
	var min_cy := floori(float(terrain.bedrock_floor_y) / float(TerrainGenerator.CHUNK_SIZE))
	var max_cy := floori(float(terrain.max_y) / float(TerrainGenerator.CHUNK_SIZE))
	return cy >= min_cy and cy <= max_cy


func _in_range(coord: Vector3i, center: Vector3i, rh: int, rv: int) -> bool:
	var d := coord - center
	return absi(d.x) <= rh and absi(d.z) <= rh and absi(d.y) <= rv


func _build_environment() -> void:
	_env = Environment.new()
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.36, 0.58, 0.95)
	sky_mat.sky_horizon_color = Color(0.64, 0.78, 0.95)
	sky_mat.ground_bottom_color = Color(0.18, 0.22, 0.14)
	sky_mat.ground_horizon_color = Color(0.55, 0.64, 0.58)
	sky_mat.sun_angle_max = 28.0
	sky_mat.sun_curve = 0.12
	sky.sky_material = sky_mat
	_env.background_mode = Environment.BG_SKY
	_env.sky = sky
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	_env.ambient_light_energy = 0.18
	_env.ambient_light_sky_contribution = 0.85
	_env.tonemap_mode = Environment.TONE_MAPPER_ACES
	_env.tonemap_exposure = 0.92
	_env.ssao_enabled = true
	_env.ssao_radius = 1.1
	_env.ssao_intensity = 2.6
	_env.ssao_power = 1.5
	_env.ssao_detail = 0.55
	_env.ssao_horizon = 0.1
	_env.glow_enabled = true
	_env.glow_intensity = 0.22
	_env.glow_strength = 0.45
	_env.glow_bloom = 0.04
	_env.glow_hdr_threshold = 1.35
	_env.glow_hdr_scale = 1.2
	_env.adjustment_enabled = true
	_env.adjustment_contrast = 1.1
	_env.adjustment_saturation = 1.16
	_env.fog_enabled = true
	_env.fog_mode = Environment.FOG_MODE_DEPTH
	_env.fog_depth_begin = 150.0
	_env.fog_depth_end = 300.0
	_env.fog_light_color = Color(0.62, 0.74, 0.9)
	_env.fog_aerial_perspective = 0.18
	var env_node := WorldEnvironment.new()
	env_node.environment = _env
	add_child(env_node)


func _build_sun() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, -28, 0)
	sun.light_energy = 1.25
	sun.light_angular_distance = 0.55
	sun.light_color = Color(1.0, 0.93, 0.78)
	sun.shadow_enabled = true
	sun.shadow_blur = 1.8
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_blend_splits = true
	sun.directional_shadow_max_distance = 180.0
	sun.shadow_bias = 0.03
	sun.shadow_normal_bias = 0.25
	add_child(sun)


func _update_sky() -> void:
	if _player == null:
		return
	var y := _player.global_position.y
	var t := clampf((12.0 - y) / 48.0, 0.0, 1.0)
	var sky_fog := Color(0.66, 0.76, 0.88)
	var cave_fog := Color(0.04, 0.035, 0.04)
	_env.fog_light_color = sky_fog.lerp(cave_fog, t)
	_env.ambient_light_energy = lerpf(0.18, 0.04, t)
	if y < 6.0:
		_env.background_mode = Environment.BG_COLOR
		_env.background_color = _env.fog_light_color
	else:
		_env.background_mode = Environment.BG_SKY


func aim_blocks(camera: Camera3D, erase: bool) -> void:
	if _block_cursor == null:
		return
	var hit := _ground_hit(camera)
	if hit.is_empty():
		_block_cursor.visible = false
		return
	var collider: Object = hit.get("collider")
	if collider is Node and (collider as Node).is_in_group("world_pad"):
		var pad := collider as Node3D
		_block_cursor.visible = true
		_block_cursor.position = pad.global_position
		return
	var cell := _face_cell(hit, erase)
	_block_cursor.visible = true
	_block_cursor.position = terrain.cell_center(cell)


func hide_block_aim() -> void:
	if _block_cursor != null:
		_block_cursor.visible = false


func paint_block(camera: Camera3D, spec: Dictionary) -> void:
	var hit := _ground_hit(camera)
	if hit.is_empty():
		return
	var collider: Object = hit.get("collider")
	if collider is Node and (collider as Node).is_in_group("world_pad"):
		var pad := collider as Node
		if bool(spec.get("erase", false)):
			pad.queue_free()
		else:
			pad.call("cycle")
		return
	if bool(spec.get("pad", false)):
		_place_world_pad(hit)
		return
	var erase := bool(spec.get("erase", false))
	var cell := _face_cell(hit, erase)
	if erase:
		if not terrain.is_solid_cell(cell):
			return
		terrain.clear_cell(cell)
	else:
		if terrain.is_solid_cell(cell):
			return
		terrain.set_cell(cell, int(spec.get("id", 1)))
	var c := terrain.cell_center(cell)
	_refresh_edit(c.x, c.z, c.y)


func _face_cell(hit: Dictionary, erase: bool) -> Vector3i:
	var normal: Vector3 = hit.get("normal", Vector3.UP)
	var point: Vector3 = hit.get("position", Vector3.ZERO)
	# 用真实法线探进面内侧，避免斜面吸附到错格
	var inward := normal.normalized() * 0.02
	var inside := terrain.world_to_cell(point - inward)
	if erase:
		return inside
	var n := _snap_face_normal(normal)
	var outside := inside + n
	var above := inside + Vector3i(0, 1, 0)
	# 平地单格会收成锥：斜面法线偏水平，外侧常落到邻格；朝上点时优先叠高
	if normal.y > 0.2 and not terrain.is_solid_cell(above):
		if n.y > 0 or terrain.is_solid_cell(outside) or normal.y >= maxf(absf(normal.x), absf(normal.z)):
			return above
	return outside


func _snap_face_normal(normal: Vector3) -> Vector3i:
	var ax := absf(normal.x)
	var ay := absf(normal.y)
	var az := absf(normal.z)
	# 略偏向上下，锥面/缓坡更容易叠高
	if ay >= ax * 0.75 and ay >= az * 0.75:
		return Vector3i(0, 1 if normal.y >= 0.0 else -1, 0)
	if ax >= az:
		return Vector3i(1 if normal.x >= 0.0 else -1, 0, 0)
	return Vector3i(0, 0, 1 if normal.z >= 0.0 else -1)


func _place_world_pad(hit: Dictionary) -> void:
	var normal: Vector3 = hit.get("normal", Vector3.UP)
	var point: Vector3 = hit.get("position", Vector3.ZERO) + normal * 0.125
	for node in get_tree().get_nodes_in_group("world_pad"):
		if node is Node3D and (node as Node3D).global_position.distance_to(point) < 0.2:
			node.call("cycle")
			return
	var pad := preload("res://scripts/world_pad.gd").new()
	pad.position = point
	add_child(pad)


func _ground_hit(camera: Camera3D) -> Dictionary:
	if camera == null:
		return {}
	var mouse := camera.get_viewport().get_mouse_position()
	var from := camera.project_ray_origin(mouse)
	var to := from + camera.project_ray_normal(mouse) * 240.0
	var query := PhysicsRayQueryParameters3D.create(from, to, 1)
	return camera.get_world_3d().direct_space_state.intersect_ray(query)


func rebuild_loaded_meshes() -> void:
	var keys: Array = loaded.keys()
	for coord in keys:
		var chunk: MeshInstance3D = loaded[coord]
		var built: Dictionary = terrain.build_chunk(coord)
		chunk.mesh = built.mesh
		chunk.set("blocks", built.blocks)
	var ground_keys: Array = _grounds.keys()
	for key in ground_keys:
		var old: StaticBody3D = _grounds[key]
		_grounds.erase(key)
		old.free()
		_ensure_ground(key.x, key.y)


func _refresh_edit(x: float, z: float, hy: float) -> void:
	var min_cx := floori((x - 1.0) / 16.0)
	var max_cx := floori((x + 1.0) / 16.0)
	var min_cz := floori((z - 1.0) / 16.0)
	var max_cz := floori((z + 1.0) / 16.0)
	var min_cy := floori((hy - 2.0) / 16.0)
	var max_cy := floori((hy + 2.0) / 16.0)
	for cz in range(min_cz, max_cz + 1):
		for cx in range(min_cx, max_cx + 1):
			var key := Vector2i(cx, cz)
			if _grounds.has(key):
				var old: StaticBody3D = _grounds[key]
				_grounds.erase(key)
				old.free()
			_ensure_ground(cx, cz)
			for cy in range(min_cy, max_cy + 1):
				var coord := Vector3i(cx, cy, cz)
				if not loaded.has(coord):
					continue
				var chunk: MeshInstance3D = loaded[coord]
				var built: Dictionary = terrain.build_chunk(coord)
				chunk.mesh = built.mesh
				chunk.set("blocks", built.blocks)


func _make_block_cursor() -> MeshInstance3D:
	var mesh := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.16, 0.12)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var s := 0.25
	var p := [
		Vector3(-s, -s, -s), Vector3(s, -s, -s), Vector3(s, s, -s), Vector3(-s, s, -s),
		Vector3(-s, -s, s), Vector3(s, -s, s), Vector3(s, s, s), Vector3(-s, s, s),
	]
	var edges := [0, 1, 1, 2, 2, 3, 3, 0, 4, 5, 5, 6, 6, 7, 7, 4, 0, 4, 1, 5, 2, 6, 3, 7]
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	for i in range(0, edges.size(), 2):
		mesh.surface_add_vertex(p[edges[i]])
		mesh.surface_add_vertex(p[edges[i + 1]])
	mesh.surface_end()
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	inst.visible = false
	return inst
