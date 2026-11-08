extends CanvasLayer

const UnitDB = preload("res://scripts/unit_db.gd")
const Yard = preload("res://scripts/assembly_yard.gd")
const Deploy = preload("res://scripts/unit_deploy.gd")
const Deployed = preload("res://scripts/deployed_unit.gd")
const UnitVM = preload("res://scripts/unit_vm.gd")

const DEFAULT_SOURCE := "# 每个控制中心每秒运行 60 行\n# 支持 if/elif/else、while、for i in range(...)、def 函数、列表和字典\n# 不支持 import / class / lambda / try，死循环会被行数预算自动限制\n# energy 剩余焦耳，wheels 轮子数量，props 螺旋桨数量\n# 装上 GPS 才有 px py pz\n# 装上线速度传感器才有 vx vy vz 和 ax ay az\n# 装上角度传感器才有 yaw pitch roll（度）和 wx wy wz\n# set_spin(序号, 弧度每秒) 绕两侧锥尖的轴转\n# set_steer(序号, 角度) 转向，0 是装上时的方向\n# set_drive(1) 所有轮子一起转\n# set_thrust(序号, 牛) 沿螺旋桨朝上的方向推，负值反向，最大 5\n# get_link(1).speed = 2    或者 wheel1.speed = 2\n# 轮子 speed 是弧度每秒，steer 是角度；螺旋桨 speed 是推力（牛）\nset_drive(0)\n"

var _terrain = null
var _player: Node3D
var _db: UnitDB
var _panel: Panel
var _chrome: Control
var _grip: ColorRect
var _arrow: Button
var _panel_open := true
var _panel_width := 468.0
var _panel_saved := 468.0
var _resizing := false
var _resize_x := 0.0
var _resize_w := 0.0
var _grip_down := Vector2.ZERO
var _grip_moved := false
var _yard: Yard
var _view: SubViewportContainer
var _viewport: SubViewport
var _status: Label
var _blueprint_dialog: FileDialog
var _blueprint_saving := false
var _blueprint_unit: Deployed
var _save_popup: PopupPanel
var _save_at := Vector2.ZERO
var _tab := 2
var _unit_page: Control
var _block_page: Control
var _hull_editor: Window
var _mode_button: Button
var _erase_button: Button
var _block_erase := false
var _block_pad := false
var _block_id := 1
var _block_choice: Array[Button] = []
var _choice_ids: Array[int] = []
var _pages: Array[Control] = []
var _tab_buttons: Array[Button] = []
var _preview_roots: Array[Node3D] = []
var _right_down := Vector2.ZERO
var _right_dragged := false
var _orbiting := false
var _panning := false
var _pause_label: Label
var _spin_re := RegEx.new()
var _code_list: ItemList
var _code_text: TextEdit
var _code_watch: RichTextLabel
var _code_note: Label
var _code_unit: Deployed
var _follow: Deployed
var _outline: ShaderMaterial
var _vm: UnitVM
var _next_serial := 1
var _loading_code := false
var _list_sig := ""
var _rename_popup: PopupPanel
var _rename_edit: LineEdit
var _rename_uid := -1


func setup(terrain, player: Node3D) -> void:
	_terrain = terrain
	_player = player


func pointer_over() -> bool:
	var mouse := get_viewport().get_mouse_position()
	if _save_popup != null and _save_popup.visible and _save_popup.get_global_rect().has_point(mouse):
		return true
	if _chrome == null:
		return false
	return _chrome.get_global_rect().has_point(mouse)


func close_panel() -> void:
	if not _panel_open:
		return
	_panel_saved = maxf(_panel_width, 280.0)
	_panel_open = false
	_apply_chrome()


func _toggle_panel() -> void:
	if _panel_open:
		close_panel()
	else:
		open_panel()


func open_panel() -> void:
	_panel_open = true
	if _panel_width < 280.0:
		_panel_width = _panel_saved
	_apply_chrome()


func _apply_chrome() -> void:
	if _chrome == null:
		return
	var limit := maxf(320.0, get_viewport().get_visible_rect().size.x - 80.0)
	var width := 0.0
	if _panel_open or _resizing:
		width = _panel_width
	if _panel_open and not _resizing:
		width = clampf(width, 280.0, limit)
		_panel_width = width
	else:
		width = clampf(width, 0.0, limit)
	_chrome.offset_left = -(width + 22.0)
	_chrome.offset_right = 0.0
	_chrome.offset_top = 0.0
	_chrome.offset_bottom = 0.0
	_grip.offset_right = 22.0
	_panel.visible = _panel_open
	_panel.offset_left = 22.0
	_panel.offset_top = 0.0
	_panel.offset_right = 0.0
	_panel.offset_bottom = 0.0
	if _arrow != null:
		_arrow.text = "›" if _panel_open else "‹"


func _on_grip_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_resizing = true
		_grip_moved = false
		_grip_down = get_viewport().get_mouse_position()
		_resize_x = _grip_down.x
		_resize_w = _panel_width if _panel_open else 0.0
		_grip.accept_event()


func locks_move_keys() -> bool:
	var focus := get_viewport().gui_get_focus_owner()
	if focus is TextEdit or focus is LineEdit:
		return true
	return _tab == 2 and _yard != null and _yard.is_holding()


func follow_target() -> Deployed:
	if _follow != null and not is_instance_valid(_follow):
		_follow = null
	return _follow


func stop_follow() -> void:
	_follow = null


