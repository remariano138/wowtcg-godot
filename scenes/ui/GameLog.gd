extends Control

const MAX_ENTRIES = 100

# Entry categories → colors
const COLORS = {
	"play":     Color(0.6, 1.0, 0.6),   # green — card played
	"resource": Color(0.6, 0.85, 1.0),  # blue  — resources exhausted
	"attack":   Color(1.0, 0.85, 0.4),  # gold  — combat
	"death":    Color(1.0, 0.4, 0.4),   # red   — card died
	"default":  Color(0.85, 0.85, 0.85),
}

@onready var panel:      Panel           = $Panel
@onready var entries:    VBoxContainer   = $Panel/Scroll/Entries
@onready var scroll:     ScrollContainer = $Panel/Scroll
@onready var toggle_btn: Button          = $ToggleButton

var _count: int = 0

func add_entry(text: String, category: String = "default") -> void:
	_count += 1
	var lbl = Label.new()
	lbl.text = "[%d] %s" % [_count, text]
	lbl.add_theme_color_override("font_color", COLORS.get(category, COLORS["default"]))
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	entries.add_child(lbl)
	while entries.get_child_count() > MAX_ENTRIES:
		entries.get_child(0).queue_free()
	await get_tree().process_frame
	scroll.scroll_vertical = int(scroll.get_v_scroll_bar().max_value)

func _on_toggle_pressed() -> void:
	panel.visible = not panel.visible
	toggle_btn.text = "Log ▲" if panel.visible else "Log ▼"
