class_name RoomView
extends Control

## The office floor. Lays out the INBOX chute (left), the memory tiles (centre),
## the OUTBOX chute (right) and the worker, then animates each VM StepAction by
## walking the worker to the relevant station and snapping number boxes around.
##
## Visual state is kept in sync with the VM purely from StepActions, so this
## node never needs to know the execution rules — only how to play them back.

# --- Layout cells -------------------------------------------------------------
const CELL := VisualTheme.CELL_SIZE
const CHUTE_TOP_ROW := 3
const WORKER_HOME_CELL := Vector2(6.5, 5.5)
const MANUAL_STEP_SPEED_SCALE := 4.0

var _content_root: Control
var _virtual_size: Vector2 = Vector2(1152, 900)
var _content_scale: float = 1.0
var _content_offset: Vector2 = Vector2.ZERO
var _stage: Control          ## Holds all moving pieces above the floor art.
var worker: Worker

var _inbox_boxes: Array[NumberBox] = []
var _outbox_boxes: Array[NumberBox] = []
var _tile_boxes: Array[NumberBox] = []     ## Per memory tile, may hold null.
var _tile_centers: Array[Vector2] = []

var _inbox_x: float
var _outbox_x: float
var _chute_top: float
var _worker_home: Vector2
var _animation_speed_scale: float = 1.0
var _active_animation_tweens: Array[Tween] = []

func _init() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_update_content_transform()
		queue_redraw()

func _draw() -> void:
	var ink := Color.html(VisualTheme.ROOM_FLOOR_DARK)
	var paper := Color.html(VisualTheme.PAPER)
	draw_rect(Rect2(Vector2.ZERO, size), ink)
	draw_set_transform(_content_offset, 0.0, Vector2(_content_scale, _content_scale))

	# Warehouse decoration is assembled only from full grid cells.
	var tile_colors := [
		Color.html(VisualTheme.SKY),
		Color.html(VisualTheme.SUN),
		Color.html(VisualTheme.CORAL),
		Color.html(VisualTheme.PLUM),
	]
	for i in 7:
		var tile_rect := Rect2(Vector2((4 + i) * CELL, 1 * CELL), Vector2(CELL, CELL))
		draw_rect(tile_rect, tile_colors[i % tile_colors.size()], true)
		draw_rect(tile_rect, paper, false, 3.0)
		var inner := tile_rect.grow(-CELL * 0.28)
		draw_rect(inner, ink, false, 3.0)

	# A final row of alternating cells grounds the play area.
	var floor_row := _bottom_decoration_row()
	for column in floori(_virtual_size.x / CELL):
		var floor_cell := Rect2(Vector2(column * CELL, floor_row * CELL), Vector2(CELL, CELL))
		if column % 2 == 0:
			draw_rect(floor_cell, paper, true)
		draw_rect(floor_cell, paper, false, 3.0)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func bottom_decoration_rect() -> Rect2:
	var virtual_rect := Rect2(Vector2(0.0, _bottom_decoration_row() * CELL), Vector2(_virtual_size.x, CELL))
	return Rect2(_content_offset + virtual_rect.position * _content_scale, virtual_rect.size * _content_scale)

func set_virtual_size(p_size: Vector2) -> void:
	_virtual_size = Vector2(maxf(p_size.x, CELL * 12.0), maxf(p_size.y, CELL * 9.0))
	_update_content_transform()
	queue_redraw()

## Build the whole room for a level. Safe to call again to restart.
func setup(level: Level) -> void:
	_clear_children()
	_ensure_content_root()
	_compute_layout(level)
	_build_floor()
	_build_chute(_inbox_x, "PICK")
	_build_chute(_outbox_x, "SEND")
	_build_tiles(level)

	_stage = Control.new()
	_stage.size = _virtual_size
	_stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content_root.add_child(_stage)

	worker = Worker.new()
	_stage.add_child(worker)
	worker.position = _worker_home - worker.size * 0.5

	_spawn_initial_memory(level)
	_spawn_inbox(level)

## Reset moving pieces to the level start without rebuilding static art.
func restart(level: Level) -> void:
	setup(level)

# --- Layout -------------------------------------------------------------------

func _compute_layout(level: Level) -> void:
	var columns := maxi(12, floori(_virtual_size.x / CELL))
	_inbox_x = CELL * 1.5
	_outbox_x = CELL * (columns - 1.5)
	_chute_top = CELL * CHUTE_TOP_ROW
	_worker_home = WORKER_HOME_CELL * CELL

	_tile_centers.clear()
	var count := level.memory_size
	var start_column := floori((columns - count) * 0.5)
	# Keep memory central on taller windows, with one clear row below for the worker.
	var memory_row := maxi(3, floori(_virtual_size.y / CELL * 0.5) - 1)
	var row_y := (memory_row + 0.5) * CELL
	for i in count:
		_tile_centers.append(Vector2((start_column + i + 0.5) * CELL, row_y))