func focus_unit(unit: Node, switch_tab: bool) -> void:
	_clear_wheel_hover()
	var deployed := unit as Deployed
	if deployed == null or not is_instance_valid(deployed):
		return
	_code_unit = deployed
	_follow = deployed
	open_panel()
	_set_outline(deployed)
	_list_sig = ""
	_sync_unit_list()
	_load_editor(deployed)
	if switch_tab:
		_show_tab(0)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_spin_re.compile("set_spin\\s*\\(\\s*(\\d+)")
	_db = UnitDB.new()
	_db.load_dir("res://data/units")
	_outline = ShaderMaterial.new()
	_outline.shader = load("res://shaders/outline.gdshader")
	_vm = UnitVM.new()
	_vm.name = "UnitVM"
	_vm.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(_vm)
	_save_popup = PopupPanel.new()
	var save_button := Button.new()
	save_button.text = "保存蓝图"
	save_button.focus_mode = Control.FOCUS_NONE
	save_button.custom_minimum_size = Vector2(128, 36)
	save_button.pressed.connect(_save_selected_unit)
	_save_popup.add_child(save_button)
	add_child(_save_popup)
	layer = 20
	_chrome = Control.new()
	_chrome.anchor_left = 1.0
	_chrome.anchor_right = 1.0
	_chrome.anchor_top = 0.0
	_chrome.anchor_bottom = 1.0
	_chrome.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_chrome)
	_grip = ColorRect.new()
	_grip.color = Color(0.16, 0.16, 0.16)
	_grip.anchor_left = 0.0
	_grip.anchor_top = 0.0
	_grip.anchor_right = 0.0
	_grip.anchor_bottom = 1.0
	_grip.offset_left = 0.0
	_grip.offset_top = 0.0
	_grip.offset_right = 22.0
	_grip.offset_bottom = 0.0
	_grip.mouse_filter = Control.MOUSE_FILTER_STOP
	_grip.mouse_default_cursor_shape = Control.CURSOR_HSIZE
	_grip.gui_input.connect(_on_grip_input)
	_chrome.add_child(_grip)
	_arrow = Button.new()
	_arrow.focus_mode = Control.FOCUS_NONE
	_arrow.text = "›"
	_arrow.anchor_left = 0.0
	_arrow.anchor_right = 0.0
	_arrow.anchor_top = 0.5
	_arrow.anchor_bottom = 0.5
	_arrow.offset_left = 0.0
	_arrow.offset_right = 22.0
	_arrow.offset_top = -28.0
	_arrow.offset_bottom = 28.0
	_arrow.add_theme_font_size_override("font_size", 18)
	var arrow_bg := StyleBoxFlat.new()
	arrow_bg.bg_color = Color(0.1, 0.1, 0.1)
	arrow_bg.border_color = Color(0.62, 0.62, 0.62)
	arrow_bg.set_border_width_all(1)
	_arrow.add_theme_stylebox_override("normal", arrow_bg)
	_arrow.add_theme_stylebox_override("hover", arrow_bg)
	_arrow.add_theme_stylebox_override("pressed", arrow_bg)
	_arrow.pressed.connect(_toggle_panel)
	_chrome.add_child(_arrow)
	_panel = Panel.new()
	_panel.anchor_right = 1.0
	_panel.anchor_top = 0.0
	_panel.anchor_bottom = 1.0
	_panel.anchor_left = 0.0
	_panel.offset_left = 22.0
	_panel.offset_top = 0.0
	_panel.offset_right = 0.0
	_panel.offset_bottom = 0.0
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.theme = _make_theme()
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0)
	bg.border_color = Color(0.22, 0.22, 0.22)
	bg.set_border_width_all(1)
	bg.set_content_margin_all(0)
	_panel.add_theme_stylebox_override("panel", bg)
	_chrome.add_child(_panel)
	_apply_chrome()
	if not get_viewport().size_changed.is_connected(_apply_chrome):
		get_viewport().size_changed.connect(_apply_chrome)
	_pause_label = Label.new()
	_pause_label.text = "暂停"
	_pause_label.visible = false
	_pause_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pause_label.anchor_left = 0.0
	_pause_label.anchor_right = 1.0
	_pause_label.offset_top = 16.0
	_pause_label.offset_bottom = 80.0
	_pause_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pause_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_pause_label.add_theme_font_size_override("font_size", 48)
	_pause_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_pause_label.add_theme_constant_override("outline_size", 10)
	_pause_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	add_child(_pause_label)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 10.0
	root.offset_top = 10.0
	root.offset_right = -10.0
	root.offset_bottom = -10.0
	root.add_theme_constant_override("separation", 8)
	_panel.add_child(root)

	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	root.add_child(tabs)
	var names: PackedStringArray = ["代码", "生产", "创造"]
	for i in names.size():
		var button := Button.new()
		button.text = names[i]
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.focus_mode = Control.FOCUS_NONE
		var index := i
		button.pressed.connect(func() -> void: _show_tab(index))
		tabs.add_child(button)
		_tab_buttons.append(button)

	_pages.append(_build_code_page())
	_pages.append(_build_production_page())
	_pages.append(_build_create_page())
	for page in _pages:
		page.size_flags_vertical = Control.SIZE_EXPAND_FILL
		root.add_child(page)
	_show_tab(2)
	_yard.status_changed.connect(_on_status)
	_on_status("右侧点一次拿起零件。点道场里的方块可挪走。右键拖动转视角，滚轮调视野。")


