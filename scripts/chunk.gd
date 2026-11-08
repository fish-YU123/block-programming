extends MeshInstance3D

var coord := Vector3i.ZERO
var blocks := PackedByteArray()


func setup(chunk_coord: Vector3i, built: Dictionary) -> void:
	coord = chunk_coord
	position = Vector3(chunk_coord * 16)
	blocks = built.blocks
	mesh = built.mesh
	gi_mode = GeometryInstance3D.GI_MODE_STATIC
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
