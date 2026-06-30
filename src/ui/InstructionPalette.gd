class_name InstructionPalette
extends PanelContainer

## The vertical strip of available instructions the player drags from. Mirrors
## the "instruction set" tab in the original game. Purely a source of drags;
## the ProgramListView handles where they land.

func _init() -> void:
	_apply_panel_style()

func _apply_panel_style() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color.html(VisualTheme.ROOM_WALL)
	style.border_color = Color.html(VisualTheme.PAPER)
	style.set_border_width_all(VisualTheme.scaled_int(3, 1, 18))
	style.set_corner_radius_all(VisualTheme.scaled_int(VisualTheme.UI_PANEL_RADIUS, 6, 72))
	add_theme_stylebox_override("panel", style)

## Populate the palette with one draggable block per available opcode.
func build(level: Level) -> void:
	_apply_panel_style()
	for child in get_children():
		child.queue_free()

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, VisualTheme.scaled_int(10, 4, 48))
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", VisualTheme.scaled_int(8, 3, 40))
	margin.add_child(column)

	var title := Label.new()
	title.text = "1. PICK A MOVE"
	title.add_theme_color_override("font_color", Color.html(VisualTheme.PAPER))
	VisualTheme.apply_font_size(title, 15, 6, 136)
	column.add_child(title)

	for op in level.palette:
		var block := InstructionBlock.new(op, true)
		block.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		column.add_child(block)
