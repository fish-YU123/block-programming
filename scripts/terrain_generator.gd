extends RefCounted

const CHUNK_SIZE := 16
const SUB := 2

var db = null
var world := {}
var seed := 0
var min_y := -560
var max_y := 160
var base_height := 52
var min_surface := 16
var dirt_depth := 4
var surface_id := 1
var dirt_id := 2
var stone_id := 3
var lava_id := 6
var bedrock_id := 7
var lava_top_y := -501
var lava_bottom_y := -525
var bedrock_floor_y := -560
var cont_amp := 24.0
var hill_base := 6.0
var hill_extra := 14.0
var detail_amp := 3.2
var ridge_start := 0.68
var ridge_height := 28.0
var bump_start := 0.74
var bump_height := 9.0
var max_ore_radius := 2

var _n_cont := FastNoiseLite.new()
var _n_hill := FastNoiseLite.new()
var _n_detail := FastNoiseLite.new()
var _n_ridge := FastNoiseLite.new()
var _n_bump := FastNoiseLite.new()

var _lit_mat: Material
var _glow_mat: Material
var _edge_mat: Material
var _tops := {}
var _kinds := {}
var _cells := {}
var _hollow := {}
var structure_id := 8
var _catalog_n := 0
var _catalog_bytes := PackedByteArray()
var _bit_perm: Array = []
var _rot_xform: Array = [] # {perm, signs}
var _struct_pos: Array = []
var _hull_store = null
const HullStore = preload("res://scripts/structure_hull_store.gd")
const Hull3D = preload("res://scripts/convex_hull_3d.gd")
# 出生点约 (8.5, 8.5) → 半格坐标 17；3×3 中心对准出生点
const GALLERY_GX0 := 16
const GALLERY_GZ0 := 16
const GALLERY_STRIDE := 4
const GALLERY_ROT_STRIDE := 4


func setup(block_db, world_path: String) -> void:
	db = block_db
	var data = db._read_json(world_path)
	if data == null or not (data is Dictionary):
		push_error("世界配置无法解析: %s" % world_path)
		return
	world = data
	seed = int(world.get("seed", 1))
	min_y = int(world.get("min_y", -560))
	max_y = int(world.get("max_y", 160))
	base_height = int(world.get("base_height", 52))
	min_surface = int(world.get("min_surface", 16))
	dirt_depth = int(world.get("dirt_depth", 4))
	surface_id = db.id_of(str(world.get("surface_block", "grass")))
	dirt_id = db.id_of(str(world.get("subsurface_block", "dirt")))
	stone_id = db.id_of(str(world.get("stone_block", "stone")))
	lava_id = db.id_of(str(world.get("lava_block", "lava")))
	bedrock_id = db.id_of(str(world.get("bedrock_block", "bedrock")))
	structure_id = db.id_of("structure")
	var below := int(world.get("lava_below_y", -500))
	var layers := int(world.get("lava_layers", 25))
	lava_top_y = below - 1
	lava_bottom_y = lava_top_y - layers + 1
	bedrock_floor_y = int(world.get("bedrock_floor_y", min_y))
	var noise: Dictionary = world.get("noise", {})
	var continental: Dictionary = noise.get("continental", {})
	var hills: Dictionary = noise.get("hills", {})
	var detail: Dictionary = noise.get("detail", {})
	var ridge: Dictionary = noise.get("ridge", {})
	var bump: Dictionary = noise.get("bump", {})
	cont_amp = float(continental.get("amplitude", 24))
	hill_base = float(hills.get("base", 6))
	hill_extra = float(hills.get("extra", 14))
	detail_amp = float(detail.get("amplitude", 3.2))
	ridge_start = float(ridge.get("start", 0.68))
	ridge_height = float(ridge.get("height", 28))
	bump_start = float(bump.get("start", 0.74))
	bump_height = float(bump.get("height", 9))
	_configure_noise(_n_cont, float(continental.get("frequency", 0.0015)), int(continental.get("seed_offset", 11)), int(continental.get("octaves", 2)))
	_configure_noise(_n_hill, float(hills.get("frequency", 0.008)), int(hills.get("seed_offset", 29)), 1)
	_configure_noise(_n_detail, float(detail.get("frequency", 0.03)), int(detail.get("seed_offset", 47)), 1)
	_configure_noise(_n_ridge, float(ridge.get("frequency", 0.016)), int(ridge.get("seed_offset", 83)), 1)
	_configure_noise(_n_bump, float(bump.get("frequency", 0.045)), int(bump.get("seed_offset", 97)), 1)
	max_ore_radius = 1
	for ore in db.ores:
		max_ore_radius = maxi(max_ore_radius, int(ore.radius_max))
	_lit_mat = _make_lit_material()
	_glow_mat = _make_glow_material()
	_edge_mat = _make_edge_material()
	_init_structure_math()
	_load_structure_catalog()
	reload_structure_hulls()


func reload_structure_hulls() -> void:
	_hull_store = HullStore.new()
	_hull_store.load_all()
	# 64 种邻接凸包只在这里算一次，网格阶段只查表
	_hull_store.rebuild_tris_cache(
		_struct_pos,
		_bit_perm.size(),
		func(m: int, r: int) -> int: return _rotate_mask(m, r),
		func(p: Vector3i, r: int) -> Vector3i: return _rotate_local_cell(p, r)
	)


func height_at(x: int, z: int) -> int:
	return clampi(int(round(height_float(x, z))), min_surface, max_y - 1)


func world_to_cell(p: Vector3) -> Vector3i:
	return Vector3i(floori(p.x / 0.5), floori(p.y / 0.5), floori(p.z / 0.5))


func cell_center(g: Vector3i) -> Vector3:
	return Vector3((float(g.x) + 0.5) * 0.5, (float(g.y) + 0.5) * 0.5, (float(g.z) + 0.5) * 0.5)


func surface_at_world(x: float, z: float) -> float:
	var gx := floori(x / 0.5)
	var gz := floori(z / 0.5)
	var col := Vector2i(gx, gz)
	if _hollow.has(col):
		return _column_top_from_cells(gx, gz)
	if _tops.has(col):
		var top := float(_tops[col])
		var extra := _column_extra_top(gx, gz, top)
		return maxf(top, extra)
	var cx := (float(gx) + 0.5) * 0.5
	var cz := (float(gz) + 0.5) * 0.5
	var natural := _natural_surface(cx, cz)
	return maxf(natural, _column_extra_top(gx, gz, natural))


func _natural_surface(x: float, z: float) -> float:
	var stepped: float = round(height_float(x, z) * 2.0) / 2.0
	return clampf(stepped, float(min_surface), float(max_y - 1))


func surface_at(x: int, z: int) -> float:
	return surface_at_world(float(x) + 0.001, float(z) + 0.001)


func cell_kind(x: float, z: float) -> int:
	var key := Vector2i(floori(x / 0.5), floori(z / 0.5))
	if _kinds.has(key):
		return int(_kinds[key])
	return 0


func is_structure_block(block_id: int) -> bool:
	if block_id <= 0 or not db.has_id(block_id):
		return false
	if block_id == structure_id:
		return true
	var def = db.get_def(block_id)
	return def.tags.has("structure") or str(def.props.get("mesh", "")) == "edges"


func is_smooth_block(block_id: int) -> bool:
	if block_id <= 0 or not db.has_id(block_id):
		return false
	if is_structure_block(block_id):
		return false
	var def = db.get_def(block_id)
	return def.tags.has("terrain") or def.tags.has("soil") or def.tags.has("stone")


func get_cell(g: Vector3i) -> int:
	if _cells.has(g):
		return int(_cells[g])
	var col := Vector2i(g.x, g.z)
	if _hollow.has(col):
		return 0
	var gallery := _gallery_cell(g)
	if gallery >= 0:
		return gallery
	return _natural_cell(g)