func _process(delta: float) -> void:
	if _tab == 2 and _view != null and _yard != null:
		_sync_viewport()
		var local := _view.get_local_mouse_position()
		var inside := Rect2(Vector2.ZERO, _view.size).has_point(local)
		_yard.set_pointer(local, inside)
	for node in _preview_roots:
		node.rotate_y(delta * 0.7)
	_sync_unit_list()
	_refresh_note()
	_refresh_watch(delta)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SLASH:
			var typing := get_viewport().gui_get_focus_owner()
			if typing is TextEdit or typing is LineEdit:
				return
			get_tree().paused = not get_tree().paused
			if _pause_label != null:
				_pause_label.visible = get_tree().paused
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_ESCAPE:
			if _yard != null:
				_yard.cancel_hold()
			stop_follow()
			_set_outline(null)
		if locks_move_keys():
			if event.keycode == KEY_W:
				_yard.rotate_axis(Vector3.RIGHT, -1)
			elif event.keycode == KEY_S:
				_yard.rotate_axis(Vector3.RIGHT, 1)
			elif event.keycode == KEY_A:
				_yard.rotate_axis(Vector3.UP, 1)
			elif event.keycode == KEY_D:
				_yard.rotate_axis(Vector3.UP, -1)
			elif event.keycode == KEY_Q:
				_yard.rotate_axis(Vector3.FORWARD, 1)
			elif event.keycode == KEY_E:
				_yard.rotate_axis(Vector3.FORWARD, -1)
	elif event is InputEventMouseMotion and _resizing:
		var motion := event as InputEventMouseMotion
		if motion.position.distance_to(_grip_down) > 4.0:
			_grip_moved = true
		_panel_width = _resize_w + (_resize_x - motion.position.x)
		var limit := maxf(320.0, get_viewport().get_visible_rect().size.x - 80.0)
		_panel_width = clampf(_panel_width, 0.0, limit)
		_panel_open = _panel_width >= 48.0
		_apply_chrome()
	elif event is InputEventMouseMotion and _panning and _yard != null:
		_yard.pan((event as InputEventMouseMotion).relative)
	elif event is InputEventMouseMotion and _orbiting and _yard != null:
		var motion := event as InputEventMouseMotion
		if motion.position.distance_to(_right_down) > 5.0:
			_right_dragged = true
		if _right_dragged:
			_yard.orbit(motion.relative)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed and _resizing:
		_resizing = false
		if _panel_width < 160.0:
			_panel_open = false
			if _resize_w >= 280.0:
				_panel_saved = _resize_w
		else:
			_panel_open = true
			_panel_saved = _panel_width
		_apply_chrome()
	elif event is InputEventMouseButton:
		var over_view := _tab == 2 and _view != null and _view.get_global_rect().has_point(get_viewport().get_mouse_position())
		if event.button_index == MOUSE_BUTTON_MIDDLE and event.pressed and over_view:
			_panning = true
		elif event.button_index == MOUSE_BUTTON_MIDDLE and not event.pressed:
			_panning = false
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed and over_view:
			_orbiting = true
			_right_dragged = false
			_right_down = event.position
		elif event.button_index == MOUSE_BUTTON_RIGHT and not event.pressed:
			if _orbiting and not _right_dragged and over_view and _yard != null:
				var local := _view.get_local_mouse_position()
				_yard.set_pointer(local, true)
				_yard.try_remove()
			_orbiting = false
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed and _tab == 2 and not pointer_over():
			_remove_deployed()
		elif over_view and event.pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				_yard.add_fov(-2.0)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_yard.add_fov(2.0)


func _show_tab(index: int) -> void:
	_tab = index
	if index != 2 and _yard != null:
		_yard.cancel_hold()
	for i in _pages.size():
		_pages[i].visible = i == index
	for i in _tab_buttons.size():
		var on := i == index
		var face := _flat(Color(0.24, 0.24, 0.24), Color(0.92, 0.92, 0.92)) if on else _flat(Color(0.08, 0.08, 0.08), Color(0.26, 0.26, 0.26))
		_tab_buttons[i].add_theme_stylebox_override("normal", face)
		_tab_buttons[i].add_theme_stylebox_override("hover", face)
		_tab_buttons[i].add_theme_stylebox_override("pressed", face)


func _build_code_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 6)
	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 8)
	page.add_child(row)
	_code_list = ItemList.new()
	_code_list.custom_minimum_size = Vector2(120, 0)
	_code_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_code_list.focus_mode = Control.FOCUS_NONE
	_code_list.item_selected.connect(_show_code)
	_code_list.item_activated.connect(_activate_code)
	_code_list.gui_input.connect(_code_list_input)
	row.add_child(_code_list)
	_code_text = TextEdit.new()
	_code_text.editable = true
	_code_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_code_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_code_text.wrap_mode = TextEdit.LINE_WRAPPING_NONE
	_code_text.add_theme_font_size_override("font_size", 13)
	_code_text.text_changed.connect(_on_source_changed)
	_code_text.gui_input.connect(_on_code_hover)
	_code_text.mouse_exited.connect(_clear_wheel_hover)
	row.add_child(_code_text)
	_code_watch = RichTextLabel.new()
	_code_watch.custom_minimum_size = Vector2(132, 0)
	_code_watch.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_code_watch.bbcode_enabled = true
	_code_watch.scroll_active = false
	_code_watch.fit_content = false
	_code_watch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_code_watch.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	_code_watch.add_theme_font_size_override("normal_font_size", 12)
	var watch_font := SystemFont.new()
	watch_font.font_names = PackedStringArray(["Menlo", "SF Mono", "Monaco"])
	_code_watch.add_theme_font_override("normal_font", watch_font)
	row.add_child(_code_watch)
	_code_note = Label.new()
	_code_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_code_note.custom_minimum_size = Vector2(0, 48)
	page.add_child(_code_note)
	_rename_popup = PopupPanel.new()
	_rename_edit = LineEdit.new()
	_rename_edit.custom_minimum_size = Vector2(200, 32)
	_rename_edit.placeholder_text = "单位名称"
	_rename_edit.text_submitted.connect(_apply_rename)
	_rename_popup.add_child(_rename_edit)
	add_child(_rename_popup)
	return page


