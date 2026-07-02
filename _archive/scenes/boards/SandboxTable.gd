extends Control

const CARD_SCENE  = preload("res://scenes/elements/Card.tscn")
const CARD_ASPECT = 5.0 / 7.0
const CARD_FILL   = 0.95
const ZOOM_MIN    = 0.4
const ZOOM_MAX    = 3.0
const ZOOM_SPEED  = 0.1

enum MenuAction { PLAY_BOARD, PLACE_RESOURCE, SEND_GRAVEYARD, RETURN_HAND, EXHAUST, READY, GENERATE_CARD, DEAL_DAMAGE, RANDOMIZE_HERO, RESET_HERO_HEALTH, USE_POWER }

@onready var card_inspector:   TextureRect   = $CardInspector
@onready var game_log:         Control       = $GameLog
@onready var turn_label:       Label         = $TurnPanel/TurnLabel
@onready var end_turn_btn:     Button        = $TurnPanel/EndTurnButton
@onready var end_game_dialog:  Control       = $EndGameDialog
@onready var setup_panel:      Control       = $SetupPanel
@onready var mulligan_panel_p1:  Control = $MulliganPanelP1
@onready var mulligan_panel_p2:  Control = $MulliganPanelP2
@onready var camera_container: Control       = $CameraContainer
@onready var game_manager:     Node          = $GameManager
@onready var hand_area:        Control       = $CameraContainer/Board/HandArea
@onready var ally_row_area:    Control       = $CameraContainer/Board/PlayerArea/PlayZones/AllyRow
@onready var hero_equip_area:  Control       = $CameraContainer/Board/PlayerArea/PlayZones/HeroEquipRow
@onready var resource_area:    Control       = $CameraContainer/Board/PlayerArea/PlayZones/ResourceRow
@onready var hand_container:   HBoxContainer = $CameraContainer/Board/HandArea/HandContainer
@onready var ally_row:         HBoxContainer = $CameraContainer/Board/PlayerArea/PlayZones/AllyRow/Cards
@onready var hero_equip_row:   HBoxContainer = $CameraContainer/Board/PlayerArea/PlayZones/HeroEquipRow/Cards
@onready var resource_row:     HBoxContainer = $CameraContainer/Board/PlayerArea/PlayZones/ResourceRow/Cards
@onready var right_column:     Control       = $CameraContainer/Board/PlayerArea/RightColumn
@onready var hero_slot:        ColorRect     = $CameraContainer/Board/PlayerArea/RightColumn/HeroSlot
@onready var deck_slot:        ColorRect     = $CameraContainer/Board/PlayerArea/RightColumn/DeckSlot
@onready var grav_slot:        ColorRect     = $CameraContainer/Board/PlayerArea/RightColumn/GraveyardSlot
@onready var opp_right_column:  Control       = $CameraContainer/Board/OpponentArea/OpponentRightColumn
@onready var opp_hero_slot:     ColorRect     = $CameraContainer/Board/OpponentArea/OpponentRightColumn/OpponentHeroSlot
@onready var opp_deck_slot:     ColorRect     = $CameraContainer/Board/OpponentArea/OpponentRightColumn/OpponentDeckSlot
@onready var opp_grav_slot:     ColorRect     = $CameraContainer/Board/OpponentArea/OpponentRightColumn/OpponentGraveyardSlot
@onready var opp_hand_area:     Control       = $CameraContainer/Board/OpponentHand
@onready var opp_ally_row_area: Control       = $CameraContainer/Board/OpponentArea/OpponentZones/OpponentAllyRow
@onready var opp_hero_area:     Control       = $CameraContainer/Board/OpponentArea/OpponentZones/OpponentHeroEquipRow
@onready var opp_resource_area: Control       = $CameraContainer/Board/OpponentArea/OpponentZones/OpponentResourceRow
@onready var opp_hand_container: HBoxContainer = $CameraContainer/Board/OpponentHand/OpponentHandContainer
@onready var opp_ally_row:      HBoxContainer = $CameraContainer/Board/OpponentArea/OpponentZones/OpponentAllyRow/Cards
@onready var opp_hero_equip_row: HBoxContainer = $CameraContainer/Board/OpponentArea/OpponentZones/OpponentHeroEquipRow/Cards
@onready var opp_resource_row:  HBoxContainer = $CameraContainer/Board/OpponentArea/OpponentZones/OpponentResourceRow/Cards

# Pile slots: cards stacked face-up (graveyard) or face-down (deck)
var _pile_slots: Array = []

# Hero cards currently in play
var _p1_hero: Control = null
var _p2_hero: Control = null

# Mulligan / turn tracking
var _p1_mulliganed: bool = false
var _p2_mulliganed: bool = false
var _p1_ready:      bool = false
var _p2_ready:      bool = false
var _first_turn_skip: String = ""  # whichever player goes first skips turn-1 draw

# Violation resolution
var _violation_cards:    Array    = []
var _violation_overlays: Array    = []  # [[ColorRect, Label], ...]
var _violation_callback: Callable

# Combat targeting
var _attacker: Control = null
var _is_animating: bool = false
var _combat_canvas: CanvasLayer
var _combat_line: Line2D

# Generic ability targeting (for non-combat powers that need a target pick)
signal ability_target_chosen(card: Control)
var _ability_target_candidates: Array = []
var _ability_source: Control = null
var _protect_prompt_active: bool = false
var _heal_cursor_tex: ImageTexture = null
var _turn_banner_dismissed: bool = true
var _resource_placed_this_turn: Dictionary = {"player_1": false, "player_2": false}

# Observer registry: trigger_name -> Array[Control] of in-play cards currently
# registered for that trigger. Lets a broadcast-style trigger (e.g. "ally_damaged",
# which any ally in play might react to, not just the one being damaged) skip
# straight to "is anyone even listening" instead of re-scanning every ally in play
# on every occurrence. Kept in sync by _sync_observer_registration(), called
# wherever an ally enters/leaves play.
const OBSERVER_TRIGGERS = ["ally_damaged"]
var _observers: Dictionary = {}

# HP tooltip
var _hp_tooltip: Control
var _hp_label: RichTextLabel

# Resource counters
var _p1_counter_slot: ColorRect
var _p1_counter_label: Label
var _p2_counter_slot: ColorRect
var _p2_counter_label: Label

# Hero HP bars
const HP_BAR_WIDTH = 28.0
const HP_BAR_GAP   = 6.0
var _p1_hp_bg:    ColorRect
var _p1_hp_fill:  ColorRect
var _p1_hp_label: Label
var _p2_hp_bg:    ColorRect
var _p2_hp_fill:  ColorRect
var _p2_hp_label: Label

# Context menu
var context_menu: PopupMenu
var _context_card: Control = null
var _deck_menu_owner: String = ""
var _warn_dialog: AcceptDialog
var _x_dialog: ConfirmationDialog
signal x_value_chosen(value: int)
var _game_over: bool = false

# ── Camera ────────────────────────────────────────────────────────────────────
func _make_counter_slot(parent: Control) -> ColorRect:
	var slot = ColorRect.new()
	slot.layout_mode = 0
	slot.color = Color(0.02, 0.08, 0.02, 1)
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(slot)
	var label = Label.new()
	label.layout_mode = 1
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 20)
	label.text = "0"
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(label)
	return slot

func _ensure_hero_hp_bar(card_owner: String) -> void:
	var has_bar = _p1_hp_bg if card_owner == "player_1" else _p2_hp_bg
	if has_bar:
		return
	var parent = right_column if card_owner == "player_1" else opp_right_column
	var bg = ColorRect.new()
	bg.layout_mode = 0
	bg.color = Color(0.5, 0.08, 0.08, 1)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(bg)
	var fill = ColorRect.new()
	fill.layout_mode = 0
	fill.color = Color(0.15, 0.75, 0.15, 1)
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(fill)
	var label = Label.new()
	label.layout_mode = 1
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_constant_override("outline_size", 2)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(label)
	if card_owner == "player_1":
		_p1_hp_bg = bg
		_p1_hp_fill = fill
		_p1_hp_label = label
	else:
		_p2_hp_bg = bg
		_p2_hp_fill = fill
		_p2_hp_label = label

func _position_hero_hp_bar(card_owner: String, hero_rect: ColorRect) -> void:
	_ensure_hero_hp_bar(card_owner)
	var bg = _p1_hp_bg if card_owner == "player_1" else _p2_hp_bg
	# Heroes can exhaust (rotate 90°) like allies now. Rotation pivots around the
	# card's center, so a rotated card's horizontal extent grows from its width
	# to its height, bulging out (height - width) / 2 past its unrotated right
	# edge. Push the HP bar out by that much extra so it doesn't overlap — the
	# hero slot itself stays put (it's aligned with the rest of the board layout).
	var rotated_overhang = max(hero_rect.size.y - hero_rect.size.x, 0.0) / 2.0
	bg.position = Vector2(
		hero_rect.position.x + hero_rect.size.x + HP_BAR_GAP + rotated_overhang,
		hero_rect.position.y)
	bg.size     = Vector2(HP_BAR_WIDTH, hero_rect.size.y)
	_update_hero_hp_bar(card_owner)

func _update_hero_hp_bar(card_owner: String) -> void:
	var hero = _p1_hero if card_owner == "player_1" else _p2_hero
	var bg    = _p1_hp_bg    if card_owner == "player_1" else _p2_hp_bg
	var fill  = _p1_hp_fill  if card_owner == "player_1" else _p2_hp_fill
	var label = _p1_hp_label if card_owner == "player_1" else _p2_hp_label
	if not bg:
		return
	if not is_instance_valid(hero):
		fill.size = Vector2.ZERO
		label.text = ""
		return
	var ratio = clamp(float(hero.current_health) / float(max(hero.max_health, 1)), 0.0, 1.0)
	var fill_h = bg.size.y * ratio
	fill.size     = Vector2(bg.size.x, fill_h)
	fill.position = Vector2(0, bg.size.y - fill_h)
	label.text = str(hero.current_health)

func _on_card_health_changed(card: Control) -> void:
	if card.card_type == "Hero":
		_update_hero_hp_bar(card.card_owner)
	_update_berserking(card)

func _on_card_damaged(card: Control, amount: int) -> void:
	if card.card_type == "Ally":
		await _fire_ally_damaged(card, amount)

# "Berserking" (house term, not an official keyword): a continuous ATK bonus that
# scales with the card's own current damage, re-checked every time its health
# changes (i.e. via the health_changed signal) rather than only on board-state
# changes like the health-modifier auras — it's about THIS card's own damage, not
# who else is in play. amount = bonus ATK per point of damage on this card.
func _update_berserking(card: Control) -> void:
	var bonus = 0
	for r in _parse_effects(card.effects):
		if r.get("trigger", "") == "berserking":
			bonus += card.damage_taken * int(r.get("amount", "1"))
	card.set_berserking_atk_modifier(bonus)

func _count_ready_resources(row: HBoxContainer) -> int:
	var count = 0
	for child in row.get_children():
		if child.has_method("exhaust") and not child.exhausted:
			count += 1
	return count

func _update_resource_counts() -> void:
	var p1 = _count_ready_resources(resource_row)
	var p2 = _count_ready_resources(opp_resource_row)
	game_manager.player1_resources = p1
	game_manager.player2_resources = p2
	if _p1_counter_label:
		_p1_counter_label.text = str(p1)
	if _p2_counter_label:
		_p2_counter_label.text = str(p2)

func _zoom(factor: float, mouse_pos: Vector2) -> void:
	var old_scale = camera_container.scale.x
	var new_scale = clamp(old_scale * factor, ZOOM_MIN, ZOOM_MAX)
	if is_equal_approx(new_scale, old_scale):
		return
	camera_container.position = mouse_pos - (mouse_pos - camera_container.position) * (new_scale / old_scale)
	camera_container.scale = Vector2(new_scale, new_scale)

func _reset_camera() -> void:
	camera_container.position = Vector2.ZERO
	camera_container.scale    = Vector2.ONE

# ── Card sizing ───────────────────────────────────────────────────────────────
func card_size_for_zone(zone: Control) -> Vector2:
	var h = zone.size.y * CARD_FILL
	return Vector2(h * CARD_ASPECT, h)

func slot_size_for_zone(zone: Control) -> Vector2:
	var h = zone.size.y * CARD_FILL
	return Vector2(h, h)

func _is_board_ally(card: Control) -> bool:
	return card.card_type == "Ally" and card.get_parent() in [ally_row, opp_ally_row]

func _is_valid_target(card: Control, attacker: Control) -> bool:
	var attacker_owner = attacker.card_owner
	var opp = "player_2" if attacker_owner == "player_1" else "player_1"
	var opp_row = opp_ally_row if opp == "player_2" else ally_row
	var opp_hero = _p2_hero if opp == "player_2" else _p1_hero
	if card.get_parent() != opp_row and card != opp_hero:
		return false
	return can_propose_defender(card, attacker)

# Cards in play with a "can attack only this [if able]" continuous effect (e.g.
# Sarmoth) that are still legal targets for `attacker` ignoring that effect itself
# (i.e. non-Elusive) — per rule 601.2c, this only narrows attacker's legal
# defenders to these cards; it does NOT force attacker to attack, and if none of
# them are legal for this particular attacker, normal legality applies instead.
func _attack_lockers_for(attacker: Control) -> Array:
	var opp = "player_2" if attacker.card_owner == "player_1" else "player_1"
	var opp_row = opp_ally_row if opp == "player_2" else ally_row
	var opp_hero = _p2_hero if opp == "player_2" else _p1_hero
	var candidates = opp_row.get_children().filter(func(c): return c.card_type == "Ally")
	if is_instance_valid(opp_hero):
		candidates.append(opp_hero)
	var lockers: Array = []
	for c in candidates:
		if c.has_keyword("elusive"):
			continue
		for r in _parse_effects(c.effects):
			if r.get("trigger", "") == "continuous" and r.get("action", "") == "lock_attackers":
				lockers.append(c)
				break
	return lockers

# ── Rule-enforcement hooks ──────────────────────────────────────────────────────
# Sandbox imposes no rules beyond mechanical state (a card must be a board ally
# and not currently exhausted to be proposed as an attacker). DuelTable overrides
# these to add real legality (summoning sickness w/ Ferocity, Elusive, etc.).
func can_propose_attacker(_card: Control) -> bool:
	return true

func can_propose_defender(_card: Control, _attacker: Control = null) -> bool:
	return true

func can_play_card(_card: Control) -> bool:
	return true

# Sandbox imposes no rules; DuelTable overrides this to enforce "one resource
# placement per turn" (tracked via _resource_placed_this_turn). Powers that
# override this rule (e.g. Lifeboon) just bypass this check entirely rather
# than going through the menu action — this hook only gates the manual menu option.
func can_place_resource(_player: String) -> bool:
	return true

func can_act() -> bool:
	return true

# Sandbox-only debug tools (randomize hero, reset health, deal 1 damage) are
# hidden entirely in DuelTable — they have no meaning in a rules-enforced game.
func show_sandbox_tools() -> bool:
	return true

func can_use_power(card: Control) -> bool:
	return can_use_power_reason(card) == ""

# Returns "" if the power can currently be used, or a short human-readable reason
# why not (shown as a tooltip on the disabled "Use Power" menu item). Sandbox has
# no rules, so it's always usable; DuelTable overrides this with real legality.
func can_use_power_reason(card: Control) -> String:
	# A face-down card is just a resource — it has no usable text, regardless of
	# what power its face-up side would otherwise have. This applies even in
	# permissive Sandbox, since it's not a rules restriction, it's what "face
	# down" means.
	if card.face_down:
		return "Face down"
	return ""

