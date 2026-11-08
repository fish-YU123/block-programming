extends CanvasLayer
## 玩家代码编辑面板：选中一台预设单位，改它跑的那份代码，按「应用」立刻生效。
## 快捷键：C 开关面板（面板打开时相机不动、不能挖方块）。

signal apply_pressed(uid: int, code: String)
signal unit_selected(uid: int)
signal panel_closed

const MONO_FONTS := ["Menlo", "Monaco", "Courier New", "Consolas", "DejaVu Sans Mono"]
const MAX_LOG_LINES := 12
const PANEL_WIDTH := 620.0

var root_control: Control
var editor: CodeEdit
var unit_list: ItemList
var status_label: Label
var error_label: Label
var log_label: Label
var hint_label: Label
var apply_button: Button
var close_button: Button

var _uids: Array = []
var _current_uid := -1


func _ready() -> void:
	layer = 30
	visible = false
	_build()


func is_open() -> bool:
	return visible


func toggle() -> void:
	if visible:
		close()
	else:
		open()


func open() -> void:
	visible = true
	editor.grab_focus()


func close() -> void:
	visible = false
	panel_closed.emit()


func current_uid() -> int:
	return _current_uid


# ---------------------------------------------------------------- 对外接口

## 刷新左侧单位列表：[{uid:int, label:String, error:String}]
func set_units(items: Array) -> void:
	_uids.clear()
	unit_list.clear()
	for item in items:
		var uid := int(item.get("uid", 0))
		var label := str(item.get("label", "单位 %d" % uid))
		var error := str(item.get("error", ""))
		_uids.append(uid)
		var index := unit_list.add_item(("⚠ " if error != "" else "") + label)
		unit_list.set_item_metadata(index, uid)
	if _current_uid not in _uids and not _uids.is_empty():
		_current_uid = int(_uids[0])
	_select_in_list()


func set_code(uid: int, code: String) -> void:
	if uid != _current_uid:
		_current_uid = uid
		_select_in_list()
	editor.text = code
	var lines := editor.get_line_count()
	editor.set_caret_line(maxi(0, mini(editor.get_caret_line(), lines - 1)))
	error_label.text = ""
	log_label.text = ""


func set_current(uid: int) -> void:
	if uid == _current_uid:
		return
	_current_uid = uid
	_select_in_list()


func show_error(text: String) -> void:
	error_label.text = "" if text == "" else "代码出错：" + text


func show_logs(lines: Array) -> void:
	if lines.is_empty():
		log_label.text = ""
		return
	var tail: Array = lines
	if tail.size() > MAX_LOG_LINES:
		tail = tail.slice(tail.size() - MAX_LOG_LINES)
	var out: PackedStringArray = []
	for line in tail:
		out.append(str(line))
	log_label.text = "\n".join(out)


func show_status(text: String) -> void:
	status_label.text = text


# ---------------------------------------------------------------- 内部