func _show_code(index: int) -> void:
	_clear_wheel_hover()
	var unit := _unit_at(index)
	if unit == null:
		return
	_code_unit = unit
	_load_editor(unit)


func _activate_code(index: int) -> void:
	var unit := _unit_at(index)
	if unit == null:
		return
	focus_unit(unit, false)


func _code_list_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var button := event as InputEventMouseButton
	if button.button_index != MOUSE_BUTTON_RIGHT or not button.pressed:
		return
	var index := _code_list.get_item_at_position(button.position, true)
	var unit := _unit_at(index)
	if unit == null:
		return
	_rename_uid = unit.uid
	_rename_edit.text = unit.display_name
	_rename_edit.select_all()
	var mouse := Vector2i(get_viewport().get_mouse_position())
	_rename_popup.popup(Rect2i(mouse, Vector2i(220, 44)))
	_rename_edit.grab_focus()
	_code_list.accept_event()


func _apply_rename(new_name: String) -> void:
	var trimmed := new_name.strip_edges()
	_rename_popup.hide()
	if trimmed == "":
		return
	for unit in _live_units():
		if unit.uid == _rename_uid:
			unit.display_name = trimmed
			unit.name = trimmed
			_list_sig = ""
			_sync_unit_list()
			return


func _build_production_page() -> Control:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 10)
	scroll.add_child(box)
	var text := FileAccess.get_file_as_string("res://data/production.json")
	var rows = JSON.parse_string(text)
	if rows == null or not (rows is Array):
		return scroll
	for row in rows:
		if not (row is Dictionary):
			continue
		var part_id := str(row.get("produces", ""))
		if not _db.has_part(part_id):
			continue
		var def := _db.get_part(part_id)
		var card := HBoxContainer.new()
		card.add_theme_constant_override("separation", 10)
		card.add_child(_make_preview(def))
		var words := VBoxContainer.new()
		words.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var title := Label.new()
		title.text = str(row.get("display_name", part_id))
		var produced := Label.new()
		produced.text = "产出 %s" % def.display_name
		var size_label := Label.new()
		size_label.text = "%s×%s×%s    %s kg    %s    摩擦 %s" % [_num(def.size.x), _num(def.size.y), _num(def.size.z), _num(def.mass), _power_text(def), _num(def.friction)]
		words.add_child(title)
		words.add_child(produced)
		words.add_child(size_label)
		card.add_child(words)
		box.add_child(card)
	return scroll


func _build_create_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 8)
	var sub := HBoxContainer.new()
	sub.add_theme_constant_override("separation", 6)
	var edit_unit := Button.new()
	edit_unit.text = "编辑单位"
	edit_unit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit_unit.focus_mode = Control.FOCUS_NONE
	edit_unit.pressed.connect(_show_create_unit)
	var edit_blocks := Button.new()
	edit_blocks.text = "放置/删除方块"
	edit_blocks.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit_blocks.focus_mode = Control.FOCUS_NONE
	edit_blocks.pressed.connect(_show_create_blocks)
	sub.add_child(edit_unit)
	sub.add_child(edit_blocks)
	page.add_child(sub)
	_unit_page = _build_unit_page()
	_block_page = _build_block_page()
	_block_page.visible = false
	page.add_child(_unit_page)
	page.add_child(_block_page)
	return page


