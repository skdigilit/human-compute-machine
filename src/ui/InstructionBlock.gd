class_name InstructionBlock
extends PanelContainer

## A coloured instruction chip. Used in two modes:
##  * palette mode  — a source you drag into the program (no operands shown).
##  * program mode  — a line in the program; draggable to reorder, with an
##    editable operand (memory tile) or jump-target chip.
##
## Drag-and-drop uses Godot's built-in Control drag system. The drop target
## (ProgramListView) reads the dictionary returned by `_get_drag_data`.

signal request_target_pick(block: InstructionBlock)
signal instruction_changed()

## Payload keys used to describe a drag in flight.
const DRAG_KIND := "kind"
const DRAG_PALETTE := "palette"
const DRAG_REORDER := "reorder"
const DRAG_JUMP_TARGET := "jumptarget"
const DRAG_OP := "op"
const DRAG_BLOCK := "block"
const DRAG_JUMP_BLOCK := "jump_block"

var op: InstructionDef.Op
var is_palette: bool
## The model object this block represents (null for palette blocks).
var instruction: Instruction = null

var _memory_size: int = 0
var _operand_button: Button = null
var _target_button: JumpTargetHandle = null
var _label: Label = null
## Visual flags combined by _apply_style: execution highlight and drop-candidate.
var _active: bool = false
var _candidate: bool = false

func _init(p_op: InstructionDef.Op, p_is_palette: bool, p_instruction: Instruction = null) -> void:
	op = p_op
	is_palette = p_is_palette
	instruction = p_instruction
	mouse_filter = Control.MOUSE_FILTER_STOP

func _ready() -> void:
	_apply_style()
	custom_minimum_size = VisualTheme.scaled_size(Vector2(150, 0), Vector2(80, 0), Vector2(900, 0))
	size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	# Native hover tooltip explaining the command. The Viewport walks up from the
	# hovered child (label / chip) to this block for the text, so one assignment
	# covers the whole block.
	tooltip_text = InstructionDef.tooltip_for(op)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", VisualTheme.scaled_int(6, 2, 28))
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, VisualTheme.scaled_int(10, 4, 48))
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, VisualTheme.scaled_int(6, 2, 32))
	margin.add_child(row)
	add_child(margin)

	_label = Label.new()
	_label.text = InstructionDef.label_for(op)
	_label.add_theme_color_override("font_color", Color.html("#FBF7EE"))
	VisualTheme.apply_font_size(_label, 17, 6, 160)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_label)

	if not is_palette:
		_build_operand(row)

## Build the operand affordance appropriate to this opcode.
func _build_operand(row: HBoxContainer) -> void:
	var kind := InstructionDef.operand_kind_for(op)
	if kind == InstructionDef.OperandKind.ADDRESS:
		_operand_button = _make_chip(str(instruction.address))
		_operand_button.pressed.connect(_on_cycle_address)
		row.add_child(_operand_button)
	elif kind == InstructionDef.OperandKind.JUMP:
		# A draggable arrow handle: click cycles the target, drag wires it directly.
		_target_button = JumpTargetHandle.new(self)
		_target_button.pressed.connect(func() -> void: request_target_pick.emit(self))
		row.add_child(_target_button)

## A small light chip-button used for operands and jump targets.
func _make_chip(text: String) -> Button:
	var b := Button.new()
	b.text = text
	var style := VisualTheme.make_box_style("#F3ECD8", "#B9AE8C")
	style.shadow_size = 0
	b.add_theme_stylebox_override("normal", style)
	b.add_theme_stylebox_override("hover", style)
	b.add_theme_stylebox_override("pressed", style)
	VisualTheme.set_button_font_color(b, Color.html("#3A3526"))
	VisualTheme.apply_button_size(b, Vector2(34, 28), 18, 20.0)
	return b

## Cycle the memory tile this instruction refers to.
func _on_cycle_address() -> void:
	if _memory_size <= 0:
		return
	instruction.address = (instruction.address + 1) % _memory_size
	_operand_button.text = str(instruction.address)
	instruction_changed.emit()