func is_solid_cell(g: Vector3i) -> bool:
	var id := get_cell(g)
	if id <= 0:
		return false
	if not db.has_id(id):
		return false
	return db.get_def(id).solid


func set_cell(g: Vector3i, block_id: int) -> void:
	if block_id <= 0:
		clear_cell(g)
		return
	if is_structure_block(block_id) or not is_smooth_block(block_id):
		_cells[g] = block_id
		return
	var col := Vector2i(g.x, g.z)
	var top := surface_at_world((float(g.x) + 0.5) * 0.5, (float(g.z) + 0.5) * 0.5)
	var top_gy := floori((top - 0.001) / 0.5)
	if not _hollow.has(col) and g.y == top_gy + 1:
		var next := (float(g.y) + 1.0) * 0.5
		paint_cell((float(g.x) + 0.5) * 0.5, (float(g.z) + 0.5) * 0.5, next, block_id)
		return
	_cells[g] = block_id


func clear_cell(g: Vector3i) -> void:
	if _cells.has(g):
		_cells.erase(g)
		return
	var gallery := _gallery_cell(g)
	if gallery > 0:
		_cells[g] = 0
		return
	var col := Vector2i(g.x, g.z)
	if _hollow.has(col):
		return
	if not is_solid_cell(g):
		return
	var top := surface_at_world((float(g.x) + 0.5) * 0.5, (float(g.z) + 0.5) * 0.5)
	var top_gy := floori((top - 0.001) / 0.5)
	if g.y == top_gy:
		var next := float(g.y) * 0.5
		paint_cell((float(g.x) + 0.5) * 0.5, (float(g.z) + 0.5) * 0.5, next, 0)
		return
	_voxelize_column(g.x, g.z, g)


func _voxelize_column(gx: int, gz: int, except: Vector3i) -> void:
	var col := Vector2i(gx, gz)
	var top := surface_at_world((float(gx) + 0.5) * 0.5, (float(gz) + 0.5) * 0.5)
	var top_gy := floori((top - 0.001) / 0.5)
	var bed_gy := floori(float(bedrock_floor_y) / 0.5)
	var kind := cell_kind((float(gx) + 0.5) * 0.5, (float(gz) + 0.5) * 0.5)
	_hollow[col] = true
	_tops.erase(col)
	_kinds.erase(col)
	for gy in range(bed_gy, top_gy + 1):
		var g := Vector3i(gx, gy, gz)
		if g == except:
			continue
		var id := _natural_cell_raw(gx, gy, gz, top_gy, kind)
		if id > 0:
			_cells[g] = id


func _natural_cell(g: Vector3i) -> int:
	var cx := (float(g.x) + 0.5) * 0.5
	var cz := (float(g.z) + 0.5) * 0.5
	var top := _column_heightmap_top(g.x, g.z)
	var top_gy := floori((top - 0.001) / 0.5)
	var kind := cell_kind(cx, cz)
	return _natural_cell_raw(g.x, g.y, g.z, top_gy, kind)


func _natural_cell_raw(gx: int, gy: int, gz: int, top_gy: int, kind: int) -> int:
	if gy > top_gy:
		return 0
	var y_block := gy
	# map half-block gy to old integer height model approximately
	var h := top_gy
	if gy == h:
		return kind if kind > 0 else surface_id
	var dirt_n := dirt_depth * 2
	if gy >= h - dirt_n:
		return dirt_id
	if gy * 0.5 <= float(lava_top_y):
		if gy * 0.5 < float(lava_bottom_y):
			return bedrock_id
		return lava_id
	return stone_id


func _column_heightmap_top(gx: int, gz: int) -> float:
	var col := Vector2i(gx, gz)
	if _tops.has(col):
		return float(_tops[col])
	return _natural_surface((float(gx) + 0.5) * 0.5, (float(gz) + 0.5) * 0.5)


func _column_top_from_cells(gx: int, gz: int) -> float:
	var best := float(bedrock_floor_y)
	for key in _cells.keys():
		var g: Vector3i = key
		if g.x != gx or g.z != gz:
			continue
		if int(_cells[g]) <= 0:
			continue
		best = maxf(best, (float(g.y) + 1.0) * 0.5)
	return best


func _column_extra_top(gx: int, gz: int, base_top: float) -> float:
	var best := base_top
	var base_gy := floori((base_top - 0.001) / 0.5)
	for key in _cells.keys():
		var g: Vector3i = key
		if g.x != gx or g.z != gz:
			continue
		var id := int(_cells[g])
		if id <= 0 or is_structure_block(id):
			continue
		if not is_smooth_block(id):
			continue
		if g.y <= base_gy:
			continue
		# only raise smooth surface for contiguous stack on top
		if g.y == base_gy + 1 or g.y <= floori((best - 0.001) / 0.5) + 1:
			best = maxf(best, (float(g.y) + 1.0) * 0.5)
	return best


func paint_cell(x: float, z: float, height: float, block_id: int) -> void:
	var gx := floori(x / 0.5)
	var gz := floori(z / 0.5)
	var key := Vector2i(gx, gz)
	if _hollow.has(key):
		_hollow.erase(key)
	var cx := (float(gx) + 0.5) * 0.5
	var cz := (float(gz) + 0.5) * 0.5
	var natural := _natural_surface(cx, cz)
	var next := clampf(height, float(bedrock_floor_y), float(max_y - 1))
	if absf(next - natural) < 0.001 and block_id <= 0:
		_tops.erase(key)
		_kinds.erase(key)
		return
	_tops[key] = next
	if block_id > 0:
		_kinds[key] = block_id
	else:
		_kinds.erase(key)


func column_has_edit(cx: int, cz: int) -> bool:
	var x0 := float(cx * CHUNK_SIZE)
	var z0 := float(cz * CHUNK_SIZE)
	var x1 := x0 + float(CHUNK_SIZE)
	var z1 := z0 + float(CHUNK_SIZE)
	for key in _tops.keys():
		var cell: Vector2i = key
		var wx := (float(cell.x) + 0.5) * 0.5
		var wz := (float(cell.y) + 0.5) * 0.5
		if wx >= x0 and wx < x1 and wz >= z0 and wz < z1:
			return true
	for key in _cells.keys():
		var g: Vector3i = key
		var wx2 := (float(g.x) + 0.5) * 0.5
		var wz2 := (float(g.z) + 0.5) * 0.5
		if wx2 >= x0 and wx2 < x1 and wz2 >= z0 and wz2 < z1:
			return true
	return false


func collision_faces(cx: int, cz: int) -> PackedVector3Array:
	var tris := surface_triangles(float(cx * CHUNK_SIZE), float(cz * CHUNK_SIZE), CHUNK_SIZE * SUB, -100000.0, 100000.0)
	_append_voxel_collision(tris, cx, cz)
	return tris


func height_float(x: float, z: float) -> float:
	var cont := _n_cont.get_noise_2d(x, z)
	var hill := _n_hill.get_noise_2d(x, z)
	var detail := _n_detail.get_noise_2d(x, z)
	var hill_scale := hill_base + hill_extra * clampf(cont * 0.5 + 0.5, 0.0, 1.0)
	var h := float(base_height) + cont * absf(cont) * cont_amp + hill * hill_scale + detail * detail_amp
	var ridge := maxf(_n_ridge.get_noise_2d(x, z), 0.0)
	if ridge > ridge_start:
		var ridge_t := (ridge - ridge_start) / maxf(0.001, 1.0 - ridge_start)
		h += pow(ridge_t, 1.35) * ridge_height
	var bump := _n_bump.get_noise_2d(x, z)
	if bump > bump_start:
		h += pow((bump - bump_start) / maxf(0.001, 1.0 - bump_start), 1.4) * bump_height
	return clampf(h, float(min_surface), float(max_y - 1))