# ── Card effects (powers) ───────────────────────────────────────────────────────
# Recipe format: one or more "trigger|key=value|key=value" chunks, separated by ";".
# e.g. "continuous|action=health_modifier|amount=-1|scope=other_allies"
#      "activate|cost=resources:3|action=custom"
func _parse_effects(effects_str: String) -> Array:
	var recipes: Array = []
	if effects_str == "":
		return recipes
	for chunk in effects_str.split(";"):
		chunk = chunk.strip_edges()
		if chunk == "":
			continue
		var parts = chunk.split("|")
		var recipe = {"trigger": parts[0].strip_edges()}
		for i in range(1, parts.size()):
			var kv = parts[i].split("=", true, 1)
			if kv.size() == 2:
				recipe[kv[0].strip_edges()] = kv[1].strip_edges()
		recipes.append(recipe)
	return recipes

func _get_activate_recipe(card: Control) -> Dictionary:
	for r in _parse_effects(card.effects):
		if r.get("trigger", "") == "activate":
			return r
	return {}

func _has_activate_power(card: Control) -> bool:
	return not _get_activate_recipe(card).is_empty()

# Adds the "Use Power" menu item if the card has an activatable power, greyed out
# (still visible, not removed) if it currently can't legally be used — so the
# player sees the option exists without being able to trigger it unexpectedly.
func _add_use_power_item(card: Control) -> void:
	if not _has_activate_power(card):
		return
	context_menu.add_item("Use Power", MenuAction.USE_POWER)
	var idx = context_menu.item_count - 1
	var reason = can_use_power_reason(card)
	context_menu.set_item_disabled(idx, reason != "")
	if reason != "":
		context_menu.set_item_tooltip(idx, reason)

func _all_heroes_and_allies() -> Array:
	return _heroes_and_allies_scoped("any")

func _hand_cards_of(owner: String) -> Array:
	return game_manager.hand.filter(func(c): return c.card_owner == owner)

# target_scope: "any" (hero or ally, either side — the default for most powers),
# "ally" (allies only, no heroes — e.g. Dizdemona's "target ally"), or "hero"
# (heroes only, no allies — e.g. Omedus's "target hero").
func _heroes_and_allies_scoped(target_scope: String = "any") -> Array:
	var result: Array = []
	if target_scope != "hero":
		result += ally_row.get_children().filter(func(c): return c.card_type == "Ally")
		result += opp_ally_row.get_children().filter(func(c): return c.card_type == "Ally")
	if target_scope == "any" or target_scope == "hero":
		if is_instance_valid(_p1_hero):
			result.append(_p1_hero)
		if is_instance_valid(_p2_hero):
			result.append(_p2_hero)
	return result

# Default AI heuristic for picking a target with no UI: "damage" has its own
# lethality-aware logic (see _ai_pick_damage_target); "heal" prefers its own
# side's lowest-current-HP candidate (most benefit); "sacrifice"/"discard"
# (giving up one of your own cards, as a cost or as a forced effect) prefers the
# cheapest candidate, minimizing what's lost; "opponent" (choosing which PLAYER
# something happens to, e.g. Mias the Putrid's "target player discards") prefers
# the opponent's side, never self. Falls back to all candidates if none match the
# preferred side (e.g. an unusual target_scope), and picks randomly for any other
# cursor_kind.
func _ai_pick_target(source: Control, candidates: Array, cursor_kind: String,
		recipe: Dictionary = {}, amount_key: String = "amount") -> Control:
	var preferred = candidates.duplicate()
	if cursor_kind == "damage":
		return _ai_pick_damage_target(source, candidates, recipe, amount_key)
	elif cursor_kind == "heal":
		var own_side = candidates.filter(func(c): return c.card_owner == source.card_owner)
		if not own_side.is_empty():
			preferred = own_side
		# Biggest missing-HP (max - current) first, not lowest absolute current HP —
		# a higher-max-HP character down by more damage is a better heal target than
		# a naturally-low-HP one that's only down by a little.
		preferred.sort_custom(func(a, b): return (a.max_health - a.current_health) > (b.max_health - b.current_health))
	elif cursor_kind == "sacrifice" or cursor_kind == "discard":
		# De-prioritize Protectors and Pets (same reasoning as resource placement:
		# they're too valuable to give up unless there's no other choice). Among
		# the remaining cards, prefer cheapest to minimise the loss.
		var is_valuable = func(c): return c.has_keyword("protector")
		var non_valuable = preferred.filter(func(c): return not is_valuable.call(c))
		if not non_valuable.is_empty():
			preferred = non_valuable
		preferred.sort_custom(func(a, b): return a.cost < b.cost)
	elif cursor_kind == "protect":
		# AI always protects when able (this branch is only reached with a non-empty
		# candidate list — declining is only possible via a human's right-click, see
		# _resolve_protect_point). Prefers the protector most likely to survive this
		# combat and be worth healing later: highest current HP.
		preferred.sort_custom(func(a, b): return a.current_health > b.current_health)
	elif cursor_kind == "opponent":
		var opposing = candidates.filter(func(c): return c.card_owner != source.card_owner)
		if not opposing.is_empty():
			preferred = opposing
		preferred.shuffle()
	else:
		preferred.shuffle()
	return preferred[0]

# Damage-targeting heuristic, shared by every "deal damage" power (used heavily
# enough to deserve its own logic rather than the generic highest-HP fallback):
#   1. If hitting the opponent's hero would be lethal, do it — wins the game.
#   2. Otherwise, among all candidates this hit would be lethal against, kill the
#      most expensive one (random tie-break) — get full value from a kill rather
#      than a cheap one when a pricier kill was equally available.
#   3. If nothing is lethal, pick randomly — no other principled basis to prefer
#      one non-kill over another.
# `recipe` lets this resolve the amount per-candidate (via _resolve_amount), since
# some powers' amount depends on the target itself (e.g. Omedus's hand_deficit).
func _ai_pick_damage_target(source: Control, candidates: Array, recipe: Dictionary,
		amount_key: String = "amount") -> Control:
	var opposing = candidates.filter(func(c): return c.card_owner != source.card_owner)
	var pool = opposing if not opposing.is_empty() else candidates

	var is_lethal = func(c): return _resolve_amount(source, recipe, amount_key, c) >= c.current_health

	var enemy_heroes = pool.filter(func(c): return c.card_type == "Hero" and is_lethal.call(c))
	if not enemy_heroes.is_empty():
		return enemy_heroes[0]

	var lethal = pool.filter(is_lethal)
	if not lethal.is_empty():
		var max_cost = lethal[0].cost
		for c in lethal:
			max_cost = max(max_cost, c.cost)
		var priciest_kills = lethal.filter(func(c): return c.cost == max_cost)
		priciest_kills.shuffle()
		return priciest_kills[0]

	var fallback = pool.duplicate()
	fallback.shuffle()
	return fallback[0]

# Awaits a click (or right-click cancel, which resolves to null) on one of `candidates`.
# Used by bespoke card-effect scripts that need the player to choose a target. If
# the deciding player's controller is AI, resolves immediately via _ai_pick_target
# instead of waiting for a click — normally that's `source`'s controller, but pass
# `decider` to override it (e.g. Mias the Putrid: Mias's controller picks WHICH
# player discards, but that targeted player — not Mias's controller — picks WHICH
# card, so the AI-vs-human check there must follow the target, not the source).
# `source` also drives the same arrow-cursor UI combat uses: pass cursor_kind
# "damage" (uses dmg_type's icon) or "heal" (green cross), and the amount as
# label_text.
func _prompt_target(prompt: String, candidates: Array, source: Control = null,
		cursor_kind: String = "damage", dmg_type: String = "", label_text: String = "",
		decider: String = "", recipe: Dictionary = {}, amount_key: String = "amount") -> Control:
	if candidates.is_empty():
		return null
	var decision_owner = decider if decider != "" else (source.card_owner if source else "")
	if decision_owner != "" and _is_ai_player(decision_owner):
		var chosen_ai = _ai_pick_target(source, candidates, cursor_kind, recipe, amount_key)
		game_log.add_entry("%s — %s chose %s" % [prompt, _player_name(decision_owner), chosen_ai.card_name], "default")
		return chosen_ai
	game_log.add_entry(prompt, "default")
	_ability_target_candidates = candidates
	if source:
		_enter_ability_targeting(source, cursor_kind, dmg_type, label_text, prompt)
	var chosen = await ability_target_chosen
	if source:
		_exit_ability_targeting()
	return chosen

func _recalculate_continuous_auras(player: String) -> void:
	var row = ally_row if player == "player_1" else opp_ally_row
	var allies = row.get_children().filter(func(c): return c.card_type == "Ally")
	var health_mods: Dictionary = {}
	var atk_mods: Dictionary = {}
	var hero_keywords: Array = []
	for a in allies:
		health_mods[a] = 0
		atk_mods[a] = 0
	for source in allies:
		for recipe in _parse_effects(source.effects):
			if recipe.get("trigger", "") != "continuous":
				continue
			match recipe.get("action", ""):
				"health_modifier":
					var amount = int(recipe.get("amount", "0"))
					var scope = recipe.get("scope", "other_allies")
					for target_ally in allies:
						if scope == "other_allies" and target_ally == source:
							continue
						health_mods[target_ally] = health_mods.get(target_ally, 0) + amount
				# "while there are N or more allies in your party, this gets +ATK/+health" —
				# self-only conditional buff keyed off the same party-size state that's
				# already recomputed on every ally row membership change, so no separate
				# observer is needed (unlike ally_damaged, this isn't reacting to a discrete
				# event, it's recomputed from scratch from current board state every time).
				"self_buff_if_party_size":
					var min_allies = int(recipe.get("min_allies", "0"))
					if allies.size() >= min_allies:
						atk_mods[source] = atk_mods.get(source, 0) + int(recipe.get("atk", "0"))
						health_mods[source] = health_mods.get(source, 0) + int(recipe.get("health", "0"))
				# "your hero has [keyword]" — e.g. Sentry Gwynn granting Elusive to the
				# hero. Recomputed from scratch each time, same as the modifiers above,
				# so it naturally goes away the moment the granting ally leaves play.
				# "+N ATK for each ally in your party" — linear self-buff keyed off
				# current party size (including the source itself).
				"self_atk_per_ally":
					atk_mods[source] = atk_mods.get(source, 0) + allies.size() * int(recipe.get("amount", "1"))
				"grant_hero_keyword":
					hero_keywords.append(recipe.get("keyword", "").to_lower())
	for a in allies:
		a.set_health_modifier(health_mods.get(a, 0))
		a.set_aura_atk_modifier(atk_mods.get(a, 0))
	var hero = _p1_hero if player == "player_1" else _p2_hero
	if is_instance_valid(hero):
		hero.granted_keywords = hero_keywords

# Keeps the observer registry in sync with `card` entering/leaving play. Called
# from move_card() alongside the continuous-aura recompute, since both care about
# the same "is this ally in play" transition.
func _sync_observer_registration(card: Control, now_in_play: bool) -> void:
	for trigger_name in OBSERVER_TRIGGERS:
		var list: Array = _observers.get(trigger_name, [])
		list.erase(card)
		_observers[trigger_name] = list
	if not now_in_play:
		return
	for r in _parse_effects(card.effects):
		var trig = r.get("trigger", "")
		if trig in OBSERVER_TRIGGERS:
			var list: Array = _observers.get(trig, [])
			if card not in list:
				list.append(card)
			_observers[trig] = list

# Broadcasts "an ally was dealt damage" to every registered observer (almost
# always zero of them) — e.g. Skorn, Mistress of Shadow. `damaged_ally` is whoever
# actually took the damage, which may or may not be the observer itself.
func _fire_ally_damaged(damaged_ally: Control, amount: int) -> void:
	for observer in _observers.get("ally_damaged", []):
		if not is_instance_valid(observer):
			continue
		for r in _parse_effects(observer.effects):
			if r.get("trigger", "") == "ally_damaged":
				await _run_action(observer, r, {"damaged_ally": damaged_ally, "amount": amount})
				break

func _activate_power(card: Control) -> bool:
	if not can_use_power(card):
		return false
	var activate_recipe = _get_activate_recipe(card)
	if activate_recipe.is_empty():
		return false
	_dismiss_turn_banner()

	# Pay the cost — comma-separated tokens support combined costs (e.g. flip AND
	# pay resources). "flip" itself needs no separate action here (set_power_used()
	# below covers it), EXCEPT a hero's power resource cost is stored in the card's
	# own `cost` field (heroes have no other use for it, since they're never "played").
	# Track what was paid so it can be refunded if the player backs out before the
	# power actually does anything (see _run_action's return value below) — paying
	# upfront and only refunding on a no-op keeps the common case simple while still
	# not punishing a cancelled prompt, which is a UI action, not a game decision.
	var paid_exhaust_self  = false
	var paid_resources     = 0
	var paid_self_damage   = 0
	var marked_once_per_turn = false
	var hero_power_was_already_used = card.power_used

	for token in activate_recipe.get("cost", "").split(","):
		token = token.strip_edges()
		if token.begins_with("exhaust"):
			card.exhaust()
			paid_exhaust_self = true
		elif token.begins_with("resources"):
			var parts = token.split(":")
			var spec = parts[1] if parts.size() > 1 else "0"
			var amount = await _resolve_recipe_amount(card, spec)
			_exhaust_resources(card.card_owner, amount)
			paid_resources += amount
		elif token.begins_with("flip") and card.card_type == "Hero" and (card.cost_x or card.cost > 0):
			var spec = "X" if card.cost_x else str(card.cost)
			# For X-cost heal powers, cap the AI's reasonable max to the most damage
			# on any healable candidate — no point paying 3 to heal a target with 1 damage.
			var reasonable_cap = -1
			if spec == "X" and activate_recipe.get("action", "") in ["heal_target", "heal_self"]:
				var candidates = _heroes_and_allies_scoped(activate_recipe.get("target_scope", "any"))
				var max_dmg = 0
				for c in candidates:
					max_dmg = max(max_dmg, c.damage_taken)
				reasonable_cap = max_dmg
			var amount = await _resolve_recipe_amount(card, spec, reasonable_cap)
			_exhaust_resources(card.card_owner, amount)
			paid_resources += amount
		elif token.begins_with("self_damage"):
			var parts = token.split(":")
			var spec = parts[1] if parts.size() > 1 else "1"
			var amount = await _resolve_recipe_amount(card, spec)
			card.take_damage(amount)
			_spawn_damage_number(card, amount)
			paid_self_damage += amount
	if activate_recipe.get("once_per_turn", "false") == "true":
		card.mark_activated_this_turn()
		marked_once_per_turn = true
	if card.card_type == "Hero":
		card.set_power_used(true)

	# Fire-and-forget: wiggles `card` for as long as _run_action is still
	# resolving (e.g. a human picking a target), plus the usual settle duration
	# afterward — see _wiggle_card.
	var wiggle_stop = {"stop": false}
	_wiggle_card(card, wiggle_stop)
	var committed = await _run_action(card, activate_recipe)
	wiggle_stop["stop"] = true
	if not committed:
		if paid_exhaust_self:
			card.ready_card()
		if paid_resources > 0:
			_ready_resources(card.card_owner, paid_resources)
		if paid_self_damage > 0:
			card.heal(paid_self_damage)
		if marked_once_per_turn:
			card.reset_turn_flags()
		if card.card_type == "Hero" and not hero_power_was_already_used:
			card.set_power_used(false)
		game_log.add_entry("%s's power was cancelled — cost refunded" % card.card_name, "default")
	# IMPORTANT for future triggers like "if you've exhausted a resource this turn":
	# any such tracking must be incremented HERE (only when committed == true), not
	# inside the cost-payment loop above. Resources get exhausted upfront and may
	# still be refunded above — recording "a resource was spent" at payment time
	# would let a player exploit cancel-to-refund to satisfy that condition without
	# ever actually committing to a power.
	return committed

