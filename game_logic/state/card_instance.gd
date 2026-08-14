class_name CardInstance
extends Resource

# Everything about one physical card that can change during a game.
# Static data (name, printed stats, type, keywords) lives in CardDef, looked
# up via card_def_id through CardDatabase. CardInstance never duplicates that.

# ── Identity ───────────────────────────────────────────────────────────────────
var instance_id: String     # unique per physical card in this game ("inst_0001" etc.)
var card_def_id: String     # key into CardDatabase
var owner: String           # player_id in whose deck this card started (rule 401.2)
var controller: String      # player_id currently controlling it; defaults to owner,
                            # can differ via effects like Mind Control (rule 401.3)
var zone_id: String         # current zone:
                            #   "p1_hand", "p1_deck", "p1_graveyard", "p1_rfg"
                            #   "p1_ally_row", "p1_hero_row", "p1_resource_row"
                            #   "p2_*" equivalents
                            #   "attached" — in play but physically under a host card (rule 400.5)

# ── Token identity ─────────────────────────────────────────────────────────────
# True for cards created by an effect rather than dealt from a deck (Mya's
# Mechanical Dragonling, Tooga's Quest's Tooga). A token ceases to exist the
# moment it leaves play: GameLogic.move_card redirects ANY play → non-play move
# of a token to its owner's RFG zone, so no token ever reaches a graveyard, a
# hand or a deck. Destruction is unaffected — card_destroyed still fires and
# every "when destroyed" trigger sees it; only the destination differs.
# Mirrored from CardDef.is_token at creation so move_card needs no db lookup.
var is_token: bool = false
# Turn number on which this card was put into play. Only meaningful for tokens:
# delayed "at the start of your NEXT turn" triggers (Tooga) use it to avoid
# firing on the turn the token was created.
var created_on_turn: int = 0

# ── Attachment relationship (rule 400) ────────────────────────────────────────
# Attachments have zone_id == "attached" and attached_to set.
# Hosts carry the instance_ids of all cards attached to them.
# Both sides must be kept in sync by the zone-move primitive.
var attached_to: String = ""           # instance_id of host card; empty if not an attachment
var attachments: Array[String] = []    # instance_ids of cards attached to this card

# ── Borrowed control (Nyn'jah — rule 401.3) ───────────────────────────────────
# "You control that equipment while Nyn'jah remains in your party": control of a
# stolen card is conditional on a LINK to the card that took it, so both ends are
# recorded and kept in sync by the zone-move primitive (GameLogic.move_card),
# exactly like the attachment relationship above.
#   stolen_by      — on the stolen card: instance_id of the thief holding it.
#   stolen_ids     — on the thief: instance_ids of every card it currently holds.
# When the link breaks (the thief leaves play, or stops being in the same party
# because its own controller changed) control reverts to the card's OWNER.
var stolen_by: String = ""
var stolen_ids: Array[String] = []

# ── Turn/game flags ────────────────────────────────────────────────────────────
var is_exhausted: bool = false
var face_down: bool = false
var just_summoned: bool = false        # summoning sickness; cleared at controller's turn start
var hero_power_used: bool = false      # hero flip power: once flipped, true for the rest of the game
var used_this_turn: bool = false       # once-per-turn gate for non-exhaust powers; reset each turn

# ── Damage ─────────────────────────────────────────────────────────────────────
# Physical damage tokens placed on this card (rule 302).
# current_hp = max(printed_health + sum(health buffs) - damage_taken, 0)
var damage_taken: int = 0

# ── Buffs and restrictions ─────────────────────────────────────────────────────
# All stat modifiers, bonuses, and restrictions active on this card.
# See Buff for stat strings and duration rules.
# Computed values (current_atk, max_hp, current_hp) are derived from these
# plus the static CardDef values — never cached here.
var active_buffs: Array[Buff] = []

# ── Counters ───────────────────────────────────────────────────────────────────
# Named integer counters placed on this card by effects (wind counters, charge
# counters, etc.). Distinct from buffs — counters are raw state that effects
# read and mutate; they don't directly modify stats.
var counters: Dictionary = {}          # { "wind": 3, "charge": 1 } etc.

