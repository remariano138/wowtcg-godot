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

	return d
