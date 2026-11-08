extends RefCounted

class Socket:
	var pos: Vector3
	var normal: Vector3


class PartDef:
	var id: String
	var display_name: String
	var order: int
	var size: Vector3
	var mass: float
	var color: Color
	var wheel: bool
	var energy_j: float
	var power_w: float
	var friction: float
	var thrust_n: float
	var propeller: bool
	var connections: Array[Socket] = []
	var source: String


var parts: Array[PartDef] = []
var _by_id := {}


func load_dir(dir_path: String) -> void:
	parts.clear()
	_by_id.clear()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_error("打不开单位目录: %s" % dir_path)
		return
	for file_name in dir.get_files():
		if not str(file_name).ends_with(".json"):
			continue
		var path := dir_path.path_join(str(file_name))
		var text := FileAccess.get_file_as_string(path)
		var data = JSON.parse_string(text)
		if data == null or not (data is Dictionary):
			push_error("单位 JSON 无法解析: %s" % path)
			continue
		var def := _make(data, text)
		if _by_id.has(def.id):
			push_error("单位 id 重复: %s" % def.id)
			continue
		parts.append(def)
		_by_id[def.id] = def
	parts.sort_custom(func(a: PartDef, b: PartDef): return a.order < b.order)


func get_part(part_id: String) -> PartDef:
	return _by_id[part_id]


func has_part(part_id: String) -> bool:
	return _by_id.has(part_id)


func make_box(def: PartDef) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = def.size
	return mesh


func make_mesh(def: PartDef) -> Mesh:
	if def.wheel:
		return _wheel_mesh()
	if def.propeller:
		return _propeller_mesh()
	return make_box(def)


func make_shape(def: PartDef) -> Shape3D:
	var box := BoxShape3D.new()
	box.size = def.size
	return box


func add_body_shapes(body: RigidBody3D, def: PartDef) -> void:
	if def.wheel:
		_add_shape(body, _disc_shape(), Transform3D.IDENTITY)
		_add_shape(body, _cone_shape(), Transform3D(Basis.IDENTITY, Vector3(0, 0.1875, 0)))
		_add_shape(body, _cone_shape(), Transform3D(Basis(Vector3.RIGHT, PI), Vector3(0, -0.1875, 0)))
		return
	if def.propeller:
		var disc := CylinderShape3D.new()
		disc.radius = 0.25
		disc.height = 0.25
		_add_shape(body, disc, Transform3D.IDENTITY)
		return
	_add_shape(body, make_shape(def), Transform3D.IDENTITY)


func _add_shape(body: RigidBody3D, shape: Shape3D, xform: Transform3D) -> void:
	var node := CollisionShape3D.new()
	node.shape = shape
	node.transform = xform
	body.add_child(node)


func _wheel_mesh() -> ArrayMesh:
	var disc := CylinderMesh.new()
	disc.top_radius = 0.5
	disc.bottom_radius = 0.5
	disc.height = 0.25
	disc.radial_segments = 32
	var cone := CylinderMesh.new()
	cone.bottom_radius = 0.5
	cone.top_radius = 0.0
	cone.height = 0.125
	cone.radial_segments = 24
	var mesh := ArrayMesh.new()
	_append_mesh(mesh, disc, Transform3D.IDENTITY)
	_append_mesh(mesh, cone, Transform3D(Basis.IDENTITY, Vector3(0, 0.1875, 0)))
	_append_mesh(mesh, cone, Transform3D(Basis(Vector3.RIGHT, PI), Vector3(0, -0.1875, 0)))
	return mesh


func _propeller_mesh() -> ArrayMesh:
	var hub := CylinderMesh.new()
	hub.top_radius = 0.04
	hub.bottom_radius = 0.04
	hub.height = 0.25
	hub.radial_segments = 16
	var blade := BoxMesh.new()
	blade.size = Vector3(0.48, 0.025, 0.07)
	var mesh := ArrayMesh.new()
	_append_mesh(mesh, hub, Transform3D.IDENTITY)
	_append_mesh(mesh, blade, Transform3D.IDENTITY)
	return mesh


func _append_mesh(out: ArrayMesh, source: Mesh, xform: Transform3D) -> void:
	for surface in source.get_surface_count():
		var arrays: Array = source.surface_get_arrays(surface)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for i in verts.size():
			verts[i] = xform * verts[i]
			if i < norms.size():
				norms[i] = (xform.basis * norms[i]).normalized()
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = norms
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


func _disc_shape() -> CylinderShape3D:
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.5
	cyl.height = 0.25
	return cyl


func _cone_shape() -> ConvexPolygonShape3D:
	var shape := ConvexPolygonShape3D.new()
	var points := PackedVector3Array()
	points.append(Vector3(0, 0.0625, 0))
	var segments := 16
	for i in segments:
		var angle := TAU * float(i) / float(segments)
		points.append(Vector3(cos(angle) * 0.5, -0.0625, sin(angle) * 0.5))
	shape.points = points
	return shape


func make_material(color: Color, alpha: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, alpha)
	mat.roughness = 0.82
	if alpha < 0.999:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return mat


func _make(data: Dictionary, source: String) -> PartDef:
	var def := PartDef.new()
	def.id = str(data.get("id", ""))
	def.display_name = str(data.get("display_name", def.id))
	def.order = int(data.get("order", 0))
	def.size = _vec3(data.get("size", [1, 1, 1]))
	def.mass = float(data.get("mass", 1.0))
	def.color = _color(data.get("color", [255, 0, 255]))
	def.wheel = bool(data.get("wheel", false))
	def.energy_j = float(data.get("energy_j", 0.0))
	def.power_w = float(data.get("power_w", 0.0))
	def.friction = float(data.get("friction", 0.5))
	def.thrust_n = float(data.get("thrust_n", 0.0))
	def.propeller = bool(data.get("propeller", false))
	def.source = source
	def.connections = []
	var raw: Array = data.get("connections", [])
	for item in raw:
		if not (item is Dictionary):
			continue
		var sock := Socket.new()
		sock.pos = _vec3(item.get("pos", [0, 0, 0]))
		sock.normal = _vec3(item.get("normal", [0, 1, 0])).normalized()
		def.connections.append(sock)
	return def


func _vec3(value) -> Vector3:
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return Vector3.ONE


func _color(value) -> Color:
	if value is Array and value.size() >= 3:
		return Color(float(value[0]) / 255.0, float(value[1]) / 255.0, float(value[2]) / 255.0)
	return Color.MAGENTA
