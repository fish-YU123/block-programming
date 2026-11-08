extends CanvasLayer
## 游戏 HUD：准星、选中方块、坐标与提示。

var info_label: Label
var hint_label: Label
var block_label: Label
var crosshair: Control
var message_label: Label
## F3 调试信息（F3 开关）
var debug_label: Label
var resources_label: Label
var overlay_label: Label
var loading_label: Label
var _loading_bg: ColorRect
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
	block_label.position = Vector2(16, 62)
	block_label.add_theme_color_override("font_color", Color(0.9, 0.95, 0.7, 0.9))
	add_child(block_label)

	hint_label = Label.new()
	hint_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	hint_label.position = Vector2(16, -54)
	hint_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	hint_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.65))
	hint_label.text = "WASD 移动 / 空格上升 / Shift 下降 / ⌘ 加速 / 滚轮调视野\n按住左键拖动转视角 / 单击左键标记挖掘 / 右键标记放置\n数字键 1-8 选方块 / Q 切换建筑 / B 标记建造 / N 标记拆除\nF 放置飞飞 / G 收回 / C 代码面板（标记只是虚影，由单位代码执行）"
	add_child(hint_label)

	loading_label = Label.new()
	loading_label.set_anchors_preset(Control.PRESET_CENTER)
	_loading_bg = ColorRect.new()
	_loading_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_loading_bg.color = Color(0.02, 0.04, 0.08, 0.78)
	_loading_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_loading_bg.visible = false
	add_child(_loading_bg)

	loading_label.position = Vector2(-360, -20)
	loading_label.size = Vector2(720, 40)
	loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	loading_label.add_theme_font_size_override("font_size", 22)
	loading_label.add_theme_color_override("font_color", Color(0.85, 0.93, 1.0))
	loading_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	loading_label.add_theme_constant_override("shadow_offset_x", 2)
	loading_label.add_theme_constant_override("shadow_offset_y", 2)
	loading_label.text = ""
	add_child(loading_label)

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

	debug_label = Label.new()
	debug_label.position = Vector2(16, 108)
	debug_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.4))
	debug_label.add_theme_font_size_override("font_size", 13)
	debug_label.visible = false
	add_child(debug_label)


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


## 载入进度提示（空字符串表示隐藏）
## 加载阶段：压暗背景、藏掉操作提示，只留进度文字
func set_loading_mode(on: bool) -> void:
	if _loading_bg != null:
		_loading_bg.visible = on
	for node in [info_label, block_label, hint_label, resources_label, message_label, crosshair]:
		if node != null:
			node.visible = not on
	if loading_label != null and not on:
		loading_label.text = ""


func set_loading(text: String) -> void:
	if loading_label != null:
		loading_label.text = text


func show_overlay(text: String) -> void:
	overlay_label.text = text


func set_resources(text: String) -> void:
	resources_label.text = text


func set_block_name(text: String) -> void:
	block_label.text = text
