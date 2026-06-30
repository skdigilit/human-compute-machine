class_name Game
extends Control

## Top-level orchestrator. Owns the level, the program model and the VM, lays
## out every panel, and drives execution by feeding VM StepActions to the
## RoomView animation while keeping the program highlight and status in sync.
##
## Logic lives here; presentation lives in the panels. The VM never touches a
## node and the panels never execute instructions.

# The initial viewport determines the room's grid layout. UI panels may resize
# freely; room width and child coordinates stay stable so the grid-based puzzle
# and character visuals do not shift during window resizes.
const PANEL_GAP := 8.0
const ROOM_WIDTH_RATIO := 0.64
const PALETTE_WIDTH_RATIO := 0.12
const CONTROL_HEIGHT_RATIO := 0.10
const BRIEFING_HEIGHT_RATIO := 0.25
const MIN_ROOM_WIDTH := 720.0
const MIN_PALETTE_WIDTH := 180.0
const MIN_EDITOR_WIDTH := 330.0
const MIN_CONTROL_HEIGHT := 112.0
const MIN_BRIEFING_HEIGHT := 220.0
const MIN_PROGRAM_HEIGHT := 260.0
const MAX_PROGRAM_PAGES := 3
const DEFAULT_SAVE_PATH := "user://instruction_pages.json"
const RESIZE_EDGE_THICKNESS := 10.0
const RESIZE_NONE := 0
const RESIZE_PALETTE_SPLIT := 1
const RESIZE_EDITOR_SPLIT := 2
const RESIZE_ROOM_SPLIT := 3
const WIN_BANNER_BOTTOM_GAP_RATIO := 0.20

var _level: Level
var _levels: Array[Level] = []
var _level_index: int = 0
var _program: Program
var _program_pages: Array[Program] = []
var _active_page: int = 0
var _saved_levels: Dictionary = {}
var _save_path: String = DEFAULT_SAVE_PATH
var _vm: VM = null

var _room: RoomView
var _palette: InstructionPalette
var _briefing: BriefingNote
var _program_list: ProgramListView
var _control_bar: ControlBar
var _win_banner: Label
var _room_visual_size: Vector2 = Vector2.ZERO
var _palette_sidebar_ratio: float = 0.0
var _editor_question_ratio: float = BRIEFING_HEIGHT_RATIO
var _resize_kind: int = RESIZE_NONE

var _running: bool = false
var _busy: bool = false
var _halted: bool = false
var _step_buffered: bool = false
var _manual_step_loop_active: bool = false
var _delay: float = 0.4

func _ready() -> void:
	VisualTheme.set_viewport_size(get_viewport_rect().size)
	theme = VisualTheme.make_ui_theme()
	_levels = LevelLibrary.all_levels()
	_level = _levels[_level_index]
	_load_saved_levels()
	_load_level_pages()
	_build_background()
	_build_panels()
	_room_visual_size = _compute_initial_room_size(get_viewport_rect().size)
	_room.set_virtual_size(_room_visual_size)
	_palette_sidebar_ratio = _compute_initial_palette_sidebar_ratio(get_viewport_rect().size, _room_visual_size.x)
	_layout_panels(get_viewport_rect().size)
	_wire_signals()
	_delay = _control_bar.initial_delay()
	_start_fresh()
	_apply_ui_scale(false)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _room != null:
		if VisualTheme.set_viewport_size(get_viewport_rect().size):
			_apply_ui_scale(false)
		_layout_panels(get_viewport_rect().size)

func _input(event: InputEvent) -> void:
	if _handle_resize_input(event):
		return
	if event is InputEventKey:
		var key := event as InputEventKey
		if not key.pressed or key.echo:
			return
		if _is_scale_up_key(key):
			if VisualTheme.adjust_user_ui_scale(1):
				_apply_ui_scale()
			accept_event()
		elif _is_scale_down_key(key):
			if VisualTheme.adjust_user_ui_scale(-1):
				_apply_ui_scale()
			accept_event()
		elif _is_show_hint_key(key):
			_briefing.show_hint()
			accept_event()

# --- Construction -------------------------------------------------------------

func _build_background() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color.html(VisualTheme.ROOM_FLOOR_DARK)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