func base_block(x: int, y: int, z: int) -> int:
	return _block_at_height(y, height_at(x, z))


func _block_at_height(y: int, h: int) -> int:
	if y > max_y or y < bedrock_floor_y:
		return db.AIR_ID
	if y < lava_bottom_y:
		return bedrock_id
	if y <= lava_top_y:
		return lava_id
	if y > h:
		return db.AIR_ID
	if y == h:
		return surface_id
	if y >= h - dirt_depth:
		return dirt_id
	return stone_id


func build_chunk(coord: Vector3i) -> Dictionary:
	var origin := coord * CHUNK_SIZE
	var empty := PackedByteArray()
	var y0 := float(origin.y)
	var y1 := float(origin.y + CHUNK_SIZE)
	var min_h := 100000.0
	var max_h := -100000.0
	for z in range(0, CHUNK_SIZE + 1, 2):
		for x in range(0, CHUNK_SIZE + 1, 2):
			var h := float(height_at(origin.x + x, origin.z + z))
			min_h = minf(min_h, h)
			max_h = maxf(max_h, h)
	var surface := max_h >= y0 and min_h < y1
	var lava_y := float(lava_top_y + 1)
	var lava := lava_y >= y0 and lava_y < y1
	var has_voxels := _chunk_has_voxels(origin, y0, y1)
	if not surface and not lava and not has_voxels:
		return {"mesh": null, "blocks": empty}
	var mesh := _build_smooth(origin, y0, y1, surface, lava, lava_y)
	return {"mesh": mesh, "blocks": empty}


func _build_smooth(origin: Vector3i, y0: float, y1: float, surface: bool, lava: bool, lava_y: float) -> ArrayMesh:
	var lit_v := PackedVector3Array()
	var lit_n := PackedVector3Array()
	var lit_c := PackedColorArray()
	var lit_i := PackedInt32Array()
	var glow_v := PackedVector3Array()
	var glow_n := PackedVector3Array()
	var glow_c := PackedColorArray()
	var glow_i := PackedInt32Array()
	var edge_v := PackedVector3Array()
	if surface:
		var ores := _collect_surface_ores(origin)
		_add_center_corner_surface(origin, y0, y1, ores, lit_v, lit_n, lit_c, lit_i)
	if lava:
		var lava_color: Color = db.get_def(lava_id).color_top
		var cells_l := CHUNK_SIZE * SUB
		var step_l := 1.0 / float(SUB)
		var local_y := lava_y - float(origin.y)
		for gz in cells_l:
			for gx in cells_l:
				var x0 := float(gx) * step_l
				var z0 := float(gz) * step_l
				var corners_l := [
					Vector3(x0, local_y, z0),
					Vector3(x0 + step_l, local_y, z0),
					Vector3(x0 + step_l, local_y, z0 + step_l),
					Vector3(x0, local_y, z0 + step_l),
				]
				var up := Vector3.UP
				var colors_l: Array[Color] = []
				for corner in corners_l:
					var wx: float = float(origin.x) + corner.x
					var wz: float = float(origin.z) + corner.z
					var wobble := 0.92 + 0.16 * absf(sin(wx * 0.37) * cos(wz * 0.29))
					colors_l.append(lava_color * wobble)
				var normals_l := [up, up, up, up]
				_add_smooth_quad(glow_v, glow_n, glow_c, glow_i, corners_l, normals_l, colors_l)
	_add_voxel_meshes(origin, y0, y1, lit_v, lit_n, lit_c, lit_i, edge_v)
	if lit_v.is_empty() and glow_v.is_empty() and edge_v.is_empty():
		return null
	var mesh := ArrayMesh.new()
	if not lit_v.is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _arrays(lit_v, lit_n, lit_c, lit_i))
		mesh.surface_set_material(mesh.get_surface_count() - 1, _lit_mat)
	if not glow_v.is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _arrays(glow_v, glow_n, glow_c, glow_i))
		mesh.surface_set_material(mesh.get_surface_count() - 1, _glow_mat)
	if not edge_v.is_empty():
		var edge_arrays := []
		edge_arrays.resize(Mesh.ARRAY_MAX)
		edge_arrays[Mesh.ARRAY_VERTEX] = edge_v
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, edge_arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, _edge_mat)
	return mesh


func surface_triangles(x0: float, z0: float, cells: int, y0: float, y1: float) -> PackedVector3Array:
	# 自然地表始终连续高度场。自定义凸包只用于放置层/图鉴（悬崖边掩码撞上图鉴时不再撕地形）
	var step := 1.0 / float(SUB)
	var span := cells + 2
	var heights := PackedFloat32Array()
	heights.resize(span * span)
	for gz in range(-1, cells + 1):
		for gx in range(-1, cells + 1):
			var wx := x0 + (float(gx) + 0.5) * step
			var wz := z0 + (float(gz) + 0.5) * step
			heights[(gx + 1) + (gz + 1) * span] = surface_at_world(wx, wz)
	var tris := PackedVector3Array()
	for gz in cells:
		for gx in cells:
			_emit_cell(tris, heights, gx, gz, span, x0, z0, step, y0, y1)
	return tris


func _neighbor_mask(g: Vector3i) -> int:
	# 与结构图鉴同一套六面比特：有实心方块=1（草/石/结构都算）
	var mask := 0
	for i in _struct_pos.size():
		var off: Vector3i = _struct_pos[i] - Vector3i(1, 1, 1)
		if is_solid_cell(g + off):
			mask |= 1 << i
	return mask


func _append_cached_hull_tris(tris: PackedVector3Array, g: Vector3i, mask: int, y0: float, y1: float, occlude_smooth: bool = true) -> void:
	if _hull_store == null:
		return
	var local_tris: PackedVector3Array = _hull_store.get_cached_tris(mask)
	var origin := Vector3(float(g.x), float(g.y), float(g.z)) * 0.5
	for i in range(0, local_tris.size(), 3):
		var la: Vector3 = local_tris[i]
		var lb: Vector3 = local_tris[i + 1]
		var lc: Vector3 = local_tris[i + 2]
		var n: Vector3 = (lb - la).cross(lc - la)
		if n.length_squared() < 1e-12:
			continue
		n = n.normalized()
		# 贴着不透明实心邻格的面不画（结构线框不挡）；自定义凸包时草也不挡（与图鉴一致）
		if _hull_face_occluded_at(n, g, occlude_smooth):
			continue
		var a: Vector3 = la + origin
		var b: Vector3 = lb + origin
		var c: Vector3 = lc + origin
		var mid := (a + b + c) / 3.0
		if mid.y < y0 or mid.y >= y1:
			continue
		tris.append(a)
		tris.append(b)
		tris.append(c)


func _hull_face_occluded_at(n: Vector3, g: Vector3i, occlude_smooth: bool = true) -> bool:
	var dir := Vector3i.ZERO
	var ax := absf(n.x)
	var ay := absf(n.y)
	var az := absf(n.z)
	if ax >= ay and ax >= az:
		if absf(n.x) < 0.35:
			return false
		dir = Vector3i(1 if n.x > 0.0 else -1, 0, 0)
	elif ay >= ax and ay >= az:
		if absf(n.y) < 0.35:
			return false
		dir = Vector3i(0, 1 if n.y > 0.0 else -1, 0)
	else:
		if absf(n.z) < 0.35:
			return false
		dir = Vector3i(0, 0, 1 if n.z > 0.0 else -1)
	var ng := g + dir
	var id := get_cell(ng)
	if id <= 0 or not db.has_id(id):
		return false
	if is_structure_block(id):
		return false
	if is_smooth_block(id) and not occlude_smooth:
		return false
	var def = db.get_def(id)
	return def.solid and def.opaque


