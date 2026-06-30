extends SceneTree

## Verifies hints are hidden from the briefing UI until Shift+H reveals them.

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	var game: Game = load("res://game_main.tscn").instantiate()
	game._save_path = "user://hint_shortcut_test_%d.json" % Time.get_ticks_usec()
	root.add_child(game)
	for i in 4:
		await process_frame

	var hint_button_hidden := _find_button(game._briefing, "SHOW HINT") == null
	var hint_starts_hidden := game._briefing._body.text == game._briefing._problem_text

	var plain_h_event := InputEventKey.new()
	plain_h_event.pressed = true
	plain_h_event.keycode = KEY_H
	plain_h_event.physical_keycode = KEY_H
	plain_h_event.key_label = KEY_H
	game._input(plain_h_event)
	var plain_h_keeps_hint_hidden := game._briefing._body.text == game._briefing._problem_text

	var event := InputEventKey.new()
	event.pressed = true
	event.keycode = KEY_H
	event.physical_keycode = KEY_H
	event.key_label = KEY_H
	event.shift_pressed = true
	game._input(event)

	var hint_shown_by_shortcut := (
		game._briefing._body.text == game._briefing._problem_text + "\n\n" + game._briefing._hint_text
	)
	var passed := (
		hint_button_hidden
		and hint_starts_hidden
		and plain_h_keeps_hint_hidden
		and hint_shown_by_shortcut
	)
	if not passed:
		print("hint_button_hidden=", hint_button_hidden)
		print("hint_starts_hidden=", hint_starts_hidden)
		print("plain_h_keeps_hint_hidden=", plain_h_keeps_hint_hidden)
		print("hint_shown_by_shortcut=", hint_shown_by_shortcut)

	game.queue_free()
	for i in 2:
		await process_frame
	print("RESULT: ", "PASS" if passed else "FAIL")
	quit(0 if passed else 1)

func _find_button(node: Node, text: String) -> Button:
	if node is Button and (node as Button).text == text:
		return node as Button
	for child in node.get_children():
		var found := _find_button(child, text)
		if found:
			return found
	return null