# Re-readies up to `amount` exhausted resources for `player` — the inverse of
# _exhaust_resources, used to refund a cancelled power's cost.
func _ready_resources(player: String, amount: int) -> void:
	var row = resource_row if player == "player_1" else opp_resource_row
	var readied = 0
	for child in row.get_children():
		if readied >= amount:
			break
		if child.has_method("ready_card") and child.exhausted:
			child.ready_card()
			readied += 1
	_update_resource_counts()

# Runs the action named in `recipe` — shared by activated powers (after cost is paid)
# and passive triggers (enters_play, dies, etc., which have no cost to pay at all).
# The action library itself doesn't know or care which trigger invoked it. Returns
# true if the action actually did something (so its cost should stick), or false if
# it was a no-op (no target chosen, declined, or genuinely not implemented yet) —
# callers use this to decide whether to refund the cost.
func _run_action(card: Control, recipe: Dictionary, context: Dictionary = {}) -> bool:
	var action = recipe.get("action", "")
	match action:
		"custom":
			if CardEffects.is_implemented(card.card_id):
				await CardEffects.run(self, card)
				return true
			game_log.add_entry(
				"%s's power isn't implemented yet" % card.card_name, "default")
			return false
		"deal_damage":
			return await _run_deal_damage_action(card, recipe)
		"heal_self":
			return _run_heal_self_action(card, recipe)
		"ready_self":
			return _run_ready_self_action(card)
		"deal_and_heal":
			return await _run_deal_and_heal_action(card, recipe)
		"heal_target":
			return await _run_heal_target_action(card, recipe)
		"deal_damage_self_cost":
			return await _run_deal_damage_self_cost_action(card, recipe)
		"shuffle_redraw":
			return _run_shuffle_redraw_action(card)
		"destroy_target":
			return await _run_destroy_target_action(card, recipe)
		"sacrifice_deal_damage":
			return await _run_sacrifice_deal_damage_action(card, recipe)
		"sacrifice_draw_card":
			return await _run_sacrifice_draw_card_action(card, recipe)
		"draw_card":
			return _run_draw_card_action(card, recipe)
		"deal_damage_all_opposing":
			return _run_deal_damage_all_opposing_action(card, recipe)
		"heal_all_own_party":
			return _run_heal_all_own_party_action(card, recipe)
		"place_resource_from_hand":
			return await _run_place_resource_from_hand_action(card, recipe)
		"return_to_hand":
			return await _run_return_to_hand_action(card, recipe)
		"target_player_discards":
			return await _run_target_player_discards_action(card, recipe)
		"defender_controller_discards":
			return await _run_defender_controller_discards_action(card, context)
		"deal_damage_to_controller_hero":
			return _run_deal_damage_to_controller_hero_action(card, recipe, context)
		_:
			game_log.add_entry(
				"%s used its power (action '%s' not implemented)" % [card.card_name, action], "default")
			return false

# Fires this specific card instance's "enters_play" trigger, if it has one. Scoped
# to this exact card object — e.g. playing a second copy of a card whose ability
# triggers "when this enters play" does NOT also re-trigger for copies already in
# play; each card instance only ever fires its own trigger for its own entry.
func _fire_enters_play(card: Control) -> void:
	for r in _parse_effects(card.effects):
		if r.get("trigger", "") == "enters_play":
			await _run_action(card, r)
			return

# Fires every card's "start_of_turn" trigger, if it has one, as `player`'s turn
# begins. scope=any (default) fires regardless of whose turn it is (e.g. Fa'tafi:
# "at the start of each turn"); scope=own_turn only fires when this card's
# controller is the player whose turn is starting (e.g. Ka'tali Stonetusk: "at
# the start of your turn").
func _fire_start_of_turn(player: String) -> void:
	for card in _all_heroes_and_allies():
		for r in _parse_effects(card.effects):
			if r.get("trigger", "") != "start_of_turn":
				continue
			if r.get("scope", "any") == "own_turn" and card.card_owner != player:
				continue
			await _run_action(card, r)

# Fires every card's "end_of_turn" trigger, if it has one, as `player`'s turn
# ends — same scope convention as _fire_start_of_turn (any/own_turn).
func _fire_end_of_turn(player: String) -> void:
	for card in _all_heroes_and_allies():
		for r in _parse_effects(card.effects):
			if r.get("trigger", "") != "end_of_turn":
				continue
			if r.get("scope", "any") == "own_turn" and card.card_owner != player:
				continue
			await _run_action(card, r)

# Fires `dealer`'s "deals_combat_damage" trigger, if it has one matching `role`
# ("attacking" or "defending" — whichever side `dealer` was on for this exchange)
# and `target_type` (defaults to "any"; "hero"/"ally" narrows it, e.g. Samuel
# Grey's "to a defending hero" requires role=attacking AND target_type=hero).
func _fire_deals_combat_damage(dealer: Control, target: Control, role: String) -> void:
	for r in _parse_effects(dealer.effects):
		if r.get("trigger", "") != "deals_combat_damage":
			continue
		var want_role = r.get("role", "any")
		if want_role != "any" and want_role != role:
			continue
		var want_type = r.get("target_type", "any")
		if want_type == "hero" and target.card_type != "Hero":
			continue
		if want_type == "ally" and target.card_type != "Ally":
			continue
		await _run_action(dealer, r, {"defender": target})
		return

# Resolves a cost amount that may be a literal int string or the literal "X" — in
# the X case, prompts a human / asks the AI (see _resolve_x_value) and records the
# chosen value on the card so the action step below can reuse the same value.
func _resolve_recipe_amount(card: Control, spec: String, reasonable_cap: int = -1) -> int:
	if spec == "X":
		var x = await _resolve_x_value(card, card.card_owner, card.cost_base, reasonable_cap)
		card.chosen_x = x
		return card.cost_base + x
	return int(spec)

# Resolves an action param that may be:
#   - a literal int string
#   - "X" — reuses whatever value was already chosen while paying the cost
#   - "hand_deficit:N" — N minus the number of cards in `target`'s controller's
#     hand (min 0), e.g. Omedus the Punisher.
#   - "per_hand_card:N" — N times the number of cards in `target`'s controller's
#     hand (the inverse incentive of hand_deficit — more cards means more damage,
#     not less), e.g. Vexra Darkfall.
#   Both target-dependent specs need `target` to already be chosen (see
#   _preview_amount_label for what to show while it's still unknown).
func _resolve_amount(card: Control, recipe: Dictionary, key: String, target: Control = null) -> int:
	var raw = recipe.get(key, "0")
	if raw == "X":
		return card.chosen_x
	if target != null:
		if raw.begins_with("hand_deficit:"):
			var n = int(raw.split(":")[1])
			var hand_size = game_manager.hand.filter(func(c): return c.card_owner == target.card_owner).size()
			return max(n - hand_size, 0)
		if raw.begins_with("per_hand_card:"):
			var n = int(raw.split(":")[1])
			var hand_size = game_manager.hand.filter(func(c): return c.card_owner == target.card_owner).size()
			return n * hand_size
	return int(raw)

# What to show on the targeting cursor before the final amount is known — literal
# numbers and "X" are already known up front; target-dependent specs show "?".
func _preview_amount_label(recipe: Dictionary, key: String) -> String:
	var raw = recipe.get(key, "0")
	if raw == "X":
		return "X"
	if raw.begins_with("hand_deficit:") or raw.begins_with("per_hand_card:"):
		return "?"
	return raw

# Generic templated action for the common "deal X [type] damage to target hero or
# ally" power shape. Targets any hero/ally on the board, either side.
func _run_deal_damage_action(card: Control, recipe: Dictionary) -> bool:
	var dmg_type = recipe.get("dmg_type", "")
	var type_str = (" " + dmg_type) if dmg_type else ""
	var preview = _preview_amount_label(recipe, "amount")
	var target = await _prompt_target(
		"%s: choose a target to deal %s%s damage to" % [card.card_name, preview, type_str],
		_heroes_and_allies_scoped(recipe.get("target_scope", "any")), card, "damage", dmg_type, preview,
		"", recipe)
	if target == null:
		game_log.add_entry("%s's power fizzled (no target chosen)" % card.card_name, "default")
		return false
	var amount = _resolve_amount(card, recipe, "amount", target)
	target.take_damage(amount)
	game_log.add_entry(
		"%s dealt %d%s damage to %s" % [card.card_name, amount, type_str, target.card_name], "attack")
	return true

# Generic templated action for "deal X [type] damage to target hero or ally and
# heal Y from another target hero or ally" — two distinct targets, either side.
func _run_deal_and_heal_action(card: Control, recipe: Dictionary) -> bool:
	var dmg_amount = _resolve_amount(card, recipe, "damage_amount")
	var dmg_type = recipe.get("dmg_type", "")
	var heal_amount = _resolve_amount(card, recipe, "heal_amount")
	var type_str = (" " + dmg_type) if dmg_type else ""
	var all_targets = _heroes_and_allies_scoped(recipe.get("target_scope", "any"))

	var dmg_target = await _prompt_target(
		"%s: choose a target to deal %d%s damage to" % [card.card_name, dmg_amount, type_str],
		all_targets, card, "damage", dmg_type, str(dmg_amount),
		"", recipe, "damage_amount")
	if dmg_target == null:
		game_log.add_entry("%s's power fizzled (no target chosen)" % card.card_name, "default")
		return false
	dmg_target.take_damage(dmg_amount)
	game_log.add_entry(
		"%s dealt %d%s damage to %s" % [card.card_name, dmg_amount, type_str, dmg_target.card_name], "attack")

	# The damage already happened — committed regardless of the heal half's outcome.
	var heal_candidates = all_targets.filter(func(c): return c != dmg_target)
	var heal_target = await _prompt_target(
		"%s: choose another target to heal %d damage from" % [card.card_name, heal_amount],
		heal_candidates, card, "heal", "", str(heal_amount))
	if heal_target != null:
		heal_target.heal(heal_amount)
		_spawn_heal_number(heal_target, heal_amount)
		game_log.add_entry(
			"%s healed %d damage from %s" % [card.card_name, heal_amount, heal_target.card_name], "default")
	return true

# Generic templated action for "heal X damage from target hero or ally" — a single
# target, either side. Supports amount="X" for variable-cost powers (e.g. a hero
# whose printed cost is "X" and who heals exactly however much X was chosen).
func _run_heal_target_action(card: Control, recipe: Dictionary) -> bool:
	var amount = _resolve_amount(card, recipe, "amount")
	# Fizzle if X resolved to 0 (e.g. no resources available when paying a flip cost).
	# Triggers a full cost refund via _activate_power's committed==false path.
	if amount <= 0:
		game_log.add_entry("%s's power has no effect (X = 0)" % card.card_name, "default")
		return false
	var candidates = _heroes_and_allies_scoped(recipe.get("target_scope", "any"))
	# Fizzle if nobody has any damage to heal — spending resources on a no-op is wrong.
	if candidates.filter(func(c): return c.damage_taken > 0).is_empty():
		game_log.add_entry("%s's power has no effect (no damaged targets)" % card.card_name, "default")
		return false
	var target = await _prompt_target(
		"%s: choose a target to heal %d damage from" % [card.card_name, amount],
		candidates, card, "heal", "", str(amount))
	if target == null:
		game_log.add_entry("%s's power fizzled (no target chosen)" % card.card_name, "default")
		return false
	target.heal(amount)
	_spawn_heal_number(target, amount)
	game_log.add_entry(
		"%s healed %d damage from %s" % [card.card_name, amount, target.card_name], "default")
	return true

# Generic templated action for "heal X damage from this card" — no targeting,
# always self (e.g. Fa'tafi/Ka'tali Stonetusk's start_of_turn self-heal).
func _run_heal_self_action(card: Control, recipe: Dictionary) -> bool:
	var amount = _resolve_amount(card, recipe, "amount")
	var actually_healed = min(amount, card.damage_taken)
	card.heal(amount)
	if actually_healed > 0:
		_spawn_heal_number(card, actually_healed)
	game_log.add_entry("%s healed %d damage" % [card.card_name, actually_healed], "default")
	return true

# Generic templated action for "ready this card" — no targeting, always self
# (e.g. Kulan Earthguard's end_of_turn self-ready). No-op (and no log spam) if
# it's already ready.
func _run_ready_self_action(card: Control) -> bool:
	if not card.exhausted:
		return true
	card.ready_card()
	game_log.add_entry("%s readies itself" % card.card_name, "default")
	return true

# Generic templated action for "put X damage on this card, deal X [type] damage to
# target [hero or] ally" — a self-damage-funded X cost where the amount is decided
# AFTER the target is picked (so the legal/reasonable max can be capped sensibly):
# legal max = won't kill the source (current_health - 1); reasonable max (AI) is
# also capped by the target's current HP, since spending more would just be wasted
# damage. Self-inflicted-cost powers are rare but not unique to one card, hence the
# generic template rather than a bespoke script.
func _run_deal_damage_self_cost_action(card: Control, recipe: Dictionary) -> bool:
	var dmg_type = recipe.get("dmg_type", "")
	var type_str = (" " + dmg_type) if dmg_type else ""
	var target = await _prompt_target(
		"%s: choose a target to deal X%s damage to (costs X damage to self)" % [card.card_name, type_str],
		_heroes_and_allies_scoped(recipe.get("target_scope", "any")), card, "damage", dmg_type, "X")
	if target == null:
		game_log.add_entry("%s's power fizzled (no target chosen)" % card.card_name, "default")
		return false

	var legal_max = max(card.current_health - 1, 0)
	var reasonable_max = min(legal_max, target.current_health)
	var x = await _resolve_x_value_with_max(card, legal_max, reasonable_max,
		"Costs X damage to self (current HP: %d)" % card.current_health)
	card.chosen_x = x
	if x <= 0:
		game_log.add_entry("%s chose X=0 — no effect" % card.card_name, "default")
		return true

	card.take_damage(x)
	target.take_damage(x)
	game_log.add_entry(
		"%s took %d damage and dealt %d%s damage to %s" % [
			card.card_name, x, x, type_str, target.card_name], "attack")
	return true

# Generic templated action for "shuffle your hand into your deck, then draw that
# many cards" — no targeting/amount needed, always affects the activator's own hand.
func _run_shuffle_redraw_action(card: Control) -> bool:
	var count = _shuffle_hand_into_deck(card.card_owner)
	game_log.add_entry(
		"%s shuffled their hand into their deck and drew %d card%s" % [
			card.card_name, count, "s" if count != 1 else ""], "default")
	return true

# Generic templated action for "destroy target [hero or] ally" — optionally scoped
# to exhausted targets only (requires_exhausted=true), e.g. Timmo Shadestep.
func _run_destroy_target_action(card: Control, recipe: Dictionary) -> bool:
	var candidates = _heroes_and_allies_scoped(recipe.get("target_scope", "any"))
	if recipe.get("requires_exhausted", "false") == "true":
		candidates = candidates.filter(func(c): return c.exhausted)
	var target = await _prompt_target(
		"%s: choose a target to destroy" % card.card_name,
		candidates, card, "damage", recipe.get("dmg_type", ""), "")
	if target == null:
		game_log.add_entry("%s's power fizzled (no target chosen)" % card.card_name, "default")
		return false
	game_log.add_entry("%s destroyed %s" % [card.card_name, target.card_name], "death")
	await _on_card_died(target)
	return true

