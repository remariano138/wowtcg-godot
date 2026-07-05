class_name GameState
extends Resource

# Single source of truth for everything that can change during a game.
# No Godot node references — this object is fully serializable and can be
# built and manipulated in a headless test without any scene tree.
#
# Read-only access pattern: call the get_* helpers below rather than
# reading nested dictionaries directly — helpers validate keys and apply
# derived-value logic (stat summing, hp calculation) in one place.

# ── Core data ──────────────────────────────────────────────────────────────────
var players: Dictionary = {}   # player_id (String) -> PlayerState
var zones: Dictionary = {}     # zone_id (String)   -> Zone
var cards: Dictionary = {}     # instance_id (String) -> CardInstance

# ── Turn / phase state ─────────────────────────────────────────────────────────
# Phases follow the WoW TCG turn structure:
#   "setup"     — pre-game (deck reveal, hero selection, opening hand)
#   "ready"     — ready step: ready all cards, instants-only priority window
#   "draw"      — draw step: draw one card, instants-only priority window
#   "action"    — action phase: full priority window (allies, instants, resources, combat)
#   "end"       — end phase: instants-only priority window, then wrap-up (no window)
var turn_number: int = 0
var turn_player: String = ""       # player_id of who has the active turn
var first_player: String = ""      # player_id who goes first (set once at game start)
var phase: String = "setup"
var priority_player: String = ""   # player_id who currently holds priority

# ── Interrupt stack (rule 409 / 410) ──────────────────────────────────────────
# A stack of proposed-but-not-yet-resolved actions. Last in, first resolved.
# PendingAction class is defined in Phase 4 (stack_resolver.gd).
# Declared here as untyped Array so state serializes correctly before that
# class exists; typed enforcement added when PendingAction is implemented.
var pending_actions: Array = []
var consecutive_passes: int = 0

# ── Active combat state (cleared after each combat concludes) ──────────────────
var combat_attacker: String = ""   # instance_id of attacker; "" = no combat
var combat_defender: String = ""   # instance_id of proposed/actual defender
var in_protect_point: bool  = false # true while waiting for protect decision
# Rule 602.1 / 602.3: priority windows within a combat step.
var combat_attack_window: bool  = false  # true during the Attack Window
var combat_defend_window: bool  = false  # true during the Defend Window

# ── Pending interactive choices (cleared once resolved) ────────────────────────
var pending_discard_player: String = ""  # player who must discard; "" = none pending
var pending_discard_count:  int    = 0   # how many cards still to discard
# Non-empty while an enters-play targeted effect is waiting for the controller to choose a target.
# Keys: card_id (String), effect (String), dmg_type (String), amount (int).
var pending_enter_play_effect: Dictionary = {}
# Pet uniqueness: player must sacrifice pets until at most 1 remains in play.
var pending_pet_sacrifice_player: String = ""
var pending_pet_sacrifice_ids: Array[String] = []  # instance_ids of ALL pets currently in play for that player
# Equipment slot uniqueness (rule 414.3): player must destroy equipment until at
# most one occupies the conflicting slot.
var pending_equip_sacrifice_player: String = ""
var pending_equip_sacrifice_ids: Array[String] = []  # instance_ids of same-slot equipment in play

# ── Mulligan state (cleared once both players have committed) ──────────────────
# player_id -> true once the player has made their mulligan decision.
var mulligan_decided: Dictionary = {}
# player_id -> true if the player chose to mulligan (shuffle+redraw).
var mulligan_wants:   Dictionary = {}


# ── Factory ────────────────────────────────────────────────────────────────────
static func create_new(player_ids: Array[String]) -> GameState:
	var gs := GameState.new()
	gs.zones = Zone.create_standard_zones()
	for pid in player_ids:
		gs.players[pid] = PlayerState.make(pid)
	return gs


# ── Card accessors ─────────────────────────────────────────────────────────────
# Play zones are where cards can be exhausted, damaged, buffed, etc.
# Hand, deck, graveyard, and rfg are out-of-play zones for these purposes.
const PLAY_ZONE_TYPES := ["ally_row", "hero_row", "resource_row", "attached"]

func is_in_play(instance_id: String) -> bool:
	var card := get_card(instance_id)
	if not card:
		return false
	var zone := zones.get(card.zone_id) as Zone
	return zone != null and zone.zone_type in PLAY_ZONE_TYPES


func get_card(instance_id: String) -> CardInstance:
	return cards.get(instance_id) as CardInstance

func cards_in_zone(zone_id: String) -> Array[CardInstance]:
	var zone := zones.get(zone_id) as Zone
	if not zone:
		return []
	var result: Array[CardInstance] = []
	for cid in zone.card_ids:
		var c := get_card(cid)
		if c:
			result.append(c)
	return result

# All cards in play for a player: ally_row + hero_row + attachments they control.
# "Attached" is a positional zone, not an out-of-play zone — Cyclone attached to
# an ally is still in play and counts for "abilities in play" queries.
# Callers filter by card_type as needed; zone separation already ensures
# ally_row queries don't accidentally include abilities or attachments.
# Resource row is excluded — use cards_in_zone(player_id + "_resource_row") for that.
func cards_in_play(player_id: String) -> Array[CardInstance]:
	var result: Array[CardInstance] = []
	result.append_array(cards_in_zone(player_id + "_ally_row"))
	result.append_array(cards_in_zone(player_id + "_hero_row"))
	for card in cards_in_zone("attached"):
		if card.controller == player_id:
			result.append(card)
	return result

