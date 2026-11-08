extends SceneTree
const BlockDB = preload("res://scripts/world/block_db.gd")
const VoxelWorld = preload("res://scripts/world/voxel_world.gd")
const UnitDB = preload("res://scripts/units/unit_db.gd")
const Flyer = preload("res://scripts/units/flyer.gd")
var _w: VoxelWorld
var _u: Flyer
var _f := 0
func _initialize() -> void:
	var db := BlockDB.new(); db.load_dir("res://data/blocks")
	_w = VoxelWorld.new(); root.add_child(_w); _w.setup(db, 4242, 64, 64, 48); _w.build_all()
	var ud := UnitDB.new(); ud.load_dir("res://data/units")
	_u = Flyer.new(); root.add_child(_u)
	_u.global_position = Vector3(20, float(_w.surface_height(20,20)) + 6.0, 20)
	_u.setup(_w, ud.get_def("feifei"))
	print("mass=", _u.mass, " gravity_scale=", _u.gravity_scale, " thrust_max=", _u.hover_thrust)
func _process(d: float) -> bool:
	_f += 1
	_u.controls["lift"] = 1.0
	if _f % 20 == 0:
		print("f=", _f, " y=", "%.2f" % _u.global_position.y, " vy=", "%.2f" % _u.linear_velocity.y, " thrust=", "%.1f" % _u.thrust_now, " thrust_applied=", "%.1f" % (_u.hover_thrust * 1.0))
	if _f > 60:
		quit(0)
	return false