func _bottom_decoration_row() -> int:
	return floori(_virtual_size.y / CELL) - 1

# --- Static art ---------------------------------------------------------------

func _build_floor() -> void:
	queue_redraw()

## A tall dark chute frame plus an IN/OUT sign.
func _build_chute(center_x: float, label_text: String) -> void:
	var frame := Panel.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color.html(VisualTheme.ROOM_FLOOR_DARK)
	style.border_color = Color.html(VisualTheme.STATION_FRAME)
	style.set_border_width_all(4)
	frame.add_theme_stylebox_override("panel", style)
	frame.size = Vector2(CELL, CELL * 7)
	frame.position = Vector2(center_x - CELL * 0.5, _chute_top)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content_root.add_child(frame)

	for row in range(1, 7):
		var divider := ColorRect.new()
		divider.color = Color.html(VisualTheme.STATION_FRAME)
		divider.position = Vector2(0, row * CELL - 2)
		divider.size = Vector2(CELL, 4)
		divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(divider)

	var sign := Label.new()
	sign.text = label_text
	sign.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sign.set_meta("base_font_size", 23)
	VisualTheme.apply_font_size(sign, 23, 6, 160)
	sign.add_theme_color_override("font_color", Color.html(VisualTheme.INK))
	sign.add_theme_color_override("font_outline_color", Color.html(VisualTheme.PAPER))
	sign.add_theme_constant_override("outline_size", VisualTheme.scaled_int(8, 2, 24))
	sign.size = Vector2(CELL * 2, CELL)
	sign.position = Vector2(center_x - sign.size.x * 0.5, _chute_top - CELL)
	sign.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content_root.add_child(sign)

## Empty memory cells with their index in the corner.
func _build_tiles(level: Level) -> void:
	_tile_boxes.clear()
	for i in level.memory_size:
		var tile := Panel.new()
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.95, 0.93, 0.82, 0.08)
		style.border_color = Color.html(VisualTheme.PAPER)
		style.set_border_width_all(3)
		tile.add_theme_stylebox_override("panel", style)
		tile.size = VisualTheme.TILE_SIZE
		tile.position = _tile_centers[i] - VisualTheme.TILE_SIZE * 0.5
		tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_content_root.add_child(tile)

		var idx := Label.new()
		idx.text = str(i)
		idx.add_theme_color_override("font_color", Color.html(VisualTheme.PAPER))
		idx.set_meta("base_font_size", 18)
		VisualTheme.apply_font_size(idx, 18, 6, 120)
		idx.position = _tile_centers[i] + Vector2(CELL * 0.5 - 18, CELL * 0.5 - 26)
		idx.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_content_root.add_child(idx)

		_tile_boxes.append(null)

func _spawn_initial_memory(level: Level) -> void:
	for i in level.memory_size:
		if level.initial_memory.has(i):
			var nb := _new_box(level.initial_memory[i], _tile_centers[i])
			_tile_boxes[i] = nb

func _spawn_inbox(level: Level) -> void:
	_inbox_boxes.clear()
	_outbox_boxes.clear()
	for i in level.inbox.size():
		var nb := _new_box(level.inbox[i], _inbox_slot_center(i))
		_inbox_boxes.append(nb)

# --- Slot positions -----------------------------------------------------------

func _inbox_slot_center(index: int) -> Vector2:
	return Vector2(_inbox_x, _chute_top + CELL * 0.5 + index * CELL)

func _outbox_slot_center(index: int) -> Vector2:
	return Vector2(_outbox_x, _chute_top + CELL * 0.5 + index * CELL)

# --- Box factory --------------------------------------------------------------

## Create a number box on the stage centred at a point.
func _new_box(value: int, center: Vector2) -> NumberBox:
	var nb := NumberBox.new(value)
	(_stage if _stage else _content_root).add_child(nb)
	nb.place_centered(center)
	return nb

# =====================================================================
#  Animation — each returns once its tweens finish so the play loop can
#  await a full step before moving on.
# =====================================================================