func _build_unit_page() -> Control:
	var page := VBoxContainer.new()
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_theme_constant_override("separation", 8)
	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 8)
	page.add_child(row)

	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.transparent_bg = false
	_viewport.handle_input_locally = false
	_viewport.size = Vector2i(280, 480)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_yard = Yard.new()
	_yard.name = "Yard"
	_viewport.add_child(_yard)
	_yard.setup(_db)

	_view = SubViewportContainer.new()
	_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view.stretch = true
	_view.mouse_filter = Control.MOUSE_FILTER_STOP
	_view.add_child(_viewport)
	_view.gui_input.connect(_on_yard_gui)
	var stage := Control.new()
	stage.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stage.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_view.mouse_filter = Control.MOUSE_FILTER_STOP
	stage.add_child(_view)
	_mode_button = Button.new()
	_mode_button.text = "建造"
	_mode_button.focus_mode = Control.FOCUS_NONE
	_mode_button.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_mode_button.offset_left = 8
	_mode_button.offset_top = -40
	_mode_button.offset_right = 96
	_mode_button.offset_bottom = -8
	_mode_button.z_index = 2
	_mode_button.pressed.connect(_cycle_yard_tool)
	stage.add_child(_mode_button)
	row.add_child(stage)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(138, 0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var parts := VBoxContainer.new()
	parts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parts.add_theme_constant_override("separation", 6)
	scroll.add_child(parts)
	for def in _db.parts:
		var button := Button.new()
		button.text = "%s\n%s×%s×%s\n%s kg\n%s\n摩擦 %s" % [def.display_name, _num(def.size.x), _num(def.size.y), _num(def.size.z), _num(def.mass), _power_text(def), _num(def.friction)]
		button.custom_minimum_size = Vector2(0, 104)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.focus_mode = Control.FOCUS_NONE
		var part_id := def.id
		button.pressed.connect(func() -> void: _yard.hold(part_id))
		parts.add_child(button)
	row.add_child(scroll)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 6)
	var place := Button.new()
	place.text = "放到地图"
	place.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	place.focus_mode = Control.FOCUS_NONE
	place.pressed.connect(_deploy)
	var clear := Button.new()
	clear.text = "清空道场"
	clear.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clear.focus_mode = Control.FOCUS_NONE
	clear.pressed.connect(func() -> void: _yard.clear_pieces())
	actions.add_child(place)
	actions.add_child(clear)
	page.add_child(actions)
	var files := HBoxContainer.new()
	files.add_theme_constant_override("separation", 6)
	var save_blueprint := Button.new()
	save_blueprint.text = "保存蓝图"
	save_blueprint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_blueprint.focus_mode = Control.FOCUS_NONE
	save_blueprint.pressed.connect(_save_blueprint)
	var load_blueprint := Button.new()
	load_blueprint.text = "导入蓝图"
	load_blueprint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	load_blueprint.focus_mode = Control.FOCUS_NONE
	load_blueprint.pressed.connect(_import_blueprint)
	files.add_child(save_blueprint)
	files.add_child(load_blueprint)
	page.add_child(files)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(0, 52)
	page.add_child(_status)
	return page


func _build_block_page() -> Control:
	var page := VBoxContainer.new()
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_theme_constant_override("separation", 8)
	var hint := Label.new()
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.text = "鼠标对准面：放置在外侧一格，删除内侧一格（可搭「）。结构块为12边线框。图鉴在出生点正上方。点充电片可切换模式。"
	page.add_child(hint)
	var hull_btn := Button.new()
	hull_btn.text = "编辑结构平滑（3×3×3 凸包）"
	hull_btn.focus_mode = Control.FOCUS_NONE
	hull_btn.pressed.connect(_open_hull_editor)
	page.add_child(hull_btn)
	_erase_button = Button.new()
	_erase_button.text = "删除画笔"
	_erase_button.toggle_mode = true
	_erase_button.focus_mode = Control.FOCUS_NONE
	_erase_button.toggled.connect(_on_erase_toggled)
	page.add_child(_erase_button)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 6)
	scroll.add_child(list)
	page.add_child(scroll)
	if _terrain != null and _terrain.db != null:
		var ids: Array[int] = []
		for key in _terrain.db.props_by_id.keys():
			var block_id := int(key)
			if block_id == 0:
				continue
			var def = _terrain.db.get_def(block_id)
			if not def.solid:
				continue
			ids.append(block_id)
		ids.sort()
		for block_id in ids:
			var def = _terrain.db.get_def(block_id)
			var button := Button.new()
			button.text = def.display_name
			button.focus_mode = Control.FOCUS_NONE
			button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var picked := block_id
			button.pressed.connect(func() -> void: _choose_block(picked))
			list.add_child(button)
			_block_choice.append(button)
			_choice_ids.append(block_id)
		if not ids.is_empty():
			_block_id = ids[0]
	var pad := Button.new()
	pad.text = "无线充电片"
	pad.focus_mode = Control.FOCUS_NONE
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.pressed.connect(_choose_pad)
	list.add_child(pad)
	_block_choice.append(pad)
	_choice_ids.append(-1)
	_mark_block_choice()
	return page


func _show_create_unit() -> void:
	if _unit_page != null:
		_unit_page.visible = true
	if _block_page != null:
		_block_page.visible = false


func _show_create_blocks() -> void:
	if _unit_page != null:
		_unit_page.visible = false
	if _block_page != null:
		_block_page.visible = true


func _open_hull_editor() -> void:
	if _terrain == null:
		return
	if _hull_editor == null:
		_hull_editor = preload("res://scripts/structure_hull_editor.gd").new()
		get_tree().root.add_child(_hull_editor)
		_hull_editor.setup(_terrain)
		_hull_editor.saved.connect(_on_hull_saved)
	else:
		_hull_editor.setup(_terrain)
	_hull_editor.popup_centered()


func _on_hull_saved() -> void:
	var world := get_parent()
	if world == null or _terrain == null:
		return
	# 地面与图鉴都按凸包重算
	if world.has_method("rebuild_loaded_meshes"):
		world.call("rebuild_loaded_meshes")
		return
	if not world.has_method("_refresh_edit"):
		return
	var base_gy: int = _terrain.gallery_base_gy()
	var x: float = (float(_terrain.GALLERY_GX0) + 1.5) * 0.5
	var z: float = (float(_terrain.GALLERY_GZ0) + 1.5) * 0.5
	var y: float = (float(base_gy) + 1.0) * 0.5
	for i in mini(12, _terrain._catalog_n):
		var xi: float = x + float(i * _terrain.GALLERY_STRIDE) * 0.5
		world.call("_refresh_edit", xi, z, y)
		for r in 4:
			world.call("_refresh_edit", xi, z, y + float(r * _terrain.GALLERY_ROT_STRIDE) * 0.5)


