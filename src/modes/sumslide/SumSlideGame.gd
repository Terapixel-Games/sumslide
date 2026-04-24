extends Control

const TARGET := 10
const SWIPE_THRESHOLD := 48.0
const MAX_STRIKES := 3

@onready var _score_label: Label = %ScoreLabel
@onready var _best_label: Label = %BestLabel
@onready var _combo_label: Label = %ComboLabel
@onready var _board_grid: GridContainer = %BoardGrid
@onready var _pause_button: Button = %PauseButton
@onready var _pause_overlay: PanelContainer = %PauseOverlay
@onready var _resume_button: Button = %ResumeButton
@onready var _pause_menu_button: Button = %PauseMenuButton
@onready var _pause_end_run_button: Button = %PauseEndRunButton
@onready var _no_moves_overlay: PanelContainer = %NoMovesOverlay
@onready var _no_moves_label: Label = %NoMovesLabel
@onready var _rewarded_shuffle_button: Button = %RewardedShuffleButton
@onready var _rewarded_undo_button: Button = %RewardedUndoButton
@onready var _end_run_button: Button = %EndRunButton

var _rng := RandomNumberGenerator.new()
var _board := PackedInt32Array()
var _score := 0
var _best := 0
var _combo := 0
var _strikes := 0
var _undo_used := false
var _last_state: Dictionary = {}
var _game_over := false
var _tracking_swipe := false
var _swipe_origin := Vector2.ZERO
var _cell_panels: Array[PanelContainer] = []
var _cell_labels: Array[Label] = []


func _ready() -> void:
	_rng.randomize()
	_best = SaveStore.get_high_score("sumslide")
	_wire_signals()
	_create_board_cells()
	_start_game_state()


func _wire_signals() -> void:
	_pause_button.pressed.connect(_on_pause_pressed)
	_resume_button.pressed.connect(_on_resume_pressed)
	_pause_menu_button.pressed.connect(_on_pause_menu_pressed)
	_pause_end_run_button.pressed.connect(_on_pause_end_run_pressed)
	_rewarded_shuffle_button.pressed.connect(_on_rewarded_shuffle_pressed)
	_rewarded_undo_button.pressed.connect(_on_rewarded_undo_pressed)
	_end_run_button.pressed.connect(_on_end_run_pressed)


func _start_game_state() -> void:
	_score = 0
	_combo = 0
	_strikes = 0
	_undo_used = false
	_last_state = {}
	_game_over = false

	_board = SumSlideRules.create_random_board(_rng)
	_board = SumSlideRules.ensure_board_has_pair(_board, TARGET, _rng, 30)
	if RunManager.start_with_shuffle:
		_board = SumSlideRules.shuffle_board_with_pair(TARGET, _rng, 8)
		RunManager.start_with_shuffle = false

	_pause_overlay.visible = false
	_no_moves_overlay.visible = false
	_refresh_hud()
	_refresh_board()
	_update_powerup_buttons()


func _create_board_cells() -> void:
	if not _cell_panels.is_empty():
		return
	for _i in range(SumSlideRules.BOARD_CELLS):
		var panel := PanelContainer.new()
		panel.custom_minimum_size = Vector2(58, 58)
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

		var label := Label.new()
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.size_flags_vertical = Control.SIZE_EXPAND_FILL
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE

		panel.add_child(label)
		_board_grid.add_child(panel)
		_cell_panels.append(panel)
		_cell_labels.append(label)


func _refresh_hud() -> void:
	_best = max(_best, _score)
	_score_label.text = "Score: %d" % _score
	_best_label.text = "Best: %d" % max(_best, SaveStore.get_high_score("sumslide"))
	_combo_label.text = "Combo: x%d  Strikes: %d/%d" % [_combo, _strikes, MAX_STRIKES]


func _refresh_board() -> void:
	for i in range(_board.size()):
		var value := _board[i]
		var label := _cell_labels[i]
		var panel := _cell_panels[i]
		label.text = str(value) if value > 0 else ""
		label.add_theme_color_override("font_color", _cell_text_color(value))
		panel.modulate = _cell_color(value)


func _update_game_over_overlay() -> void:
	_game_over = _strikes >= MAX_STRIKES
	_no_moves_overlay.visible = _game_over
	if _game_over:
		_no_moves_label.text = "Game Over: 3 Strikes"


func _update_powerup_buttons() -> void:
	var rewarded_ready: bool = AdManager.has_method("is_rewarded_ready") and AdManager.is_rewarded_ready()
	_rewarded_shuffle_button.visible = rewarded_ready
	_rewarded_shuffle_button.disabled = not rewarded_ready

	var can_undo: bool = rewarded_ready and not _undo_used and not _last_state.is_empty()
	_rewarded_undo_button.visible = can_undo
	_rewarded_undo_button.disabled = not can_undo