# ── Play-time choices ──────────────────────────────────────────────────────────
var chosen_x: int = 0                 # X value chosen when this card was played or power used

# ── Dynamic keyword grants ─────────────────────────────────────────────────────
# Keywords granted by another card's continuous effect (rule 714).
# Recomputed from scratch whenever continuous effects are recalculated.
var granted_keywords: Array[String] = []


# ── Factory ────────────────────────────────────────────────────────────────────
static func create(inst_id: String, def_id: String, p_owner: String, p_zone_id: String) -> CardInstance:
	var inst := CardInstance.new()
	inst.instance_id = inst_id
	inst.card_def_id = def_id
	inst.owner       = p_owner
	inst.controller  = p_owner
	inst.zone_id     = p_zone_id
	return inst


# ── Buff helpers ───────────────────────────────────────────────────────────────
func sum_stat(stat: String) -> int:
	var total := 0
	for b in active_buffs:
		if b.stat == stat:
			total += b.amount
	return total

func has_restriction(stat: String) -> bool:
	return sum_stat(stat) > 0

func remove_buffs_from_source(source_id: String) -> void:
	active_buffs = active_buffs.filter(func(b: Buff) -> bool: return b.source_id != source_id)

func remove_this_turn_buffs() -> void:
	active_buffs = active_buffs.filter(func(b: Buff) -> bool: return b.duration_type != "turns" or b.turns_remaining > 0)

func decrement_turn_buffs() -> void:
	for b in active_buffs:
		if b.duration_type == "turns":
			b.turns_remaining -= 1
	remove_this_turn_buffs()


# ── Serialization ──────────────────────────────────────────────────────────────
func to_dict() -> Dictionary:
	var buffs_data: Array = []
	for b in active_buffs:
		buffs_data.append(b.to_dict())
	return {
		"instance_id":      instance_id,
		"card_def_id":      card_def_id,
		"owner":            owner,
		"controller":       controller,
		"zone_id":          zone_id,
		"is_token":         is_token,
		"created_on_turn":  created_on_turn,
		"attached_to":      attached_to,
		"attachments":      attachments.duplicate(),
		"stolen_by":        stolen_by,
		"stolen_ids":       stolen_ids.duplicate(),
		"is_exhausted":     is_exhausted,
		"face_down":        face_down,
		"just_summoned":    just_summoned,
		"hero_power_used":  hero_power_used,
		"used_this_turn":   used_this_turn,
		"damage_taken":     damage_taken,
		"active_buffs":     buffs_data,
		"counters":         counters.duplicate(),
		"chosen_x":         chosen_x,
		"granted_keywords": granted_keywords.duplicate(),
	}

static func from_dict(d: Dictionary) -> CardInstance:
	var inst := CardInstance.new()
	inst.instance_id     = d["instance_id"]
	inst.card_def_id     = d["card_def_id"]
	inst.owner           = d["owner"]
	inst.controller      = d["controller"]
	inst.zone_id         = d["zone_id"]
	inst.is_token        = d.get("is_token", false)
	inst.created_on_turn = d.get("created_on_turn", 0)
	inst.attached_to     = d.get("attached_to", "")
	inst.attachments.assign(d.get("attachments", []))
	inst.stolen_by       = d.get("stolen_by", "")
	inst.stolen_ids.assign(d.get("stolen_ids", []))
	inst.is_exhausted    = d.get("is_exhausted", false)
	inst.face_down       = d.get("face_down", false)
	inst.just_summoned   = d.get("just_summoned", false)
	inst.hero_power_used = d.get("hero_power_used", false)
	inst.used_this_turn  = d.get("used_this_turn", false)
	inst.damage_taken    = d.get("damage_taken", 0)
	inst.counters        = d.get("counters", {}).duplicate()
	inst.chosen_x        = d.get("chosen_x", 0)
	inst.granted_keywords.assign(d.get("granted_keywords", []))
	for bd in d.get("active_buffs", []):
		inst.active_buffs.append(Buff.from_dict(bd))
	return inst
