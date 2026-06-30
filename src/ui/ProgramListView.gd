class_name ProgramListView
extends Control

## The numbered program — the heart of the editor. It:
##  * renders one row per instruction,
##  * accepts palette drops (insert) and self drops (reorder),
##  * shows an empty "landing slot" where a dragged command will fall,
##  * deletes a line when it is dragged out of the list,
##  * lets a jump's arrow be dragged onto a line to set its target,
##  * gives every jump a dummy instruction box before its destination row,
##  * highlights the executing line.

signal program_changed()
signal page_requested(index: int)
signal add_page_requested()

const LINE_NUMBER_WIDTH := 34.0
const HEADER_HEIGHT := 50.0
const MAX_PAGES := 3
const TARGET_BOX_SIZE := Vector2(86, 34)
const ROW_DIM_ALPHA := 0.3 ## Opacity of a line while it is being dragged.
const CONNECTOR_LANE_GAP := 8.0

var program: Program
var memory_size: int = 0

var _scroll: ScrollContainer
var _list: VBoxContainer
var _blocks: Array[InstructionBlock] = []
var _active_index: int = -1
var _jump_underlay: Control
var _page_header: HBoxContainer
var _target_boxes: Dictionary = {} ## Jump instruction id -> dummy target box.
var _page_buttons: Array[Button] = []
var _add_page_button: Button
var _active_page: int = 0
var _page_count: int = 1

# Drag-session state -----------------------------------------------------------
var _placeholder: PanelContainer            ## The empty landing slot.
var _row_centers: Array[float] = []         ## Global y-centres cached at drag start.
var _dragging_block: InstructionBlock = null  ## Line being reordered (for delete).
var _drop_handled: bool = false             ## True once a drop was consumed here.
var _jump_drag_source: InstructionBlock = null  ## Jump whose arrow is being dragged.
var _jump_drag_origin: Control = null       ## Handle or blank box drag started from.
var _candidate_block: InstructionBlock = null   ## Line a dragged arrow points at.

func _init() -> void:
	clip_contents = true

func _ready() -> void:
	var panel := Panel.new()
	panel.add_theme_stylebox_override("panel", _make_panel_style())
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)

	# Connectors live below the scroll/list, so they never intercept input or
	# paint over command blocks and target markers.
	_jump_underlay = Control.new()
	_jump_underlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_jump_underlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_jump_underlay.draw.connect(_draw_jump_underlay)
	add_child(_jump_underlay)

	_scroll = ScrollContainer.new()
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_apply_scroll_offsets()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_scroll)

	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", VisualTheme.scaled_int(5, 2, 28))
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.mouse_filter = Control.MOUSE_FILTER_PASS
	_scroll.add_child(_list)

	_build_page_header()
	_placeholder = _make_placeholder()
	set_process(true)

func _build_page_header() -> void:
	_page_header = HBoxContainer.new()
	_page_header.position = Vector2(10, 8)
	_page_header.size = Vector2(size.x - 20, 34)
	_page_header.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_apply_header_offsets()
	_page_header.add_theme_constant_override("separation", VisualTheme.scaled_int(6, 2, 28))
	add_child(_page_header)

	for i in MAX_PAGES:
		var page_button := Button.new()
		page_button.text = str(i + 1)
		VisualTheme.apply_button_size(page_button, Vector2(42, 34), 18, 24.0)
		page_button.pressed.connect(_on_page_button_pressed.bind(i))
		_page_header.add_child(page_button)
		_page_buttons.append(page_button)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_page_header.add_child(spacer)

	_add_page_button = Button.new()
	_add_page_button.text = "+"
	_add_page_button.tooltip_text = "Add instruction page"
	VisualTheme.apply_button_size(_add_page_button, Vector2(42, 34), 24, 20.0)
	_add_page_button.pressed.connect(func() -> void: add_page_requested.emit())
	_page_header.add_child(_add_page_button)
	_refresh_page_header()

func _on_page_button_pressed(index: int) -> void:
	page_requested.emit(index)