func _layer_built(kind: int, natural_h: float, surface_h: float, block_top: float) -> bool:
	if kind <= 0:
		return false
	if block_top > natural_h + 0.001:
		return true
	return absf(block_top - surface_h) <= 0.001


func _grid_h(heights: PackedFloat32Array, gx: int, gz: int, span: int) -> float:
	return heights[(gx + 1) + (gz + 1) * span]


func _is_one_step_lower(own: float, nh: float, step: float) -> bool:
	return nh < own - 0.001 and own - nh <= step + 0.001


func _corner_y(heights: PackedFloat32Array, gx: int, gz: int, span: int, vx: int, vz: int, own: float, step: float) -> float:
	# 顶点周围4格决定角高；所有同高格结果一致 → 无白缝
	# 布局  h01 h11
	#       h00 h10
	var h00 := _grid_h(heights, vx - 1, vz - 1, span)
	var h10 := _grid_h(heights, vx, vz - 1, span)
	var h01 := _grid_h(heights, vx - 1, vz, span)
	var h11 := _grid_h(heights, vx, vz, span)
	var hi := maxf(maxf(h00, h10), maxf(h01, h11))
	# 矮侧台地：绝不被高柱拉高
	if own < hi - 0.001:
		return own
	# 本格在最高层：与「不超过矮1格」的邻格取最低，保证共边一致（地面无缝）
	var y := hi
	var near := 0
	for h in [h00, h10, h01, h11]:
		if h >= hi - step - 0.001:
			near += 1
			y = minf(y, h)
	# 只有本格触及该顶点的最高层 → 降1格做锥顶
	if near <= 1:
		return hi - step
	return y


func _corner_y_voxel(heights: PackedFloat32Array, gx: int, gz: int, span: int, vx: int, vz: int, own: float, step: float) -> float:
	# 浮空体素层：同高实心（含结构块）共角保持最高，否则会收成锥
	var h00 := _grid_h(heights, vx - 1, vz - 1, span)
	var h10 := _grid_h(heights, vx, vz - 1, span)
	var h01 := _grid_h(heights, vx - 1, vz, span)
	var h11 := _grid_h(heights, vx, vz, span)
	var hi := maxf(maxf(h00, h10), maxf(h01, h11))
	if own < hi - 0.001:
		return own
	var at_hi := 0
	for h in [h00, h10, h01, h11]:
		if h >= hi - 0.001:
			at_hi += 1
	if at_hi >= 2:
		return hi
	return hi - step


func _emit_cell(tris: PackedVector3Array, heights: PackedFloat32Array, gx: int, gz: int, span: int, x0: float, z0: float, step: float, y0: float, y1: float, voxel_mode: bool = false) -> void:
	var h := _grid_h(heights, gx, gz, span)
	var xa := x0 + float(gx) * step
	var za := z0 + float(gz) * step
	var he := _grid_h(heights, gx + 1, gz, span)
	var hw := _grid_h(heights, gx - 1, gz, span)
	var hn := _grid_h(heights, gx, gz + 1, span)
	var hs := _grid_h(heights, gx, gz - 1, span)
	var sw := Vector3(xa, _corner_at(heights, gx, gz, span, gx, gz, h, step, voxel_mode), za)
	var se := Vector3(xa + step, _corner_at(heights, gx, gz, span, gx + 1, gz, h, step, voxel_mode), za)
	var ne := Vector3(xa + step, _corner_at(heights, gx, gz, span, gx + 1, gz + 1, h, step, voxel_mode), za + step)
	var nw := Vector3(xa, _corner_at(heights, gx, gz, span, gx, gz + 1, h, step, voxel_mode), za + step)
	var interior := Vector3(xa + step * 0.5, h - 1.0, za + step * 0.5)
	var all_low := sw.y < h - 0.001 and se.y < h - 0.001 and ne.y < h - 0.001 and nw.y < h - 0.001
	if all_low:
		# 顶层四面锥（单放或叠放的最上格）
		var center := Vector3(xa + step * 0.5, h, za + step * 0.5)
		_emit_clipped(tris, center, sw, se, interior, y0, y1)
		_emit_clipped(tris, center, se, ne, interior, y0, y1)
		_emit_clipped(tris, center, ne, nw, interior, y0, y1)
		_emit_clipped(tris, center, nw, sw, interior, y0, y1)
	else:
		var flat := absf(sw.y - se.y) <= 0.001 and absf(se.y - ne.y) <= 0.001 and absf(ne.y - nw.y) <= 0.001
		if flat:
			_emit_clipped(tris, sw, se, ne, interior, y0, y1)
			_emit_clipped(tris, sw, ne, nw, interior, y0, y1)
		else:
			var high_a := sw.y + ne.y
			var high_b := se.y + nw.y
			if high_a >= high_b:
				_emit_clipped(tris, sw, se, ne, interior, y0, y1)
				_emit_clipped(tris, sw, ne, nw, interior, y0, y1)
			else:
				_emit_clipped(tris, sw, se, nw, interior, y0, y1)
				_emit_clipped(tris, se, ne, nw, interior, y0, y1)
	# 墙：从斜面底边（约 own-step 或邻顶）落到邻居顶；1格落差无墙
	var edge_a: Array[Vector3] = [sw, se, ne, nw]
	var edge_b: Array[Vector3] = [se, ne, nw, sw]
	var nhs: Array[float] = [hs, he, hn, hw]
	for s in 4:
		var nh: float = nhs[s]
		if nh >= h - step - 0.001:
			continue
		var ha: Vector3 = edge_a[s]
		var hb: Vector3 = edge_b[s]
		if absf(ha.y - nh) <= 0.001 and absf(hb.y - nh) <= 0.001:
			continue
		var ngx := gx
		var ngz := gz
		var vx0 := gx
		var vz0 := gz
		var vx1 := gx
		var vz1 := gz
		if s == 0:
			ngz = gz - 1
			vx0 = gx
			vx1 = gx + 1
			vz0 = gz
			vz1 = gz
		elif s == 1:
			ngx = gx + 1
			vx0 = gx + 1
			vx1 = gx + 1
			vz0 = gz
			vz1 = gz + 1
		elif s == 2:
			ngz = gz + 1
			vx0 = gx + 1
			vx1 = gx
			vz0 = gz + 1
			vz1 = gz + 1
		else:
			ngx = gx - 1
			vx0 = gx
			vx1 = gx
			vz0 = gz + 1
			vz1 = gz
		var la := Vector3(ha.x, _corner_at(heights, ngx, ngz, span, vx0, vz0, nh, step, voxel_mode), ha.z)
		var lb := Vector3(hb.x, _corner_at(heights, ngx, ngz, span, vx1, vz1, nh, step, voxel_mode), hb.z)
		var wall_in := Vector3(xa + step * 0.5, (ha.y + nh) * 0.5, za + step * 0.5)
		_emit_clipped(tris, ha, hb, lb, wall_in, y0, y1)
		_emit_clipped(tris, ha, lb, la, wall_in, y0, y1)


func _corner_at(heights: PackedFloat32Array, gx: int, gz: int, span: int, vx: int, vz: int, own: float, step: float, voxel_mode: bool) -> float:
	if voxel_mode:
		return _corner_y_voxel(heights, gx, gz, span, vx, vz, own, step)
	return _corner_y(heights, gx, gz, span, vx, vz, own, step)


func _emit_clipped(tris: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3, interior: Vector3, y0: float, y1: float) -> void:
	var mid := (a + b + c) / 3.0
	if mid.y < y0 or mid.y >= y1:
		return
	_add_inward(tris, a, b, c, interior)


