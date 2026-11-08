extends CanvasLayer
## 联机面板：开房间 / 加入房间 / 断开，以及状态显示。按 M 开关。

signal host_requested
signal join_requested(address: String)
signal disconnect_requested

const PANEL_POS := Vector2(16, 200)
const PANEL_WIDTH := 330.0

var host_button: Button
var join_button: Button
var disconnect_button: Button
var address_edit: LineEdit
var status_label: Label
var hint_label: Label


func _ready() -> void:
	layer = 28
	visible = false
	_build()


func _build() -> void:
	var panel := PanelContainer.new()
	panel.position = PANEL_POS
	panel.custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.07, 0.11, 0.92)
	style.border_color = Color(0.35, 0.55, 0.9, 0.9)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	var title := Label.new()
	title.text = "联机（M 关闭）"
	title.add_theme_color_override("font_color", Color(0.85, 0.92, 1.0))
	box.add_child(title)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	box.add_child(row)

	address_edit = LineEdit.new()
	address_edit.text = "127.0.0.1"
	address_edit.custom_minimum_size = Vector2(120, 0)
	row.add_child(address_edit)

	host_button = Button.new()
	host_button.text = "开房间"
	host_button.pressed.connect(func(): host_requested.emit())
	row.add_child(host_button)

	join_button = Button.new()
	join_button.text = "加入"
	join_button.pressed.connect(func(): join_requested.emit(address_edit.text.strip_edges()))
	row.add_child(join_button)

	disconnect_button = Button.new()
	disconnect_button.text = "断开"
	disconnect_button.pressed.connect(func(): disconnect_requested.emit())
	box.add_child(disconnect_button)

	status_label = Label.new()
	status_label.text = "未连接"
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.custom_minimum_size = Vector2(PANEL_WIDTH - 24, 0)
	status_label.add_theme_color_override("font_color", Color(0.75, 0.85, 1.0))
	box.add_child(status_label)

	hint_label = Label.new()
	hint_label.text = "别人加入后填主机 IP（端口默认 27015）\n主机是蓝方，加入的人是红方"
	hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint_label.custom_minimum_size = Vector2(PANEL_WIDTH - 24, 0)
	hint_label.add_theme_color_override("font_color", Color(0.62, 0.7, 0.82))
	hint_label.add_theme_font_size_override("font_size", 12)
	box.add_child(hint_label)


func set_status(text: String) -> void:
	if status_label != null:
		status_label.text = text


func toggle() -> void:
	visible = not visible


func is_open() -> bool:
	return visible