func _build_panels() -> void:
	_room = RoomView.new()
	add_child(_room)

	_control_bar = ControlBar.new()
	add_child(_control_bar)

	_palette = InstructionPalette.new()
	add_child(_palette)

	_briefing = BriefingNote.new()
	add_child(_briefing)

	_program_list = ProgramListView.new()
	add_child(_program_list)

	_win_banner = Label.new()
	_win_banner.text = "GREAT JOB!"
	_win_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_win_banner.add_theme_color_override("font_color", Color.html("#FFE066"))
	_win_banner.add_theme_color_override("font_outline_color", Color.html("#5A4A10"))
	_win_banner.visible = false
	add_child(_win_banner)
	_apply_win_banner_scale()

func _compute_initial_room_size(viewport_size: Vector2) -> Vector2:
	var gap := _panel_gap()
	var available_width := viewport_size.x - gap * 4.0
	var palette_width := maxf(_min_palette_width(), viewport_size.x * PALETTE_WIDTH_RATIO)
	var editor_width := maxf(_min_editor_width(), viewport_size.x - viewport_size.x * ROOM_WIDTH_RATIO - palette_width - gap * 4.0)
	var room_width := available_width - palette_width - editor_width
	if room_width < _min_room_width():
		room_width = _min_room_width()
		editor_width = maxf(_min_editor_width(), available_width - room_width - palette_width)

	var control_height := maxf(_min_control_height(), viewport_size.y * CONTROL_HEIGHT_RATIO)
	var room_height := viewport_size.y - control_height - gap * 3.0
	return Vector2(room_width, room_height)

func _compute_initial_palette_sidebar_ratio(viewport_size: Vector2, room_width: float) -> float:
	var gap := _panel_gap()
	var right_width := maxf(1.0, viewport_size.x - room_width - gap * 4.0)
	var palette_width := minf(right_width, maxf(_min_palette_width(), viewport_size.x * PALETTE_WIDTH_RATIO))
	return clampf(palette_width / right_width, 0.0, 1.0)

## Size every panel from the current window while preserving room coordinates.
func _layout_panels(viewport_size: Vector2) -> void:
	var gap := _panel_gap()
	if _room_visual_size == Vector2.ZERO:
		_room_visual_size = _compute_initial_room_size(viewport_size)
	if _palette_sidebar_ratio <= 0.0:
		_palette_sidebar_ratio = _compute_initial_palette_sidebar_ratio(viewport_size, _room_visual_size.x)

	var content_width := maxf(1.0, viewport_size.x - gap * 4.0)
	var control_height := clampf(
		maxf(_min_control_height(), viewport_size.y * CONTROL_HEIGHT_RATIO * VisualTheme.effective_ui_scale()),
		minf(viewport_size.y * 0.18, viewport_size.y - gap * 3.0),
		maxf(gap, viewport_size.y * 0.34)
	)
	var top_height := maxf(1.0, viewport_size.y - control_height - gap * 3.0)
	var widths := _adaptive_column_widths(content_width)
	var room_width: float = widths[0]
	var palette_width: float = widths[1]
	var editor_width: float = widths[2]

	var editor_stack_height := maxf(1.0, top_height - gap)
	var briefing_height := editor_stack_height * _clamped_editor_question_ratio(editor_stack_height)
	var program_height := editor_stack_height - briefing_height

	_room.position = Vector2(gap, gap)
	_room.size = Vector2(room_width, top_height)
	var actual_room_width := minf(_room.size.x, maxf(1.0, viewport_size.x - gap * 4.0))
	_room.size = Vector2(actual_room_width, top_height)

	_control_bar.position = Vector2(gap, gap * 2.0 + top_height)
	_control_bar.size = Vector2(maxf(1.0, viewport_size.x - gap * 2.0), control_height)

	_palette.position = Vector2(actual_room_width + gap * 2.0, gap)
	_palette.size = Vector2(palette_width, top_height)
	var max_palette_width := maxf(1.0, viewport_size.x - _palette.position.x - gap * 2.0)
	var actual_palette_width := minf(_palette.size.x, max_palette_width)
	_palette.size = Vector2(actual_palette_width, top_height)

	var editor_x := actual_room_width + actual_palette_width + gap * 3.0
	editor_width = maxf(1.0, viewport_size.x - editor_x - gap)
	_briefing.position = Vector2(editor_x, gap)
	_briefing.size = Vector2(editor_width, briefing_height)

	_program_list.position = Vector2(editor_x, briefing_height + gap * 2.0)
	_program_list.size = Vector2(editor_width, program_height)
	_layout_win_banner()