func _add_inward(tris: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3, interior: Vector3) -> void:
	var nrm: Vector3 = (b - a).cross(c - a)
	if nrm.length_squared() < 0.0000001:
		return
	if nrm.dot(interior - a) > 0.0:
		tris.append(a)
		tris.append(b)
		tris.append(c)
	else:
		tris.append(a)
		tris.append(c)
		tris.append(b)


func _add_center_corner_surface(origin: Vector3i, y0: float, y1: float, ores: Dictionary, verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array) -> void:
	var cells := CHUNK_SIZE * SUB
	var tris := surface_triangles(float(origin.x), float(origin.z), cells, y0, y1)
	var shift := Vector3(origin)
	for i in range(0, tris.size(), 3):
		var a := tris[i] - shift
		var b := tris[i + 1] - shift
		var c := tris[i + 2] - shift
		var n: Vector3 = (c - a).cross(b - a).normalized()
		var mid := (tris[i] + tris[i + 1] + tris[i + 2]) / 3.0
		var top_y := maxf(tris[i].y, maxf(tris[i + 1].y, tris[i + 2].y))
		if absf(fposmod(top_y, 0.5) - 0.25) < 0.02:
			top_y += 0.25
		var color := _edited_color(mid, top_y, n, ores)
		_add_tri(verts, normals, colors, indices, a, b, c, n, n, n, color, color, color)


func _add_tri(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3, ca: Color, cb: Color, cc: Color) -> void:
	var base := verts.size()
	verts.append(a)
	verts.append(b)
	verts.append(c)
	normals.append(na)
	normals.append(nb)
	normals.append(nc)
	colors.append(ca)
	colors.append(cb)
	colors.append(cc)
	indices.append(base)
	indices.append(base + 1)
	indices.append(base + 2)


func _edited_color(pos: Vector3, block_top: float, normal: Vector3, ores: Dictionary) -> Color:
	var kind := cell_kind(pos.x, pos.z)
	var natural := _natural_surface((floori(pos.x / 0.5) + 0.5) * 0.5, (floori(pos.z / 0.5) + 0.5) * 0.5)
	var surface := surface_at_world(pos.x, pos.z)
	if _layer_built(kind, natural, surface, block_top) and db.has_id(kind):
		var def = db.get_def(kind)
		var up := clampf(normal.y, 0.0, 1.0)
		return def.color_side.lerp(def.color_top, smoothstep(0.2, 0.85, up))
	return _surface_color(pos.x, pos.z, normal, ores)


func _surface_color(x: float, z: float, normal: Vector3, ores: Dictionary) -> Color:
	var up := clampf(normal.y, 0.0, 1.0)
	var top: Color = db.get_def(surface_id).color_top
	var side: Color = db.get_def(surface_id).color_side
	var color := side.lerp(top, smoothstep(0.2, 0.85, up))
	var slope := 1.0 - up
	var key := Vector2i(floori(x), floori(z))
	if ores.has(key) and slope > 0.45:
		var packed: Vector2i = ores[key]
		var ore_color: Color = db.get_def(packed.x).color_top
		color = color.lerp(ore_color, smoothstep(0.45, 0.8, slope) * 0.85)
	return color


func _add_smooth_quad(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, corners: Array, norms: Array, cols: Array) -> void:
	var base := verts.size()
	for i in 4:
		verts.append(corners[i])
		normals.append(norms[i])
		colors.append(cols[i])
	indices.append(base)
	indices.append(base + 1)
	indices.append(base + 2)
	indices.append(base)
	indices.append(base + 2)
	indices.append(base + 3)


func _collect_surface_ores(origin: Vector3i) -> Dictionary:
	var found := {}
	var reach := max_ore_radius
	var min_cx := floori(float(origin.x - reach) / float(CHUNK_SIZE))
	var max_cx := floori(float(origin.x + CHUNK_SIZE - 1 + reach) / float(CHUNK_SIZE))
	var min_cz := floori(float(origin.z - reach) / float(CHUNK_SIZE))
	var max_cz := floori(float(origin.z + CHUNK_SIZE - 1 + reach) / float(CHUNK_SIZE))
	for ore in db.ores:
		for cz in range(min_cz, max_cz + 1):
			for cx in range(min_cx, max_cx + 1):
				var rng := RandomNumberGenerator.new()
				rng.seed = _column_seed(cx, cz, int(ore.seed_offset))
				for _i in int(ore.clusters):
					var x := cx * CHUNK_SIZE + rng.randi_range(0, CHUNK_SIZE - 1)
					var z := cz * CHUNK_SIZE + rng.randi_range(0, CHUNK_SIZE - 1)
					var y := rng.randi_range(int(ore.min_y), int(ore.max_y))
					var radius := rng.randi_range(int(ore.radius_min), int(ore.radius_max))
					_paint_ore(found, origin, x, y, z, radius, int(ore.block_id))
				for _j in int(ore.surface_clusters):
					var x2 := cx * CHUNK_SIZE + rng.randi_range(0, CHUNK_SIZE - 1)
					var z2 := cz * CHUNK_SIZE + rng.randi_range(0, CHUNK_SIZE - 1)
					var depth := rng.randi_range(int(ore.surface_depth_min), int(ore.surface_depth_max))
					var radius2 := rng.randi_range(int(ore.radius_min), int(ore.radius_max))
					var y2 := height_at(x2, z2) - dirt_depth - depth
					_paint_ore(found, origin, x2, y2, z2, radius2, int(ore.block_id))
	return found


func _paint_ore(found: Dictionary, origin: Vector3i, cx: int, cy: int, cz: int, radius: int, block_id: int) -> void:
	var r2 := radius * radius
	for y in range(cy - radius, cy + radius + 1):
		for z in range(cz - radius, cz + radius + 1):
			for x in range(cx - radius, cx + radius + 1):
				var dx := x - cx
				var dy := y - cy
				var dz := z - cz
				if dx * dx + dy * dy + dz * dz > r2:
					continue
				if x < origin.x or x >= origin.x + CHUNK_SIZE or z < origin.z or z >= origin.z + CHUNK_SIZE:
					continue
				var stone_top := height_at(x, z) - dirt_depth
				if y > stone_top or y < stone_top - 5:
					continue
				var key := Vector2i(x, z)
				var depth := stone_top - y
				if found.has(key):
					var prev: Vector2i = found[key]
					if prev.y < depth:
						continue
				found[key] = Vector2i(block_id, depth)


func _arrays(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array) -> Array:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	return arrays


func _column_seed(cx: int, cz: int, salt: int) -> int:
	var n := ((cx * 73856093) ^ (cz * 19349663) ^ (salt * 83492791) ^ (seed * 15485863))
	n = n & 0x7fffffffffffffff
	return n if n != 0 else 1


func _configure_noise(noise: FastNoiseLite, frequency: float, salt: int, octaves: int) -> void:
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.seed = seed + salt
	noise.frequency = frequency
	if octaves <= 1:
		noise.fractal_type = FastNoiseLite.FRACTAL_NONE
	else:
		noise.fractal_type = FastNoiseLite.FRACTAL_FBM
		noise.fractal_octaves = octaves
		noise.fractal_lacunarity = 2.0
		noise.fractal_gain = 0.5


func _make_lit_material() -> Material:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/terrain.gdshader")
	return mat


func _make_glow_material() -> Material:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/lava.gdshader")
	return mat


func _make_edge_material() -> Material:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.82, 0.84, 0.92)
	mat.roughness = 1.0
	return mat