# Generic templated action for "destroy one of your [subtype] allies, deal X
# [type] damage to target [scope]" — X is determined by which ally is sacrificed
# (its cost by default, or its ATK if x_source=atk — e.g. Mezzik Darkspark),
# not chosen freely. sacrifice_filter narrows the sacrifice pool to a subtype
# (e.g. "Pet"); leave empty to allow any ally. The AI always uses the "sacrifice"
# cursor_kind's cheapest-cost heuristic regardless of x_source — for an atk-based
# X this is a deliberate simplification (cheapest cost isn't necessarily lowest
# ATK) rather than a separate ATK-aware heuristic.
func _run_sacrifice_deal_damage_action(card: Control, recipe: Dictionary) -> bool:
	var filter_subtype = recipe.get("sacrifice_filter", "")
	var x_source = recipe.get("x_source", "cost")
	var own_row = ally_row if card.card_owner == "player_1" else opp_ally_row
	var sac_candidates = own_row.get_children().filter(func(c):
		return c.card_type == "Ally" and (filter_subtype == "" or filter_subtype in c.card_subtype))
	var noun = filter_subtype if filter_subtype != "" else "ally"
	var sac_target = await _prompt_target(
		"%s: pick one of your %ss to destroy" % [card.card_name, noun],
		sac_candidates, card, "sacrifice", "", "")
	if sac_target == null:
		game_log.add_entry("%s's power fizzled (no %s to sacrifice)" % [card.card_name, noun], "default")
		return false

	var x = sac_target.atk if x_source == "atk" else sac_target.cost
	card.chosen_x = x
	sac_target.ready_card()
	game_log.add_entry(
		"%s destroyed %s (%s %d) to fuel its power" % [card.card_name, sac_target.card_name, x_source, x], "death")
	move_card(sac_target, _grav_for(sac_target.card_owner))

	var dmg_type = recipe.get("dmg_type", "")
	var type_str = (" " + dmg_type) if dmg_type else ""
	# The sacrifice already happened (irreversible) — committed regardless of
	# whether a damage target is then found/chosen.
	var target = await _prompt_target(
		"%s: choose a target to deal %d%s damage to" % [card.card_name, x, type_str],
		_heroes_and_allies_scoped(recipe.get("target_scope", "any")), card, "damage", dmg_type, str(x))
	if target == null:
		game_log.add_entry("%s's power fizzled (no target chosen)" % card.card_name, "default")
		return true
	target.take_damage(x)
	game_log.add_entry(
		"%s dealt %d%s damage to %s" % [card.card_name, x, type_str, target.card_name], "attack")
	return true

# Generic templated action for "destroy an ally in your party, draw a card" —
# the sacrifice (any own ally, including the activator itself) goes through the
# canonical _on_card_died path so any "dies" triggers on the sacrificed ally
# still fire; the AI picks the cheapest ally to sacrifice via the existing
# "sacrifice" cursor_kind heuristic in _ai_pick_target.
func _run_sacrifice_draw_card_action(card: Control, recipe: Dictionary) -> bool:
	var filter_subtype = recipe.get("sacrifice_filter", "")
	var own_row = ally_row if card.card_owner == "player_1" else opp_ally_row
	var sac_candidates = own_row.get_children().filter(func(c):
		return c.card_type == "Ally" and (filter_subtype == "" or filter_subtype in c.card_subtype))
	var noun = filter_subtype if filter_subtype != "" else "ally"
	var sac_target = await _prompt_target(
		"%s: pick an %s in your party to destroy" % [card.card_name, noun],
		sac_candidates, card, "sacrifice", "", "")
	if sac_target == null:
		game_log.add_entry("%s's power fizzled (no %s to sacrifice)" % [card.card_name, noun], "default")
		return false
	game_log.add_entry("%s destroyed %s to draw a card" % [card.card_name, sac_target.card_name], "death")
	await _on_card_died(sac_target)
	var amount = _resolve_amount(card, recipe, "amount")
	for _i in amount:
		_draw_card(card.card_owner)
	return true

# Generic templated action for "draw N cards" — no targeting needed, always draws
# for the activator's own controller.
func _run_draw_card_action(card: Control, recipe: Dictionary) -> bool:
	var amount = _resolve_amount(card, recipe, "amount")
	for _i in amount:
		_draw_card(card.card_owner)
	game_log.add_entry(
		"%s drew %d card%s" % [card.card_name, amount, "s" if amount != 1 else ""], "default")
	return true

# Generic templated action for "deal X [type] damage to each opposing hero and
# ally" — automatic, no targeting choice involved, always hits everyone on the
# activator's opponent's side.
func _run_deal_damage_all_opposing_action(card: Control, recipe: Dictionary) -> bool:
	var amount = _resolve_amount(card, recipe, "amount")
	var dmg_type = recipe.get("dmg_type", "")
	var type_str = (" " + dmg_type) if dmg_type else ""
	var opp = "player_2" if card.card_owner == "player_1" else "player_1"
	var opp_row = opp_ally_row if opp == "player_2" else ally_row
	var opp_hero = _p2_hero if opp == "player_2" else _p1_hero
	var targets = opp_row.get_children().filter(func(c): return c.card_type == "Ally")
	if is_instance_valid(opp_hero):
		targets.append(opp_hero)
	for t in targets:
		t.take_damage(amount)
		_spawn_damage_number(t, amount)
	game_log.add_entry(
		"%s dealt %d%s damage to each opposing hero and ally" % [card.card_name, amount, type_str], "attack")
	return true

# Generic templated action for "heal X damage from each hero and ally in your
# party" — automatic, no targeting choice involved, always heals everyone on the
# activator's own side.
func _run_heal_all_own_party_action(card: Control, recipe: Dictionary) -> bool:
	var amount = _resolve_amount(card, recipe, "amount")
	var owner = card.card_owner
	var row = ally_row if owner == "player_1" else opp_ally_row
	var hero = _p1_hero if owner == "player_1" else _p2_hero
	var targets = row.get_children().filter(func(c): return c.card_type == "Ally")
	if is_instance_valid(hero):
		targets.append(hero)
	for t in targets:
		var actually_healed = min(amount, t.damage_taken)
		t.heal(amount)
		if actually_healed > 0:
			_spawn_heal_number(t, actually_healed)
	game_log.add_entry(
		"%s healed %d damage from each hero and ally in their party" % [card.card_name, amount], "default")
	return true

# Generic templated action for "you may put a card from your hand into your
# resource row face down[, exhausted]" — the first action whose target pool is
# the activator's own hand instead of board characters. Optional ("may"): right-
# click cancels the same way any other prompt declines. start_exhausted=true
# makes the new resource enter already exhausted (vs. the normal ready state when
# placing a resource manually).
func _run_place_resource_from_hand_action(card: Control, recipe: Dictionary) -> bool:
	var owner = card.card_owner
	var start_exhausted = recipe.get("start_exhausted", "false") == "true"
	var exhausted_note = ", exhausted" if start_exhausted else ""
	var chosen = await _prompt_target(
		"%s: pick a card from your hand to place as a resource (face down%s)" % [card.card_name, exhausted_note],
		_hand_cards_of(owner), card, "resource", "", "")
	if chosen == null:
		game_log.add_entry("%s's power was declined" % card.card_name, "default")
		return false
	chosen.set_face_down(true)
	move_card(chosen, resource_row if owner == "player_1" else opp_resource_row)
	if start_exhausted:
		chosen.exhaust()
	game_log.add_entry(
		"%s put %s into %s's resource row%s" % [
			card.card_name, chosen.card_name, _player_name(owner), exhausted_note], "resource")
	return true

# Generic templated action for "you may put target [hero or] ally into its
# owner's hand" — optional, target defaults to "ally" since that's the common
# wording. Goes through move_card() like every other hand-return, so hand-size
# bookkeeping (e.g. Omedus's hand_deficit) stays correct automatically.
func _run_return_to_hand_action(card: Control, recipe: Dictionary) -> bool:
	var candidates = _heroes_and_allies_scoped(recipe.get("target_scope", "ally"))
	var target = await _prompt_target(
		"%s: you may pick a target to return to its owner's hand" % card.card_name,
		candidates, card, "resource", "", "")
	if target == null:
		game_log.add_entry("%s's power was declined" % card.card_name, "default")
		return false
	target.ready_card()
	move_card(target, _hand_for(target.card_owner))
	game_log.add_entry(
		"%s put %s into %s's hand" % [card.card_name, target.card_name, _player_name(target.card_owner)], "default")
	return true

# Generic templated action for "target player discards a card" — the first action
# targeting a PLAYER rather than a card (a hero is used as the clickable proxy for
# "this player"), and the first where the SECOND choice (which card) is made by
# someone other than the activator: the targeted player picks their own discard,
# so that step's AI-vs-human check follows them, not this card's controller. This
# is mandatory text (no "may"), so unlike every other optional prompt, a cancelled
# choice auto-resolves at random rather than fizzling/refunding — the effect must
# happen, only WHO/WHICH is up to choice when possible.
func _run_target_player_discards_action(card: Control, _recipe: Dictionary) -> bool:
	var hero_candidates = _heroes_and_allies_scoped("hero")
	var target_hero = await _prompt_target(
		"%s: choose a player to discard a card" % card.card_name,
		hero_candidates, card, "opponent", "", "")
	if target_hero == null:
		target_hero = hero_candidates[randi() % hero_candidates.size()]
	await _resolve_discard(card, target_hero.card_owner)
	return true

# "That hero's controller discards a card" — the WHO is already determined by
# combat (context.defender), not chosen; only WHICH card is a choice, made by the
# defending player. e.g. Samuel Grey: "deals combat damage to a defending hero."
func _run_defender_controller_discards_action(card: Control, context: Dictionary) -> bool:
	var defender = context.get("defender")
	if defender == null:
		return false
	await _resolve_discard(card, defender.card_owner)
	return true

# "Deals that amount of [type] damage to target hero in that ally's party" — no
# real choice involved, since each player has exactly one hero. context supplies
# WHO was damaged (damaged_ally) and HOW MUCH (amount); e.g. Skorn, Mistress of
# Shadow: "When an ally is dealt damage, deals that amount of shadow damage to
# target hero in that ally's party."
func _run_deal_damage_to_controller_hero_action(card: Control, recipe: Dictionary, context: Dictionary) -> bool:
	var damaged_ally = context.get("damaged_ally")
	var amount = context.get("amount", 0)
	if damaged_ally == null or amount <= 0:
		return false
	var hero = _p1_hero if damaged_ally.card_owner == "player_1" else _p2_hero
	if not is_instance_valid(hero):
		return false
	var dmg_type = recipe.get("dmg_type", "")
	var type_str = (" " + dmg_type) if dmg_type else ""
	hero.take_damage(amount)
	_spawn_damage_number(hero, amount)
	game_log.add_entry(
		"%s deals %d%s damage to %s (triggered by damage to %s)" % [
			card.card_name, amount, type_str, hero.card_name, damaged_ally.card_name], "attack")
	return true

# Shared discard resolution: `target_player` (already determined) picks which of
# their own hand cards to discard. Mandatory — a cancelled choice auto-resolves at
# random rather than letting the player dodge it, same reasoning as the callers.
func _resolve_discard(card: Control, target_player: String) -> void:
	var hand_cards = _hand_cards_of(target_player)
	if hand_cards.is_empty():
		game_log.add_entry("%s has no cards to discard" % _player_name(target_player), "default")
		return
	var discarded = await _prompt_target(
		"%s: choose a card to discard" % _player_name(target_player),
		hand_cards, card, "discard", "", "", target_player)
	if discarded == null:
		discarded = hand_cards[randi() % hand_cards.size()]
	discarded.ready_card()
	move_card(discarded, _grav_for(discarded.card_owner))
	game_log.add_entry(
		"%s discarded %s" % [_player_name(target_player), discarded.card_name], "default")

const DMG_ICONS = {
	"Arcane": "res://assets/dmg_icons/arcane.png",
	"Fire":   "res://assets/dmg_icons/fire.png",
	"Frost":  "res://assets/dmg_icons/frost.png",
	"Holy":   "res://assets/dmg_icons/holy.png",
	"Melee":  "res://assets/dmg_icons/melee.png",
	"Nature": "res://assets/dmg_icons/nature.png",
	"Ranged": "res://assets/dmg_icons/ranged.png",
	"Shadow": "res://assets/dmg_icons/shadow.png",
}

func _set_targeting_cursor(dmg_type: String = "", cursor_kind: String = "damage") -> void:
	if cursor_kind == "heal":
		Input.set_custom_mouse_cursor(_get_heal_cursor_texture(), Input.CURSOR_ARROW, Vector2(16, 16))
		return
	var icon_path = DMG_ICONS.get(dmg_type, "")
	var tex = load(icon_path) if icon_path != "" else null
	if tex:
		Input.set_custom_mouse_cursor(tex, Input.CURSOR_ARROW, tex.get_size() / 2.0)
	else:
		DisplayServer.cursor_set_shape(DisplayServer.CURSOR_CROSS)

func _get_heal_cursor_texture() -> ImageTexture:
	if _heal_cursor_tex:
		return _heal_cursor_tex
	var size = 32
	var img = Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var thickness = 8
	var mid = size / 2
	var c = Color(0.15, 0.85, 0.25, 1.0)  # universal heal green
	for x in range(size):
		for y in range(size):
			if abs(x - mid) <= thickness / 2 or abs(y - mid) <= thickness / 2:
				img.set_pixel(x, y, c)
	_heal_cursor_tex = ImageTexture.create_from_image(img)
	return _heal_cursor_tex

func _show_targeting_prompt(text: String) -> void:
	var lbl = _combat_canvas.get_node("PromptLabel") as Label
	var bg  = _combat_canvas.get_node("PromptBg") as ColorRect
	var visible_flag = text != ""
	lbl.visible = visible_flag
	bg.visible = visible_flag
	if not visible_flag:
		return
	lbl.text = text
	var pad = Vector2(16, 8)
	var min_size = lbl.get_minimum_size()
	var vp_w = get_viewport_rect().size.x
	lbl.size = min_size
	lbl.position = Vector2((vp_w - min_size.x) / 2.0, 24)
	bg.size = min_size + pad * 2.0
	bg.position = lbl.position - pad

func _hide_targeting_prompt() -> void:
	_combat_canvas.get_node("PromptLabel").visible = false
	_combat_canvas.get_node("PromptBg").visible = false

# Explicit, clickable alternative to right-click-to-decline, shown only during a
# protect-point prompt (see _resolve_protect_point) — right-click still works too,
# but a visible button is needed since "accept the attack as-is" isn't something
# a player would otherwise know to express by right-clicking empty space.
func _show_accept_combat_button() -> void:
	var btn = _combat_canvas.get_node("AcceptCombatBtn") as Button
	var lbl = _combat_canvas.get_node("PromptLabel") as Label
	btn.size = btn.get_minimum_size()
	btn.position = Vector2(
		lbl.position.x + (lbl.size.x - btn.size.x) / 2.0,
		lbl.position.y + lbl.size.y + 16)
	btn.visible = true

func _hide_accept_combat_button() -> void:
	_combat_canvas.get_node("AcceptCombatBtn").visible = false

func _on_accept_combat_pressed() -> void:
	if not _protect_prompt_active:
		return
	_ability_target_candidates = []
	ability_target_chosen.emit(null)