func _cycle_yard_tool() -> void:
	if _yard == null or _mode_button == null:
		return
	_yard.set_tool_mode(_yard.tool_mode + 1)
	var words := ["建造", "连电", "连控制"]
	_mode_button.text = words[_yard.tool_mode]


func block_edit_active() -> bool:
	return _tab == 2 and _block_page != null and _block_page.visible


func block_paint() -> Dictionary:
	return {"erase": _block_erase, "pad": _block_pad, "id": _block_id}


func _on_erase_toggled(on: bool) -> void:
	_block_erase = on
	if on:
		_block_pad = false
	if _erase_button != null:
		_erase_button.text = "删除画笔（开）" if on else "删除画笔"
	_mark_block_choice()


func _choose_block(block_id: int) -> void:
	_block_id = block_id
	_block_pad = false
	_block_erase = false
	if _erase_button != null:
		_erase_button.set_pressed_no_signal(false)
		_erase_button.text = "删除画笔"
	_mark_block_choice()


func _choose_pad() -> void:
	_block_pad = true
	_block_erase = false
	if _erase_button != null:
		_erase_button.set_pressed_no_signal(false)
		_erase_button.text = "删除画笔"
	_mark_block_choice()


func _mark_block_choice() -> void:
	if _terrain == null or _terrain.db == null:
		return
	for index in _choice_ids.size():
		var block_id := _choice_ids[index]
		if block_id < 0:
			_block_choice[index].text = ("● " if _block_pad and not _block_erase else "") + "无线充电片"
			continue
		var mark := "● " if not _block_erase and not _block_pad and block_id == _block_id else ""
		_block_choice[index].text = mark + _terrain.db.get_def(block_id).display_name


func _on_yard_gui(event: InputEvent) -> void:
	if _yard == null or not (event is InputEventMouseButton):
		return
	var button := event as InputEventMouseButton
	if button.button_index != MOUSE_BUTTON_LEFT or not button.pressed:
		return
	_yard.set_pointer(button.position, true)
	_yard.on_left_click()
	_view.accept_event()


func offer_unit_save(unit: Node, at: Vector2) -> void:
	var deployed := unit as Deployed
	if deployed == null or not is_instance_valid(deployed):
		return
	_blueprint_unit = deployed
	_save_at = at
	call_deferred("_popup_unit_save")


func _popup_unit_save() -> void:
	if _save_popup == null:
		return
	_save_popup.popup(Rect2i(Vector2i(_save_at), Vector2i(144, 52)))


func _save_selected_unit() -> void:
	if _blueprint_unit == null or not is_instance_valid(_blueprint_unit):
		return
	if _blueprint_unit.layout.is_empty():
		_on_status("这个单位没有可保存的结构。")
		return
	_save_popup.hide()
	_blueprint_saving = true
	var dialog := _blueprint_picker()
	dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dialog.title = "保存蓝图"
	dialog.current_dir = _blueprint_dir()
	dialog.current_file = "%s.json" % _blueprint_unit.display_name
	dialog.popup_centered(Vector2i(760, 520))


func _save_blueprint() -> void:
	if _yard == null:
		return
	_blueprint_unit = null
	_yard.park_move()
	if _yard.pieces.is_empty():
		_on_status("道场是空的，没有可保存的蓝图。")
		return
	_blueprint_saving = true
	var dialog := _blueprint_picker()
	dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dialog.title = "保存蓝图"
	dialog.current_dir = _blueprint_dir()
	dialog.current_file = "蓝图.json"
	dialog.popup_centered(Vector2i(760, 520))


func _import_blueprint() -> void:
	if _yard == null:
		return
	_blueprint_saving = false
	var dialog := _blueprint_picker()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.title = "导入蓝图"
	dialog.current_dir = _blueprint_dir()
	dialog.current_file = ""
	dialog.popup_centered(Vector2i(760, 520))


func _blueprint_picker() -> FileDialog:
	if _blueprint_dialog != null:
		return _blueprint_dialog
	var dialog := FileDialog.new()
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.use_native_dialog = true
	dialog.filters = PackedStringArray(["*.json ; 蓝图"])
	dialog.file_selected.connect(_on_blueprint_file)
	add_child(dialog)
	_blueprint_dialog = dialog
	return dialog


func _blueprint_dir() -> String:
	var dir := ProjectSettings.globalize_path("res://data/blueprints")
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


func _on_blueprint_file(path: String) -> void:
	if _yard == null:
		return
	if _blueprint_saving:
		var file := path
		if not file.ends_with(".json"):
			file += ".json"
		var payload: Dictionary
		if _blueprint_unit != null and is_instance_valid(_blueprint_unit):
			payload = {"kind": "unit_blueprint", "pieces": _blueprint_unit.layout, "code": _blueprint_unit.source}
			_blueprint_unit = null
		else:
			payload = _yard.blueprint_data()
		var handle := FileAccess.open(file, FileAccess.WRITE)
		if handle == null:
			_on_status("蓝图没有写进去。")
			return
		handle.store_string(JSON.stringify(payload, "\t"))
		handle.close()
		_on_status("已保存蓝图 %s。" % file.get_file())
		return
	var text := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(text)
	if parsed == null or not (parsed is Dictionary):
		_on_status("这个文件不是单位蓝图。")
		return
	var problem := _yard.load_blueprint(parsed)
	if problem != "":
		_on_status(problem)
		return
	if _yard.blueprint_code == "":
		_on_status("已导入 %s，%s 个零件。" % [path.get_file(), str(_yard.pieces.size())])
	else:
		_on_status("已导入 %s，%s 个零件，放下时带代码。" % [path.get_file(), str(_yard.pieces.size())])