func _init_structure_math() -> void:
	# 只枚举草块六面邻格；角与棱一律空
	_struct_pos.clear()
	_struct_pos.append(Vector3i(1, 1, 0))
	_struct_pos.append(Vector3i(1, 1, 2))
	_struct_pos.append(Vector3i(1, 0, 1))
	_struct_pos.append(Vector3i(1, 2, 1))
	_struct_pos.append(Vector3i(0, 1, 1))
	_struct_pos.append(Vector3i(2, 1, 1))
	var nbits: int = _struct_pos.size()
	_bit_perm.clear()
	_rot_xform.clear()
	var perms: Array = [
		[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]
	]
	for perm in perms:
		for s in 8:
			var signs := Vector3i(1 if (s & 1) == 0 else -1, 1 if (s & 2) == 0 else -1, 1 if (s & 4) == 0 else -1)
			var M := [
				[0, 0, 0],
				[0, 0, 0],
				[0, 0, 0],
			]
			for i in 3:
				M[i][int(perm[i])] = [signs.x, signs.y, signs.z][i]
			var det: int = M[0][0] * (M[1][1] * M[2][2] - M[1][2] * M[2][1]) - M[0][1] * (M[1][0] * M[2][2] - M[1][2] * M[2][0]) + M[0][2] * (M[1][0] * M[2][1] - M[1][1] * M[2][0])
			if det != 1:
				continue
			var pmap: Array[int] = []
			pmap.resize(nbits)
			for i in nbits:
				var p: Vector3i = _struct_pos[i]
				var q := Vector3i(
					signs.x * ([p.x, p.y, p.z][int(perm[0])] - 1) + 1,
					signs.y * ([p.x, p.y, p.z][int(perm[1])] - 1) + 1,
					signs.z * ([p.x, p.y, p.z][int(perm[2])] - 1) + 1
				)
				var j := 0
				while j < nbits:
					var r: Vector3i = _struct_pos[j]
					if r == q:
						break
					j += 1
				pmap[i] = j
			_bit_perm.append(pmap)
			_rot_xform.append({"perm": perm, "signs": signs})


func _load_structure_catalog() -> void:
	_catalog_n = 0
	_catalog_bytes = PackedByteArray()
	var path := "res://data/structure_catalog.bin"
	if not FileAccess.file_exists(path):
		push_warning("缺少结构图鉴: %s" % path)
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	_catalog_n = int(f.get_32())
	_catalog_bytes = f.get_buffer(_catalog_n * 4)
	print("结构图鉴 ", _catalog_n, " 种（仅草六面，旋转归并，沿 +X）")


func catalog_mask(index: int) -> int:
	if index < 0 or index >= _catalog_n:
		return 0
	var o := index * 4
	return int(_catalog_bytes[o]) | (int(_catalog_bytes[o + 1]) << 8) | (int(_catalog_bytes[o + 2]) << 16) | (int(_catalog_bytes[o + 3]) << 24)


func _rotate_mask(mask: int, r: int) -> int:
	var pmap: Array = _bit_perm[r]
	var out := 0
	var nbits: int = _struct_pos.size()
	for i in nbits:
		if (mask >> i) & 1:
			out |= 1 << int(pmap[i])
	return out