func animate(action: StepAction) -> void:
	_animation_speed_scale = 1.0
	match action.op:
		InstructionDef.Op.INBOX:
			if action.source == StepAction.Source.INBOX:
				await _do_inbox()
		InstructionDef.Op.OUTBOX:
			if action.sink == StepAction.Sink.OUTBOX:
				await _do_outbox(action)
		InstructionDef.Op.COPYFROM:
			if action.source == StepAction.Source.MEMORY:
				await _do_copyfrom(action)
		InstructionDef.Op.COPYTO:
			if action.sink == StepAction.Sink.MEMORY:
				await _do_copyto(action)
		InstructionDef.Op.ADD, InstructionDef.Op.SUB:
			if action.source == StepAction.Source.MEMORY:
				await _do_math(action)
		InstructionDef.Op.BUMP_UP, InstructionDef.Op.BUMP_DOWN:
			if action.source == StepAction.Source.MEMORY:
				await _do_bump(action)
		InstructionDef.Op.JUMP, InstructionDef.Op.JUMP_IF_ZERO, InstructionDef.Op.JUMP_IF_NEG:
			await _do_hop()
	_animation_speed_scale = 1.0

## Finish the current instruction quickly when another manual step is queued.
## New tweens created by later phases of the same instruction inherit the boost.
func speed_up_current_animation() -> void:
	_animation_speed_scale = MANUAL_STEP_SPEED_SCALE
	for tween in _active_animation_tweens:
		if tween.is_valid():
			tween.set_speed_scale(_animation_speed_scale)

func _do_inbox() -> void:
	var box := _inbox_boxes[0]
	await _walk_near(box.position + box.size * 0.5, Vector2(CELL, 0))
	await _fly_to_hand(box)
	_inbox_boxes.remove_at(0)
	await _reflow_inbox()

func _do_outbox(action: StepAction) -> void:
	var slot := _outbox_slot_center(_outbox_boxes.size())
	await _walk_near(slot, Vector2(-CELL, 0))
	if worker.held_box == null:
		var restored := _new_box(action.held_value, _carry_global())
		_stage.remove_child(restored)
		worker.add_child(restored)
		restored.place_centered(worker.carry_local_center())
		worker.held_box = restored
	var box := _detach_from_hand()
	await _fly_box(box, slot, VisualTheme.PICK_TIME)
	_outbox_boxes.append(box)

func _do_copyfrom(action: StepAction) -> void:
	var center := _tile_centers[action.address]
	await _walk_near(center, Vector2(0, CELL))
	if worker.held_box:
		_discard(worker.held_box)
		worker.held_box = null
	var picked := _tile_boxes[action.address]
	if picked:
		var copied := _new_box(action.held_value, center)
		await _fly_to_hand(copied)
	else:
		var restored := _new_box(action.held_value, center)
		await _fly_to_hand(restored)

func _do_copyto(action: StepAction) -> void:
	var center := _tile_centers[action.address]
	await _walk_near(center, Vector2(0, CELL))
	# Copy the carried value onto the tile while the worker keeps holding it.
	if worker.held_box:
		if _tile_boxes[action.address]:
			_discard(_tile_boxes[action.address])
		var placed := _new_box(action.memory_value, _carry_global())
		await _fly_box(placed, center, VisualTheme.PICK_TIME)
		placed.set_value(action.memory_value)
		_tile_boxes[action.address] = placed
		await _pop(placed)
	elif _tile_boxes[action.address]:
		_tile_boxes[action.address].set_value(action.memory_value)
		await _pop(_tile_boxes[action.address])
	else:
		var nb := _new_box(action.memory_value, center)
		_tile_boxes[action.address] = nb
		await _pop(nb)

func _do_math(action: StepAction) -> void:
	var center := _tile_centers[action.address]
	await _walk_near(center, Vector2(0, CELL))
	if worker.held_box:
		worker.held_box.set_value(action.held_value)
		await _pop(worker.held_box)
	else:
		var result := _new_box(action.held_value, center)
		await _fly_to_hand(result)

func _do_bump(action: StepAction) -> void:
	var center := _tile_centers[action.address]
	await _walk_near(center, Vector2(0, CELL))
	if _tile_boxes[action.address]:
		_tile_boxes[action.address].set_value(action.memory_value)
		await _pop(_tile_boxes[action.address])
	# The bumped value also ends up in the worker's hands.
	if worker.held_box:
		worker.held_box.set_value(action.held_value)
	else:
		var clone := _new_box(action.held_value, center)
		await _fly_to_hand(clone)

func _do_hop() -> void:
	var t := _create_animation_tween()
	var home := worker.position
	t.tween_property(worker, "position", home - Vector2(0, 14), VisualTheme.BUMP_TIME)
	t.tween_property(worker, "position", home, VisualTheme.BUMP_TIME)
	await t.finished

# --- Movement / box helpers ---------------------------------------------------