# Shown for a human player at the start of their turn, dismissed automatically once
# they actually resolve their first combat or power that turn (not just by browsing/
# selecting a target) — see _dismiss_turn_banner().
func _show_turn_banner(player: String) -> void:
	var lbl = _combat_canvas.get_node("TurnBannerLabel") as Label
	var bg  = _combat_canvas.get_node("TurnBannerBg") as ColorRect
	lbl.text = "%s's turn has started" % _player_name(player)
	var pad = Vector2(24, 12)
	var min_size = lbl.get_minimum_size()
	var vp = get_viewport_rect().size
	lbl.size = min_size
	lbl.position = Vector2((vp.x - min_size.x) / 2.0, vp.y * 0.35)
	bg.size = min_size + pad * 2.0
	bg.position = lbl.position - pad
	lbl.visible = true
	bg.visible = true
	_turn_banner_dismissed = false

# Shown during the BEGINNING phase (mulligan/ready) — unlike _show_turn_banner,
# stays up through mulligan and is only ever dismissed by _start_game() once
# BOTH players have pressed Ready, so a player who's already readied up still
# sees it as a reminder that their opponent hasn't yet.
func _show_get_ready_banner() -> void:
	var lbl = _combat_canvas.get_node("TurnBannerLabel") as Label
	var bg  = _combat_canvas.get_node("TurnBannerBg") as ColorRect
	lbl.text = "Get ready"
	var pad = Vector2(24, 12)
	var min_size = lbl.get_minimum_size()
	var vp = get_viewport_rect().size
	lbl.size = min_size
	lbl.position = Vector2((vp.x - min_size.x) / 2.0, vp.y * 0.35)
	bg.size = min_size + pad * 2.0
	bg.position = lbl.position - pad
	lbl.visible = true
	bg.visible = true
	_turn_banner_dismissed = false

func _dismiss_turn_banner() -> void:
	if _turn_banner_dismissed:
		return
	_turn_banner_dismissed = true
	_combat_canvas.get_node("TurnBannerLabel").visible = false
	_combat_canvas.get_node("TurnBannerBg").visible = false

func _enter_targeting_mode(card: Control) -> void:
	_attacker = card
	_set_targeting_cursor(card.dmg_type, "damage")
	var atk_lbl = _combat_canvas.get_node("AtkLabel")
	atk_lbl.text = str(card.atk)
	atk_lbl.visible = true
	_combat_line.visible = true
	_show_targeting_prompt("Pick an opposing ally or hero to attack")

func _exit_targeting_mode() -> void:
	_attacker = null
	Input.set_custom_mouse_cursor(null)
	_combat_line.visible = false
	_combat_canvas.get_node("ArrowHead").visible = false
	_combat_canvas.get_node("AtkLabel").visible = false
	_hide_targeting_prompt()

# ── Generic (non-combat) ability targeting ─────────────────────────────────────
func _enter_ability_targeting(source: Control, cursor_kind: String, dmg_type: String,
		label_text: String, prompt: String = "") -> void:
	_ability_source = source
	_set_targeting_cursor(dmg_type, cursor_kind)
	var atk_lbl = _combat_canvas.get_node("AtkLabel")
	atk_lbl.text = label_text
	atk_lbl.visible = true
	_combat_line.visible = true
	_show_targeting_prompt(prompt)

func _exit_ability_targeting() -> void:
	_ability_source = null
	Input.set_custom_mouse_cursor(null)
	_combat_line.visible = false
	_combat_canvas.get_node("ArrowHead").visible = false
	_combat_canvas.get_node("AtkLabel").visible = false
	_hide_targeting_prompt()

func _play_wiggle(attacker: Control, defender: Control) -> void:
	var start      = attacker.global_position
	var atk_center = start + attacker.size / 2.0
	var def_center = defender.global_position + defender.size / 2.0
	var direction  = (def_center - atk_center).normalized()
	var distance   = atk_center.distance_to(def_center)
	var punch_dist = distance * 0.5
	var tween = create_tween()
	tween.tween_property(attacker, "global_position", start + direction * punch_dist, 0.12)
	tween.tween_property(attacker, "global_position", start, 0.10)
	await tween.finished

func _spawn_damage_number(card: Control, amount: int) -> void:
	if amount <= 0:
		return
	_spawn_floating_number(card, "-%d" % amount, Color(1, 0.15, 0.15))

func _spawn_heal_number(card: Control, amount: int) -> void:
	if amount <= 0:
		return
	_spawn_floating_number(card, "+%d" % amount, Color(0.25, 0.95, 0.35))

const FLOATING_NUMBER_DURATION = 2.4

func _spawn_floating_number(card: Control, text: String, color: Color) -> void:
	var lbl = Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 28)
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_constant_override("outline_size", 3)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	var origin = card.global_position + card.size / 2.0 - Vector2(20, 14)
	lbl.position = origin
	lbl.size = Vector2(60, 36)
	_combat_canvas.add_child(lbl)
	var tween = create_tween()
	tween.tween_property(lbl, "position", origin + Vector2(0, -70), FLOATING_NUMBER_DURATION)
	tween.parallel().tween_property(lbl, "modulate:a", 0.0, FLOATING_NUMBER_DURATION)
	tween.tween_callback(lbl.queue_free)

# One full left-right-back wiggle cycle (up to 30° off resting rotation),
# scaled to `duration`. Shared by both the looping phase (while waiting on a
# target pick) and the final settle phase of _wiggle_card below.
func _play_wiggle_cycle(card: Control, resting_degrees: float, duration: float) -> void:
	var tween = create_tween()
	tween.tween_property(card, "rotation_degrees", resting_degrees + 30.0, duration * 0.15)
	tween.tween_property(card, "rotation_degrees", resting_degrees - 30.0, duration * 0.3)
	tween.tween_property(card, "rotation_degrees", resting_degrees + 20.0, duration * 0.25)
	tween.tween_property(card, "rotation_degrees", resting_degrees - 10.0, duration * 0.2)
	tween.tween_property(card, "rotation_degrees", resting_degrees, duration * 0.1)
	await tween.finished

# Wiggles `card` left/right to mark it as the source of a non-attack power
# effect. Keeps looping short cycles for as long as the effect is still
# resolving (stop_flag["stop"] is false) — e.g. while a human is still picking
# a target, so the wiggle doesn't fizzle out before they've even chosen — then
# plays one final cycle for FLOATING_NUMBER_DURATION so the wiggle and the
# resulting floating number read together, before snapping back to the card's
# correct resting rotation (exhausted = 90°, ready = 0°; this rotates the same
# `rotation_degrees` property exhaust()/ready_card() use).
func _wiggle_card(card: Control, stop_flag: Dictionary) -> void:
	if not is_instance_valid(card):
		return
	var resting_degrees = 90.0 if card.exhausted else 0.0
	card.pivot_offset = card.size / 2.0
	const WIGGLE_CYCLE_DURATION = 0.6
	while not stop_flag.get("stop", false):
		if not is_instance_valid(card):
			return
		await _play_wiggle_cycle(card, resting_degrees, WIGGLE_CYCLE_DURATION)
	if not is_instance_valid(card):
		return
	await _play_wiggle_cycle(card, resting_degrees, FLOATING_NUMBER_DURATION)
	if is_instance_valid(card):
		card.rotation_degrees = resting_degrees

func _resolve_combat(attacker: Control, defender: Control) -> void:
	_dismiss_turn_banner()
	_exit_targeting_mode()
	# Protect point (602.2) happens after attacker/defender are chosen but before
	# any damage — must come before _is_animating blocks input, since a human
	# defender needs to be able to click a protector (or decline) here.
	var final_defender = await _resolve_protect_point(attacker, defender)
	var protected = final_defender != defender

	_is_animating = true
	var atk_dmg = attacker.atk + _get_combat_atk_bonus(attacker, final_defender)
	var def_dmg = final_defender.atk
	attacker.exhaust()

	await _play_wiggle(attacker, final_defender)

	attacker.take_damage(def_dmg)
	final_defender.take_damage(atk_dmg)
	_spawn_damage_number(final_defender, atk_dmg)
	_spawn_damage_number(attacker, def_dmg)

	var atk_type = (" " + attacker.dmg_type) if atk_dmg > 0 and attacker.dmg_type else ""
	var def_type = (" " + final_defender.dmg_type) if def_dmg > 0 and final_defender.dmg_type else ""
	game_log.add_entry(
		"%s attacked %s — dealt %d%s damage / received %d%s damage" % [
			attacker.card_name, final_defender.card_name,
			atk_dmg, atk_type, def_dmg, def_type],
		"attack")
	_update_resource_counts()
	_is_animating = false

	# "Combat damage" is damage dealt as part of this exchange, by either side —
	# unlike a power's deal_damage, which never fires this. Symmetric: the attacker
	# dealt combat damage to the defender, AND the defender dealt combat damage
	# back to the attacker. A card's own trigger's `role` filter (attacking/
	# defending/any) decides which of those it actually cares about.
	if atk_dmg > 0:
		await _fire_deals_combat_damage(attacker, final_defender, "attacking")
	if def_dmg > 0:
		await _fire_deals_combat_damage(final_defender, attacker, "defending")

	# Protector exhausts only now, AFTER combat — see _resolve_protect_point.
	if protected:
		final_defender.exhaust()

# Rule 601.2/602.2 "Protect": at the protect point, the defending player may
# exhaust a ready ally with Protector (other than the proposed defender itself)
# to become the defender instead — this never forces the block, declining just
# resolves the original proposed defender.
#
# Deliberately checks for the EXISTENCE of a Protector ally (any state) before
# deciding whether to show the prompt at all, separately from which of them are
# currently exhausted (legal to actually pick). If a Protector exists but every
# instance is exhausted, the prompt still appears for a human with no legal
# candidate to click (so "accept combat" — right-click — is the only option) —
# this looks like a no-op now, but is forward-compatible with future instant
# effects that can surprise-ready a protector mid-prompt. An AI decider skips
# straight past with no prompt if it has no READY protector, since it has no
# such effects to consider and there's nothing for it to decide.
#
# NOTE: doesn't yet check Stealth (602.2a forbids protecting against a Stealth
# attacker) since no implemented card has Stealth yet.
func _resolve_protect_point(attacker: Control, defender: Control) -> Control:
	var all_protectors = _protectors_for(defender)
	if all_protectors.is_empty():
		return defender
	var ready_protectors = all_protectors.filter(func(c): return not c.exhausted)
	var decider = defender.card_owner
	var prompt = "%s is attacking your %s — protect them?" % [attacker.card_name, defender.card_name]

	var chosen: Control = null
	if _is_ai_player(decider):
		if ready_protectors.is_empty():
			return defender
		chosen = _ai_pick_target(attacker, ready_protectors, "protect")
	else:
		game_log.add_entry(prompt, "default")
		_ability_target_candidates = ready_protectors
		_enter_ability_targeting(attacker, "protect", "", "", prompt)
		_protect_prompt_active = true
		_show_accept_combat_button()
		chosen = await ability_target_chosen
		_protect_prompt_active = false
		_hide_accept_combat_button()
		_exit_ability_targeting()

	if chosen == null:
		game_log.add_entry(
			"%s declined to protect %s" % [_player_name(decider), defender.card_name], "default")
		return defender
	# NOT exhausted here — per design, a Protector only exhausts AFTER combat
	# resolves (see _resolve_combat), so effects that check "is the defender
	# exhausted" (e.g. Bala Silentblade's +3 ATK vs an exhausted target) don't
	# see the protector as exhausted just because it chose to protect against
	# THIS attack.
	game_log.add_entry(
		"%s protects %s from %s" % [chosen.card_name, defender.card_name, attacker.card_name], "default")
	return chosen

# Every Protector ally belonging to defender's controller, regardless of exhausted
# state (used to decide whether the protect-point check applies at all — see
# _resolve_protect_point). Excludes the proposed defender itself, since a
# defender can't protect itself or another proposed defender (602.2b).
func _protectors_for(defender: Control) -> Array:
	var row = ally_row if defender.card_owner == "player_1" else opp_ally_row
	return row.get_children().filter(func(c):
		return c.card_type == "Ally" and c != defender and c.has_keyword("protector"))

func _process(_delta: float) -> void:
	var source = _attacker if _attacker else _ability_source
	if source:
		var mouse  = get_viewport().get_mouse_position()
		var start  = source.global_position + source.size / 2.0
		var dir    = (mouse - start).normalized()
		var head_size = 18.0
		var shaft_end = mouse - dir * head_size
		_combat_line.set_point_position(0, start)
		_combat_line.set_point_position(1, shaft_end)

		var on_target = _hovered_card != null and (
			_is_valid_target(_hovered_card, source) if _attacker
			else _hovered_card in _ability_target_candidates)
		var arrow_color = Color(0.2, 1.0, 0.2, 0.9) if on_target else Color(1.0, 0.4, 0.0, 0.9)
		_combat_line.default_color = arrow_color

		var perp = Vector2(-dir.y, dir.x) * (head_size * 0.5)
		var head = _combat_canvas.get_node("ArrowHead")
		head.color = arrow_color
		head.polygon = PackedVector2Array([mouse, shaft_end + perp, shaft_end - perp])
		head.visible = true

		# Amount label follows cursor, offset to bottom-right of icon
		var atk_lbl = _combat_canvas.get_node("AtkLabel")
		atk_lbl.position = mouse + Vector2(22, 18)

func _hand_owner_of(card: Control) -> String:
	return "player_1" if card.get_parent() == hand_container else "player_2"

func _available_resources(player: String) -> int:
	return game_manager.player1_resources if player == "player_1" else game_manager.player2_resources

func _warn_not_enough_resources(card: Control) -> void:
	var available  = _available_resources(_hand_owner_of(card))
	var cost_label = ("Minimum cost: %d" % card.cost_base) if card.cost_x else ("Cost: %d" % card.cost)
	_warn_dialog.dialog_text = (
		"Not enough resources to play %s.\n%s  |  Available: %d" \
		% [card.card_name, cost_label, available]
	)
	_warn_dialog.popup_centered()

func _zone_for_container(container: Control) -> Control:
	var map = {
		hand_container:      hand_area,
		ally_row:            ally_row_area,
		hero_equip_row:      hero_equip_area,
		resource_row:        resource_area,
		opp_hand_container:  opp_hand_area,
		opp_ally_row:        opp_ally_row_area,
		opp_hero_equip_row:  opp_hero_area,
		opp_resource_row:    opp_resource_area,
	}
	return map.get(container, ally_row_area)

# Owner-aware zone helpers
func _ally_row_for(card_owner: String) -> HBoxContainer:
	return ally_row if card_owner == "player_1" else opp_ally_row

func _hand_for(card_owner: String) -> HBoxContainer:
	return hand_container if card_owner == "player_1" else opp_hand_container

func _grav_for(card_owner: String) -> ColorRect:
	return grav_slot if card_owner == "player_1" else opp_grav_slot

func _hand_area_for(card_owner: String) -> Control:
	return hand_area if card_owner == "player_1" else opp_hand_area

# ── Slot positioning ──────────────────────────────────────────────────────────
func _row_y_in_col(row: Control, col: Control) -> float:
	return row.global_position.y - col.global_position.y