func _unhandled_input(event: InputEvent) -> void:
	if _pause_overlay.visible or _no_moves_overlay.visible:
		return

	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_tracking_swipe = true
			_swipe_origin = touch.position
		elif _tracking_swipe:
			_tracking_swipe = false
			_handle_swipe_delta(touch.position - _swipe_origin)
	elif event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		if mouse.button_index == MOUSE_BUTTON_LEFT:
			if mouse.pressed:
				_tracking_swipe = true
				_swipe_origin = mouse.position
			elif _tracking_swipe:
				_tracking_swipe = false
				_handle_swipe_delta(mouse.position - _swipe_origin)
	elif event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and not key.echo:
			match key.keycode:
				KEY_LEFT:
					_perform_swipe("left")
				KEY_RIGHT:
					_perform_swipe("right")
				KEY_UP:
					_perform_swipe("up")
				KEY_DOWN:
					_perform_swipe("down")


func _handle_swipe_delta(delta: Vector2) -> void:
	if delta.length() < SWIPE_THRESHOLD:
		return
	if absf(delta.x) > absf(delta.y):
		_perform_swipe("right" if delta.x > 0.0 else "left")
	else:
		_perform_swipe("down" if delta.y > 0.0 else "up")


func _perform_swipe(dir: String) -> void:
	if _game_over:
		return

	_last_state = _capture_state()
	var result := SumSlideRules.step(_board, dir, TARGET, _rng)
	_board = _to_board(result.get("board", _board))
	var pairs_cleared := int(result.get("pairs_cleared", 0))
	var score_delta := int(result.get("score_delta", 0))

	if pairs_cleared > 0:
		_combo += 1
		score_delta += pairs_cleared * (5 * _combo)
	else:
		_combo = 0

	var strike_state: Dictionary = SumSlideRules.apply_strike_state(_strikes, pairs_cleared, MAX_STRIKES)
	_strikes = int(strike_state.get("strikes", _strikes))

	_score += score_delta
	_refresh_hud()
	_refresh_board()
	_update_game_over_overlay()
	_update_powerup_buttons()


func _capture_state() -> Dictionary:
	return {
		"board": _board.duplicate(),
		"score": _score,
		"combo": _combo,
		"strikes": _strikes
	}


func _to_board(value: Variant) -> PackedInt32Array:
	var normalized := PackedInt32Array()
	normalized.resize(SumSlideRules.BOARD_CELLS)

	if value is PackedInt32Array:
		var packed: PackedInt32Array = value
		var count := mini(packed.size(), normalized.size())
		for i in range(count):
			normalized[i] = int(packed[i])
	elif value is Array:
		var arr: Array = value
		var arr_count := mini(arr.size(), normalized.size())
		for i in range(arr_count):
			normalized[i] = int(arr[i])
	else:
		return _board

	return normalized


func _on_pause_pressed() -> void:
	_pause_overlay.visible = true


func _on_resume_pressed() -> void:
	_pause_overlay.visible = false


func _on_pause_menu_pressed() -> void:
	RunManager.goto_menu()


func _on_pause_end_run_pressed() -> void:
	_end_run()


func _on_rewarded_shuffle_pressed() -> void:
	if not AdManager.is_rewarded_ready():
		return
	AdManager.show_rewarded("powerup_shuffle", Callable(self, "_on_shuffle_reward_granted"), Callable(self, "_on_rewarded_closed"))


func _on_shuffle_reward_granted() -> void:
	_board = SumSlideRules.shuffle_preserving_distribution(_board, TARGET, _rng, 30)
	_combo = 0
	_strikes = 0
	_game_over = false
	_no_moves_overlay.visible = false
	_refresh_hud()
	_refresh_board()
	_update_powerup_buttons()


func _on_rewarded_undo_pressed() -> void:
	if _undo_used or _last_state.is_empty() or not AdManager.is_rewarded_ready():
		return
	AdManager.show_rewarded("powerup_undo", Callable(self, "_on_undo_reward_granted"), Callable(self, "_on_rewarded_closed"))


func _on_undo_reward_granted() -> void:
	if _last_state.is_empty():
		return
	_board = _to_board(_last_state.get("board", _board))
	_score = int(_last_state.get("score", _score))
	_combo = int(_last_state.get("combo", _combo))
	_strikes = int(_last_state.get("strikes", _strikes))
	_game_over = _strikes >= MAX_STRIKES
	_undo_used = true
	_last_state = {}
	_no_moves_overlay.visible = _game_over
	if _game_over:
		_no_moves_label.text = "Game Over: 3 Strikes"
	_refresh_hud()
	_refresh_board()
	_update_powerup_buttons()


func _on_rewarded_closed() -> void:
	_update_powerup_buttons()


func _on_end_run_pressed() -> void:
	_end_run()


func _end_run() -> void:
	RunManager.finish_mode(_score)


func _cell_color(value: int) -> Color:
	if value <= 0:
		return Color(0.18, 0.19, 0.23)
	var ratio := float(value - 1) / 8.0
	return Color.from_hsv(0.08 + ratio * 0.38, 0.55, 0.95)


func _cell_text_color(value: int) -> Color:
	if value >= 6:
		return Color(1.0, 1.0, 1.0)
	return Color(0.11, 0.11, 0.14)
