extends StaticBody3D

const ENERGY_MAX := 2099520.0
var energy_cap := 2099520.0

var mode := "out"
var enabled := true
var energy_j := 0.0

var _mesh: MeshInstance3D
var _label: Label3D


func _ready() -> void:
	add_to_group("charge_pad")
	add_to_group("world_pad")
	collision_layer = 1
	collision_mask = 1
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.5, 0.25, 0.5)
	shape.shape = box
	add_child(shape)
	_mesh = MeshInstance3D.new()
	var visual := BoxMesh.new()
	visual.size = Vector3(0.5, 0.25, 0.5)
	_mesh.mesh = visual
	add_child(_mesh)
	_label = Label3D.new()
	_label.font = _font()
	_label.font_size = 42
	_label.pixel_size = 0.0011
	_label.outline_size = 8
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.position = Vector3(0, 0.22, 0)
	add_child(_label)
	refresh()


func cycle() -> void:
	if enabled and mode == "out":
		mode = "in"
		enabled = true
	elif enabled and mode == "in":
		mode = "off"
		enabled = false
	else:
		mode = "out"
		enabled = true
	refresh()


func refresh() -> void:
	if _mesh != null:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = pad_color(mode, enabled)
		_mesh.material_override = mat
	if _label != null:
		_label.text = pad_word(mode, enabled)


static func pad_color(pad_mode: String, on: bool) -> Color:
	if not on or pad_mode == "off":
		return Color(0.22, 0.24, 0.28)
	if pad_mode == "in":
		return Color(0.95, 0.62, 0.18)
	return Color(0.15, 0.78, 0.86)


static func pad_word(pad_mode: String, on: bool) -> String:
	if not on or pad_mode == "off":
		return "关闭"
	if pad_mode == "in":
		return "输入"
	return "输出"


static func _font() -> Font:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["PingFang SC", "Hiragino Sans GB", "Heiti SC"])
	return font