func _position_slots() -> void:
	var hero_h = hero_equip_area.size.y
	var res_h  = resource_area.size.y

	var hero_card   = card_size_for_zone(hero_equip_area)
	var res_card    = card_size_for_zone(resource_area)
	var hero_slot_w = hero_card.x
	var hero_slot_h = hero_card.y
	var res_slot_w  = res_card.x
	var res_slot_h  = res_card.y

	# Reserve room for the hero card's rotated (exhausted) overhang too — see
	# _position_hero_hp_bar — so the HP bar's extra offset doesn't overflow the column.
	var hero_rotated_overhang = max(hero_slot_h - hero_slot_w, 0.0) / 2.0
	var col_w = max(hero_slot_w + HP_BAR_GAP + hero_rotated_overhang + HP_BAR_WIDTH, res_slot_w * 2.0 + 8.0)
	right_column.custom_minimum_size.x     = col_w
	opp_right_column.custom_minimum_size.x = col_w

	var hero_row_y     = _row_y_in_col(hero_equip_area, right_column)
	var res_row_y      = _row_y_in_col(resource_area,   right_column)
	var opp_res_area   = $CameraContainer/Board/OpponentArea/OpponentZones/OpponentResourceRow
	var opp_hero_area  = $CameraContainer/Board/OpponentArea/OpponentZones/OpponentHeroEquipRow
	var opp_res_row_y  = _row_y_in_col(opp_res_area,  opp_right_column)
	var opp_hero_row_y = _row_y_in_col(opp_hero_area, opp_right_column)

	hero_slot.position = Vector2(0,                hero_row_y + (hero_h - hero_slot_h) / 2.0)
	hero_slot.size     = Vector2(hero_slot_w,      hero_slot_h)
	deck_slot.position = Vector2(0,                res_row_y  + (res_h  - res_slot_h)  / 2.0)
	deck_slot.size     = Vector2(res_slot_w,       res_slot_h)
	grav_slot.position = Vector2(res_slot_w + 8.0, res_row_y  + (res_h  - res_slot_h)  / 2.0)
	grav_slot.size     = Vector2(res_slot_w,       res_slot_h)

	opp_deck_slot.position = Vector2(0,                opp_res_row_y  + (res_h  - res_slot_h)  / 2.0)
	opp_deck_slot.size     = Vector2(res_slot_w,       res_slot_h)
	opp_grav_slot.position = Vector2(res_slot_w + 8.0, opp_res_row_y  + (res_h  - res_slot_h)  / 2.0)
	opp_grav_slot.size     = Vector2(res_slot_w,       res_slot_h)
	opp_hero_slot.position = Vector2(0,                opp_hero_row_y + (hero_h - hero_slot_h) / 2.0)
	opp_hero_slot.size     = Vector2(hero_slot_w,      hero_slot_h)

	_position_hero_hp_bar("player_1", hero_slot)
	_position_hero_hp_bar("player_2", opp_hero_slot)

	_pile_slots = [grav_slot, deck_slot, opp_grav_slot, opp_deck_slot]

	deck_slot.gui_input.connect(func(e): _on_deck_gui_input(e, "player_1"))
	opp_deck_slot.gui_input.connect(func(e): _on_deck_gui_input(e, "player_2"))

	# Resource counter slots — same size as deck slot, centered in ally-level empty space
	var slot_w = deck_slot.size.x
	var slot_h = deck_slot.size.y
	var row_h  = ally_row_area.size.y  # all rows are equal height

	_p1_counter_slot = _make_counter_slot(right_column)
	_p1_counter_label = _p1_counter_slot.get_child(0)
	_p1_counter_slot.size = Vector2(slot_w, slot_h)
	_p1_counter_slot.position = Vector2(deck_slot.position.x, (row_h - slot_h) / 2.0)

	_p2_counter_slot = _make_counter_slot(opp_right_column)
	_p2_counter_label = _p2_counter_slot.get_child(0)
	_p2_counter_slot.size = Vector2(slot_w, slot_h)
	var p2_start = opp_hero_slot.position.y + opp_hero_slot.size.y
	_p2_counter_slot.position = Vector2(opp_deck_slot.position.x, p2_start + (row_h - slot_h) / 2.0)

# ── Ready ─────────────────────────────────────────────────────────────────────
func _ready() -> void:
	setup_panel.confirmed.connect(_on_setup_confirmed)

	end_turn_btn.pressed.connect(_on_end_turn_pressed)
	mulligan_panel_p1.get_node("VBox/MulliganBtn").pressed.connect(func(): _mulligan("player_1"))
	mulligan_panel_p1.get_node("VBox/ReadyBtn").pressed.connect(func(): _set_ready("player_1"))
	mulligan_panel_p2.get_node("VBox/MulliganBtn").pressed.connect(func(): _mulligan("player_2"))
	mulligan_panel_p2.get_node("VBox/ReadyBtn").pressed.connect(func(): _set_ready("player_2"))
	end_game_dialog.rematch_requested.connect(_on_rematch)
	end_game_dialog.new_game_requested.connect(_on_new_game)
	end_game_dialog.quit_requested.connect(func(): get_tree().quit())

	context_menu = PopupMenu.new()
	add_child(context_menu)
	context_menu.id_pressed.connect(_on_context_menu_id_pressed)

	_warn_dialog = AcceptDialog.new()
	_warn_dialog.title = "Cannot play card"
	add_child(_warn_dialog)

	_x_dialog = ConfirmationDialog.new()
	_x_dialog.title = "Choose X"
	var vbox = VBoxContainer.new()
	_x_dialog.add_child(vbox)
	var lbl = Label.new()
	lbl.name = "Desc"
	vbox.add_child(lbl)
	var spin = SpinBox.new()
	spin.name = "Spin"
	spin.min_value = 0
	spin.max_value = 99
	spin.step = 1
	vbox.add_child(spin)
	_x_dialog.confirmed.connect(_on_x_confirmed)
	add_child(_x_dialog)

	_combat_canvas = CanvasLayer.new()
	_combat_canvas.layer = 10
	add_child(_combat_canvas)
	_combat_line = Line2D.new()
	_combat_line.width = 3.0
	_combat_line.default_color = Color(1.0, 0.4, 0.0, 0.9)
	_combat_line.add_point(Vector2.ZERO)
	_combat_line.add_point(Vector2.ZERO)
	_combat_line.visible = false
	_combat_canvas.add_child(_combat_line)
	var head = Polygon2D.new()
	head.color = Color(1.0, 0.4, 0.0, 0.9)
	head.name = "ArrowHead"
	_combat_canvas.add_child(head)

	var atk_lbl = Label.new()
	atk_lbl.name = "AtkLabel"
	atk_lbl.add_theme_font_size_override("font_size", 26)
	atk_lbl.add_theme_color_override("font_color", Color(1.0, 0.92, 0.3))
	atk_lbl.add_theme_constant_override("outline_size", 4)
	atk_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	atk_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	atk_lbl.visible = false
	_combat_canvas.add_child(atk_lbl)

	var prompt_bg = ColorRect.new()
	prompt_bg.name = "PromptBg"
	prompt_bg.color = Color(0, 0, 0, 0.55)
	prompt_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	prompt_bg.visible = false
	_combat_canvas.add_child(prompt_bg)

	var prompt_lbl = Label.new()
	prompt_lbl.name = "PromptLabel"
	prompt_lbl.add_theme_font_size_override("font_size", 22)
	prompt_lbl.add_theme_color_override("font_color", Color(1, 1, 1))
	prompt_lbl.add_theme_constant_override("outline_size", 4)
	prompt_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	prompt_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	prompt_lbl.visible = false
	_combat_canvas.add_child(prompt_lbl)

	var accept_combat_btn = Button.new()
	accept_combat_btn.name = "AcceptCombatBtn"
	accept_combat_btn.text = "Accept Combat (no protection)"
	accept_combat_btn.add_theme_font_size_override("font_size", 32)  # ~2x default, easier to click
	accept_combat_btn.add_theme_constant_override("h_separation", 16)
	accept_combat_btn.custom_minimum_size = Vector2(0, 64)
	accept_combat_btn.visible = false
	accept_combat_btn.pressed.connect(_on_accept_combat_pressed)
	_combat_canvas.add_child(accept_combat_btn)

	var turn_bg = ColorRect.new()
	turn_bg.name = "TurnBannerBg"
	turn_bg.color = Color(0, 0, 0, 0.55)
	turn_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	turn_bg.visible = false
	_combat_canvas.add_child(turn_bg)

	var turn_lbl = Label.new()
	turn_lbl.name = "TurnBannerLabel"
	turn_lbl.add_theme_font_size_override("font_size", 32)
	turn_lbl.add_theme_color_override("font_color", Color(1, 1, 1))
	turn_lbl.add_theme_constant_override("outline_size", 5)
	turn_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	turn_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	turn_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	turn_lbl.visible = false
	_combat_canvas.add_child(turn_lbl)

	_hp_tooltip = ColorRect.new()
	_hp_tooltip.color = Color(0.05, 0.05, 0.05, 0.9)
	_hp_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hp_tooltip.visible = false
	_hp_tooltip.z_index = 101
	add_child(_hp_tooltip)
	var rtl = RichTextLabel.new()
	rtl.layout_mode = 1
	rtl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rtl.bbcode_enabled = true
	rtl.fit_content = false
	rtl.scroll_active = false
	rtl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rtl.add_theme_font_size_override("normal_font_size", 18)
	_hp_tooltip.add_child(rtl)
	_hp_label = rtl

	# Layout must settle before _init_game can measure zones
	camera_container.size = get_viewport_rect().size
	await get_tree().process_frame
	await get_tree().process_frame
	_position_slots()

func _place_card_in_zone(card_id: String, container: HBoxContainer, card_owner: String, face_down: bool = false) -> Control:
	var db   = game_manager.card_database
	var zone = _zone_for_container(container)
	var card = CARD_SCENE.instantiate()
	card.set_display_size(slot_size_for_zone(zone))
	container.add_child(card)
	card.setup(card_id, db)
	card.card_owner = card_owner
	if face_down:
		card.set_face_down(true)
	card.card_right_clicked.connect(_on_card_right_clicked)
	card.card_hovered.connect(_on_card_hovered)
	card.card_unhovered.connect(_on_card_unhovered)
	card.card_died.connect(_on_card_died)
	card.card_clicked.connect(_on_card_clicked)
	card.health_changed.connect(_on_card_health_changed)
	card.damaged.connect(_on_card_damaged)
	game_manager.board.append(card)
	return card

func _init_board() -> void:
	pass  # Board starts clean — cards enter play through normal game actions

func _hero_slot_for(card_owner: String) -> ColorRect:
	return hero_slot if card_owner == "player_1" else opp_hero_slot

func _randomize_deck_for_player(card_owner: String) -> void:
	var deck = game_manager.deck_manager.random_deck_maker(game_manager.card_database)
	if card_owner == "player_1":
		game_manager.player1_deck = deck
		game_manager.player1_draw_pile = deck.to_draw_pile()
	else:
		game_manager.player2_deck = deck
		game_manager.player2_draw_pile = deck.to_draw_pile()
	_place_hero(card_owner, deck.hero_id)

func _place_hero(card_owner: String, hero_id: String = "") -> void:
	var db = game_manager.card_database
	if hero_id == "":
		var heroes = db._db.keys().filter(func(id): return db._db[id]["type"] == "Hero")
		if heroes.is_empty():
			return
		hero_id = heroes[randi() % heroes.size()]
	var slot = _hero_slot_for(card_owner)
	var existing = _p1_hero if card_owner == "player_1" else _p2_hero
	if is_instance_valid(existing):
		existing.queue_free()
	var card_id = hero_id
	var card = CARD_SCENE.instantiate()
	card.layout_mode = 0
	card.position = Vector2.ZERO
	slot.add_child(card)
	card.setup(card_id, db)
	card.card_owner = card_owner
	card.set_display_size(slot.size)
	card.card_clicked.connect(_on_card_clicked)
	card.card_right_clicked.connect(_on_card_right_clicked)
	card.card_hovered.connect(_on_card_hovered)
	card.card_unhovered.connect(_on_card_unhovered)
	card.card_died.connect(_on_card_died)
	card.health_changed.connect(_on_card_health_changed)
	if card_owner == "player_1":
		_p1_hero = card
	else:
		_p2_hero = card
	_update_hero_hp_bar(card_owner)

func _spawn_card(card_id: String, db: Node, card_owner: String,
		container: Control, zone_area: Control) -> Control:
	var card = CARD_SCENE.instantiate()
	card.set_display_size(card_size_for_zone(zone_area))
	container.add_child(card)
	card.setup(card_id, db)
	card.card_owner = card_owner
	card.card_clicked.connect(_on_card_clicked)
	card.card_right_clicked.connect(_on_card_right_clicked)
	card.card_hovered.connect(_on_card_hovered)
	card.card_unhovered.connect(_on_card_unhovered)
	card.card_died.connect(_on_card_died)
	card.health_changed.connect(_on_card_health_changed)
	card.damaged.connect(_on_card_damaged)
	return card

# Single canonical "this card has been destroyed" entry point — used both for
# fatal-damage death (via the card_died signal) and explicit destroy effects
# (_run_destroy_target_action, uniqueness violations). Per rule 405.2, dying from
# fatal damage IS "destroyed", so a "when this is destroyed" trigger fires the
# same way regardless of cause — unlike a "deals damage" trigger, which should
# NOT fire from a non-damage destroy effect (that distinction lives in which
# trigger a card uses, not here).
func _on_card_died(card: Control) -> void:
	await _fire_dies(card)
	if card.card_type == "Hero":
		var winner = "player_2" if card.card_owner == "player_1" else "player_1"
		_end_game(winner)
		return
	card.ready_card()
	game_log.add_entry("%s was destroyed and sent to the graveyard" % card.card_name, "death")
	move_card(card, _grav_for(card.card_owner))

# Fires this specific card instance's "dies" trigger, if it has one.
func _fire_dies(card: Control) -> void:
	for r in _parse_effects(card.effects):
		if r.get("trigger", "") == "dies":
			await _run_action(card, r)
			return

# Sums any "combat_buff" ATK bonuses `attacker` has while attacking `defender` —
# e.g. Bala Silentblade's "+3 ATK while attacking an exhausted hero or ally."
# scope (default "attacking") lets a future card define a "while defending"
# variant without needing a separate trigger name. Conditions are evaluated
# against `defender`, since that's what the bonus is conditional on.
func _get_combat_atk_bonus(attacker: Control, defender: Control) -> int:
	var bonus = 0
	# Self combat_buff effects (e.g. Bala Silentblade's "+3 ATK vs exhausted").
	for r in _parse_effects(attacker.effects):
		if r.get("trigger", "") != "combat_buff" or r.get("scope", "attacking") != "attacking":
			continue
		var condition = r.get("condition", "")
		var met = true
		match condition:
			"defender_exhausted":
				met = defender.exhausted
		if met:
			bonus += int(r.get("amount", "0"))
	# Party-wide "while attacking" auras (e.g. Zorm Stonefury). All allies in
	# the attacker's row are scanned — multiple copies of an aura source stack
	# (no uniqueness restriction on non-Pet allies). Face-down resources ignored.
	var row = ally_row if attacker.card_owner == "player_1" else opp_ally_row
	for ally in row.get_children():
		if ally.card_type != "Ally" or ally.face_down:
			continue
		for r in _parse_effects(ally.effects):
			if r.get("trigger", "") == "continuous" \
					and r.get("action", "") == "party_atk_while_attacking":
				bonus += int(r.get("amount", "0"))
	return bonus

# ── End game ──────────────────────────────────────────────────────────────────

func _end_game(winner: String) -> void:
	_game_over = true
	if winner == "player_1":
		game_manager.player1_wins += 1
	else:
		game_manager.player2_wins += 1
	game_log.add_entry("%s wins the game!" % _player_name(winner), "death")
	end_game_dialog.show_result(
		_player_name(winner),
		game_manager.player1_wins,
		game_manager.player2_wins)