func _refresh_page_header() -> void:
	for i in _page_buttons.size():
		var button := _page_buttons[i]
		button.visible = i < _page_count
		_apply_page_button_style(button, i == _active_page)
		button.tooltip_text = "Instruction page %d" % (i + 1)
	if _add_page_button:
		_add_page_button.disabled = _page_count >= MAX_PAGES
		_add_page_button.tooltip_text = (
			"Maximum of three instruction pages"
			if _add_page_button.disabled
			else "Add instruction page"
		)

func _apply_page_button_style(button: Button, is_active: bool) -> void:
	var fill := VisualTheme.SUN if is_active else "#B8AE91"
	var border := "#8A6415" if is_active else "#8C8269"
	var text := Color.html(VisualTheme.INK) if is_active else Color(0.22, 0.21, 0.17, 0.55)
	var style := VisualTheme.make_box_style(fill, border, 4)
	button.add_theme_stylebox_override("normal", style)
	button.add_theme_stylebox_override("hover", style if is_active else VisualTheme.make_box_style("#CDC3A5", border, 4))
	button.add_theme_stylebox_override("pressed", style)
	VisualTheme.set_button_font_color(button, text)
	var base_font_size := 24 if button == _add_page_button else 18
	VisualTheme.apply_button_size(button, Vector2(42, 34), base_font_size, 24.0)

## The dashed empty slot shown at the drop position.
func _make_placeholder() -> PanelContainer:
	var slot := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.18)
	style.border_color = Color.html("#8C7E5C")
	style.set_border_width_all(VisualTheme.scaled_int(2, 1, 14))
	style.set_corner_radius_all(VisualTheme.scaled_int(7, 2, 36))
	slot.add_theme_stylebox_override("panel", style)
	slot.custom_minimum_size = VisualTheme.scaled_size(Vector2(0, 42), Vector2(0, 18), Vector2(0, 344))
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var hint := Label.new()
	hint.text = "DROP MOVE HERE"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_color_override("font_color", Color(0.3, 0.27, 0.18, 0.7))
	VisualTheme.apply_font_size(hint, 16, 6, 136)
	slot.add_child(hint)
	return slot

func apply_ui_scale() -> void:
	for child in get_children():
		if child is Panel:
			child.add_theme_stylebox_override("panel", _make_panel_style())
			break
	_apply_scroll_offsets()
	if _list:
		_list.add_theme_constant_override("separation", VisualTheme.scaled_int(5, 2, 28))
	if _page_header:
		_apply_header_offsets()
		_page_header.add_theme_constant_override("separation", VisualTheme.scaled_int(6, 2, 28))
	for button in _page_buttons:
		VisualTheme.apply_button_size(button, Vector2(42, 34), 18, 24.0)
	if _add_page_button:
		VisualTheme.apply_button_size(_add_page_button, Vector2(42, 34), 24, 20.0)
	_refresh_page_header()
	if _placeholder:
		_detach_placeholder()
		_placeholder.queue_free()
	_placeholder = _make_placeholder()
	var active_index := _active_index
	rebuild()
	set_active_line(active_index)

func _make_panel_style() -> StyleBoxFlat:
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color.html("#E7DFC5")
	bg.border_color = Color.html(VisualTheme.INK)
	bg.set_border_width_all(VisualTheme.scaled_int(4, 1, 24))
	bg.set_corner_radius_all(VisualTheme.scaled_int(VisualTheme.UI_PANEL_RADIUS, 6, 72))
	return bg

func _apply_scroll_offsets() -> void:
	if _scroll == null:
		return
	var inset := VisualTheme.scaled(8.0, 3.0, 36.0)
	_scroll.offset_right = -inset
	_scroll.offset_left = inset
	_scroll.offset_top = _header_height()
	_scroll.offset_bottom = -inset

func _apply_header_offsets() -> void:
	if _page_header == null:
		return
	_page_header.offset_left = VisualTheme.scaled(10.0, 4.0, 44.0)
	_page_header.offset_right = -VisualTheme.scaled(10.0, 4.0, 44.0)
	_page_header.offset_top = VisualTheme.scaled(8.0, 3.0, 36.0)
	_page_header.offset_bottom = _header_height() - VisualTheme.scaled(8.0, 3.0, 36.0)