func _build() -> void:
	root_control = Control.new()
	root_control.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root_control)

	# 贴在屏幕右侧的面板（世界留在左边，方便边看单位边改代码）
	var panel := PanelContainer.new()
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_top = 0.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -PANEL_WIDTH - 16.0
	panel.offset_right = -16.0
	panel.offset_top = 16.0
	panel.offset_bottom = -16.0
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.06, 0.10, 0.93)
	style.border_color = Color(0.25, 0.42, 0.62, 0.8)
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(14)
	panel.add_theme_stylebox_override("panel", style)
	root_control.add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	panel.add_child(column)

	# 标题行
	var title_row := HBoxContainer.new()
	column.add_child(title_row)
	var title := Label.new()
	title.text = "单位代码"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.72, 0.88, 1.0))
	title_row.add_child(title)
	close_button = Button.new()
	close_button.text = "关闭 C"
	close_button.pressed.connect(close)
	title_row.add_child(close_button)

	# 单位列表（只列自己的单位）
	unit_list = ItemList.new()
	unit_list.custom_minimum_size = Vector2(0, 96)
	var list_style := StyleBoxFlat.new()
	list_style.bg_color = Color(0.07, 0.10, 0.15, 0.95)
	list_style.set_corner_radius_all(6)
	list_style.set_content_margin_all(4)
	unit_list.add_theme_stylebox_override("panel", list_style)
	unit_list.add_theme_color_override("font_color", Color(0.86, 0.92, 1.0))
	unit_list.item_selected.connect(_on_unit_picked)
	column.add_child(unit_list)

	# 代码编辑
	editor = CodeEdit.new()
	editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	editor.gutters_draw_line_numbers = true
	editor.indent_size = 4
	editor.highlight_current_line = true
	var font := SystemFont.new()
	font.font_names = PackedStringArray(MONO_FONTS)
	editor.add_theme_font_override("font", font)
	editor.add_theme_font_size_override("font_size", 14)
	editor.add_theme_color_override("background_color", Color(0.07, 0.09, 0.13))
	editor.add_theme_color_override("font_color", Color(0.88, 0.92, 0.96))
	column.add_child(editor)

	# 应用按钮 + 状态
	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 10)
	column.add_child(action_row)
	apply_button = Button.new()
	apply_button.text = "应用代码 ⌘+回车"
	apply_button.pressed.connect(_on_apply)
	action_row.add_child(apply_button)
	status_label = Label.new()
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.add_theme_color_override("font_color", Color(0.8, 0.9, 1.0))
	action_row.add_child(status_label)

	error_label = Label.new()
	error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	error_label.custom_minimum_size = Vector2(0, 34)
	error_label.add_theme_color_override("font_color", Color(1.0, 0.7, 0.6))
	column.add_child(error_label)

	var log_title := Label.new()
	log_title.text = "print 输出"
	log_title.add_theme_color_override("font_color", Color(0.6, 0.9, 0.7))
	column.add_child(log_title)
	log_label = Label.new()
	log_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	log_label.custom_minimum_size = Vector2(0, 80)
	log_label.add_theme_color_override("font_color", Color(0.75, 0.95, 0.8))
	var log_font := SystemFont.new()
	log_font.font_names = PackedStringArray(MONO_FONTS)
	log_label.add_theme_font_override("font", log_font)
	log_label.add_theme_font_size_override("font_size", 12)
	column.add_child(log_label)

	hint_label = Label.new()
	hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint_label.text = "结构：def start() 跑一次 → def loop() 反复跑（每秒共 60 行）\n控制：set_lift() set_tilt() set_rcs() drill()\n传感器：pos vel cell yaw energy blocks[5][5] heights[5][5] here enemies"
	hint_label.add_theme_font_size_override("font_size", 11)
	hint_label.add_theme_color_override("font_color", Color(0.62, 0.68, 0.76))
	column.add_child(hint_label)


## 点到代码以外的地方就交出键盘焦点，避免在别处点击后还在往代码里打字
func _input(event: InputEvent) -> void:
	if not visible or editor == null:
		return
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	if not editor.get_global_rect().has_point(event.position):
		editor.release_focus()


func _select_in_list() -> void:
	for i in unit_list.item_count:
		if int(unit_list.get_item_metadata(i)) == _current_uid:
			unit_list.select(i)
			return


func _on_unit_picked(index: int) -> void:
	var uid := int(unit_list.get_item_metadata(index))
	if uid == _current_uid:
		return
	_current_uid = uid
	unit_selected.emit(uid)


func _on_apply() -> void:
	if _current_uid < 0:
		return
	apply_pressed.emit(_current_uid, editor.text)


func _unhandled_key_input(event: InputEvent) -> void:
	if not visible:
		return
	if not (event is InputEventKey) or not event.pressed:
		return
	if event.keycode == KEY_ESCAPE or event.keycode == KEY_C:
		close()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_ENTER and (event.meta_pressed or event.ctrl_pressed):
		_on_apply()
		get_viewport().set_input_as_handled()