func _adaptive_column_widths(content_width: float) -> Array[float]:
	var ui_scale := VisualTheme.effective_ui_scale()
	var base_room_width := _room_visual_size.x if _room_visual_size != Vector2.ZERO else content_width * ROOM_WIDTH_RATIO
	var room_min := minf(base_room_width, maxf(320.0, content_width * 0.24))
	var base_right_width := maxf(1.0, content_width - base_room_width)
	var right_width := clampf(base_right_width * ui_scale, 1.0, content_width - room_min)
	var room_width := content_width - right_width
	var ratio_bounds := _palette_sidebar_ratio_bounds(right_width)
	var palette_ratio := clampf(_palette_sidebar_ratio, ratio_bounds.x, ratio_bounds.y)
	var palette_width := right_width * palette_ratio
	var editor_width := right_width - palette_width
	return [room_width, palette_width, editor_width]

func _palette_sidebar_ratio_bounds(right_width: float) -> Vector2:
	if right_width <= 1.0:
		return Vector2(0.12, 0.88)
	var min_ratio := clampf(_min_palette_width() / right_width, 0.12, 0.65)
	var max_ratio := clampf(1.0 - _min_editor_width() / right_width, 0.35, 0.88)
	if min_ratio > max_ratio:
		return Vector2(0.12, 0.88)
	return Vector2(min_ratio, max_ratio)

func _clamped_editor_question_ratio(stack_height: float) -> float:
	if stack_height <= 1.0:
		return BRIEFING_HEIGHT_RATIO
	var min_ratio := clampf(_min_briefing_height() / stack_height, 0.12, 0.80)
	var max_ratio := clampf(1.0 - _min_program_height() / stack_height, 0.20, 0.88)
	if min_ratio > max_ratio:
		return clampf(_editor_question_ratio, 0.12, 0.88)
	return clampf(_editor_question_ratio, min_ratio, max_ratio)

func _panel_gap() -> float:
	return VisualTheme.scaled(PANEL_GAP, 4.0, 36.0)

func _min_room_width() -> float:
	return MIN_ROOM_WIDTH

func _min_palette_width() -> float:
	return VisualTheme.scaled(MIN_PALETTE_WIDTH, 90.0, 1440.0)

func _min_editor_width() -> float:
	return VisualTheme.scaled(MIN_EDITOR_WIDTH, 170.0, 2560.0)

func _min_control_height() -> float:
	return VisualTheme.scaled(MIN_CONTROL_HEIGHT, 56.0, 880.0)

func _min_briefing_height() -> float:
	return VisualTheme.scaled(MIN_BRIEFING_HEIGHT, 110.0, 1680.0)

func _min_program_height() -> float:
	return VisualTheme.scaled(MIN_PROGRAM_HEIGHT, 130.0, 2080.0)

func _apply_ui_scale(rebuild_dynamic_panels: bool = true) -> void:
	theme = VisualTheme.make_ui_theme()
	_apply_win_banner_scale()
	if _control_bar:
		_control_bar.apply_ui_scale()
	if rebuild_dynamic_panels:
		if _briefing and _level:
			_briefing.set_level(_level, _level_index, _levels.size())
		if _palette and _level:
			_palette.build(_level)
		if _program_list and _program:
			_program_list.apply_ui_scale()
	if _room:
		_room.apply_ui_scale()
	_layout_panels(get_viewport_rect().size)

func _apply_win_banner_scale() -> void:
	if _win_banner == null:
		return
	VisualTheme.apply_font_size(_win_banner, 64, 24, 180)
	_win_banner.add_theme_constant_override("outline_size", VisualTheme.scaled_int(8, 2, 28))
	_layout_win_banner()

func _layout_win_banner() -> void:
	if _win_banner == null or _room == null:
		return
	var decoration_rect := _room.bottom_decoration_rect()
	var banner_size := _win_banner.get_combined_minimum_size()
	_win_banner.size = Vector2(decoration_rect.size.x, banner_size.y)
	_win_banner.position = _room.position + Vector2(
		decoration_rect.get_center().x - _win_banner.size.x * 0.5,
		decoration_rect.position.y - _win_banner.size.y - decoration_rect.size.y * WIN_BANNER_BOTTOM_GAP_RATIO
	)