func _line_number_width() -> float:
	return VisualTheme.scaled(LINE_NUMBER_WIDTH, 15.0, 288.0)

func _header_height() -> float:
	return VisualTheme.scaled(HEADER_HEIGHT, 22.0, 376.0)

func _target_box_size() -> Vector2:
	return VisualTheme.scaled_size(TARGET_BOX_SIZE, Vector2(40, 16), Vector2(680, 280))

func _connector_lane_gap() -> float:
	return VisualTheme.scaled(CONNECTOR_LANE_GAP, 3.0, 36.0)

## Bind the program model and (re)draw all rows.
func setup(p_program: Program, p_memory_size: int, p_active_page: int = 0, p_page_count: int = 1) -> void:
	program = p_program
	memory_size = p_memory_size
	_active_page = p_active_page
	_page_count = clampi(p_page_count, 1, MAX_PAGES)
	_refresh_page_header()
	rebuild()

## Recreate every row from the program model.
func rebuild() -> void:
	_detach_placeholder()
	for child in _list.get_children():
		child.queue_free()
	_blocks.clear()
	_target_boxes.clear()
	_candidate_block = null

	var rows: Array[Control] = []
	for i in program.size():
		var inst := program.instructions[i]
		rows.append(_make_row(i, inst))

	for target_index in program.size():
		for jump_index in program.size():
			var jump := program.instructions[jump_index]
			if not jump.is_jump():
				continue
			var resolved_target := program.index_of_id(jump.jump_target_id)
			if resolved_target == -1:
				resolved_target = jump_index
			if resolved_target != target_index:
				continue
			var box := _make_target_box(_blocks[jump_index])
			_target_boxes[jump.id] = box
			_list.add_child(_make_target_row(box))
		_list.add_child(rows[target_index])
	_refresh_all_targets()
	_update_jump_underlay()
	queue_redraw()

## Blank instruction-sized box showing where a jump lands.
func _make_target_box(owner_block: InstructionBlock) -> JumpTargetBox:
	var box := JumpTargetBox.new(owner_block)
	var style := StyleBoxFlat.new()
	style.bg_color = Color.html(InstructionDef.COLOR_JUMP)
	style.border_color = Color.html(InstructionDef.COLOR_JUMP).darkened(0.25)
	style.set_border_width_all(VisualTheme.scaled_int(3, 1, 18))
	style.set_corner_radius_all(VisualTheme.scaled_int(2, 1, 18))
	box.add_theme_stylebox_override("normal", style)
	box.add_theme_stylebox_override("hover", VisualTheme.make_box_style("#96A0D6", InstructionDef.COLOR_JUMP, 2))
	box.add_theme_stylebox_override("pressed", style)
	box.custom_minimum_size = _target_box_size()
	return box

## Dummy targets occupy their own unnumbered row immediately before the
## instruction they point at, matching the original game's jump labels.
func _make_target_row(box: JumpTargetBox) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", VisualTheme.scaled_int(8, 3, 36))
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	row.set_meta("jump_target_marker", true)

	var number_spacer := Control.new()
	number_spacer.custom_minimum_size = Vector2(_line_number_width(), 0)
	number_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(number_spacer)
	row.add_child(box)
	return row

## Build a single "NN  [block]" row.
func _make_row(index: int, inst: Instruction) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", VisualTheme.scaled_int(8, 3, 36))
	row.mouse_filter = Control.MOUSE_FILTER_PASS

	var number := Label.new()
	number.text = "%02d" % (index + 1)
	number.custom_minimum_size = Vector2(_line_number_width(), 0)
	number.add_theme_color_override("font_color", Color.html("#6B5E40"))
	VisualTheme.apply_font_size(number, 18, 6, 160)
	number.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(number)

	var block := InstructionBlock.new(inst.op, false, inst)
	block.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	block.set_memory_size(memory_size)
	block.request_target_pick.connect(_on_cycle_target)
	block.instruction_changed.connect(func() -> void: program_changed.emit())
	row.add_child(block)
	_blocks.append(block)
	return row

