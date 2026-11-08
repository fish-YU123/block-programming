extends CanvasLayer
## 游戏 HUD：准星、选中方块、坐标与提示。

var info_label: Label
var hint_label: Label
var block_label: Label
var crosshair: Control
var message_label: Label
var resources_label: Label
var overlay_label: Label
var _message_timer := 0.0


func _ready() -> void:
	layer = 20
	crosshair = Control.new()
	crosshair.set_anchors_preset(Control.PRESET_CENTER)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h := ColorRect.new()
	h.color = Color(1, 1, 1, 0.85)
	h.size = Vector2(14, 2)
	h.position = Vector2(-7, -1)
	crosshair.add_child(h)
	var v := ColorRect.new()
	v.color = Color(1, 1, 1, 0.85)
	v.size = Vector2(2, 14)
	v.position = Vector2(-1, -7)
	crosshair.add_child(v)
	add_child(crosshair)

	info_label = Label.new()
	info_label.position = Vector2(16, 12)
	info_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.8))
	add_child(info_label)

	resources_label = Label.new()
	resources_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	resources_label.position = Vector2(-320, 12)
	resources_label.add_theme_color_override("font_color", Color(0.95, 0.9, 0.6, 0.95))
	add_child(resources_label)

	block_label = Label.new()
	block_label.position = Vector2(16, 38)
	block_label.add_theme_color_override("font_color", Color(0.9, 0.95, 0.7, 0.9))
	add_child(block_label)

	hint_label = Label.new()
	hint_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	hint_label.position = Vector2(16, -54)
	hint_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	hint_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.65))
	hint_label.text = "WASD 移动 / 空格上升 / Shift 下降 / ⌘ 加速\n按住左键拖动转动视角 / 单击左键挖掘 / 右键放置\n滚轮或数字键 1-8 选方块\nF 放置飞飞 / G 收回最后一台"
	add_child(hint_label)

	overlay_label = Label.new()
	overlay_label.set_anchors_preset(Control.PRESET_CENTER)
	overlay_label.position = Vector2(-300, -60)
	overlay_label.size = Vector2(600, 120)
	overlay_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	overlay_label.add_theme_font_size_override("font_size", 40)
	overlay_label.add_theme_color_override("font_color", Color(1, 0.95, 0.6))
	add_child(overlay_label)

	message_label = Label.new()
	message_label.set_anchors_preset(Control.PRESET_CENTER)
	message_label.position = Vector2(-200, 120)
	message_label.add_theme_color_override("font_color", Color(1, 0.85, 0.4))
	add_child(message_label)


func show_message(text: String, seconds := 2.0) -> void:
	message_label.text = text
	_message_timer = seconds


func _process(delta: float) -> void:
	if _message_timer > 0.0:
		_message_timer -= delta
		if _message_timer <= 0.0:
			message_label.text = ""


func set_info(text: String) -> void:
	info_label.text = text


func show_overlay(text: String) -> void:
	overlay_label.text = text


func set_resources(text: String) -> void:
	resources_label.text = text


func set_block_name(text: String) -> void:
	block_label.text = text
