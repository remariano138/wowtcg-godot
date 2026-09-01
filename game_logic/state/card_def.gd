class_name CardDef
extends Resource

# Static, read-only definition of a card as printed. One instance per unique
# card in the database — shared across all CardInstances of the same card.
# Nothing here can change during a game; mutable game state lives in CardInstance.

var card_def_id: String        # matches "id" column in cards.csv
var card_name: String = ""
var cost: int = -1             # total cost; -1 = free or not applicable
var cost_x: bool = false       # true if cost contains a variable X component
var cost_base: int = 0         # fixed part of cost (e.g. 1 in "1+X", 0 in pure "X")
var printed_atk: int = 0
var printed_health: int = 0
var card_type: String = ""     # "Ally", "Hero", "Ability", "Equipment", "Quest", etc.
var is_instant: bool = false   # true when type line begins with "Instant"
var alignment: String = ""     # "Alliance", "Horde", or "" for neutral
var tags: String = ""
var dmg_type: String = ""      # "Melee", "Ranged", "Frost", "Fire", etc.
var power_text: String = ""
var card_class: String = ""
var card_subtype: String = ""  # e.g. "Gnome Warrior", "Pet", "Instant"
var rarity: String = ""        # "Common", "Uncommon", "Rare", "Epic"
var keywords: Array[String] = []   # lowercase, e.g. ["protector", "ferocity"]
var effects: String = ""       # raw recipe string from CSV effects column
var image_path: String = ""    # relative path under res://
# Auto-mute conditions, from the `mute_when` CSV column: a `+`-joined list of
# named condition tokens. When ANY of them holds, the card is treated as muted
# by the auto-pass probes (InputRouter.has_any_legal_play(true)) — it stays
# fully playable and highlighted, it just no longer HOLDS a priority window
# open, because playing it right then is provably pointless.
#
# PURE UI DATA. Nothing in game_logic reads it and it never changes legality;
# InputRouter._mute_condition_holds is the one interpreter. See the Auto-mute
# section in CLAUDE.md for the token list.
var mute_when: String = ""
# True for defs loaded from data/tokens.csv. Tokens are created by effects, are
# never deckable (DeckManager.authorize_deck_def rejects them), and cease to
# exist the moment they leave play (GameLogic.move_card redirects them to RFG).
var is_token: bool = false



# cards.csv `class` column format. A single-class card stores the full class
# name ("Hunter"); a multi-class one stores concatenated two-letter abbreviations
# ("MaPrLo"). This lives on CardDef rather than in DeckManager because the format
# is a property of the card DATA, and two unrelated readers need it: deck
# legality (rule 100.2a) and Lok'delar's "when you play a <class> ability" play
# trigger. DeckManager delegates here so there is one source of truth.
const CLASS_ABBREVS := {
	"Dk": "Death Knight", "Dr": "Druid",  "Hu": "Hunter",  "Ma": "Mage",
	"Pa": "Paladin",      "Pr": "Priest", "Ro": "Rogue",   "Sh": "Shaman",
	"Lo": "Warlock",      "Wa": "Warrior",
}


# The classes this card's `class` column names: [] = no restriction (legal for
# any hero), one or more full class names otherwise, or ["?"] when the value
# parses as neither — DeckManager.authorize_deck_def reports that as a data error.
static func parse_class_restriction(raw: String) -> Array[String]:
	var t := raw.strip_edges()
	if t.is_empty():
		return []
	if t in CLASS_ABBREVS.values():
		return [t]
	if t.length() % 2 != 0:
		return ["?"]
	var classes: Array[String] = []
	for i in range(0, t.length(), 2):
		var abbrev := t.substr(i, 2)
		if not CLASS_ABBREVS.has(abbrev):
			return ["?"]
		classes.append(CLASS_ABBREVS[abbrev])
	return classes


# True when this card carries `class_name_wanted`'s icon. A card with NO class
# restriction is deliberately not "a Hunter card" — it belongs to no class, so
# Lok'delar's trigger ignores a neutral ability even in a Hunter deck.
func has_class(class_name_wanted: String) -> bool:
	return class_name_wanted in parse_class_restriction(card_class)


# Build a CardDef from a raw CSV row dictionary (as returned by CardDatabase).
static func from_csv_row(id: String, row: Dictionary) -> CardDef:
	var d := CardDef.new()
	d.card_def_id = id
	d.card_name   = row.get("name", "")
	var raw_type: String = row.get("type", "")
	if raw_type.begins_with("Instant "):
		d.is_instant = true
		d.card_type  = raw_type.trim_prefix("Instant ").strip_edges()
	else:
		d.is_instant = false
		d.card_type  = raw_type
	d.alignment   = row.get("alignment", "")
	d.tags        = row.get("tags", "")
	d.dmg_type    = row.get("dmg_type", "")
	d.power_text  = row.get("power_text", "")
	d.card_class  = row.get("class", "")
	d.card_subtype = row.get("subtype", "")
	d.rarity      = row.get("rarity", "").strip_edges()
	d.effects     = row.get("effects", "")
	d.image_path  = row.get("image_path", "")

	var cost_str: String = row.get("cost", "")
	if "X" in cost_str:
		d.cost_x    = true
		d.cost_base = int(cost_str.split("+")[0]) if "+" in cost_str else 0
		d.cost      = -1
	else:
		d.cost = int(cost_str) if cost_str != "" else -1

	d.printed_atk    = int(row["atk"])    if row.get("atk", "")    != "" else 0
	d.printed_health = int(row["health"]) if row.get("health", "") != "" else 0

	var kw_str: String = row.get("keywords", "")
	d.keywords = []
	if kw_str != "":
		for k in kw_str.split(","):
			d.keywords.append(k.strip_edges().to_lower())

	d.mute_when = row.get("mute_when", "").strip_edges()

	return d


# Rule 305.3a: "Totems are ability allies and count as both in all zones." A
# Totem's printed card_type is Ability / Instant Ability, so a bare
# `card_type == "Ally"` test silently misses it. These two live here, on the def
# itself, because both the resolver (StackResolver.is_totem_def /
# is_ally_card_def, thin wrappers over them) and GameState's cost auras
# (Diplomacy) need the answer, and GameState must not depend on the resolver.
func is_totem() -> bool:
	for seg in effects.split("|"):
		var s := seg.strip_edges()
		if s == "totem" or s.begins_with("totem:"):
			return true
	return false


# "Is this an ALLY CARD" — the one predicate, in every zone. Do NOT use it for
# in-play scans: there, "an ally in your party" is the controller's ally_row read
# live, which includes totems by construction.
func is_ally_card() -> bool:
	return card_type == "Ally" or is_totem()