## Walk the worker so its centre rests at `target_center + offset`.
func _walk_near(target_center: Vector2, offset: Vector2) -> void:
	var dest := target_center + offset - worker.size * 0.5
	var t := _create_animation_tween()
	var distance := worker.position.distance_to(dest)
	var duration := maxf(VisualTheme.WALK_TIME, distance / 900.0)
	t.set_parallel(true)
	t.tween_property(worker, "position", dest, duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.tween_property(worker, "rotation", 0.06 if dest.x > worker.position.x else -0.06, duration * 0.45)
	t.tween_property(worker, "scale", Vector2(1.06, 0.94), duration * 0.45)
	await t.finished
	var settle := _create_animation_tween().set_parallel(true)
	settle.tween_property(worker, "rotation", 0.0, VisualTheme.BUMP_TIME)
	settle.tween_property(worker, "scale", Vector2.ONE, VisualTheme.BUMP_TIME).set_trans(Tween.TRANS_BACK)
	await settle.finished

## Fly a stage-space box into the worker's hands, then snap it as a child.
func _fly_to_hand(box: NumberBox) -> void:
	await _fly_box(box, _carry_global(), VisualTheme.PICK_TIME)
	_stage.remove_child(box)
	worker.add_child(box)
	box.place_centered(worker.carry_local_center())
	worker.held_box = box

## Move the worker's held box back onto the stage and return it.
func _detach_from_hand() -> NumberBox:
	var box := worker.held_box
	var global_center := _carry_global()
	worker.remove_child(box)
	_stage.add_child(box)
	box.place_centered(global_center)
	worker.held_box = null
	return box

## Tween a box (must be a stage child) so it is centred on `center`.
func _fly_box(box: NumberBox, center: Vector2, time: float) -> void:
	var t := _create_animation_tween()
	t.set_parallel(true)
	t.tween_property(box, "position", center - box.size * 0.5, time).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_property(box, "rotation", 0.10, time * 0.5)
	await t.finished
	box.rotation = 0.0

## Quick scale "pop" to draw the eye to a changed value.
func _pop(node: Control) -> void:
	var t := _create_animation_tween()
	t.tween_property(node, "scale", Vector2(1.25, 1.25), VisualTheme.BUMP_TIME)
	t.tween_property(node, "scale", Vector2.ONE, VisualTheme.BUMP_TIME)
	await t.finished

## Fade out and free a box that is being replaced.
func _discard(box: NumberBox) -> void:
	var t := _create_animation_tween()
	t.tween_property(box, "modulate:a", 0.0, VisualTheme.BUMP_TIME)
	t.finished.connect(box.queue_free)

## Slide remaining inbox boxes up into their new slots after a grab.
func _reflow_inbox() -> void:
	var last_tween: Tween = null
	for i in _inbox_boxes.size():
		var t := _create_animation_tween()
		t.tween_property(_inbox_boxes[i], "position",
			_inbox_slot_center(i) - _inbox_boxes[i].size * 0.5, VisualTheme.PICK_TIME)
		last_tween = t
	if last_tween:
		await last_tween.finished

func _create_animation_tween() -> Tween:
	var tween := create_tween()
	tween.set_speed_scale(_animation_speed_scale)
	_active_animation_tweens.append(tween)
	tween.finished.connect(_forget_animation_tween.bind(tween))
	return tween

func _forget_animation_tween(tween: Tween) -> void:
	_active_animation_tweens.erase(tween)

## Worker's carry point expressed in stage-space coordinates.
func _carry_global() -> Vector2:
	return worker.position + worker.carry_local_center()

func _clear_children() -> void:
	for child in get_children():
		child.queue_free()
	_content_root = null
	_stage = null
	worker = null
	_inbox_boxes.clear()
	_outbox_boxes.clear()
	_tile_boxes.clear()
	_active_animation_tweens.clear()
	_animation_speed_scale = 1.0

func apply_ui_scale() -> void:
	_apply_ui_scale_recursive(self)

func _ensure_content_root() -> void:
	_content_root = Control.new()
	_content_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content_root.size = _virtual_size
	add_child(_content_root)
	_update_content_transform()

func _update_content_transform() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	_content_scale = minf(size.x / _virtual_size.x, size.y / _virtual_size.y)
	_content_scale = maxf(_content_scale, 0.05)
	_content_offset = (size - _virtual_size * _content_scale) * 0.5
	if _content_root:
		_content_root.position = _content_offset
		_content_root.scale = Vector2(_content_scale, _content_scale)
		_content_root.size = _virtual_size

func _apply_ui_scale_recursive(node: Node) -> void:
	if node is Label and node.has_meta("base_font_size"):
		var label := node as Label
		VisualTheme.apply_font_size(label, int(label.get_meta("base_font_size")), 6, 184)
		if label.text == "PICK" or label.text == "SEND":
			label.add_theme_constant_override("outline_size", VisualTheme.scaled_int(8, 2, 24))
	elif node is NumberBox:
		(node as NumberBox).apply_ui_scale()
	for child in node.get_children():
		_apply_ui_scale_recursive(child)