func _rotation_variants(mask: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for r in _bit_perm.size():
		var m := _rotate_mask(mask, r)
		var dup := false
		for i in out.size():
			if out[i] == m:
				dup = true
				break
		if not dup:
			out.append(m)
	return out


func gallery_base_gy() -> int:
	# 出生点地表之上再抬一段，抬头即见
	var h := _natural_surface(8.5, 8.5)
	return floori(h / 0.5) + 12


func _gallery_cell(g: Vector3i) -> int:
	if _catalog_n <= 0:
		return -1
	var dz := g.z - GALLERY_GZ0
	if dz < 0 or dz > 2:
		return -1
	var dx := g.x - GALLERY_GX0
	if dx < 0:
		return -1
	var idx := int(dx / GALLERY_STRIDE)
	var lx := dx % GALLERY_STRIDE
	if lx > 2 or idx >= _catalog_n:
		return -1
	var base := gallery_base_gy()
	var dy := g.y - base
	if dy < 0:
		return -1
	var rot_i := int(dy / GALLERY_ROT_STRIDE)
	var ly := dy % GALLERY_ROT_STRIDE
	if ly > 2:
		return -1
	var variants := _rotation_variants(catalog_mask(idx))
	if rot_i >= variants.size():
		return -1
	var mask := int(variants[rot_i])
	if lx == 1 and ly == 1 and dz == 1:
		return stone_id
	var bit := _struct_bit(lx, ly, dz)
	if bit < 0:
		return 0
	if (mask >> bit) & 1:
		return structure_id
	return 0


func _struct_bit(lx: int, ly: int, lz: int) -> int:
	for i in _struct_pos.size():
		var p: Vector3i = _struct_pos[i]
		if p.x == lx and p.y == ly and p.z == lz:
			return i
	return -1


func _chunk_has_voxels(origin: Vector3i, y0: float, y1: float) -> bool:
	var x0 := origin.x
	var z0 := origin.z
	var x1 := x0 + CHUNK_SIZE
	var z1 := z0 + CHUNK_SIZE
	for key in _cells.keys():
		var g: Vector3i = key
		var cy := (float(g.y) + 0.5) * 0.5
		if cy < y0 or cy >= y1:
			continue
		if (float(g.x) + 0.5) * 0.5 >= float(x0) and (float(g.x) + 0.5) * 0.5 < float(x1) and (float(g.z) + 0.5) * 0.5 >= float(z0) and (float(g.z) + 0.5) * 0.5 < float(z1):
			return true
	if _catalog_n <= 0:
		return false
	var gx0 := floori(float(x0) / 0.5)
	var gx1 := floori(float(x1 - 0.001) / 0.5)
	var gz0 := floori(float(z0) / 0.5)
	var gz1 := floori(float(z1 - 0.001) / 0.5)
	if gz1 < GALLERY_GZ0 or gz0 > GALLERY_GZ0 + 2:
		return false
	if gx1 < GALLERY_GX0:
		return false
	var base := gallery_base_gy()
	var gy0 := floori(y0 / 0.5)
	var gy1 := floori((y1 - 0.001) / 0.5)
	if gy1 < base:
		return false
	var max_y_gal := base + 24 * GALLERY_ROT_STRIDE
	if gy0 > max_y_gal:
		return false
	return gx0 <= GALLERY_GX0 + _catalog_n * GALLERY_STRIDE


func _add_voxel_meshes(origin: Vector3i, y0: float, y1: float, lit_v: PackedVector3Array, lit_n: PackedVector3Array, lit_c: PackedColorArray, lit_i: PackedInt32Array, edge_v: PackedVector3Array) -> void:
	var shift := Vector3(origin)
	var seen := {}
	var smooth_by_gy := {}
	for key in _cells.keys():
		var g: Vector3i = key
		var id := int(_cells[g])
		if id <= 0:
			continue
		_collect_voxel(g, id, shift, y0, y1, lit_v, lit_n, lit_c, lit_i, edge_v, seen, smooth_by_gy)
	_collect_gallery_voxels(origin, y0, y1, shift, lit_v, lit_n, lit_c, lit_i, edge_v, seen, smooth_by_gy)
	# 与地面相同：按层建高度场，再对每个草格走 _emit_cell / _corner_y
	for gy_key in smooth_by_gy.keys():
		var gy: int = gy_key
		var grass_cells: Array = smooth_by_gy[gy]
		_emit_smooth_layer(grass_cells, gy, shift, y0, y1, lit_v, lit_n, lit_c, lit_i)


func _collect_gallery_voxels(origin: Vector3i, y0: float, y1: float, shift: Vector3, lit_v: PackedVector3Array, lit_n: PackedVector3Array, lit_c: PackedColorArray, lit_i: PackedInt32Array, edge_v: PackedVector3Array, seen: Dictionary, smooth_by_gy: Dictionary) -> void:
	if _catalog_n <= 0:
		return
	var gx0 := floori(float(origin.x) / 0.5)
	var gx1 := floori(float(origin.x + CHUNK_SIZE - 0.001) / 0.5)
	var gz0 := floori(float(origin.z) / 0.5)
	var gz1 := floori(float(origin.z + CHUNK_SIZE - 0.001) / 0.5)
	if gz1 < GALLERY_GZ0 or gz0 > GALLERY_GZ0 + 2 or gx1 < GALLERY_GX0:
		return
	var i0 := maxi(0, int((gx0 - GALLERY_GX0) / GALLERY_STRIDE))
	var i1 := mini(_catalog_n - 1, int((gx1 - GALLERY_GX0) / GALLERY_STRIDE))
	var base := gallery_base_gy()
	var gy0 := floori(y0 / 0.5)
	var gy1 := floori((y1 - 0.001) / 0.5)
	for idx in range(i0, i1 + 1):
		var base_mask: int = catalog_mask(idx)
		var variants := _rotation_variants(base_mask)
		for rot_i in variants.size():
			var oy := base + rot_i * GALLERY_ROT_STRIDE
			if oy + 2 < gy0 or oy > gy1:
				continue
			var ox := GALLERY_GX0 + idx * GALLERY_STRIDE
			var oz := GALLERY_GZ0
			var variant_mask: int = int(variants[rot_i])
			# 中心格直接用该邻接掩码的缓存凸包
			_emit_cached_cell_hull(Vector3i(ox + 1, oy + 1, oz + 1), variant_mask, shift, y0, y1, lit_v, lit_n, lit_c, lit_i, stone_id)
			for ly in 3:
				for lz in 3:
					for lx in 3:
						var g := Vector3i(ox + lx, oy + ly, oz + lz)
						if _cells.has(g):
							continue
						var id := _gallery_cell(g)
						if id <= 0:
							continue
						if is_smooth_block(id):
							seen[g] = true
							continue
						_collect_voxel(g, id, shift, y0, y1, lit_v, lit_n, lit_c, lit_i, edge_v, seen, smooth_by_gy)


func _find_rotation_to(base_mask: int, target: int) -> int:
	for r in _bit_perm.size():
		if _rotate_mask(base_mask, r) == target:
			return r
	return 0


func _rotate_local_cell(p: Vector3i, rot: int) -> Vector3i:
	if rot < 0 or rot >= _rot_xform.size():
		return p
	var xf: Dictionary = _rot_xform[rot]
	var perm = xf.perm
	var signs: Vector3i = xf.signs
	return Vector3i(
		signs.x * ([p.x, p.y, p.z][int(perm[0])] - 1) + 1,
		signs.y * ([p.x, p.y, p.z][int(perm[1])] - 1) + 1,
		signs.z * ([p.x, p.y, p.z][int(perm[2])] - 1) + 1
	)


func _emit_cached_cell_hull(g: Vector3i, mask: int, shift: Vector3, y0: float, y1: float, lit_v: PackedVector3Array, lit_n: PackedVector3Array, lit_c: PackedColorArray, lit_i: PackedInt32Array, block_id: int) -> void:
	if _hull_store == null or not db.has_id(block_id):
		return
	var world_tris := PackedVector3Array()
	# 图鉴中心：结构邻格不挡；自定义形状时草邻也不挡
	# 图鉴已保存的形状（含整盒）完整画出；草/结构邻格都不挡
	var saved: bool = _hull_store.has_hull(mask)
	_append_cached_hull_tris(world_tris, g, mask, y0, y1, not saved)
	if world_tris.is_empty():
		return
	var def = db.get_def(block_id)
	for i in range(0, world_tris.size(), 3):
		var a: Vector3 = world_tris[i] - shift
		var b: Vector3 = world_tris[i + 1] - shift
		var c: Vector3 = world_tris[i + 2] - shift
		var n: Vector3 = (b - a).cross(c - a)
		if n.length_squared() < 1e-12:
			continue
		n = n.normalized()
		var up := clampf(n.y, 0.0, 1.0)
		var color: Color = def.color_side.lerp(def.color_top, smoothstep(0.2, 0.85, up))
		_add_tri(lit_v, lit_n, lit_c, lit_i, a, b, c, n, n, n, color, color, color)


func _collect_voxel(g: Vector3i, id: int, shift: Vector3, y0: float, y1: float, lit_v: PackedVector3Array, lit_n: PackedVector3Array, lit_c: PackedColorArray, lit_i: PackedInt32Array, edge_v: PackedVector3Array, seen: Dictionary, smooth_by_gy: Dictionary) -> void:
	if seen.has(g):
		return
	seen[g] = true
	var c := cell_center(g)
	if c.y < y0 or c.y >= y1:
		return
	var local := c - shift
	var s := 0.25
	if is_structure_block(id):
		_append_edge_cube(edge_v, local, s)
		return
	if not db.has_id(id):
		return
	var col := Vector2i(g.x, g.z)
	if is_smooth_block(id):
		if not _hollow.has(col):
			var top := _column_heightmap_top(g.x, g.z)
			var top_gy := floori((top - 0.001) / 0.5)
			if g.y <= top_gy:
				# 地表由 surface_triangles 画（高度场或结构凸包），这里不重复
				return
		if not smooth_by_gy.has(g.y):
			smooth_by_gy[g.y] = []
		smooth_by_gy[g.y].append(g)
		return
	var def = db.get_def(id)
	_append_solid_cube(lit_v, lit_n, lit_c, lit_i, local, s, def.color_top, def.color_side)


func _voxel_solid_for_smooth(g: Vector3i) -> bool:
	var id := get_cell(g)
	if id <= 0 or not db.has_id(id):
		return false
	return db.get_def(id).solid


func _layer_column_height(gx: int, gy: int, gz: int) -> float:
	# 等价于地面 heightmap：该柱在这一层有实心则顶面在 gy+1，否则矮 1 格
	if _voxel_solid_for_smooth(Vector3i(gx, gy, gz)):
		return (float(gy) + 1.0) * 0.5
	return float(gy) * 0.5


func _mask_bit_count(mask: int) -> int:
	var n: int = 0
	var m: int = mask & 63
	while m != 0:
		n += m & 1
		m >>= 1
	return n


func _neighbor_mask_placed(g: Vector3i) -> int:
	# 只统计 _cells 里放置的实心，忽略自然地形（避免翼格吃到洞外石头变成「更大中心」）
	var mask := 0
	for i in _struct_pos.size():
		var off: Vector3i = _struct_pos[i] - Vector3i(1, 1, 1)
		var ng: Vector3i = g + off
		if not _cells.has(ng):
			continue
		var id := int(_cells[ng])
		if id <= 0 or not db.has_id(id):
			continue
		if db.get_def(id).solid:
			mask |= 1 << i
	return mask


func _should_emit_saved_hull(g: Vector3i, mask: int) -> bool:
	# 图鉴凸包：掩码须完全由放置格构成（无自然地形掺入），且放置比特为本模式最大
	if _hull_store == null or not _hull_store.has_hull(mask):
		return false
	var placed: int = _neighbor_mask_placed(g)
	if placed != (mask & 63):
		return false
	var my_bits: int = _mask_bit_count(placed)
	for i in _struct_pos.size():
		var off: Vector3i = _struct_pos[i] - Vector3i(1, 1, 1)
		var ng: Vector3i = g + off
		if not _cells.has(ng) or int(_cells[ng]) <= 0:
			continue
		var n_bits: int = _mask_bit_count(_neighbor_mask_placed(ng))
		if n_bits > my_bits:
			return false
	return true


func _is_saved_hull_wing(g: Vector3i) -> bool:
	if not _cells.has(g) or int(_cells[g]) <= 0:
		return false
	for i in _struct_pos.size():
		var off: Vector3i = _struct_pos[i] - Vector3i(1, 1, 1)
		var ng: Vector3i = g + off
		if not _cells.has(ng) or int(_cells[ng]) <= 0:
			continue
		var nmask: int = _neighbor_mask(ng)
		if _should_emit_saved_hull(ng, nmask):
			return true
	return false


func _emit_smooth_layer(grass_cells: Array, gy: int, shift: Vector3, y0: float, y1: float, lit_v: PackedVector3Array, lit_n: PackedVector3Array, lit_c: PackedColorArray, lit_i: PackedInt32Array) -> void:
	# 放置层：中心格命中图鉴 → 完整凸包；翼格/普通草 → 单位立方（邻接遮挡）
	if grass_cells.is_empty():
		return
	for item in grass_cells:
		var g: Vector3i = item
		var id := get_cell(g)
		if id <= 0 or not is_smooth_block(id) or not db.has_id(id):
			continue
		var mask: int = _neighbor_mask(g)
		var use_hull: bool = _should_emit_saved_hull(g, mask)
		if not use_hull and _is_saved_hull_wing(g):
			# 与图鉴一致：翼格只占位（结构线框/草邻），不画实心，避免撕出一堆立方尖刺
			continue
		var tris := PackedVector3Array()
		if use_hull:
			_append_cached_hull_tris(tris, g, mask, y0, y1, false)
		else:
			_append_cached_hull_tris(tris, g, 0, y0, y1, true)
		if tris.is_empty():
			continue
		var def = db.get_def(id)
		for i in range(0, tris.size(), 3):
			var a := tris[i] - shift
			var b := tris[i + 1] - shift
			var c := tris[i + 2] - shift
			var normal: Vector3 = (b - a).cross(c - a)
			if normal.length_squared() < 0.0000001:
				continue
			normal = normal.normalized()
			var up := clampf(normal.y, 0.0, 1.0)
			var color: Color = def.color_side.lerp(def.color_top, smoothstep(0.2, 0.85, up))
			_add_tri(lit_v, lit_n, lit_c, lit_i, a, b, c, normal, normal, normal, color, color, color)


func _append_edge_cube(verts: PackedVector3Array, c: Vector3, s: float) -> void:
	var p := [
		c + Vector3(-s, -s, -s), c + Vector3(s, -s, -s), c + Vector3(s, s, -s), c + Vector3(-s, s, -s),
		c + Vector3(-s, -s, s), c + Vector3(s, -s, s), c + Vector3(s, s, s), c + Vector3(-s, s, s),
	]
	var edges := [0, 1, 1, 2, 2, 3, 3, 0, 4, 5, 5, 6, 6, 7, 7, 4, 0, 4, 1, 5, 2, 6, 3, 7]
	for i in range(0, edges.size(), 2):
		verts.append(p[edges[i]])
		verts.append(p[edges[i + 1]])


func _append_solid_cube(verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array, c: Vector3, s: float, top: Color, side: Color) -> void:
	var faces := [
		[Vector3(0, 1, 0), top, Vector3(-s, s, -s), Vector3(s, s, -s), Vector3(s, s, s), Vector3(-s, s, s)],
		[Vector3(0, -1, 0), side, Vector3(-s, -s, s), Vector3(s, -s, s), Vector3(s, -s, -s), Vector3(-s, -s, -s)],
		[Vector3(0, 0, 1), side, Vector3(-s, -s, s), Vector3(-s, s, s), Vector3(s, s, s), Vector3(s, -s, s)],
		[Vector3(0, 0, -1), side, Vector3(s, -s, -s), Vector3(s, s, -s), Vector3(-s, s, -s), Vector3(-s, -s, -s)],
		[Vector3(1, 0, 0), side, Vector3(s, -s, s), Vector3(s, s, s), Vector3(s, s, -s), Vector3(s, -s, -s)],
		[Vector3(-1, 0, 0), side, Vector3(-s, -s, -s), Vector3(-s, s, -s), Vector3(-s, s, s), Vector3(-s, -s, s)],
	]
	for face in faces:
		var n: Vector3 = face[0]
		var col: Color = face[1]
		var a: Vector3 = c + face[2]
		var b: Vector3 = c + face[3]
		var d: Vector3 = c + face[4]
		var e: Vector3 = c + face[5]
		_add_tri(verts, normals, colors, indices, a, b, d, n, n, n, col, col, col)
		_add_tri(verts, normals, colors, indices, a, d, e, n, n, n, col, col, col)


func _append_voxel_collision(tris: PackedVector3Array, cx: int, cz: int) -> void:
	var x0 := float(cx * CHUNK_SIZE)
	var z0 := float(cz * CHUNK_SIZE)
	var x1 := x0 + float(CHUNK_SIZE)
	var z1 := z0 + float(CHUNK_SIZE)
	var seen := {}
	for key in _cells.keys():
		var g: Vector3i = key
		var id := int(_cells[g])
		if id <= 0:
			continue
		var c := cell_center(g)
		if c.x < x0 or c.x >= x1 or c.z < z0 or c.z >= z1:
			continue
		seen[g] = true
		if is_smooth_block(id):
			var sm: int = _neighbor_mask(g)
			if _should_emit_saved_hull(g, sm):
				_append_cached_hull_tris(tris, g, sm, -100000.0, 100000.0, false)
			else:
				_append_cached_hull_tris(tris, g, 0, -100000.0, 100000.0, true)
		else:
			_append_box_collision(tris, c, 0.25)
	if _catalog_n <= 0:
		return
	var gx0 := floori(x0 / 0.5)
	var gx1 := floori((x1 - 0.001) / 0.5)
	var gz0 := floori(z0 / 0.5)
	var gz1 := floori((z1 - 0.001) / 0.5)
	if gz1 < GALLERY_GZ0 or gz0 > GALLERY_GZ0 + 2 or gx1 < GALLERY_GX0:
		return
	var i0 := maxi(0, int((gx0 - GALLERY_GX0) / GALLERY_STRIDE))
	var i1 := mini(_catalog_n - 1, int((gx1 - GALLERY_GX0) / GALLERY_STRIDE))
	var base := gallery_base_gy()
	for idx in range(i0, i1 + 1):
		var variants := _rotation_variants(catalog_mask(idx))
		for rot_i in variants.size():
			var oy := base + rot_i * GALLERY_ROT_STRIDE
			var ox := GALLERY_GX0 + idx * GALLERY_STRIDE
			var variant_mask: int = int(variants[rot_i])
			for ly in 3:
				for lz in 3:
					for lx in 3:
						var g := Vector3i(ox + lx, oy + ly, GALLERY_GZ0 + lz)
						if seen.has(g):
							continue
						var gid := _gallery_cell(g)
						if gid <= 0:
							continue
						if is_smooth_block(gid) and lx == 1 and ly == 1 and lz == 1 and _hull_store != null:
							_append_cached_hull_tris(tris, g, variant_mask, -100000.0, 100000.0)
						else:
							_append_box_collision(tris, cell_center(g), 0.25)


func _append_box_collision(tris: PackedVector3Array, c: Vector3, s: float) -> void:
	var p := [
		c + Vector3(-s, -s, -s), c + Vector3(s, -s, -s), c + Vector3(s, s, -s), c + Vector3(-s, s, -s),
		c + Vector3(-s, -s, s), c + Vector3(s, -s, s), c + Vector3(s, s, s), c + Vector3(-s, s, s),
	]
	var faces := [
		[0, 1, 2, 0, 2, 3], [4, 6, 5, 4, 7, 6], [0, 4, 5, 0, 5, 1],
		[3, 2, 6, 3, 6, 7], [0, 3, 7, 0, 7, 4], [1, 5, 6, 1, 6, 2],
	]
	for face in faces:
		for i in 6:
			tris.append(p[face[i]])
