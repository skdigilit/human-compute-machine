extends SceneTree

## Verifies adaptive layout keeps panels inside the viewport without overlap.

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	var game: Game = load("res://game_main.tscn").instantiate()
	game._save_path = "user://responsive_layout_test_%d.json" % Time.get_ticks_usec()
	root.add_child(game)
	for i in 4:
		await process_frame

	var initial_room_size := game._room.size
	var initial_palette_width := game._palette.size.x
	var initial_briefing_width := game._briefing.size.x
	var initial_control_height := game._control_bar.size.y
	var initial_worker_position := game._room.worker.position
	var initial_viewport := Vector2(
		game._briefing.position.x + game._briefing.size.x + Game.PANEL_GAP,
		game._control_bar.position.y + game._control_bar.size.y + Game.PANEL_GAP
	)
	var room_has_outer_padding := game._room.position == Vector2(Game.PANEL_GAP, Game.PANEL_GAP)
	var initial_banner_aligned := _banner_is_centered_above_bottom_decoration(game)

	var grown_viewport := initial_viewport + Vector2(240, 160)
	game._layout_panels(grown_viewport)
	for i in 2:
		await process_frame

	var palette_resized := not is_equal_approx(game._palette.size.x, initial_palette_width)
	var briefing_resized := not is_equal_approx(game._briefing.size.x, initial_briefing_width)
	var controls_resized := not is_equal_approx(game._control_bar.size.y, initial_control_height)
	var controls_reach_grown_bottom := is_equal_approx(
		game._control_bar.position.y + game._control_bar.size.y,
		grown_viewport.y - Game.PANEL_GAP
	)
	var worker_position_kept := game._room.worker.position == initial_worker_position
	var grown_no_overlap := _regions_do_not_overlap(game)
	var grown_inside_viewport := _regions_inside_viewport(game, grown_viewport)
	var grown_banner_aligned := _banner_is_centered_above_bottom_decoration(game)

	var shrunk_viewport := initial_viewport - Vector2(0, 280)
	game._layout_panels(shrunk_viewport)
	for i in 2:
		await process_frame

	var room_height_can_shrink := game._room.size.y < initial_room_size.y
	var controls_reach_shrunk_bottom := is_equal_approx(
		game._control_bar.position.y + game._control_bar.size.y,
		shrunk_viewport.y - Game.PANEL_GAP
	)
	var worker_position_kept_after_shrink := game._room.worker.position == initial_worker_position
	var shrunk_no_overlap := _regions_do_not_overlap(game)
	var shrunk_inside_viewport := _regions_inside_viewport(game, shrunk_viewport)
	var shrunk_banner_aligned := _banner_is_centered_above_bottom_decoration(game)
	var passed := (
		room_has_outer_padding
		and initial_banner_aligned
		and palette_resized
		and briefing_resized
		and controls_resized
		and controls_reach_grown_bottom
		and grown_no_overlap
		and grown_inside_viewport
		and grown_banner_aligned
		and worker_position_kept
		and room_height_can_shrink
		and controls_reach_shrunk_bottom
		and shrunk_no_overlap
		and shrunk_inside_viewport
		and shrunk_banner_aligned
		and worker_position_kept_after_shrink
	)
	if not passed:
		print("room_has_outer_padding=", room_has_outer_padding)
		print("initial_banner_aligned=", initial_banner_aligned)
		print("palette_resized=", palette_resized)
		print("briefing_resized=", briefing_resized)
		print("controls_resized=", controls_resized)
		print("controls_reach_grown_bottom=", controls_reach_grown_bottom)
		print("grown_no_overlap=", grown_no_overlap)
		print("grown_inside_viewport=", grown_inside_viewport)
		print("grown_banner_aligned=", grown_banner_aligned)
		print("worker_position_kept=", worker_position_kept)
		print("room_height_can_shrink=", room_height_can_shrink)
		print("controls_reach_shrunk_bottom=", controls_reach_shrunk_bottom)
		print("shrunk_no_overlap=", shrunk_no_overlap)
		print("shrunk_inside_viewport=", shrunk_inside_viewport)
		print("shrunk_banner_aligned=", shrunk_banner_aligned)
		print("worker_position_kept_after_shrink=", worker_position_kept_after_shrink)

	print("RESULT: ", "PASS" if passed else "FAIL")
	quit()

func _regions_do_not_overlap(game: Game) -> bool:
	var regions := [
		game._room.get_global_rect(),
		game._palette.get_global_rect(),
		game._briefing.get_global_rect(),
		game._program_list.get_global_rect(),
		game._control_bar.get_global_rect(),
	]
	for i in regions.size():
		for j in range(i + 1, regions.size()):
			if regions[i].intersects(regions[j]):
				return false
	return true

func _regions_inside_viewport(game: Game, viewport_size: Vector2) -> bool:
	for rect in [
		game._room.get_global_rect(),
		game._palette.get_global_rect(),
		game._briefing.get_global_rect(),
		game._program_list.get_global_rect(),
		game._control_bar.get_global_rect(),
	]:
		if rect.position.x < -0.01 or rect.position.y < -0.01:
			return false
		if rect.end.x > viewport_size.x + 0.01 or rect.end.y > viewport_size.y + 0.01:
			return false
	return true

func _banner_is_centered_above_bottom_decoration(game: Game) -> bool:
	var decoration_rect := game._room.bottom_decoration_rect()
	var decoration_global := Rect2(game._room.global_position + decoration_rect.position, decoration_rect.size)
	var banner_rect := game._win_banner.get_global_rect()
	return (
		is_equal_approx(banner_rect.get_center().x, decoration_global.get_center().x)
		and banner_rect.end.y <= decoration_global.position.y + 0.01
		and banner_rect.position.y >= game._room.get_global_rect().position.y - 0.01
	)