func _deploy() -> void:
	if _yard == null or _player == null:
		return
	if _yard.pieces.is_empty():
		_on_status("道场是空的，先把零件拼起来。")
		return
	var host := _player.get_parent().get_node_or_null("Machines") as Node3D
	if host == null:
		host = Node3D.new()
		host.name = "Machines"
		_player.get_parent().add_child(host)
	var unit := Deploy.spawn(host, _terrain, _player, _yard, _db, _outline)
	if unit == null:
		return
	unit.uid = _next_serial
	unit.display_name = "单位%s" % str(_next_serial)
	unit.name = unit.display_name
	unit.source = _yard.blueprint_code if _yard.blueprint_code != "" else DEFAULT_SOURCE
	unit.revision = 1
	_next_serial += 1
	_list_sig = ""
	_sync_unit_list()


func _machines() -> Node:
	if _player == null:
		return null
	return _player.get_parent().get_node_or_null("Machines")


func _live_units() -> Array[Deployed]:
	var found: Array[Deployed] = []
	var host := _machines()
	if host == null:
		return found
	for child in host.get_children():
		var unit := child as Deployed
		if unit != null:
			found.append(unit)
	return found


func _unit_at(index: int) -> Deployed:
	if index < 0:
		return null
	var units := _live_units()
	if index >= units.size():
		return null
	return units[index]


func _sync_unit_list() -> void:
	if _code_list == null:
		return
	var sig := ""
	for unit in _live_units():
		sig += "%s=%s;" % [str(unit.uid), unit.display_name]
	if sig == _list_sig:
		return
	_list_sig = sig
	var keep := -1
	if _code_unit != null and is_instance_valid(_code_unit):
		keep = _code_unit.uid
	_loading_code = true
	_code_list.clear()
	var select_index := -1
	var units := _live_units()
	for i in units.size():
		_code_list.add_item(units[i].display_name)
		_code_list.set_item_metadata(i, units[i].uid)
		if units[i].uid == keep:
			select_index = i
	if select_index >= 0:
		_code_list.select(select_index)
	elif units.is_empty():
		_code_unit = null
		_code_text.text = ""
	_loading_code = false


func _load_editor(unit: Deployed) -> void:
	if _code_text == null or unit == null:
		return
	_loading_code = true
	_code_text.text = unit.source
	_code_text.editable = true
	_loading_code = false
	_refresh_note()


func _on_source_changed() -> void:
	if _loading_code or _code_unit == null or not is_instance_valid(_code_unit):
		return
	_code_unit.source = _code_text.text
	_code_unit.revision += 1


func _on_code_hover(event: InputEvent) -> void:
	if not (event is InputEventMouseMotion) or _code_text == null:
		return
	var motion := event as InputEventMouseMotion
	var at: Vector2i = _code_text.get_line_column_at_pos(motion.position)
	var line := at.y
	if line < 0 or line >= _code_text.get_line_count():
		_clear_wheel_hover()
		return
	_show_spin_line(_code_text.get_line(line))


func _show_spin_line(text: String) -> void:
	if _code_unit == null or not is_instance_valid(_code_unit):
		return
	var index := -1
	if not text.strip_edges().begins_with("#"):
		var found := _spin_re.search(text)
		if found != null:
			index = int(found.get_string(1))
	_code_unit.highlight_wheel(index)


func _clear_wheel_hover() -> void:
	if _code_unit != null and is_instance_valid(_code_unit):
		_code_unit.highlight_wheel(-1)


func _refresh_watch(delta: float) -> void:
	if _code_watch == null:
		return
	var reading := {}
	if _code_unit != null and is_instance_valid(_code_unit):
		reading = _code_unit.sense(delta)
	var names: PackedStringArray = ["px", "py", "pz", "vx", "vy", "vz", "ax", "ay", "az", "yaw", "pitch", "roll", "wx", "wy", "wz", "energy", "wheels", "props"]
	var lines: PackedStringArray = []
	for key in names:
		var shown := "—"
		var color := "888888"
		if reading.has(key):
			color = "b7e0ad"
			if key == "wheels" or key == "props":
				shown = "%8d" % int(reading[key])
			else:
				shown = "%8.2f" % float(reading[key])
		lines.append("[color=#9aa0a6]%s[/color] [color=#%s]%s[/color]" % [key.rpad(6), color, shown])
	_code_watch.text = "\n".join(lines)


func _refresh_note() -> void:
	if _code_note == null:
		return
	if _code_unit == null or not is_instance_valid(_code_unit):
		_code_note.text = "放到地图后会出现单位1、单位2。右键名字可改名，双击跟随。"
		return
	var centers := _code_unit.center_count()
	var head := "%s · 控制中心 %s 个 · 每秒 60 行\n电量 %s / %s J · 当前 %s W" % [
		_code_unit.display_name,
		str(centers),
		_joule(_code_unit.energy_j),
		_joule(_code_unit.energy_max),
		_num(_code_unit.draw_w()),
	]
	if centers == 0:
		head += "（没有控制中心，代码不运行）"
	if _code_unit.runtime_error != "":
		_code_note.text = head + "\n" + _code_unit.runtime_error
		return
	if _code_unit.runtime_log != "":
		_code_note.text = head + "\n" + _code_unit.runtime_log
		return
	_code_note.text = head