func _clear_all_cards() -> void:
	var containers = [
		hand_container, opp_hand_container,
		ally_row, opp_ally_row,
		hero_equip_row, opp_hero_equip_row,
		resource_row, opp_resource_row,
		grav_slot, opp_grav_slot,
		deck_slot, opp_deck_slot,
	]
	for c in containers:
		for child in c.get_children():
			if child.get("card_id") != null:  # only free Card instances, not tscn Labels
				child.queue_free()
	if is_instance_valid(_p1_hero): _p1_hero.queue_free()
	if is_instance_valid(_p2_hero): _p2_hero.queue_free()
	_p1_hero = null
	_p2_hero = null
	_update_hero_hp_bar("player_1")
	_update_hero_hp_bar("player_2")
	game_manager.hand.clear()
	game_manager.board.clear()

func _on_rematch() -> void:
	# Same player settings, new random decks — skip setup panel
	end_game_dialog.visible = false
	_init_game()

func _on_new_game() -> void:
	# Back to setup to change Human/AI settings
	end_game_dialog.visible = false
	setup_panel.visible = true
	mulligan_panel_p2.get_node("VBox/ReadyBtn").disabled = false
	_randomize_first_player()
	_update_turn_ui()
	game_log.add_entry("--- Rematch ---", "default")

# ── Input ─────────────────────────────────────────────────────────────────────
var _hovered_card: Control = null

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		# _ability_source (not just a non-empty candidate list) is the authoritative
		# "currently awaiting an ability-target decision" flag — a protect-point
		# prompt with zero legal candidates (e.g. all Protectors exhausted) still
		# needs right-click-to-decline ("accept combat") to work.
		if _ability_source != null or _ability_target_candidates.size() > 0:
			_ability_target_candidates = []
			ability_target_chosen.emit(null)
			return
		if _attacker:
			_exit_targeting_mode()

func _input(event: InputEvent) -> void:
	# Ctrl+Space ends the current human turn (TTS-style shortcut)
	if event is InputEventKey and event.pressed and event.keycode == KEY_SPACE and event.ctrl_pressed:
		if end_turn_btn.visible and not end_turn_btn.disabled:
			var current_is_ai = game_manager.player1_is_ai if game_manager.turn_state == GameManager.TurnState.P1 \
				else game_manager.player2_is_ai
			if not current_is_ai:
				_on_end_turn_pressed()
				get_viewport().set_input_as_handled()
		return

	# Violation mode: number keys select candidate
	if _violation_cards.size() > 0 and event is InputEventKey and event.pressed:
		var idx = event.keycode - KEY_1
		if idx >= 0 and idx < _violation_cards.size():
			_resolve_violation(_violation_cards[idx])
			get_viewport().set_input_as_handled()
			return

	if _attacker and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_exit_targeting_mode()
		get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom(1.0 + ZOOM_SPEED, event.position)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom(1.0 - ZOOM_SPEED, event.position)

	if event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
		camera_container.position += event.relative

	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_R:
				_reset_camera()
			KEY_ALT:
				if _hovered_card:
					_show_inspector(_hovered_card)
			KEY_CTRL:
				if _hovered_card:
					_show_hp_tooltip(_hovered_card)
	if event is InputEventKey and not event.pressed:
		match event.keycode:
			KEY_ALT:  card_inspector.visible = false
			KEY_CTRL: _hp_tooltip.visible = false

# ── Inspector ─────────────────────────────────────────────────────────────────
func _show_inspector(card: Control) -> void:
	if not card.card_image.texture:
		return
	card_inspector.texture = card.card_image.texture
	var mouse      = get_global_mouse_position()
	var panel_size = card_inspector.size
	var vp_size    = get_viewport_rect().size
	card_inspector.position = Vector2(
		clamp(mouse.x + 20, 0, vp_size.x - panel_size.x),
		clamp(mouse.y - panel_size.y / 2.0, 0, vp_size.y - panel_size.y)
	)
	card_inspector.visible = true

func _race_of(card: Control) -> String:
	# tags holds "Race Class" (e.g. "Human Mage") or just "Race" for class-less beasts
	if card.card_class != "" and card.tags.ends_with(card.card_class):
		return card.tags.substr(0, card.tags.length() - card.card_class.length()).strip_edges()
	return card.tags.strip_edges()

const BUFF_COLOR = "#44dd44"
const DAMAGED_COLOR = "#ff3333"

func _show_hp_tooltip(card: Control) -> void:
	if card.card_type not in ["Ally", "Hero"]:
		return

	# Green = buffed above the card's printed value. Red on current HP is NOT a
	# debuff indicator — damage is tracked as tokens (damage_taken), so it's a
	# reminder this character currently has damage on them, shown whenever
	# current < max regardless of whether max itself is buffed.
	var atk_color = BUFF_COLOR if card.atk > card.printed_atk else "white"
	var max_color = BUFF_COLOR if card.max_health > card.printed_health else "white"
	var hp_color: String
	if card.current_health < card.max_health:
		hp_color = DAMAGED_COLOR
	elif card.max_health > card.printed_health:
		hp_color = BUFF_COLOR
	else:
		hp_color = "white"

	var keywords: Array = []
	var race = _race_of(card)
	if race != "":
		keywords.append(race)
	if card.card_class != "":
		keywords.append(card.card_class)
	var keywords_text = ", ".join(keywords) if not keywords.is_empty() else "-"

	_hp_label.text = "[center]Atk: [color=%s]%d[/color]\nHP: [color=%s]%d[/color] / [color=%s]%d[/color]\n%s[/center]" % \
		[atk_color, card.atk, hp_color, card.current_health, max_color, card.max_health, keywords_text]
	var mouse = get_global_mouse_position()
	_hp_tooltip.size = Vector2(220, 90)
	var vp = get_viewport_rect().size
	_hp_tooltip.position = Vector2(
		clamp(mouse.x - 110, 0, vp.x - 220),
		clamp(mouse.y - 100, 0, vp.y - 90))
	_hp_tooltip.visible = true

func _on_card_hovered(card: Control) -> void:
	_hovered_card = card
	if Input.is_key_pressed(KEY_ALT):
		_show_inspector(card)
	if Input.is_key_pressed(KEY_CTRL):
		_show_hp_tooltip(card)

func _on_card_unhovered() -> void:
	_hovered_card = null
	card_inspector.visible = false
	_hp_tooltip.visible = false

# ── Card movement ─────────────────────────────────────────────────────────────

# Move a card to target_container.
# Legality checks happen before this call — this function always executes the move.
func move_card(card: Control, target: Control) -> void:
	var move_start_pos = card.global_position
	var is_hand = target in [hand_container, opp_hand_container]
	var is_pile = target in _pile_slots
	var is_graveyard = target in [grav_slot, opp_grav_slot]

	# Allies reset to their printed HP when leaving play to hand/graveyard (clears any
	# in-play max_health buffs/debuffs too). Does NOT apply to a future "removed from
	# game" zone, where allies should keep their current HP — add that zone to a
	# separate check, not to this one, if/when it's implemented.
	if card.card_type == "Ally" and (is_hand or is_graveyard):
		card.reset_to_printed_hp()

	# Cards entering the graveyard are always ready, regardless of how they got
	# there (combat, sacrifice, discard) or what exhausted state they were in —
	# an exhausted/tapped visual has no meaning on a dead/discarded card.
	if is_graveyard and card.has_method("ready_card"):
		card.ready_card()

	game_manager.hand.erase(card)
	game_manager.board.erase(card)
	if is_hand:
		game_manager.hand.append(card)
		card.set_face_down(false)  # always face-up in hand
	elif not is_pile:
		# "board" means actually in an active zone (ally row, hero slot, resource
		# row, hero equip row) — is_pile covers BOTH deck and graveyard slots
		# (_pile_slots), so a card moving to either is erased above and NOT
		# re-added here. It stops being treated as a live, activatable card
		# (can_use_power_reason / power-activation loops / Pet uniqueness checks
		# all key off this list without separately re-checking zone).
		game_manager.board.append(card)

	var old_parent = card.get_parent()
	card.reparent(target)

	# Summoning sickness: only applies to allies played as allies (not as face-down resources)
	var ally_zones = [ally_row, opp_ally_row]
	if target in ally_zones and card.card_type == "Ally" and not card.face_down:
		card.set_just_summoned(true)
		await _fire_enters_play(card)
	_update_resource_counts()

	# Continuous auras (e.g. "other allies have -1 health") depend on which allies are
	# currently in play — recompute both parties whenever an ally enters or leaves either
	# ally row, regardless of which zone it came from/went to.
	if target in ally_zones or old_parent in ally_zones:
		_recalculate_continuous_auras("player_1")
		_recalculate_continuous_auras("player_2")
		if card.card_type == "Ally":
			_sync_observer_registration(card, target in ally_zones and not card.face_down)

	if is_pile:
		# Pile layout: manually position, size to fill slot
		card.layout_mode = 0
		card.position = Vector2.ZERO
		card.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		card.set_display_size(target.size)
	elif is_hand:
		card.set_display_size(card_size_for_zone(_hand_area_for(card.card_owner)))
	else:
		card.set_display_size(slot_size_for_zone(_zone_for_container(target)))

	# Re-apply rotation on any exhausted siblings. Godot's container sort can be
	# deferred to idle time rather than happening synchronously here, so a same-frame
	# reapply isn't reliably late enough — this waits a couple frames first, same as
	# _animate_card_move, to make sure it runs strictly after any container resort
	# that might otherwise silently reset a sibling's rotation.
	if target is HBoxContainer:
		_fix_exhausted_rotations(target)

	_animate_card_move(card, move_start_pos)

# Re-applies the exhausted (90°) rotation to every exhausted card in `row`, a
# couple frames late so it runs after any pending container sort.
func _fix_exhausted_rotations(row: HBoxContainer) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_instance_valid(row):
		return
	for sibling in row.get_children():
		if is_instance_valid(sibling) and sibling.get("exhausted") == true:
			sibling.pivot_offset = sibling.size / 2.0
			sibling.rotation_degrees = 90.0

# Plays a slide animation from `start_pos` to wherever `card` actually ends up.
# Doesn't block move_card()'s caller — container layout (e.g. HBoxContainer sort)
# settles a frame or two late, so this waits for that before reading the real
# final position.
#
# IMPORTANT: this animates a detached visual clone, NOT the real card. The real
# card is typically a child of a layout container (HBoxContainer rows), and a
# Container actively re-asserts its children's transforms on every sort — directly
# tweening the real card's position fights that and can cause the container to
# re-sort mid-animation, which previously caused sibling cards to silently lose
# their exhausted-rotation visual (the same root cause class as the old
# NOTIFICATION_TRANSFORM_CHANGED freeze bug). A free-floating clone has no such
# conflict, and the real card is simply hidden (via alpha, not `visible`, so the
# container's layout doesn't reflow around it) for the animation's duration.
func _animate_card_move(card: Control, start_pos: Vector2) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_instance_valid(card):
		return
	var end_pos = card.global_position
	if start_pos.distance_to(end_pos) < 1.0:
		return

	var ghost = card.duplicate()
	ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ghost.layout_mode = 0
	ghost.size = card.size
	ghost.global_position = start_pos
	ghost.rotation = card.rotation
	ghost.pivot_offset = card.pivot_offset
	_combat_canvas.add_child(ghost)
	card.modulate.a = 0.0

	var tween = create_tween()
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(ghost, "global_position", end_pos, 0.5)
	await tween.finished

	ghost.queue_free()
	if is_instance_valid(card):
		card.modulate.a = 1.0

# ── Context menu ──────────────────────────────────────────────────────────────
func _get_card_location(card: Control) -> String:
	var p = card.get_parent()
	if p in [hand_container, opp_hand_container]:
		return "hand"
	if p in [ally_row, hero_equip_row, resource_row, opp_ally_row, opp_hero_equip_row, opp_resource_row]:
		return "board"
	if p in _pile_slots:
		return "pile"
	return "unknown"

func _on_card_right_clicked(card: Control) -> void:
	_context_card = card
	context_menu.clear()

	if _attacker:
		_exit_targeting_mode()
		return

	if card.card_type == "Hero":
		_add_use_power_item(card)
		if show_sandbox_tools():
			context_menu.add_item("Deal 1 damage", MenuAction.DEAL_DAMAGE)
			context_menu.add_item("Randomize Hero", MenuAction.RANDOMIZE_HERO)
			context_menu.add_item("Reset Hero Health", MenuAction.RESET_HERO_HEALTH)
		if context_menu.item_count > 0:
			context_menu.position = Vector2i(get_viewport().get_mouse_position())
			context_menu.reset_size()
			context_menu.popup()
		return

	match _get_card_location(card):
		"hand":
			context_menu.add_item("Play", MenuAction.PLAY_BOARD)
			context_menu.add_item("Place as resource (face down)", MenuAction.PLACE_RESOURCE)
			var place_idx = context_menu.item_count - 1
			var place_allowed = can_place_resource(card.card_owner)
			context_menu.set_item_disabled(place_idx, not place_allowed)
			if not place_allowed:
				context_menu.set_item_tooltip(place_idx, "Already placed a resource this turn")
			context_menu.add_item("Send to graveyard", MenuAction.SEND_GRAVEYARD)
		"board":
			if not card.exhausted:
				context_menu.add_item("Exhaust", MenuAction.EXHAUST)
			else:
				context_menu.add_item("Ready", MenuAction.READY)
			if card.card_type == "Ally":
				if show_sandbox_tools():
					context_menu.add_item("Deal 1 damage", MenuAction.DEAL_DAMAGE)
				_add_use_power_item(card)
			context_menu.add_item("Send to graveyard", MenuAction.SEND_GRAVEYARD)
			context_menu.add_item("Return to hand", MenuAction.RETURN_HAND)
		"pile":
			context_menu.add_item("Return to hand", MenuAction.RETURN_HAND)

	if context_menu.item_count == 0:
		return
	context_menu.position = Vector2i(get_viewport().get_mouse_position())
	context_menu.reset_size()
	context_menu.popup()

func _on_deck_gui_input(event: InputEvent, card_owner: String) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_deck_menu_owner = card_owner
		_context_card = null
		context_menu.clear()
		context_menu.add_item("Draw a card", MenuAction.GENERATE_CARD)
		context_menu.position = Vector2i(get_viewport().get_mouse_position())
		context_menu.reset_size()
		context_menu.popup()

func _draw_card(card_owner: String) -> void:
	var pile = game_manager.player1_draw_pile if card_owner == "player_1" else game_manager.player2_draw_pile
	if pile.is_empty():
		game_log.add_entry("%s has no cards left to draw!" % _player_name(card_owner), "death")
		return
	var card_id = pile.pop_back()
	var db = game_manager.card_database
	var card = _spawn_card(card_id, db, card_owner, _hand_for(card_owner), _hand_area_for(card_owner))
	game_manager.hand.append(card)
	_update_deck_labels()
	game_log.add_entry("%s drew %s" % [_player_name(card_owner), db._db[card_id].get("name", card_id)], "play")

func _update_deck_labels() -> void:
	var p1 = game_manager.player1_draw_pile.size()
	var p2 = game_manager.player2_draw_pile.size()
	var p1_lbl = deck_slot.get_child(0) as Label
	var p2_lbl = opp_deck_slot.get_child(0) as Label
	if p1_lbl: p1_lbl.text = "Deck\n%d" % p1
	if p2_lbl: p2_lbl.text = "Deck\n%d" % p2