# --- Jump targets -------------------------------------------------------------

## Advance a jump's target to the next program line (wrapping). Used by clicking
## the arrow chip; dragging the arrow onto a line is handled in _drop_data.
func _on_cycle_target(block: InstructionBlock) -> void:
	if program.size() == 0:
		return
	var current := program.index_of_id(block.instruction.jump_target_id)
	var next := (current + 1) % program.size()
	block.instruction.jump_target_id = program.instructions[next].id
	_refresh_all_targets()
	queue_redraw()
	program_changed.emit()

## Update every jump chip to show its target's 1-based line number.
func _refresh_all_targets() -> void:
	for block in _blocks:
		if not block.has_target_chip():
			continue
		var idx := program.index_of_id(block.instruction.jump_target_id)
		block.set_target_label("→ ?" if idx == -1 else "→ %02d" % (idx + 1))

# --- Execution highlight ------------------------------------------------------

## Highlight the line the VM is about to run; pass -1 to clear.
func set_active_line(index: int) -> void:
	if _active_index >= 0 and _active_index < _blocks.size():
		_blocks[_active_index].set_active(false)
	_active_index = index
	if index >= 0 and index < _blocks.size():
		_blocks[index].set_active(true)
		_ensure_visible(_blocks[index])

## Scroll so a block is within the viewport (follows execution).
func _ensure_visible(block: InstructionBlock) -> void:
	var top := block.position.y
	var bottom := top + block.size.y
	if top < _scroll.scroll_vertical:
		_scroll.scroll_vertical = int(top)
	elif bottom > _scroll.scroll_vertical + _scroll.size.y:
		_scroll.scroll_vertical = int(bottom - _scroll.size.y)

# --- Drag session bookkeeping -------------------------------------------------

func _notification(what: int) -> void:
	match what:
		NOTIFICATION_DRAG_BEGIN:
			# Cache row centres from the clean layout so the landing slot index is
			# stable (inserting the slot must not move the thresholds = no jitter).
			_cache_row_centers()
			_drop_handled = false
		NOTIFICATION_DRAG_END:
			_end_drag_session()

## Called by a program block when it starts being dragged, so we can dim it and
## know which line to remove if it is dropped outside the list.
func _begin_reorder_drag(block: InstructionBlock) -> void:
	_dragging_block = block
	_drop_handled = false
	var row := block.get_parent() as Control
	if row:
		row.modulate.a = ROW_DIM_ALPHA

## Called by a jump handle or blank target box when it starts being dragged.
func _begin_jump_drag(block: InstructionBlock, origin: Control = null) -> void:
	_jump_drag_source = block
	_jump_drag_origin = origin

## Clean up after any drag: delete a line dropped outside, clear visuals.
func _end_drag_session() -> void:
	_hide_placeholder()
	_clear_candidate()
	var was_reorder := _dragging_block != null
	# A reorder that wasn't consumed by a drop on the list, and ended outside the
	# list, means the player flicked it away to delete it.
	if was_reorder and not _drop_handled and not _is_mouse_over_list():
		var idx := program.index_of_id(_dragging_block.instruction.id)
		if idx != -1:
			program.remove_at(idx)
			program_changed.emit()
	_dragging_block = null
	_jump_drag_source = null
	_jump_drag_origin = null
	if was_reorder:
		rebuild()  # restore dimming / reflect any deletion

# --- Drag and drop ------------------------------------------------------------

func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	return can_accept_at(global_position + at_position, data)

func _drop_data(at_position: Vector2, data: Variant) -> void:
	drop_at(global_position + at_position, data)