func _set_outline(unit: Deployed) -> void:
	for live in _live_units():
		live.set_outline(unit != null and live.uid == unit.uid)


func _remove_deployed() -> void:
	if _player == null:
		return
	var camera := _player.get_node_or_null("Camera3D") as Camera3D
	if camera == null:
		return
	var space := camera.get_world_3d().direct_space_state
	var from := camera.global_position
	var to := from + (-camera.global_basis.z) * 240.0
	var query := PhysicsRayQueryParameters3D.create(from, to, 2)
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return
	var node: Node = hit.collider as Node
	while node != null:
		if node.is_in_group("deployed_unit"):
			node.queue_free()
			return
		node = node.get_parent()


func _sync_viewport() -> void:
	if _view.size.x < 2.0 or _view.size.y < 2.0:
		return
	var want := Vector2i(maxi(int(_view.size.x), 2), maxi(int(_view.size.y), 2))
	if _viewport.size != want:
		_viewport.size = want


func _on_status(text: String) -> void:
	if _status != null:
		_status.text = text


func _make_preview(def: UnitDB.PartDef) -> SubViewportContainer:
	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	viewport.size = Vector2i(120, 88)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.04, 0.04, 0.04)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.8, 0.82, 0.86)
	env.ambient_light_energy = 0.7
	env_node.environment = env
	viewport.add_child(env_node)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 28, 0)
	sun.shadow_enabled = false
	viewport.add_child(sun)
	var pivot := Node3D.new()
	viewport.add_child(pivot)
	var mesh := MeshInstance3D.new()
	mesh.mesh = _db.make_mesh(def)
	mesh.material_override = _db.make_material(def.color, 1.0)
	pivot.add_child(mesh)
	for sock in def.connections:
		var marker := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.06
		sphere.height = 0.12
		marker.mesh = sphere
		marker.position = sock.pos
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1.0, 0.55, 0.16)
		marker.material_override = mat
		mesh.add_child(marker)
	var cam := Camera3D.new()
	var span: float = maxf(def.size.x, maxf(def.size.y, def.size.z))
	cam.position = Vector3(1, 0.8, 1).normalized() * (span * 2.4 + 0.8)
	cam.look_at_from_position(cam.position, Vector3.ZERO)
	cam.current = true
	viewport.add_child(cam)
	_preview_roots.append(pivot)
	var box := SubViewportContainer.new()
	box.custom_minimum_size = Vector2(120, 88)
	box.stretch = true
	box.add_child(viewport)
	return box


func _make_theme() -> Theme:
	var theme := Theme.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["PingFang SC", "Hiragino Sans GB", "Heiti SC", "Songti SC"])
	theme.default_font = font
	theme.default_font_size = 15
	var normal := _flat(Color(0.09, 0.09, 0.09), Color(0.28, 0.28, 0.28))
	var hover := _flat(Color(0.16, 0.16, 0.16), Color(0.45, 0.45, 0.45))
	var pressed := _flat(Color(0.24, 0.24, 0.24), Color(0.7, 0.7, 0.7))
	theme.set_stylebox("normal", "Button", normal)
	theme.set_stylebox("hover", "Button", hover)
	theme.set_stylebox("pressed", "Button", pressed)
	theme.set_stylebox("focus", "Button", normal)
	theme.set_color("font_color", "Button", Color(0.94, 0.94, 0.94))
	theme.set_color("font_hover_color", "Button", Color.WHITE)
	theme.set_color("font_pressed_color", "Button", Color.WHITE)
	theme.set_color("font_color", "Label", Color(0.92, 0.92, 0.92))
	var list_bg := _flat(Color(0, 0, 0), Color(0.2, 0.2, 0.2))
	theme.set_stylebox("panel", "ItemList", list_bg)
	theme.set_color("font_color", "ItemList", Color(0.86, 0.92, 0.84))
	theme.set_color("font_selected_color", "ItemList", Color.WHITE)
	theme.set_stylebox("selected", "ItemList", _flat(Color(0.16, 0.22, 0.16), Color(0.3, 0.45, 0.3)))
	theme.set_stylebox("hovered", "ItemList", _flat(Color(0.1, 0.1, 0.1), Color(0.25, 0.25, 0.25)))
	theme.set_color("font_color", "TextEdit", Color(0.72, 0.9, 0.68))
	theme.set_color("background_color", "TextEdit", Color(0, 0, 0))
	theme.set_stylebox("normal", "TextEdit", _flat(Color(0, 0, 0), Color(0.2, 0.2, 0.2)))
	return theme


func _flat(bg: Color, border: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg
	box.border_color = border
	box.set_border_width_all(1)
	box.set_content_margin_all(6)
	return box


func _power_text(def: UnitDB.PartDef) -> String:
	if def.energy_j > 0.0:
		return "%s J" % _joule(def.energy_j)
	if def.propeller:
		return "±%s N" % _num(def.thrust_n)
	if def.wheel:
		return "%s W 满转" % _num(def.power_w)
	return "%s W" % _num(def.power_w)


func _joule(value: float) -> String:
	return str(int(round(value)))


func _num(value: float) -> String:
	if is_equal_approx(value, round(value)):
		return str(int(round(value)))
	return str(value)
