class_name Zone
extends Resource

# An ordered collection of card instance_ids representing one game zone.
# Moving a card between zones always goes through GameLogic.move_card() —
# never by mutating card_ids directly — so zone-change triggers have one
# choke point to hook into.
#
# zone_type strings:
#   "deck"          — face-down draw pile
#   "hand"          — cards held by the player (hidden from opponent)
#   "resource_row"  — resources placed face-down (or face-up quest/location)
#   "ally_row"      — allies in play
#   "hero_row"      — hero card, weapons, armor, items, non-attachment ongoing abilities
#   "graveyard"     — destroyed/discarded/used cards; face-up, ordered
#   "rfg"           — removed from game (rule 415.7); usually face-down
#   "attached"      — virtual zone for all attachments currently in play;
#                     shared between both players (owner == "shared").
#                     Use CardInstance.attached_to / .attachments to navigate
#                     the host relationship — don't scan this zone for that.

var zone_id: String      # e.g. "p1_ally_row", "p2_graveyard", "attached"
var zone_type: String
var owner: String        # player_id, or "shared" for the attached zone
var card_ids: Array[String] = []


static func make(p_zone_id: String, p_zone_type: String, p_owner: String) -> Zone:
	var z := Zone.new()
	z.zone_id   = p_zone_id
	z.zone_type = p_zone_type
	z.owner     = p_owner
	return z


# Build all standard zones for a two-player game.
static func create_standard_zones() -> Dictionary:
	var zones: Dictionary = {}
	for pid in ["p1", "p2"]:
		for ztype in ["deck", "hand", "resource_row", "ally_row", "hero_row", "graveyard", "rfg"]:
			var zid: String = pid + "_" + ztype
			zones[zid] = Zone.make(zid, ztype, pid)
	zones["attached"] = Zone.make("attached", "attached", "shared")
	# Rule 415.6a / 415.9: chain is a shared zone where cards sit while proposed.
	# Rule 409.1: playing a card moves it from its zone into the chain.
	zones["chain"]    = Zone.make("chain",    "chain",    "shared")
	return zones


func to_dict() -> Dictionary:
	return {
		"zone_id":   zone_id,
		"zone_type": zone_type,
		"owner":     owner,
		"card_ids":  card_ids.duplicate(),
	}

static func from_dict(d: Dictionary) -> Zone:
	var z := Zone.new()
	z.zone_id   = d["zone_id"]
	z.zone_type = d["zone_type"]
	z.owner     = d["owner"]
	z.card_ids.assign(d.get("card_ids", []))
	return z