## Public entry points so program blocks can forward drops with a global point.
## (Godot reports drop positions local to whichever control was hit, and the
## live mouse position is unreliable mid-drag, so we resolve everything from the
## event's own position.)
func can_accept_at(global_point: Vector2, data: Variant) -> bool:
	if not (data is Dictionary and data.has(InstructionBlock.DRAG_KIND)):
		return false
	match data[InstructionBlock.DRAG_KIND]:
		InstructionBlock.DRAG_PALETTE, InstructionBlock.DRAG_REORDER:
			_clear_candidate()
			_show_placeholder_at(_insert_index(global_point.y))
			return true
		InstructionBlock.DRAG_JUMP_TARGET:
			_hide_placeholder()
			_set_candidate(_block_at(global_point))
			return true
	return false

func drop_at(global_point: Vector2, data: Variant) -> void:
	match data[InstructionBlock.DRAG_KIND]:
		InstructionBlock.DRAG_PALETTE:
			program.insert_at(_insert_index(global_point.y), Instruction.new(data[InstructionBlock.DRAG_OP]))
		InstructionBlock.DRAG_REORDER:
			_apply_reorder(data[InstructionBlock.DRAG_BLOCK], global_point)
		InstructionBlock.DRAG_JUMP_TARGET:
			_apply_jump_target(data[InstructionBlock.DRAG_JUMP_BLOCK], global_point)
	_drop_handled = true
	_hide_placeholder()
	_clear_candidate()
	set_active_line(-1)
	rebuild()
	program_changed.emit()

## Move an existing line to the landing slot at the drop point.
func _apply_reorder(moved: InstructionBlock, global_point: Vector2) -> void:
	var from := program.index_of_id(moved.instruction.id)
	if from == -1:
		return
	var index := _insert_index(global_point.y)
	if from < index:
		index -= 1  # removing the source shifts later indices left.
	var inst := program.remove_at(from)
	program.insert_at(index, inst)

## Point a jump's arrow at whatever line the drop landed on.
func _apply_jump_target(source: InstructionBlock, global_point: Vector2) -> void:
	var target := _block_at(global_point)
	if target == null or source == null:
		return
	source.instruction.jump_target_id = target.instruction.id

# --- Landing slot -------------------------------------------------------------

## Insert index implied by a global y, using the cached (pre-slot) row centres.
func _insert_index(global_y: float) -> int:
	for i in _row_centers.size():
		if global_y < _row_centers[i]:
			return i
	return _row_centers.size()

func _cache_row_centers() -> void:
	_row_centers.clear()
	for block in _blocks:
		_row_centers.append(block.get_global_rect().get_center().y)

## Show the empty landing slot before the row at `index`.
func _show_placeholder_at(index: int) -> void:
	# Re-attach at the end before resolving the child index so its previous
	# position cannot split a target marker from the instruction it labels.
	_detach_placeholder()
	_list.add_child(_placeholder)
	_list.move_child(_placeholder, _list_child_index_for_insert(index))
	_placeholder.visible = true

## Translate a program index to a VBox child index. Target-marker rows are
## attached to the instruction after them, so an insertion lands before both.
func _list_child_index_for_insert(index: int) -> int:
	if index >= _blocks.size():
		return _list.get_child_count() - (1 if _placeholder.get_parent() == _list else 0)
	var child_index := _blocks[index].get_parent().get_index()
	while child_index > 0 and _list.get_child(child_index - 1).has_meta("jump_target_marker"):
		child_index -= 1
	return child_index

func _hide_placeholder() -> void:
	_placeholder.visible = false
	_detach_placeholder()

func _detach_placeholder() -> void:
	if _placeholder.get_parent() != null:
		_placeholder.get_parent().remove_child(_placeholder)

# --- Jump-target candidate highlight -----------------------------------------

func _set_candidate(block: InstructionBlock) -> void:
	if block == _candidate_block:
		return
	_clear_candidate()
	_candidate_block = block
	if block:
		block.set_candidate(true)

func _clear_candidate() -> void:
	if _candidate_block and is_instance_valid(_candidate_block):
		_candidate_block.set_candidate(false)
	_candidate_block = null