func _is_scale_up_key(key: InputEventKey) -> bool:
	return (
		key.unicode == 43
		or _matches_key(key, [KEY_PLUS, KEY_KP_ADD])
		or (_matches_key(key, [KEY_EQUAL]) and key.shift_pressed)
	)

func _is_scale_down_key(key: InputEventKey) -> bool:
	return key.unicode == 45 or _matches_key(key, [KEY_MINUS, KEY_KP_SUBTRACT])

func _is_show_hint_key(key: InputEventKey) -> bool:
	return key.shift_pressed and _matches_key(key, [KEY_H])

func _matches_key(key: InputEventKey, codes: Array[int]) -> bool:
	for code in codes:
		if key.keycode == code or key.physical_keycode == code or key.key_label == code:
			return true
	return false

func _handle_resize_input(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index != MOUSE_BUTTON_LEFT:
			return false
		if button.pressed:
			_resize_kind = _resize_edge_at(button.position, _event_resize_modifier_pressed(button))
			if _resize_kind != RESIZE_NONE:
				accept_event()
				return true
		elif _resize_kind != RESIZE_NONE:
			_resize_kind = RESIZE_NONE
			_update_resize_cursor(button.position, _event_resize_modifier_pressed(button))
			accept_event()
			return true
	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _resize_kind != RESIZE_NONE:
			_apply_panel_resize(motion.position)
			accept_event()
			return true
		_update_resize_cursor(motion.position, _event_resize_modifier_pressed(motion))
	return false

func _event_resize_modifier_pressed(event: InputEventWithModifiers) -> bool:
	return event.ctrl_pressed or event.meta_pressed

func _resize_edge_at(mouse_position: Vector2, modifier_pressed: bool) -> int:
	if not modifier_pressed:
		return RESIZE_NONE
	var edge := _resize_edge_thickness()
	if _horizontal_edge_hit(_briefing, mouse_position, true, edge) or _horizontal_edge_hit(_program_list, mouse_position, false, edge):
		return RESIZE_EDITOR_SPLIT
	if _vertical_edge_hit(_palette, mouse_position, false, edge):
		return RESIZE_ROOM_SPLIT
	if _vertical_edge_hit(_palette, mouse_position, true, edge):
		return RESIZE_PALETTE_SPLIT
	return RESIZE_NONE

func _update_resize_cursor(mouse_position: Vector2, modifier_pressed: bool) -> void:
	match _resize_edge_at(mouse_position, modifier_pressed):
		RESIZE_PALETTE_SPLIT, RESIZE_ROOM_SPLIT:
			Input.set_default_cursor_shape(Input.CURSOR_HSIZE)
		RESIZE_EDITOR_SPLIT:
			Input.set_default_cursor_shape(Input.CURSOR_VSIZE)
		_:
			Input.set_default_cursor_shape(Input.CURSOR_ARROW)

func _resize_edge_thickness() -> float:
	return VisualTheme.scaled(RESIZE_EDGE_THICKNESS, 6.0, 32.0)

func _horizontal_edge_hit(control: Control, mouse_position: Vector2, bottom_edge: bool, edge: float) -> bool:
	if control == null:
		return false
	var rect := control.get_global_rect()
	var y := rect.end.y if bottom_edge else rect.position.y
	return (
		absf(mouse_position.y - y) <= edge
		and mouse_position.x >= rect.position.x - edge
		and mouse_position.x <= rect.end.x + edge
	)

func _vertical_edge_hit(control: Control, mouse_position: Vector2, right_edge: bool, edge: float) -> bool:
	if control == null:
		return false
	var rect := control.get_global_rect()
	var x := rect.end.x if right_edge else rect.position.x
	return (
		absf(mouse_position.x - x) <= edge
		and mouse_position.y >= rect.position.y - edge
		and mouse_position.y <= rect.end.y + edge
	)

func _apply_panel_resize(mouse_position: Vector2) -> void:
	match _resize_kind:
		RESIZE_PALETTE_SPLIT:
			_resize_palette_split(mouse_position)
		RESIZE_EDITOR_SPLIT:
			_resize_editor_split(mouse_position)
		RESIZE_ROOM_SPLIT:
			_resize_room_split(mouse_position)
	_layout_panels(get_viewport_rect().size)

func _resize_palette_split(mouse_position: Vector2) -> void:
	var right_width := _palette.size.x + _program_list.size.x
	if right_width <= 1.0:
		return
	var palette_width := mouse_position.x - _palette.position.x
	var ratio_bounds := _palette_sidebar_ratio_bounds(right_width)
	_palette_sidebar_ratio = clampf(palette_width / right_width, ratio_bounds.x, ratio_bounds.y)

func _resize_room_split(mouse_position: Vector2) -> void:
	var viewport_size := get_viewport_rect().size
	var gap := _panel_gap()
	var content_width := maxf(1.0, viewport_size.x - gap * 4.0)
	var right_min_width := _min_palette_width() + _min_editor_width()
	var room_min_width := minf(_min_room_width(), maxf(320.0, content_width * 0.24))
	var room_max_width := maxf(room_min_width, content_width - right_min_width)
	var desired_room_width := clampf(mouse_position.x - gap * 2.0, room_min_width, room_max_width)
	var ui_scale := VisualTheme.effective_ui_scale()
	var desired_right_width := maxf(1.0, content_width - desired_room_width)
	var base_room_width := content_width - desired_right_width / ui_scale
	_room_visual_size.x = clampf(base_room_width, room_min_width, room_max_width)

func _resize_editor_split(mouse_position: Vector2) -> void:
	var stack_top := _briefing.position.y
	var stack_height := _briefing.size.y + _program_list.size.y
	if stack_height <= 1.0:
		return
	_editor_question_ratio = _clamped_ratio_for_height(mouse_position.y - stack_top, stack_height)

func _clamped_ratio_for_height(height: float, stack_height: float) -> float:
	var min_ratio := clampf(_min_briefing_height() / stack_height, 0.12, 0.80)
	var max_ratio := clampf(1.0 - _min_program_height() / stack_height, 0.20, 0.88)
	if min_ratio > max_ratio:
		return clampf(height / stack_height, 0.12, 0.88)
	return clampf(height / stack_height, min_ratio, max_ratio)

func _wire_signals() -> void:
	_control_bar.reset_requested.connect(_on_reset)
	_control_bar.step_requested.connect(_on_step)
	_control_bar.play_toggled.connect(_on_play_toggled)
	_control_bar.speed_changed.connect(func(d: float) -> void: _delay = d)
	_program_list.program_changed.connect(_on_program_changed)
	_program_list.page_requested.connect(_on_page_requested)
	_program_list.add_page_requested.connect(_on_add_page_requested)
	_briefing.previous_requested.connect(func() -> void: _select_level(_level_index - 1))
	_briefing.next_requested.connect(func() -> void: _select_level(_level_index + 1))

# --- Level / run lifecycle ----------------------------------------------------

## Build (or rebuild) all level-dependent views from scratch.
func _start_fresh() -> void:
	_briefing.set_level(_level, _level_index, _levels.size())
	_palette.build(_level)
	_program_list.setup(_program, _level.memory_size, _active_page, _program_pages.size())
	_reset_run()

func _select_level(index: int) -> void:
	if index < 0 or index >= _levels.size() or index == _level_index:
		return
	_save_current_level()
	_level_index = index
	_level = _levels[_level_index]
	_load_level_pages()
	_start_fresh()

## Discard the running machine and return the floor to the level's start.
func _reset_run() -> void:
	_running = false
	_halted = false
	_busy = false
	_step_buffered = false
	_vm = null
	_room.setup(_level)
	_program_list.set_active_line(-1)
	_win_banner.visible = false
	_control_bar.set_running(false)
	_control_bar.set_status("Drag a move into the list. Press RUN to watch it!")

## Create the VM lazily so edits before the first run are always honoured.
func _ensure_vm() -> void:
	if _vm == null:
		_vm = VM.new(_level, _program)
		_halted = false

# --- Control bar handlers -----------------------------------------------------

func _on_reset() -> void:
	_reset_run()

func _on_program_changed() -> void:
	# Any edit invalidates a half-run machine; rewind to a clean state.
	_save_current_level()
	_reset_run()

func _on_page_requested(index: int) -> void:
	if index < 0 or index >= _program_pages.size() or index == _active_page:
		return
	_active_page = index
	_program = _program_pages[_active_page]
	_save_current_level()
	_program_list.setup(_program, _level.memory_size, _active_page, _program_pages.size())
	_reset_run()

func _on_add_page_requested() -> void:
	if _program_pages.size() >= MAX_PROGRAM_PAGES:
		return
	_program_pages.append(Program.new())
	_active_page = _program_pages.size() - 1
	_program = _program_pages[_active_page]
	_save_current_level()
	_program_list.setup(_program, _level.memory_size, _active_page, _program_pages.size())
	_reset_run()

# --- Instruction page persistence --------------------------------------------

func _level_save_key() -> String:
	return str(_level_index)

func _load_saved_levels() -> void:
	if not FileAccess.file_exists(_save_path):
		return
	var file := FileAccess.open(_save_path, FileAccess.READ)
	if file == null:
		push_warning("Could not open instruction page save file.")
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary and parsed.get("levels", {}) is Dictionary:
		_saved_levels = parsed.get("levels", {})

func _load_level_pages() -> void:
	_program_pages.clear()
	_active_page = 0
	var saved: Variant = _saved_levels.get(_level_save_key(), {})
	if saved is Dictionary:
		var pages: Variant = saved.get("pages", [])
		if pages is Array:
			for page_data in pages.slice(0, MAX_PROGRAM_PAGES):
				if page_data is Array:
					_program_pages.append(Program.from_data(page_data))
		_active_page = clampi(int(saved.get("active_page", 0)), 0, maxi(0, _program_pages.size() - 1))
	if _program_pages.is_empty():
		_program_pages.append(Program.new())
	_program = _program_pages[_active_page]

func _save_current_level() -> void:
	var pages: Array = []
	for page in _program_pages:
		pages.append(page.to_data())
	_saved_levels[_level_save_key()] = {
		"active_page": _active_page,
		"pages": pages,
	}
	var file := FileAccess.open(_save_path, FileAccess.WRITE)
	if file == null:
		push_warning("Could not save instruction pages.")
		return
	file.store_string(JSON.stringify({
		"version": 1,
		"levels": _saved_levels,
	}, "\t"))

func _on_play_toggled(should_run: bool) -> void:
	if should_run:
		_running = true
		_run_loop()
	else:
		_running = false

func _on_step() -> void:
	if _running:
		return
	_step_buffered = true
	if _busy:
		_room.speed_up_current_animation()
		return
	_run_manual_steps()

## Consume manual step requests one at a time. Multiple clicks during the same
## instruction collapse into one buffered request for the following instruction.
func _run_manual_steps() -> void:
	if _manual_step_loop_active:
		return
	_manual_step_loop_active = true
	while _step_buffered and not _running and not _halted:
		_step_buffered = false
		await _execute_one()
	_manual_step_loop_active = false

## Auto-advance through the program at the chosen speed until paused or halted.
func _run_loop() -> void:
	while _running:
		await _execute_one()
		if _halted or not _running:
			break
		await get_tree().create_timer(_delay).timeout
	_running = false
	_control_bar.set_running(false)
	if _step_buffered and not _halted:
		_run_manual_steps()

## Execute exactly one instruction and play back its animation. Guarded so
## overlapping triggers (fast clicks, run loop) never interleave.
func _execute_one() -> void:
	if _busy or _halted:
		return
	_busy = true
	_ensure_vm()

	if _program.size() == 0:
		_control_bar.set_status("Your program is empty — drag in some commands!")
		_busy = false
		return

	var action := _vm.step()
	if not action.halted:
		_program_list.set_active_line(action.line_index)
	await _room.animate(action)

	if action.halted:
		_finish(action)
	else:
		_program_list.set_active_line(_vm.pc)
	_busy = false

## React to the program ending (win, wrong output, or error).
func _finish(action: StepAction) -> void:
	_halted = true
	_running = false
	_control_bar.set_running(false)
	_program_list.set_active_line(-1)
	_control_bar.set_status(action.message)
	_win_banner.visible = action.success