## Tell address chips how many tiles exist so cycling stays in range.
func set_memory_size(count: int) -> void:
	_memory_size = count

## Set the jump target chip text; the list computes the human-readable target
## (e.g. "→ 17") since only it knows every line's current position.
func set_target_label(text: String) -> void:
	if _target_button:
		_target_button.text = text
		_target_button.apply_ui_scale()

## True when this block carries a jump-target chip.
func has_target_chip() -> bool:
	return _target_button != null

## Highlight this line while the VM is executing it.
func set_active(active: bool) -> void:
	_active = active
	_apply_style()

## Highlight this line as the line a dragged jump arrow would land on.
func set_candidate(candidate: bool) -> void:
	_candidate = candidate
	_apply_style()

## Repaint the block's frame from its current highlight flags.
func _apply_style() -> void:
	var base := InstructionDef.color_for(op)
	var style := StyleBoxFlat.new()
	style.set_corner_radius_all(VisualTheme.scaled_int(2, 1, 18))
	if _candidate:
		style.bg_color = base.lightened(0.2)
		style.border_color = Color.html("#3FA0FF")
		style.set_border_width_all(VisualTheme.scaled_int(4, 1, 24))
	elif _active:
		style.bg_color = base.lightened(0.25)
		style.border_color = Color.html("#FFE680")
		style.set_border_width_all(VisualTheme.scaled_int(4, 1, 24))
	else:
		style.bg_color = base
		style.border_color = base.darkened(0.25)
		style.set_border_width_all(VisualTheme.scaled_int(3, 1, 18))
	add_theme_stylebox_override("panel", style)

# --- Drag and drop ------------------------------------------------------------

func _get_drag_data(_pos: Vector2) -> Variant:
	var data := {}
	if is_palette:
		data[DRAG_KIND] = DRAG_PALETTE
		data[DRAG_OP] = op
	else:
		data[DRAG_KIND] = DRAG_REORDER
		data[DRAG_BLOCK] = self
		# Let the list dim this line and watch for a drop-outside-to-delete.
		var list := _find_program_list()
		if list:
			list._begin_reorder_drag(self)
	set_drag_preview(_make_preview())
	return data

## Godot only offers a drop to the top-most control under the cursor and does
## not bubble up. Since program blocks sit on top of the list, they must forward
## drops to the ProgramListView so that dropping *onto a block* still reorders.
func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	var list := _find_program_list()
	return list != null and list.can_accept_at(global_position + at_position, data)

func _drop_data(at_position: Vector2, data: Variant) -> void:
	var list := _find_program_list()
	if list:
		list.drop_at(global_position + at_position, data)

## Climb the tree to the owning ProgramListView (null for palette blocks).
func _find_program_list() -> ProgramListView:
	var node: Node = get_parent()
	while node != null:
		if node is ProgramListView:
			return node
		node = node.get_parent()
	return null

## A lightweight floating copy shown under the cursor while dragging.
func _make_preview() -> Control:
	var preview := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = InstructionDef.color_for(op)
	style.set_corner_radius_all(7)
	preview.add_theme_stylebox_override("panel", style)
	preview.modulate.a = 0.85
	var lbl := Label.new()
	lbl.text = InstructionDef.label_for(op)
	lbl.add_theme_color_override("font_color", Color.html("#FBF7EE"))
	VisualTheme.apply_font_size(lbl, 20, 6, 176)
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", VisualTheme.scaled_int(10, 4, 48))
	m.add_theme_constant_override("margin_right", VisualTheme.scaled_int(10, 4, 48))
	m.add_theme_constant_override("margin_top", VisualTheme.scaled_int(6, 2, 32))
	m.add_theme_constant_override("margin_bottom", VisualTheme.scaled_int(6, 2, 32))
	m.add_child(lbl)
	preview.add_child(m)
	return preview