func _on_context_menu_id_pressed(id: int) -> void:
	if not can_act():
		_context_card = null
		_deck_menu_owner = ""
		return
	if id == MenuAction.GENERATE_CARD:
		_draw_card(_deck_menu_owner)
		_deck_menu_owner = ""
		return
	if not _context_card:
		return
	var o = _context_card.card_owner
	match id:
		MenuAction.PLAY_BOARD:
			_play_card(_context_card)
		MenuAction.PLACE_RESOURCE:
			if not can_place_resource(o):
				return
			_dismiss_turn_banner()
			_context_card.set_face_down(true)
			move_card(_context_card, opp_resource_row if o == "player_2" else resource_row)
			_resource_placed_this_turn[o] = true
		MenuAction.EXHAUST:
			_context_card.exhaust()
			_update_resource_counts()
		MenuAction.READY:
			_context_card.ready_card()
			_update_resource_counts()
		MenuAction.DEAL_DAMAGE:
			_context_card.take_damage(1)
		MenuAction.RANDOMIZE_HERO:
			_randomize_deck_for_player(_context_card.card_owner)
		MenuAction.RESET_HERO_HEALTH:
			_context_card.reset_to_printed_hp()
		MenuAction.USE_POWER:
			_activate_power(_context_card)
		MenuAction.SEND_GRAVEYARD:
			_context_card.ready_card()
			move_card(_context_card, _grav_for(o))
		MenuAction.RETURN_HAND:
			_context_card.ready_card()
			move_card(_context_card, _hand_for(o))
		MenuAction.GENERATE_CARD:
			_draw_card(_deck_menu_owner)
	_context_card = null
	_deck_menu_owner = ""

# ── Card actions ──────────────────────────────────────────────────────────────
func _player_name(owner: String) -> String:
	return "Player 1" if owner == "player_1" else "Player 2"

func _current_turn_player() -> String:
	if game_manager.turn_state == GameManager.TurnState.P1:
		return "player_1"
	elif game_manager.turn_state == GameManager.TurnState.P2:
		return "player_2"
	return ""

# ── Turn logic ────────────────────────────────────────────────────────────────

func _update_turn_ui() -> void:
	var is_beginning = game_manager.turn_state == GameManager.TurnState.BEGINNING
	end_turn_btn.visible = not is_beginning
	match game_manager.turn_state:
		GameManager.TurnState.BEGINNING:
			turn_label.text = "Beginning"
		GameManager.TurnState.P1:
			turn_label.text = "Player 1's Turn"
			end_turn_btn.text = "End P1 Turn"
		GameManager.TurnState.P2:
			turn_label.text = "Player 2's Turn"
			end_turn_btn.text = "End P2 Turn"

func _mulligan_panel(player: String) -> Control:
	return mulligan_panel_p1 if player == "player_1" else mulligan_panel_p2

# Shuffles `player`'s entire hand into their deck, then draws that many cards back.
# Shared core for the opening mulligan and any in-game power with the same effect
# (e.g. Moonshadow) — generalized since it's not unique to the mulligan context.
func _shuffle_hand_into_deck(player: String) -> int:
	var hand_cards = game_manager.hand.filter(func(c): return c.card_owner == player)
	var count = hand_cards.size()
	var pile = game_manager.player1_draw_pile if player == "player_1" else game_manager.player2_draw_pile
	for card in hand_cards:
		pile.append(card.card_id)
		card.queue_free()
		game_manager.hand.erase(card)
	pile.shuffle()
	for _i in count:
		_draw_card(player)
	return count

func _mulligan(player: String) -> void:
	var already = _p1_mulliganed if player == "player_1" else _p2_mulliganed
	if already or game_manager.turn_state != GameManager.TurnState.BEGINNING:
		return
	var count = _shuffle_hand_into_deck(player)
	if player == "player_1":
		_p1_mulliganed = true
	else:
		_p2_mulliganed = true
	_mulligan_panel(player).get_node("VBox/MulliganBtn").disabled = true
	game_log.add_entry("%s mulliganed (%d cards)" % [_player_name(player), count], "default")

func _set_ready(player: String) -> void:
	if game_manager.turn_state != GameManager.TurnState.BEGINNING:
		return
	if player == "player_1":
		_p1_ready = true
	else:
		_p2_ready = true
	_mulligan_panel(player).get_node("VBox/ReadyBtn").disabled = true
	game_log.add_entry("%s is ready" % _player_name(player), "default")
	if _p1_ready and _p2_ready:
		_start_game()

func _start_game() -> void:
	_dismiss_turn_banner()
	mulligan_panel_p1.visible = false
	mulligan_panel_p2.visible = false
	_first_turn_skip = game_manager.first_player
	game_manager.turn_state = GameManager.TurnState.P1 \
		if game_manager.first_player == "player_1" else GameManager.TurnState.P2
	_start_turn(game_manager.first_player)

func _on_setup_confirmed(p1_is_ai: bool, p2_is_ai: bool) -> void:
	game_manager.player1_is_ai = p1_is_ai
	game_manager.player2_is_ai = p2_is_ai
	setup_panel.visible = false
	_init_game()

func _init_game() -> void:
	_game_over = false
	_clear_all_cards()
	_randomize_deck_for_player("player_1")
	_randomize_deck_for_player("player_2")
	_init_board()
	for _i in 7: _draw_card("player_1")
	for _i in 7: _draw_card("player_2")

	_p1_ready = false
	_p2_ready = false
	_p1_mulliganed = false
	_p2_mulliganed = false
	_first_turn_skip = ""
	mulligan_panel_p1.get_node("VBox/MulliganBtn").disabled = false
	mulligan_panel_p1.get_node("VBox/ReadyBtn").disabled = false
	mulligan_panel_p2.get_node("VBox/MulliganBtn").disabled = false
	mulligan_panel_p2.get_node("VBox/ReadyBtn").disabled = false
	game_manager.turn_state            = GameManager.TurnState.BEGINNING
	game_manager.player1_resources     = 0
	game_manager.player2_resources     = 0
	game_manager.player1_pet_capacity  = 1
	game_manager.player2_pet_capacity  = 1
	_update_deck_labels()
	_update_resource_counts()
	_randomize_first_player()
	_update_turn_ui()

	# AI players skip mulligan
	if game_manager.player1_is_ai:
		mulligan_panel_p1.visible = false
		_p1_ready = true
	if game_manager.player2_is_ai:
		mulligan_panel_p2.visible = false
		_p2_ready = true
	if _p1_ready and _p2_ready:
		_start_game()
		return
	# At least one human player still in mulligan phase — remind them to press Ready.
	_show_get_ready_banner()

func _randomize_first_player() -> void:
	game_manager.first_player = "player_1" if randi() % 2 == 0 else "player_2"
	var p1_goes_first = game_manager.first_player == "player_1"
	mulligan_panel_p1.get_node("VBox/OrderLabel").text = \
		"You go First" if p1_goes_first else "You go Second"
	mulligan_panel_p2.get_node("VBox/OrderLabel").text = \
		"You go Second" if p1_goes_first else "You go First"

func _start_turn(player: String) -> void:
	if _game_over:
		return
	# Once-per-turn flags reset for EVERY card each turn, regardless of owner —
	# "once per turn" means once during each turn occurrence. A card with no
	# turn_restricted flag can be used on either player's turn, so e.g. Deacon
	# Johanna could be used once on the opponent's turn and once again on her
	# controller's turn right after; tying this reset to card ownership would
	# wrongly make it "once per round" instead.
	for card in game_manager.board:
		card.reset_turn_flags()
	if is_instance_valid(_p1_hero):
		_p1_hero.reset_turn_flags()
	if is_instance_valid(_p2_hero):
		_p2_hero.reset_turn_flags()

	await _fire_start_of_turn(player)

	# Start Phase 1: ready all of this player's in-play cards + clear summoning sickness
	for card in game_manager.board:
		if card.card_owner == player:
			if card.exhausted:
				card.ready_card()
			if card.just_summoned:
				card.set_just_summoned(false)
	_resource_placed_this_turn[player] = false
	_update_resource_counts()
	# Start Phase 2: draw 1 — first player skips on their very first turn
	if player == _first_turn_skip:
		_first_turn_skip = ""  # only skips once
	else:
		_draw_card(player)
	game_log.add_entry("%s's turn begins" % _player_name(player), "default")
	_update_turn_ui()

	# Hand off to AI if this player is an AI
	var is_ai = game_manager.player1_is_ai if player == "player_1" else game_manager.player2_is_ai
	if is_ai:
		_turn_banner_dismissed = true  # nothing to show/dismiss for an AI turn
		var ai = BasicAI.new()
		ai.sandbox = self
		await ai.run_turn(player)
	else:
		_show_turn_banner(player)

func _on_end_turn_pressed() -> void:
	await _fire_end_of_turn(_current_turn_player())
	match game_manager.turn_state:
		GameManager.TurnState.P1:
			game_manager.turn_state = GameManager.TurnState.P2
			call_deferred("_start_turn", "player_2")
		GameManager.TurnState.P2:
			game_manager.turn_state = GameManager.TurnState.P1
			call_deferred("_start_turn", "player_1")

func _exhaust_resources(player: String, amount: int) -> void:
	var row = resource_row if player == "player_1" else opp_resource_row
	var exhausted = 0
	for child in row.get_children():
		if exhausted >= amount:
			break
		if child.has_method("exhaust") and not child.exhausted:
			child.exhaust()
			exhausted += 1
	_update_resource_counts()

# Resolves an X value for `card`, given an explicit legal max (the true hard cap —
# shown to a human in the dialog) and a reasonable max (what the AI should actually
# spend; equal to legal_max for plain "spend it all" costs, but can be tighter for
# costs where overspending is wasteful or dangerous — see e.g. Dizdemona, where the
# legal cap is "won't kill yourself" but the reasonable cap also considers the
# target's HP so the AI doesn't waste damage).
func _resolve_x_value_with_max(card: Control, legal_max: int, reasonable_max: int,
		extra_info: String = "") -> int:
	if _is_ai_player(card.card_owner):
		return BasicAI.choose_x_value(reasonable_max)
	var spin = _x_dialog.get_child(0).get_node("Spin") as SpinBox
	var lbl  = _x_dialog.get_child(0).get_node("Desc") as Label
	spin.max_value = legal_max
	spin.value     = 0
	var info_line = ("\n" + extra_info) if extra_info != "" else ""
	lbl.text = "%s%s\nChoose X (0 – %d):" % [card.card_name, info_line, legal_max]
	_x_dialog.popup_centered()
	var x = await x_value_chosen
	return x

# Resolves an X value for `card` (payer = whoever's paying, base = the fixed part
# of an "N+X" resource cost, 0 for pure "X"). Plain resource cost: legal max ==
# reasonable max (spend whatever's affordable).
func _resolve_x_value(card: Control, payer: String, base: int, reasonable_cap: int = -1) -> int:
	var available = _available_resources(payer)
	var max_x = max(available - base, 0)
	var reasonable = max_x if reasonable_cap < 0 else min(max_x, reasonable_cap)
	return await _resolve_x_value_with_max(card, max_x, reasonable,
		"Base cost: %d  |  Available: %d" % [base, available])

func _on_x_confirmed() -> void:
	var spin = _x_dialog.get_child(0).get_node("Spin") as SpinBox
	x_value_chosen.emit(int(spin.value))

func _play_card(card: Control) -> void:
	if not can_play_card(card):
		return
	_dismiss_turn_banner()
	if card.cost_x:
		var payer = _hand_owner_of(card)
		var x = await _resolve_x_value(card, payer, card.cost_base)
		card.chosen_x = x
		card.cost      = card.cost_base + x
		await _do_play_card(card)
		return
	await _do_play_card(card)

# ── Violation resolution ──────────────────────────────────────────────────────

func _enter_violation_mode(candidates: Array, prompt: String, callback: Callable) -> void:
	_violation_cards    = candidates
	_violation_callback = callback
	game_log.add_entry("VIOLATION — %s (click or press 1–%d)" % [prompt, candidates.size()], "death")
	for i in candidates.size():
		var card = candidates[i]
		var overlay = ColorRect.new()
		overlay.color        = Color(1.0, 0.2, 0.2, 0.45)
		overlay.layout_mode  = 1
		overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(overlay)
		var lbl = Label.new()
		lbl.text = str(i + 1)
		lbl.add_theme_font_size_override("font_size", 36)
		lbl.add_theme_color_override("font_color", Color.WHITE)
		lbl.add_theme_constant_override("outline_size", 5)
		lbl.add_theme_color_override("font_outline_color", Color.BLACK)
		lbl.layout_mode = 1
		lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(lbl)
		_violation_overlays.append([overlay, lbl])

func _exit_violation_mode() -> void:
	for pair in _violation_overlays:
		for node in pair:
			node.queue_free()
	_violation_overlays.clear()
	_violation_cards.clear()

func _resolve_violation(card: Control) -> void:
	_exit_violation_mode()
	_violation_callback.call(card)

func _is_pet_in_play(c: Control) -> bool:
	return c.card_type == "Ally" and not c.face_down and "Pet" in c.card_subtype

func _is_ai_player(player: String) -> bool:
	return game_manager.player1_is_ai if player == "player_1" else game_manager.player2_is_ai

func _check_violations_for(card: Control) -> void:
	# Pet uniqueness (also covers Warlock demons — both have subtype "Pet")
	if _is_pet_in_play(card):
		var pets = game_manager.board.filter(func(c):
			return c.card_owner == card.card_owner and _is_pet_in_play(c))
		if pets.size() > _pet_capacity(card.card_owner):
			if _is_ai_player(card.card_owner):
				_destroy_to_graveyard(BasicAI.choose_discard(pets))
			else:
				_enter_violation_mode(
					pets,
					"Too many Pets — choose one to destroy",
					func(chosen): _destroy_to_graveyard(chosen))
			return
	# TODO: equipment uniqueness, unique card violations

func _destroy_to_graveyard(card: Control) -> void:
	game_log.add_entry("%s was destroyed (uniqueness violation)" % card.card_name, "death")
	await _on_card_died(card)

func _pet_capacity(card_owner: String) -> int:
	return game_manager.player1_pet_capacity if card_owner == "player_1" \
		else game_manager.player2_pet_capacity

func _do_play_card(card: Control) -> void:
	var payer = _hand_owner_of(card)
	if card.cost > 0:
		_exhaust_resources(payer, card.cost)
		var cost_str = "%d+%d" % [card.cost_base, card.chosen_x] if card.cost_x else str(card.cost)
		game_log.add_entry(
			"%s exhausted %s resource%s to play %s" % [
				_player_name(payer), cost_str,
				"s" if card.cost > 1 else "", card.card_name],
			"resource")
	var o = card.card_owner
	match card.card_type:
		"Ally":    await move_card(card, _ally_row_for(o))
		"Ability": await move_card(card, _grav_for(o))
		_:         await move_card(card, _ally_row_for(o))
	_check_violations_for(card)

func _on_card_clicked(card: Control) -> void:
	if _is_animating:
		return
	# Violation mode takes priority — click selects which card to destroy
	if _violation_cards.size() > 0:
		if card in _violation_cards:
			_resolve_violation(card)
		return  # block all other actions until violation is resolved
	# Ability targeting (e.g. a power that needs a target pick) also takes priority.
	# Gated on _ability_source rather than just a non-empty candidate list, so a
	# protect-point prompt with zero legal candidates (e.g. all Protectors
	# exhausted) still blocks normal clicks instead of falling through to "play a
	# card" / "declare a new attack" mid-resolution of the current combat.
	if _ability_source != null or _ability_target_candidates.size() > 0:
		if card in _ability_target_candidates:
			_ability_target_candidates = []
			ability_target_chosen.emit(card)
		return
	if not can_act():
		return

	# In targeting mode
	if _attacker:
		if _is_valid_target(card, _attacker):
			_resolve_combat(_attacker, card)
		else:
			_exit_targeting_mode()
		return

	# Normal mode
	if game_manager.hand.has(card):
		_play_card(card)
	elif _is_board_ally(card) and not card.exhausted and can_propose_attacker(card):
		_enter_targeting_mode(card)
