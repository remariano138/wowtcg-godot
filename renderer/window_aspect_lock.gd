extends Node

# Keeps the OS window at the game's 16:9 aspect ratio.
#
# Godot has no built-in aspect lock, and `stretch/aspect = keep` only guarantees
# the RENDER is 16:9 — a window of any other shape just gets letterbox bars. This
# snaps the window itself back to 16:9 whenever it is resized, so the bars never
# appear and the board always fills the frame it is designed for.
#
# Autoloaded (see project.godot) so it applies to every scene, and so nothing in
# the board/UI code has to know about window management.

const ASPECT := 16.0 / 9.0
# Never shrink below this width — a smaller window can't show the 1920x1080
# layout legibly anyway.
const MIN_WIDTH := 960
# Fraction of the usable screen the window takes on first run.
const START_FILL := 1.0
# Height of the OS title bar. `Window.size`/`position` describe the CLIENT area,
# so a window sized to the full usable height would push its own title bar (and
# that much of the board) off the top of the screen.
const TITLE_BAR_H := 32

# Guards against re-entry: our own resize re-emits size_changed.
var _adjusting: bool = false
var _last_size: Vector2i = Vector2i.ZERO


func _ready() -> void:
	var win := get_window()
	if win == null:
		return
	win.size_changed.connect(_on_size_changed)
	# Start windowed at the largest 16:9 box that fits the screen. Maximised is
	# the one mode that can't be 16:9 (the OS picks the size), so the project
	# opens windowed instead.
	_fit_to_screen(win)
	_last_size = win.size


# Largest 16:9 window that fits comfortably on the current screen, centred.
func _fit_to_screen(win: Window) -> void:
	var usable := DisplayServer.screen_get_usable_rect(win.current_screen)
	# Sized from the SCREEN only — never clamped to the window's current size, or
	# the project's 1920x1080 default would be a ceiling and the window could only
	# ever shrink to fit, never grow to fill a larger display.
	var avail_w: float = usable.size.x * START_FILL
	var avail_h: float = (usable.size.y - TITLE_BAR_H) * START_FILL
	var w: float = avail_w
	var h: float = w / ASPECT
	if h > avail_h:
		h = avail_h
		w = h * ASPECT
	_adjusting = true
	win.mode = Window.MODE_WINDOWED
	win.size = Vector2i(int(w), int(h))
	win.position = usable.position + Vector2i(0, TITLE_BAR_H) \
		+ (Vector2i(usable.size.x, usable.size.y - TITLE_BAR_H) - win.size) / 2
	_adjusting = false


func _on_size_changed() -> void:
	if _adjusting:
		return
	var win := get_window()
	if win == null:
		return
	# Don't fight the window manager: fullscreen and maximised sizes aren't ours
	# to choose, and `stretch/aspect = keep` letterboxes them correctly anyway.
	if win.mode != Window.MODE_WINDOWED:
		_last_size = win.size
		return

	var size := win.size
	# Drive the ratio from whichever edge the user actually dragged, so resizing
	# by a corner or by either side all feel the same.
	var d := size - _last_size
	var target: Vector2i
	if abs(d.y) > abs(d.x):
		var h: int = max(int(MIN_WIDTH / ASPECT), size.y)
		target = Vector2i(int(round(h * ASPECT)), h)
	else:
		var w: int = max(MIN_WIDTH, size.x)
		target = Vector2i(w, int(round(w / ASPECT)))

	_last_size = target
	if target == size:
		return
	_adjusting = true
	win.size = target
	_adjusting = false