## The program block whose row contains a global point, or null. Matches on the
## full row height (not just the block) so the whole line is an easy target.
func _block_at(global_point: Vector2) -> InstructionBlock:
	for block in _blocks:
		var rect := block.get_global_rect()
		if global_point.y >= rect.position.y and global_point.y <= rect.position.y + rect.size.y:
			return block
	return null

func _is_mouse_over_list() -> bool:
	return get_global_rect().has_point(get_global_mouse_position())

# --- Jump arrows --------------------------------------------------------------

func _process(_delta: float) -> void:
	# Block positions shift with layout/scroll; keep connectors in sync cheaply.
	# Also retract drag visuals when the cursor leaves the list mid-drag.
	if get_viewport().gui_is_dragging() and not _is_mouse_over_list():
		_hide_placeholder()
		_clear_candidate()
	_update_jump_underlay()
	if _jump_drag_source:
		queue_redraw()

func _draw() -> void:
	# While dragging a jump's arrow, rubber-band a line from it to the cursor.
	if _jump_drag_source and is_instance_valid(_jump_drag_source):
		var r := _local_control_rect(_jump_drag_origin) if is_instance_valid(_jump_drag_origin) else _local_rect(_jump_drag_source)
		var start := r.get_center()
		var end := get_local_mouse_position()
		draw_line(start, end, Color.html("#3FA0FF"), 3.0, true)
		_draw_arrowhead(end, (end - start).normalized(), Color.html("#3FA0FF"))

func _update_jump_underlay() -> void:
	if program == null or _jump_underlay == null:
		return
	_jump_underlay.queue_redraw()

## Draw straight orthogonal connectors as a secondary cue between each jump and
## its dummy target box. The target box itself remains the primary destination.
func _draw_jump_underlay() -> void:
	if program == null:
		return
	var color := Color.html("#7B86C4")
	for block_index in _blocks.size():
		var block := _blocks[block_index]
		var inst := block.instruction
		if not inst.is_jump() or not _target_boxes.has(inst.id):
			continue
		var source_rect := _local_rect(block)
		var target_box: JumpTargetBox = _target_boxes[inst.id]
		var start := Vector2(source_rect.position.x + source_rect.size.x, source_rect.get_center().y)
		var target_rect := _local_control_rect(target_box)
		var end := Vector2(target_rect.end.x, target_rect.get_center().y)
		var lane_x := minf(
			size.x - VisualTheme.scaled(14.0, 5.0, 56.0),
			maxf(start.x, end.x) + VisualTheme.scaled(38.0, 14.0, 152.0) + block_index * _connector_lane_gap()
		)
		var points := PackedVector2Array([
			start,
			Vector2(lane_x, start.y),
			Vector2(lane_x, end.y),
			end,
		])
		_jump_underlay.draw_polyline(points, color, 4.0, true)
		_draw_underlay_arrowhead(end, (end - points[-2]).normalized(), color)

## Small triangle pointing in `dir` at the arrow's landing point.
func _draw_arrowhead(tip: Vector2, dir: Vector2, color: Color) -> void:
	if dir == Vector2.ZERO:
		return
	var perp := Vector2(-dir.y, dir.x)
	var a := tip
	var b := tip - dir * 10 + perp * 6
	var c := tip - dir * 10 - perp * 6
	draw_colored_polygon(PackedVector2Array([a, b, c]), color)

func _draw_underlay_arrowhead(tip: Vector2, dir: Vector2, color: Color) -> void:
	if dir == Vector2.ZERO:
		return
	var perp := Vector2(-dir.y, dir.x)
	var a := tip
	var b := tip - dir * 10 + perp * 6
	var c := tip - dir * 10 - perp * 6
	_jump_underlay.draw_colored_polygon(PackedVector2Array([a, b, c]), color)

## A block's rectangle expressed in this control's local coordinates.
func _local_rect(block: InstructionBlock) -> Rect2:
	var r := block.get_global_rect()
	r.position -= global_position
	return r

func _local_control_rect(control: Control) -> Rect2:
	var r := control.get_global_rect()
	r.position -= global_position
	return r