func get_hero(player_id: String) -> CardInstance:
	var ps := players.get(player_id) as PlayerState
	if not ps or ps.hero_instance_id == "":
		return null
	return get_card(ps.hero_instance_id)

func get_attachments(host_instance_id: String) -> Array[CardInstance]:
	var host := get_card(host_instance_id)
	if not host:
		return []
	var result: Array[CardInstance] = []
	for aid in host.attachments:
		var a := get_card(aid)
		if a:
			result.append(a)
	return result


# ── Derived stat helpers ───────────────────────────────────────────────────────
# These require a CardDatabase reference to look up printed (base) stats.
# Passing db as a parameter keeps GameState free of Godot node dependencies
# and allows headless unit testing with a mock database.

func get_atk(instance_id: String, db) -> int:
	var inst := get_card(instance_id)
	if not inst:
		return 0
	var def: CardDef = db.get_def(inst.card_def_id)
	if not def:
		return 0
	var atk := def.printed_atk + inst.sum_stat("atk")
	for segment in def.effects.split("|"):
		var parts := segment.split(":")
		if parts[0] == "atk_per_ally":
			var per_ally := int(parts[1]) if parts.size() > 1 else 1
			var ally_count := cards_in_zone(inst.controller + "_ally_row").size()
			atk += per_ally * ally_count
		elif parts[0] == "atk_per_damage_self":
			var per_damage := int(parts[1]) if parts.size() > 1 else 1
			atk += per_damage * inst.damage_taken
	return atk

func get_max_hp(instance_id: String, db) -> int:
	var inst := get_card(instance_id)
	if not inst:
		return 0
	var def: CardDef = db.get_def(inst.card_def_id)
	if not def:
		return 0
	return max(def.printed_health + inst.sum_stat("health"), 0)

func get_current_hp(instance_id: String, db) -> int:
	var inst := get_card(instance_id)
	if not inst:
		return 0
	return max(get_max_hp(instance_id, db) - inst.damage_taken, 0)

# Cost of playing a card from hand, after applying any cost-reduction buffs.
func get_play_cost(instance_id: String, db) -> int:
	var inst := get_card(instance_id)
	if not inst:
		return 0
	var def: CardDef = db.get_def(inst.card_def_id)
	if not def:
		return 0
	return max(def.cost + inst.sum_stat("cost"), 0)


# ── Resource helpers ───────────────────────────────────────────────────────────
# Available resources = ready (non-exhausted) cards in the player's resource row.
func get_available_resources(player_id: String) -> int:
	var count := 0
	for card in cards_in_zone(player_id + "_resource_row"):
		if not card.is_exhausted:
			count += 1
	return count

func get_total_resources(player_id: String) -> int:
	return cards_in_zone(player_id + "_resource_row").size()

# Face-up resources (quests/locations) retain their card identity and effects.
# Face-down resources are blank — no name, no type, no effect.
func get_face_up_resources(player_id: String) -> Array[CardInstance]:
	return cards_in_zone(player_id + "_resource_row").filter(
		func(c: CardInstance) -> bool: return not c.face_down)

# "For as many quests with that name" — count face-up resources sharing a def.
func count_face_up_resources_by_def(player_id: String, card_def_id: String) -> int:
	var count := 0
	for card in get_face_up_resources(player_id):
		if card.card_def_id == card_def_id:
			count += 1
	return count


# ── Serialization ──────────────────────────────────────────────────────────────
func to_dict() -> Dictionary:
	var players_data: Dictionary = {}
	for pid in players:
		players_data[pid] = (players[pid] as PlayerState).to_dict()

	var zones_data: Dictionary = {}
	for zid in zones:
		zones_data[zid] = (zones[zid] as Zone).to_dict()

	var cards_data: Dictionary = {}
	for cid in cards:
		cards_data[cid] = (cards[cid] as CardInstance).to_dict()

	return {
		"players":           players_data,
		"zones":             zones_data,
		"cards":             cards_data,
		"turn_number":       turn_number,
		"turn_player":       turn_player,
		"phase":             phase,
		"priority_player":   priority_player,
		"pending_actions":   _serialize_pending_actions(),
		"consecutive_passes": consecutive_passes,
	}

static func from_dict(d: Dictionary) -> GameState:
	var gs := GameState.new()
	for pid in d.get("players", {}):
		gs.players[pid] = PlayerState.from_dict(d["players"][pid])
	for zid in d.get("zones", {}):
		gs.zones[zid] = Zone.from_dict(d["zones"][zid])
	for cid in d.get("cards", {}):
		gs.cards[cid] = CardInstance.from_dict(d["cards"][cid])
	gs.turn_number        = d.get("turn_number", 0)
	gs.turn_player        = d.get("turn_player", "")
	gs.phase              = d.get("phase", "setup")
	gs.priority_player    = d.get("priority_player", "")
	gs.consecutive_passes = d.get("consecutive_passes", 0)
	for a in d.get("pending_actions", []):
		gs.pending_actions.append(PendingAction.from_dict(a))
	return gs


func _serialize_pending_actions() -> Array:
	var result: Array = []
	for a in pending_actions:
		result.append((a as PendingAction).to_dict())
	return result
