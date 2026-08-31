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
# Monotonic counter behind token instance ids (GameLogic.create_token). Tokens
# are minted mid-game, so unlike deck cards they can't get a setup-time id.
var token_counter: int = 0

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
# ── Turn event log (turn-history conditions) ──────────────────────────────────
# Structured record of rules-relevant things that HAPPENED this turn, for cards
# whose condition reads turn history rather than board state (Thysta
# Spiritlasher's "if no damage was dealt this turn", Torek's Assault's "if an
# opposing hero was dealt damage this turn by an ally in your party").
# See game_logic/turn_state_flags.md for the full design rationale.
#
# Rules of the log:
#   - Entries are appended by the PRIMITIVES (e.g. GameLogic.deal_damage), at
#     the moment the fact becomes true — NOT at event-bus emission. Rules
#     functions return events and the caller emits, so a condition read
#     mid-resolution would miss bus-level entries from its own chain.
#   - Entries snapshot the facts a condition needs AT WRITE TIME (was the
#     source an ally, who controlled it). Payloads hold ids; by read time the
#     card may be in a graveyard or under new control, so re-deriving from ids
#     gives a different answer than the moment the fact was true.
#   - Recorded unconditionally, in every game: turn-history conditions are
#     retroactive (a Thysta entering play mid-turn must see damage dealt
#     before she arrived, which nothing on the board records).
#   - Cleared at every turn start (TurnManager._enter_ready), so it stays
#     bounded and "this turn" is simply "in the log".
# Entry shape: {"type": String, ...snapshot fields}. Current types:
#   "damage_dealt" — {source_id, target_id, amount, source_controller,
#                     target_controller, source_is_ally, target_is_hero,
#                     target_is_ally}
#     Appended AFTER prevention (717.2b — fully absorbed damage was never
#     dealt), i.e. exactly when damage_dealt is constructed. `amount` is the
#     DEALT amount, which per 405.2 may exceed the target's health (only "put"
#     damage is capped at fatal) — overkill counts in full.
#   "ally_destroyed" — {card_id, controller, owner, is_ally, is_token}
#     Appended wherever GameEvent.card_destroyed is constructed
#     (GameLogic.check_destroyed / destroy_card / the 400.5 attachment sweep),
#     i.e. while the card is still in play. Every field is a SNAPSHOT: by read
#     time the card sits in a graveyard (so "was it an ally?" is no longer
#     derivable from its zone) and a token has gone to RFG.
var turn_events: Array = []

# Index into turn_events of the first "damage_dealt" entry the board's
# "when an ally is dealt damage" watchers (Skorn, Mistress of Shadow) have not
# reacted to yet. Board-global rather than per player: unlike Cold Blood's or
# Recombobulation's grants this is not a this-turn grant with an owner but a
# static power read off whatever cards are in play, so one cursor serves every
# copy — the sweep fires ALL in-play watchers for an entry before advancing
# past it. Reset to 0 with turn_events at every turn start.
var damage_watch_index: int = 0

# The same cursor for "when an ally is destroyed" watchers read off cards in
# play (Circle of Life). Separate from Recombobulation's per-player
# `recomb_from_index` for the reason above: that is a this-turn grant owned by
# the player who completed the quest, this is a static power on whatever is in
# play, so one board-global cursor serves every copy. Reset with turn_events.
var ally_destroy_watch_index: int = 0

# Shadow Bolt: "When that character is destroyed this turn, its controller
# discards a card." One entry per marked character — a CARD, not a player, since
# the discard follows whoever controlled it when it died. Marks are consumed as
# they fire (a character is destroyed once), so no cursor is needed, and the
# whole list is cleared at every turn start with the turn event log.
# See game_logic/turn_state_flags.md.
var destroy_discard_marks: Array[String] = []

# Brain Freeze: "Players can't draw cards this turn." Board-wide rather than
# per player — the card says "players", plural, with no controller clause, so it
# locks BOTH players including its own caster. Enforced at the ONE draw
# primitive (GameLogic.draw_one), so every draw site in the game respects it by
# construction, and per rule 415.9f it is a lock on DRAWING alone: a graveyard
# fetch, a reveal-pick and a "look at" all still put cards into a hand.
# Cleared at every turn start with the turn event log — "this turn".
var draws_locked_this_turn: bool = false

# Helwen: "You may choose NOT to ready Helwen during your ready step." The ready
# step's automatic actions don't use the chain (501.1a), so this is a direct-call
# choice point (StackResolver.choose_stay_exhausted) drained one card at a time.
# Such a card is left EXHAUSTED by the ready loop and queued here — the default
# is therefore "stays exhausted", and answering "ready" readies it then.
var pending_ready_choice_player: String = ""
var pending_ready_choice_ids: Array[String] = []

# The one append site. Keep new record calls co-located with the matching
# GameEvent construction in the primitive, so log truth == event truth.
func record(event_type: String, data: Dictionary) -> void:
	var entry := {"type": event_type}
	entry.merge(data)
	turn_events.append(entry)

func has_turn_event(event_type: String) -> bool:
	for e in turn_events:
		if e.get("type", "") == event_type:
			return true
	return false

func turn_events_of(event_type: String) -> Array:
	var result: Array = []
	for e in turn_events:
		if e.get("type", "") == event_type:
			result.append(e)
	return result

# ── Uniqueness re-check queue (rules 414.3 / 414.3a / 414.3b) ─────────────────
# Uniqueness is a STATE-based condition, not an on-play trigger: what matters is
# what a player controls in play, however it got there. So the queue is fed by
# the one place cards arrive in a play row — GameLogic.move_card — and drained by
# StackResolver.drain_uniqueness_checks at the resolver's gates. That covers a
# card resolving out of the chain, a token being minted, an enter-play effect and
# a CONTROL CHANGE (Infernal, Nyn'jah's steal and its reversion) with one
# mechanism, instead of a per-effect check each new card has to remember.
var pending_uniqueness_ids: Array[String] = []

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
var combat_protector: String = ""  # who exhausted to protect this combat; "" = nobody
# Rule 602.1 / 602.3: priority windows within a combat step.
var combat_attack_window: bool  = false  # true during the Attack Window
var combat_defend_window: bool  = false  # true during the Defend Window
# Weapon strikes (rule 303.2a): wielder instance_id -> Array[String] of weapon
# instance_ids associated with it for the current combat step. Cleared at
# combat conclusion. Feeds the strike modifier (+weapon ATK) in get_atk.
var combat_struck_weapons: Dictionary = {}
# "+N ATK this combat" grants (Berserking: "Your hero has +1 ATK this combat for
# each counter you removed."): wielder instance_id -> int. Applied live in
# get_atk, cleared alongside combat_struck_weapons at combat conclusion.
var combat_atk_bonus: Dictionary = {}
# Strike point (rules 602.1 / 602.3): non-empty while a hero's controller must
# decide whether to strike with a weapon. Doesn't use the chain — resolved via
# StackResolver.choose_strike() (direct call, like the protect point).
var pending_strike_player: String = ""
var pending_strike_weapon_ids: Array[String] = []  # strikeable weapons offered
var pending_strike_side: String = ""  # "attack" (602.1) or "defend" (602.3)
# Ready-on-attack point (Windseer Tarus, rule 601.x triggered ability): non-empty
# while an attacker's controller may pay to ready it after it attacks for the
# first time this turn. Opened at combat-step start (602.1), like the strike
# point; resolved via StackResolver.choose_ready_on_attack() (direct call).
var pending_ready_player: String = ""
var pending_ready_card_id: String = ""
var pending_ready_cost: int = 0
# Ready-on-strike point (Windfury Weapon: "When you strike with attached weapon
# for the first time each turn, you may pay 1. If you do, ready that weapon and
# your hero."): non-empty while the striking player may pay to ready the struck
# weapon + their hero. Opened inside choose_strike (602.1 / 602.3), before the
# held combat window; resolved via StackResolver.choose_ready_on_strike().
var pending_strike_ready_player: String = ""
var pending_strike_ready_weapon_id: String = ""
var pending_strike_ready_cost: int = 0
var pending_strike_ready_side: String = ""
# Green Whelp Armor triggered bounce (rule 305.2 triggered equipment power): after
# an attacking ally deals combat damage to the armor wielder's hero, the wielder
# MAY pay to bounce that ally to its owner's hand. Opened at combat conclusion,
# resolved via StackResolver.choose_whelp_bounce() (direct call, like the strike
# point). "" = none pending.
var pending_whelp_bounce_player: String = ""
var pending_whelp_bounce_ally_id: String = ""
var pending_whelp_bounce_cost: int = 0

# Vestia Abiectus: "When Vestia Abiectus deals combat damage, you may put an
# ability you control into its owner's hand." Opened at combat conclusion and
# answered by StackResolver.choose_vestia_return (a direct call, NOT the chain -
# see data/rules_deviations.md). `_ids` is the pool as it stood when the point
# opened; the choice is re-checked against a live pool when it is answered.
var pending_vestia_return_player: String = ""
var pending_vestia_return_source: String = ""
var pending_vestia_return_ids: Array = []
# Feral Rage (azeroth_21): "Ongoing: When your hero is dealt combat damage while
# in bear form, you may pay (1). If you do, draw a card." Opened at combat
# conclusion like the whelp bounce and resolved via
# StackResolver.choose_feral_rage() (direct call). One entry PER IN-PLAY COPY per
# qualifying hit — the trigger is a power on each card, not on the hero — so the
# queue holds player ids and is drained one offer at a time. Both heroes can
# qualify from one combat (a defender's retaliation onto an attacking hero), so
# the queue is not single-player.
var pending_feral_rage_queue: Array[String] = []   # player ids, front-first
var pending_feral_rage_player: String = ""         # who must decide now; "" = none
var pending_feral_rage_cost: int = 0
# Wisp (dark_portal_197): "At the start of your turn, if Wisp is in your
# graveyard, you may pay (1). If you do, put Wisp into your hand." The optional
# payment is a 709.2b RESOLUTION choice (707.1 locks in only X, modes and
# targets), so this opens from the trigger's chain link resolving, not when it
# fires — resources freed inside the response window can still pay it. Declining
# costs nothing, so the offer simply comes back next turn. Resolved via
# StackResolver.choose_gy_return() (direct call, like the whelp bounce);
# can_submit and pass_priority hard-block while it is pending. "" = none.
var pending_gy_return_player: String = ""
var pending_gy_return_card_id: String = ""
var pending_gy_return_cost: int = 0
# Track Humanoids: "At the start of your turn, look at the top card of your deck.
# You may put it on the bottom of your deck." Non-empty while the controller is
# deciding. The looked-at card is NOT drawn and never leaves the deck — keeping
# it on top means literally not moving it — so this holds only the card's id for
# display; the choice is resolved via StackResolver.choose_track_placement()
# (direct call, like the whelp bounce). "" = none pending.
var pending_track_look_player: String = ""
var pending_track_look_card_id: String = ""
# Where the "move it" answer sends the looked-at card. "bottom" = Track
# Humanoids ("put it on the bottom of your deck"); "graveyard" = Gustaf
# Trueshot ("put it into your graveyard"). The two cards are the same binary
# choice on the same private card, so they share the whole point — the
# destination is the only thing that differs, and it rides here rather than
# being re-derived from the source at resolution.
var pending_track_look_dest: String = "bottom"
# Stoneform (dark_portal_132): "Destroy any number of abilities attached to
# your hero." A CHOICE (not a target — nothing is announced), opened as
# Stoneform resolves into play. Candidates are recomputed live from the
# caster's hero's attachments (StackResolver.get_stoneform_destroy_candidates),
# so only the source card id needs to be tracked here. Resolved via
# StackResolver.choose_stoneform_destroy() (direct call, like the whelp
# bounce). "" = none pending.
var pending_stoneform_player: String = ""
var pending_stoneform_source: String = ""
# Rain of Fire (azeroth_129): "Ongoing: At the start of your turn, pay (4) or
# destroy Rain of Fire." The upkeep point — a pay-or-lose-it decision opened from
# the RESOLUTION of the card's start-of-turn trigger (709.2b: the payment is
# neither X, a mode nor a target, so it belongs to resolution, not announcement —
# Infernal's discard is the same call). Resolved via
# StackResolver.choose_upkeep() (direct call, like the whelp bounce);
# can_submit / pass_priority hard-block while pending.
# No queue is needed even with several copies in play: the turn-start triggers go
# on the chain ONE AT A TIME (see advance_turn_start_triggers), and this block
# stops the next link being announced until the point is answered.
var pending_upkeep_player: String = ""    # who must decide now; "" = none
var pending_upkeep_card_id: String = ""   # the card that will be destroyed if unpaid
var pending_upkeep_cost: int = 0
# What the upkeep is paid IN. "resources" = Rain of Fire ("pay (4) or destroy
# it"); "discard" = Last Stand ("discard two cards or destroy it"), where
# pending_upkeep_cost is a CARD count and paying opens the ordinary pending
# discard. Same choice point either way — only the currency differs.
var pending_upkeep_kind: String = "resources"
# Attack-exhaust point (Chops / Voss Treebender: "When [this] attacks, you may
# exhaust target hero or ally."): non-empty while the attacker's controller may
# pick a target to exhaust (or decline). Opened at combat-step start (602.1),
# BEFORE the attack window — resolving it against a ready Protector denies the
# protect point (602.2). Resolved via StackResolver.choose_attack_exhaust()
# (direct call, like the ready-on-attack point). "" = none pending.
var pending_attack_exhaust_player: String = ""
var pending_attack_exhaust_source_id: String = ""
# Which pool the pending point targets: "character" (Chops / Voss — any hero or
# ally) or "armor" (Gartok Skullsplitter — "you may exhaust target armor").
# Read by StackResolver.get_attack_exhaust_targets(), so the UI and AI ask for
# "the legal targets" without knowing which trigger opened the point.
var pending_attack_exhaust_kind: String = "character"
# Armor prevention point (rule 717.2c): opened at the moment a damage packet
# would be dealt to a hero whose controller has ready DEF>0 equipment — at
# combat conclusion, or just before a hero-damaging chain link resolves. The
# player exhausts any number of armors back-to-back (each choose_prevention
# call), or declines; then the (reduced) packet lands. Direct call, NOT the
# chain ("None of this uses the chain" — 717.2c); can_submit / pass_priority
# hard-block while pending. Resolved via StackResolver.choose_prevention().
var pending_prevention_player: String = ""   # who must decide; "" = none
var pending_prevention_amount: int = 0       # damage remaining in the current packet
var pending_prevention_source: String = ""   # packet source card (UI)
var pending_prevention_target: String = ""   # hero about to be hit
var pending_prevention_offers: Array = []    # queued packets: {player, amount, source, target}
var pending_prevention_resume: String = ""   # what to resume: "combat" or "packets"
# Deferred packet groups (resume == "packets"): EVERY non-combat damage effect
# hands its packets to StackResolver.defer_packets instead of calling
# deal_damage — each group is {packets: [{source, target, amount, riders,
# discard_per, drain_heal_per, drain_heal_to}], after: String,
# recursive_destroy: bool} and lands (pool-reduced) once its prevention offers
# are decided. This makes new damage effects preventable by construction.
var pending_prevention_deferred: Array = []

# Holy Shield: damage its scoped shield PREVENTED, waiting to be reflected back
# at the character it was warding against ("your hero deals that amount of holy
# damage to that character"). Filled by GameLogic.prevent, which cannot deal the
# damage itself — that would be re-entrant, inside the prevention pipeline of
# the packet still landing — and drained by StackResolver._drain_shield_reflects
# at the two points damage has finished landing (_apply_packet_group and
# _do_combat_conclusion), the same two Skorn and Cold Blood sweep at.
# Entries: {target, amount, dmg_type, controller}.
var pending_shield_reflects: Array = []

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
# Name-based uniqueness (rule 414.3a — the "Unique" tag): a player may not
# control two or more in-play cards with the same name that both carry Unique.
# On violation the player destroys duplicates until only one remains.
var pending_unique_sacrifice_player: String = ""
var pending_unique_sacrifice_ids: Array[String] = []  # instance_ids of the same-named Unique cards in play
# Form (1) tag-count uniqueness (rule 414.3b — Bear Form / Cat Form / Bash / Claw):
# a player may control at most one card with the Form (1) tag (`form:1` effects
# segment) in play. On violation the player destroys Forms until one remains
# (normally keeping the newly played one). Mirrors the Unique-tag flow.
var pending_form_sacrifice_player: String = ""
var pending_form_sacrifice_ids: Array[String] = []  # instance_ids of the in-play Form cards
# Bear/Cat Form death trigger: "When [this] is destroyed, you may pay (2). If you
# do, put it into your hand" (`on_destroyed:pay_return_hand:2`). Opened only when
# the controller can afford the cost; resolved via choose_form_return() (direct
# call, like the whelp bounce). See data/rules_deviations.md "Form return timing".
var pending_form_return_player: String = ""
var pending_form_return_card_id: String = ""
var pending_form_return_cost: int = 0
# Infernal-style start-of-turn choice: discard a card OR give the opponent
# control of the source. Optional discard — declining is a legal resolution
# (unlike pending_discard, which is mandatory).
var pending_control_discard_player: String = ""
var pending_control_discard_ids: Array[String] = []  # source instance_ids, resolved front-first
# Nightbloom: "You MAY put a card from your hand into your resource row face down
# and exhausted." An optional choice made at resolution (709.2b) — declining is a
# legal resolution, like the control discard above. Rule 412.1c: a resource put
# there by an effect does NOT count toward the one-per-turn placement, so this
# never touches resource_placed_this_turn.
var pending_resource_place_player: String = ""
var pending_resource_place_source: String = ""
# Seraph the Exalted: "[Activate] -> Put an ally card from your hand into play if
# its cost is less than or equal to the number of resources you have." Which ally
# is a resolution CHOICE, not a target (709.2b — nothing is announced, so 706 is
# irrelevant), so it opens a direct-call choice point like Nightbloom's above.
# MANDATORY, unlike that one — the printed text has no "may" — so there is no
# decline; a hand with no eligible ally opens no choice at all.
var pending_hand_play_player: String = ""
var pending_hand_play_source: String = ""
var pending_hand_play_ids: Array[String] = []   # eligible hand card instance_ids
# Reveal-and-pick quest reward (Big Game Hunter, Kibler's Exotic Pets, Zapped
# Giants): "Reveal the top N cards; put a revealed <type> card into your hand and
# the rest on the bottom of your deck." The revealed cards stay physically at the
# top of the deck while pending (everything else is blocked); on resolution the
# picked card goes to hand and the rest are pushed to the bottom in revealed order.
# The DECIDER may differ from the owner (The Princess Trapped: "Target opponent
# chooses one" — the cards are revealed from, and go to, pending_reveal_pick_player's
# deck/hand, but pending_reveal_pick_chooser is who clicks). The chooser defaults
# to the owner; every guard/blocker keys off _player, only the input routing and
# the AI's pick-quality key off _chooser.
var pending_reveal_pick_player: String = ""   # owner: whose deck was revealed, whose hand the pick goes to
var pending_reveal_pick_chooser: String = ""  # decider: who makes the pick ("" while no choice is open)
var pending_reveal_pick_ids: Array[String] = []   # revealed cards matching the type — the selectable set
var pending_reveal_pick_all: Array[String] = []   # every revealed card, in top→down order
# It's a Secret to Everybody: the picked card goes back on TOP of the owner's
# deck instead of into hand (the rest still go to the bottom), and the reveal is
# a private "look at" rather than a public reveal — the opponent sees nothing.
var pending_reveal_pick_to_top: bool = false
var pending_reveal_pick_private: bool = false
# ── "At the start of [this] turn" triggered effects (rule 501.1a / 500.2) ─────
# Every start-of-turn trigger on every in-play card — Searing Totem's ping,
# Infernal's discard-or-control, Healing Stream Totem's party heal, Fireball's
# attached burn, Spirit Bond, Tooga's self-removal, plain self-heals — is
# collected into this ONE queue as the ready step's automatic actions finish
# (TurnManager._collect_turn_start_triggers), in rule-708.1a order: the turn
# player's triggers first, then the opponent's.
#
# Each entry is a dict {card_id, controller, key, args}. `key` is the effects
# segment name and `args` its remaining colon-separated fields, so the queue
# carries no per-card special cases — the dispatch lives in one place
# (StackResolver._resolve_turn_start_trigger).
#
# They are ALL added to the chain in ONE PPP by
# StackResolver.advance_turn_start_triggers (708.1a/708.1b), turn player's
# first, then the opponent's, and only then does anybody get priority. Because
# the chain is LIFO, that means the OPPONENT's triggers resolve first, and
# within one player the trigger he adds LAST resolves FIRST — which is why the
# order within a player is his own CHOICE (pending_trigger_order_player below)
# rather than board order. Each announcement may still stop for a target
# (707.1d — a direct-call choice while pending_trigger_target_player is
# non-empty); both of those points hard-block can_submit and pass_priority, so
# 708.1b holds. Non-target choices are NOT made here; per 709.2b they are made
# as the link resolves (Infernal's discard, Rain of Fire's payment, Wisp's).
var pending_turn_start_triggers: Array = []
var pending_trigger_target_player: String = ""  # must pick a target for triggers[0]; "" = none
# 708.1a: "first the turn player chooses in what order his triggered effects go
# on the chain". Non-empty while a player with TWO OR MORE waiting triggers is
# being asked which one goes on next — the choice is expressed as a repeated
# "pick the next one", which is exactly equivalent to ordering them up front and
# needs no ordering widget. `_ids` is the source card ids he may pick from,
# recomputed each time. Resolved via StackResolver.choose_trigger_order()
# (a direct call, NOT the chain). One remaining trigger is not a decision, so
# the point does not open for it.
var pending_trigger_order_player: String = ""
var pending_trigger_order_ids: Array = []
# True once the adding player has named the trigger that goes on NEXT, so the
# ordering point is not re-asked for the one he just picked. Cleared as each
# trigger leaves the queue (announced or skipped), which is what makes the point
# reopen for the trigger after it.
var pending_trigger_front_settled: bool = false
# WHICH queue that pending target choice belongs to: "turn_start" or "play".
# The two share the choice point (and therefore the whole UI and AI flow), so
# this is what tells StackResolver.choose_trigger_target which queue to pop and
# which link type to announce — the pending_attack_exhaust_kind pattern.
var pending_trigger_kind: String = "turn_start"

# ── Play-triggered effects (rule 708.1 — "When you play a Holy ability, …") ───
# The third twin of pending_turn_start_triggers, for ongoing powers that watch
# their own controller PLAYING a card (Spiritual Healing). Per 708.1 the trigger
# fires as the card is played — i.e. as it is announced onto the chain — and the
# effect it creates is added to the chain during that same PPP, ON TOP of the
# card that triggered it. So the trigger RESOLVES FIRST, and it still resolves
# when the card beneath it is interrupted (711) or fizzles.
#
# Entries are {card_id, controller, key, args} like the other two queues, so the
# dispatch lives in one place (StackResolver._resolve_play_trigger).
#
# Drained ONE AT A TIME by StackResolver.advance_play_triggers: called as the
# play is announced, and again after each such link resolves — the chain is NOT
# empty while this drains (the triggering card is still on it), which is exactly
# why it can't reuse the turn-start queue's chain-empty drain point.
var pending_play_triggers: Array = []

# ── Combat-step triggered effects (rule 602.1 / 602.3 / 708.1) ───────────────
# The combat-step twin of pending_turn_start_triggers, and it exists for the same
# reason: "when this attacks" / "when this defends" powers TRIGGER as the combat
# step reaches that point, but per 708.1 the effects they create are added to the
# chain as the ensuing window opens — 602.1 and 602.3 both say so in as many
# words ("Any waiting triggered effects are added to the chain, and then the turn
# player gets priority"). They are therefore respondable, exactly like a
# start-of-turn trigger, and NOT resolved inline as the step passes through.
#
# Each entry is a dict {card_id, controller, key, args} in rule-708.1a order (the
# turn player's triggers first), so the queue carries no per-card knowledge — the
# whole dispatch is one match in StackResolver._resolve_combat_trigger.
#
# Drained ONE AT A TIME by StackResolver.advance_combat_triggers, called as the
# attack/defend window opens and again from pass_priority's window-close branch:
# the window stays OPEN while the queue drains, so each trigger gets a real
# priority window before the next is announced. Only once the queue is empty does
# the window actually close (protect point / conclusion).
var pending_combat_triggers: Array = []

# ── Quest reward "Choose one … you may choose both" (Hidden Enemies / A New
# Plague / Thwarting Kolkar Aggression / Crown of the Earth) ──────────────────
# When a `qmode:` quest resolves, the completer must pick one reward mode — or
# both, in an order of their choosing, when the `qchoice_both_race:RACE` hero
# condition is met AND both modes are currently available. Direct-call flow
# (NOT the chain, like the reveal pick): StackResolver.choose_quest_modes()
# resolves the pick; pass_priority / can_submit hard-block while any of these
# pendings is set. The chosen modes queue in quest_mode_queue and run one at a
# time; a mode needing further input opens its own pending choice below and the
# queue resumes once it resolves.
var pending_quest_choice_player: String = ""   # completer who must pick; "" = none
var pending_quest_choice_quest: String = ""    # quest instance id (UI)
var pending_quest_choice_modes: Array = []     # [{mode: String, available: bool}] in printed order
var pending_quest_choice_can_both: bool = false
var quest_mode_queue: Array = []               # [{player, quest_id, mode}] — front = next to run
# A quest reward that grants a this-turn effect to a TARGET ally the completer
# picks: Hidden Enemies' "Target ally has ferocity this turn" and The Perfect
# Stout's "Target ally can't attack this turn". Same choice point, same pool
# (any in-play ally either party, 706 respected) — only the grant differs, so
# WHICH one rides here rather than being re-derived from the quest at
# resolution. The UI and AI ask for "the legal targets" without knowing which
# reward opened the point (the Gartok pending_attack_exhaust_kind pattern).
var pending_quest_ally_grant_player: String = ""
var pending_quest_ally_grant_source: String = ""  # quest instance id (buff source / UI)
var pending_quest_ally_grant_kind: String = ""    # "ferocity" | "cannot_attack"
# Dragonkin Menace "Reward: Ready a hero or ally in your party": the completer
# CHOOSES one of their own characters (not a target — Untargetable is irrelevant).
var pending_quest_ready_player: String = ""
var pending_quest_ready_source: String = ""     # quest instance id (UI)
# Galway Steamwhistle "[Activate] -> Ready your hero and one of your weapons":
# the controller CHOOSES which of their own weapons readies (not a target —
# nothing is announced, so 706 Untargetable is irrelevant). Opened from the
# power's RESOLUTION (709.2b) and only when more than one exhausted weapon is
# in play; one candidate readies with no prompt, none opens no choice at all.
var pending_weapon_ready_player: String = ""
var pending_weapon_ready_source: String = ""    # the power's source card (UI)
var pending_weapon_ready_ids: Array[String] = []
# Poison Water "Shuffle any number of cards from your graveyard into your deck":
# the completer CHOOSES a subset of their own graveyard (not a target). "Any
# number" includes zero, so an empty pick is a legal answer.
var pending_quest_shuffle_player: String = ""
var pending_quest_shuffle_source: String = ""   # quest instance id (UI)
# A New Plague "each player destroys an ally in his party": each player with an
# ally picks their own sacrifice; completer first, drained front-first.
var pending_plague_destroy_player: String = ""
var pending_plague_destroy_queue: Array[String] = []
var pending_plague_destroy_source: String = ""  # quest instance id (UI)
# Thwarting Kolkar Aggression "target player turns one of his quests face down":
# the TARGET player picks which of their face-up quests flips.
var pending_quest_facedown_player: String = ""
var pending_quest_facedown_ids: Array[String] = []  # that player's face-up quest ids

# Death-triggered targeted effects (Boneshanks: "When [this] is destroyed,
# destroy target ally."). When such a card dies, a trigger dict {card_id,
# controller} is queued here and the front one opens as a mandatory choice:
# pending_death_target_player is the controller who must pick an ally to destroy.
# Drained one at a time (index 0 = active), resolved via
# StackResolver.choose_death_target() — a direct call, NOT a chain action, like
# the totem / strike choices. pass_priority / can_submit hard-block while pending.
# Prompted for a HUMAN controller even in hotseat (the choice is board-public).
var pending_death_triggers: Array = []

# ── Operation Recombobulation (dark_portal_292) ───────────────────────────────
# "When an opposing non-token ally is destroyed this turn, you may put an ally
# card from your graveyard into your hand." Each qualifying death queues one
# OPTIONAL pick for the quest completer, resolved one at a time via
# StackResolver.choose_recombobulation (a direct call — no chain, no priority
# pass, like the Boneshanks death target). A death with nothing in the
# graveyard to fetch never opens a choice.
var pending_recomb_queue: Array[String] = []   # completer ids, front-first
var pending_recomb_player: String = ""         # who must decide now; "" = none

# ── Circle of Life (azeroth_19) ───────────────────────────────────────────────
# "Ongoing: When an ally is destroyed, its controller may search his deck for an
# ally card with the same name and put it into play exhausted." Each qualifying
# death queues one OPTIONAL deck search for the DESTROYED ally's controller —
# either player, since the trigger is symmetric — resolved one at a time via
# StackResolver.choose_circle_of_life (a direct call — no chain, no priority
# pass, like the Recombobulation fetch). Entries are {player, card_name}: the
# name is what the search matches, carried on the queue because the dead card
# may itself have left the graveyard by the time the choice is answered.
# A death with no matching ally card in that player's deck opens no choice.
var pending_circle_queue: Array = []           # [{player, card_name}], front-first
var pending_circle_player: String = ""         # who must decide now; "" = none
var pending_circle_name: String = ""           # the name being searched for
var pending_death_target_player: String = ""  # controller who must pick a target ally; "" = none

# Players who have been required to draw a card from an empty deck (rule
# 410.6b). A decked player immediately loses the game (102.1a); if every
# remaining player becomes decked simultaneously, the game is a draw.
# Set by GameLogic.draw_one / mark_decked, never cleared during a game.
var decked_players: Array[String] = []

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


# ── Lost powers / added ally types (rule 700.3, 202.3 — Polymorph) ────────────
# "Attached ally can't attack or protect, loses all powers, and is a Sheep."
#
# THE one place "what powers does this in-play card actually have?" is answered.
# Rule 700.3: a card that loses its powers "effectively has a blank text box",
# so instead of a per-power exemption at fifty read sites, `effective_def`
# returns a BLANKED CardDef and every power-reading site asks for the def
# through it. A site that reads a def straight out of the database is reading
# the PRINTED card, which for an in-play card is now the wrong question.
#
# What is blanked, and what is not:
#   • `effects` and printed `keywords` go — 700.1 makes keywords powers too, so
#     a polymorphed Protector stops protecting and a polymorphed Ferocity ally
#     is summoning-sick again.
#   • Printed ATK and health STAY: they are on the card face, not in the text
#     box. A card's own power that MODIFIES them (Warcaller Zin'bawa, Kailis
#     Truearc) is a power and is lost, so the body drops to its printed line.
#   • `card_type` STAYS — the errata is explicit ("Polymorph doesn't change or
#     remove the attached ally's card type"), so a polymorphed ally is still an
#     ally: still a legal target for "target ally", still counts for party size,
#     and can still be exhausted to pay a cost (The Love Potion).
#   • Grants from ELSEWHERE stay, because the errata is equally explicit that a
#     blanked card "can later gain powers" — so buff-granted keywords and the
#     keyword/stat auras read live in `_has_keyword` and `_aura_atk_mods` are
#     untouched. Only what is printed on this card is silenced.
#
# The Sheep tag is ADDITIVE (202.3, and the errata: "in addition to any others
# it has"), so it is appended to both tag columns rather than replacing them —
# the two columns being the two CSV conventions for a race (a real ally carries
# it in `tags`, a token in `card_subtype`), which is what `_race_keyword_aura`
# already reads.
#
# One consequence the errata calls out: a TOTEM is an ally only because of a
# power (305.3a), so blanking it stops it being one, its Polymorph's attach
# description no longer matches, and the game destroys the Polymorph at the next
# PPP (410.6c). See StackResolver.drain_attachment_host_checks.
const LOST_POWERS_FLAG := "attached_loses_powers"
const ADD_TYPE_SEGMENT := "attached_ally_type"
# Entries of the CSV `keywords` column that are type-line TAGS (202.2) rather
# than keyword powers, and so survive a blank text box.
const TYPE_LINE_TAGS := ["unique", "unlimited"]

# Blanked-def cache, keyed by "<def_id>#<added tags>". Blanking allocates a
# CardDef, and these are read on every stat query, so the result is memoized.
# Defs are immutable, so a cached blank can never go stale.
var _effective_defs: Dictionary = {}


# True when one of this card's attachments carries `flag` as a bare segment —
# the general read behind every "Ongoing: attached ally <does/can't> …" clause
# (Entangling Roots' `attached_cannot_ready`, Polymorph's three). Live, so the
# restriction lifts the instant the attachment leaves play.
func has_attachment_flag(instance_id: String, flag: String, db) -> bool:
	var inst := get_card(instance_id)
	if not inst or not db:
		return false
	for att_id in inst.attachments:
		var att := get_card(att_id)
		if not att or att.zone_id != "attached":
			continue
		var att_def: CardDef = db.get_def(att.card_def_id)
		if att_def and _def_has_segment(att_def, flag):
			return true
	return false


# True when one of this card's attachments grants `keyword` — the mirror of
# has_attachment_flag for a segment that CARRIES an argument
# (`attached_keyword:stealth`, Lessons in Lurking). Live, so the grant lifts the
# instant the attachment leaves play, and read from StackResolver._has_keyword so
# every gate that governs a keyword answers it through the one funnel.
func attachment_grants_keyword(instance_id: String, keyword: String, db) -> bool:
	var inst := get_card(instance_id)
	if not inst or not db or keyword == "":
		return false
	for att_id in inst.attachments:
		var att := get_card(att_id)
		if not att or att.zone_id != "attached":
			continue
		var att_def: CardDef = db.get_def(att.card_def_id)
		if not att_def:
			continue
		for seg in att_def.effects.split("|"):
			var p := seg.strip_edges().split(":")
			if p[0] == "attached_keyword" and p.size() > 1 					and p[1].strip_edges() == keyword:
				return true
	return false


# True while an in-play card is under a "loses all powers" attachment.
func has_lost_powers(instance_id: String, db) -> bool:
	return has_attachment_flag(instance_id, LOST_POWERS_FLAG, db)


# Ally types this card's attachments ADD to it ("and is a Sheep"), in attach
# order. Additive per 202.3 — nothing is ever removed.
func added_ally_types(instance_id: String, db) -> Array[String]:
	var added: Array[String] = []
	var inst := get_card(instance_id)
	if not inst or not db:
		return added
	for att_id in inst.attachments:
		var att := get_card(att_id)
		if not att or att.zone_id != "attached":
			continue
		var att_def: CardDef = db.get_def(att.card_def_id)
		if not att_def:
			continue
		for seg in att_def.effects.split("|"):
			var p := seg.strip_edges().split(":")
			if p[0] == ADD_TYPE_SEGMENT and p.size() > 1:
				var t := p[1].strip_edges()
				if t != "" and not (t in added):
					added.append(t)
	return added


# THE def accessor for an in-play card. Returns the printed def unchanged in the
# overwhelmingly common case (no modifier is touching this card's text box), so
# routing a read site through it costs one dictionary lookup and nothing else.
#
# Power-reading sites for cards IN PLAY should use this instead of
# `db.get_def(inst.card_def_id)`. Sites that ask about a card in a HAND, DECK or
# GRAVEYARD must NOT — 700.2 puts powers in play, and a Polymorph can't reach
# those zones anyway.
func effective_def(instance_id: String, db) -> CardDef:
	var inst := get_card(instance_id)
	if not inst or not db:
		return null
	var printed: CardDef = db.get_def(inst.card_def_id)
	if not printed:
		return null
	var blank := has_lost_powers(instance_id, db)
	var added := added_ally_types(instance_id, db)
	if not blank and added.is_empty():
		return printed

	var key: String = "%s#%s#%s" % [inst.card_def_id, "1" if blank else "0",
		"+".join(added)]
	if _effective_defs.has(key):
		return _effective_defs[key] as CardDef
	var d: CardDef = _clone_def(printed)
	if blank:
		# 700.3 — a blank text box. Stats, cost, type and name are untouched.
		# TYPE-LINE TAGS are kept: the `keywords` column mixes true keyword
		# POWERS (protector, ferocity, elusive …) with the right-side tags of
		# 202.2, and a tag is not a power — a polymorphed Lady Jaina is still
		# Unique, so a second copy still violates 414.3a.
		d.effects  = ""
		var kept: Array[String] = []
		for kw in d.keywords:
			if kw in TYPE_LINE_TAGS:
				kept.append(kw)
		d.keywords = kept
	for t in added:
		d.tags = t if d.tags == "" else d.tags + " " + t
		d.card_subtype = t if d.card_subtype == "" else d.card_subtype + " " + t
	_effective_defs[key] = d
	return d


func _def_has_segment(def: CardDef, head: String) -> bool:
	if def.effects == "":
		return false
	for seg in def.effects.split("|"):
		if seg.strip_edges().split(":")[0] == head:
			return true
	return false


func _clone_def(src: CardDef) -> CardDef:
	var d := CardDef.new()
	d.card_def_id   = src.card_def_id
	d.card_name     = src.card_name
	d.cost          = src.cost
	d.cost_x        = src.cost_x
	d.cost_base     = src.cost_base
	d.printed_atk   = src.printed_atk
	d.printed_health = src.printed_health
	d.card_type     = src.card_type
	d.is_instant    = src.is_instant
	d.alignment     = src.alignment
	d.tags          = src.tags
	d.dmg_type      = src.dmg_type
	d.power_text    = src.power_text
	d.card_class    = src.card_class
	d.card_subtype  = src.card_subtype
	d.rarity        = src.rarity
	d.keywords      = src.keywords.duplicate()
	d.effects       = src.effects
	d.image_path    = src.image_path
	d.is_token      = src.is_token
	return d

# ── Derived stat helpers ───────────────────────────────────────────────────────
# These require a CardDatabase reference to look up printed (base) stats.
# Passing db as a parameter keeps GameState free of Godot node dependencies
# and allows headless unit testing with a mock database.

func get_atk(instance_id: String, db, assume_attacking: bool = false, clamp_floor: bool = true,
		assume_weapon: String = "") -> int:
	var inst := get_card(instance_id)
	if not inst:
		return 0
	var def: CardDef = db.get_def(inst.card_def_id)
	if not def:
		return 0
	var is_attacking := assume_attacking or (instance_id != "" and instance_id == combat_attacker)
	# (1) Direct buffs placed on this card. Conditional buffs (e.g. "while
	# attacking", from Rayder / For the Horde!) only count when their gate is met.
	var atk := def.printed_atk
	for b in inst.active_buffs:
		if b.stat != "atk":
			continue
		if b.condition == "while_attacking" and not is_attacking:
			continue
		atk += b.amount
	# (1b) Attachments on this card (rule 400): Ongoing "Attached ally has
	# +A ATK" (Mark of the Wild). Live read — never cached.
	atk += _attachment_stat_mods(inst, db, 1)
	# (2) This card's own printed continuous self-modifiers. Read off the
	# EFFECTIVE def (700.3): a self-modifier is a power, so a card that has lost
	# its powers drops to its printed ATK — which stays, being on the card face
	# rather than in the text box. See effective_def.
	var eff: CardDef = effective_def(instance_id, db)
	if not eff:
		eff = def
	var is_weapon := false
	for segment in eff.effects.split("|"):
		var parts := segment.split(":")
		if parts[0] == "atk_per_ally":
			var per_ally := int(parts[1]) if parts.size() > 1 else 1
			var ally_count := cards_in_zone(inst.controller + "_ally_row").size()
			atk += per_ally * ally_count
		elif parts[0] == "atk_per_damage_self":
			var per_damage := int(parts[1]) if parts.size() > 1 else 1
			atk += per_damage * inst.damage_taken
		elif parts[0] == "atk_per_damage_party":
			# Warcaller Zin'bawa: "+N ATK for each damage on allies in your
			# party." Live read of every card in the controller's ally_row —
			# the source itself included (he is an ally in your party), totems
			# too (305.3a). Heroes are not allies, so hero damage never counts,
			# and the scan is controller-scoped, so opposing damage doesn't
			# either. Never cached: the bonus moves the instant damage lands,
			# is healed, or an ally leaves play — mid-combat included.
			var per_dmg := int(parts[1]) if parts.size() > 1 else 1
			var party_damage := 0
			for ally in cards_in_zone(inst.controller + "_ally_row"):
				party_damage += ally.damage_taken
			atk += per_dmg * party_damage
		elif parts[0] == "buff_while_party_size":
			# Kailis Truearc: "+A ATK and +H health while there are N or more
			# allies in your party." Both halves are one conditional grant, so
			# they share `_party_size_buff` with get_max_hp — the ATK and the
			# health can never disagree about whether the condition is met.
			atk += _party_size_buff(inst, parts, 2)
		elif parts[0] == "atk_vs_exhausted_defender":
			# Bala Silentblade: "+N ATK while attacking an exhausted hero or
			# ally." Live continuous modifier — only while this card is the
			# actual combat attacker AND the current defender is exhausted
			# (re-read at every get_atk, so a defender exhausted or readied
			# mid-combat changes the bonus immediately).
			if instance_id == combat_attacker and combat_defender != "":
				var dfd := get_card(combat_defender)
				if dfd and dfd.is_exhausted:
					atk += int(parts[1]) if parts.size() > 1 else 0
		elif parts[0] == "strike_cost":
			is_weapon = true
	# (2b) Elendril's flip: "Your Ranged weapons have +3 ATK this turn."
	# Player-tracked bonus (ranged_weapon_atk_bonus) applied to this player's
	# Ranged weapons. Reads live so a struck weapon's contribution reflects it.
	if is_weapon and def.dmg_type == "Ranged":
		var wps := players.get(inst.controller) as PlayerState
		if wps:
			atk += wps.ranged_weapon_atk_bonus
	# (3) Party auras granted by other cards in play (e.g. Zorm Stonefury).
	atk += _aura_atk_mods(inst, is_attacking, db)
	# (3b) Strike modifier (rule 303.2b): +X ATK per weapon associated with this
	# wielder for the current combat step. Live lookup — never cached.
	for weapon_id in combat_struck_weapons.get(instance_id, []):
		atk += get_atk(weapon_id, db)
	# (3b-preview) A weapon this wielder has not struck with YET (the attack
	# cursor, after the player picked "Attack" off a specific weapon). Counted
	# before the floor below so an ATK-subtracting aura (Hootie) nets against the
	# weapon exactly as it will at the conclusion. DISPLAY ONLY.
	if assume_weapon != "" and not (assume_weapon in combat_struck_weapons.get(instance_id, [])):
		atk += get_atk(assume_weapon, db)
	# (3c) "+N ATK this combat" grants (Berserking). Live lookup — never cached;
	# cleared with the combat step.
	atk += int(combat_atk_bonus.get(instance_id, 0))
	# (3d) Berserking, forecast half: an attacking hero WILL cash its berserk
	# counters in as +N ATK the moment the combat step starts, so show them here
	# too (attacker gate + attack cursor). No double-count once combat is real —
	# the trigger erases the counters as it fills combat_atk_bonus above.
	if is_attacking:
		var b_ps := players.get(inst.controller) as PlayerState
		if b_ps and b_ps.hero_instance_id == instance_id:
			atk += _pending_berserk_atk(inst.controller, db)
	# (4) Party-wide "while attacking this turn" grants (Rayder, For the
	# Horde!) — tracked per-player, not per-card, so they also cover allies
	# that entered play after the effect resolved. Card text is "allies", so
	# a hero attacking never gets these.
	if is_attacking:
		var zone := zones.get(inst.zone_id) as Zone
		var is_ally := zone != null and zone.zone_type == "ally_row"
		if is_ally:
			var ps := players.get(inst.controller) as PlayerState
			if ps:
				for grant in ps.party_atk_buffs_this_turn:
					var alignment: String = grant.get("alignment", "")
					if alignment != "" and def.alignment != alignment:
						continue
					atk += int(grant.get("amount", 0))
	# ATK floors at 0 — a character can't have negative ATK. Only the clamp is
	# applied here; the raw negative buff (Ravenous Bite's -3) stays on the card,
	# so a later +ATK effect counts from the true value, not from 0.
	# `clamp_floor = false` returns that raw total instead — DISPLAY ONLY (the UI
	# uses it to tell "0 ATK" apart from "0 ATK because an aura is subtracting");
	# never let an unclamped value reach a rules decision.
	return max(atk, 0) if clamp_floor else atk


# Preview helper: what would this card's ATK be if it were the combat attacker
# right now? Used by the UI to show the true damage number on the attack
# targeting cursor before propose_combat actually runs (rule 601 — a card isn't
# "attacking" until combat is proposed, so plain get_atk correctly omits
# "while attacking" bonuses like Zorm/Rayder/For the Horde! during target
# selection). Never use this for anything but display — it doesn't reflect
# real game state and must not influence rules decisions.
func get_atk_if_attacking(instance_id: String, db, assume_weapon: String = "") -> int:
	return get_atk(instance_id, db, true, true, assume_weapon)


# Display helper: the UNCLAMPED ATK total (see the clamp note in get_atk). A
# negative result means something is subtracting ATK from a character whose
# printed ATK is too low to show it — a 0-ATK hero under Hootie's aura reads 0
# either way, so without this the UI has no way to know the aura is doing
# anything. Never use for rules decisions.
func get_atk_raw(instance_id: String, db, assume_attacking: bool = false) -> int:
	return get_atk(instance_id, db, assume_attacking, false)


# ATK this player's hero would gain from berserk counters sitting on their
# in-play Berserkings (`berserk_atk_on_hero_attack:N`) if it attacked right now.
func _pending_berserk_atk(player_id: String, db) -> int:
	if not db:
		return 0
	var bonus := 0
	for card in cards_in_zone(player_id + "_hero_row"):
		var count := int(card.counters.get("berserk", 0))
		if count <= 0:
			continue
		var def: CardDef = effective_def(card.instance_id, db)
		if not def or def.effects == "":
			continue
		for seg in def.effects.split("|"):
			var p := seg.strip_edges().split(":")
			if p[0].strip_edges() == "berserk_atk_on_hero_attack":
				bonus += (int(p[1]) if p.size() > 1 else 1) * count
				break
	return bonus


# Sum of ATK bonuses this card receives from static "aura" sources in its
# controller's party — continuous modifiers that live on another card in play
# and affect a dynamic set, so they can't be pre-placed as buffs (the source may
# outlive, or predate, the cards it buffs). New party auras add a match arm here.
# ── Form definitions ─────────────────────────────────────────────
# What each named form MEANS. A form is not a bag of segments a card happens to
# carry — it is a glossary entry, and the parenthetical reminder text printed on
# every card that grants one ("bear form (Has protector. Destroy this card when
# you strike with a weapon or play a non-Feral ability.)") is restating THIS,
# not saying anything card-specific. So the properties live here, keyed on the
# name, and a card grants them by declaring `form_state:<name>` and nothing more.
#
# That is what makes the form name the single source of truth: reading "bear"
# implies protector and the Feral break, with no way for a card to declare the
# state and forget the grant. Before this table each Form card repeated
# `hero_has_protector|form_break:Feral` by hand, and omitting either silently
# produced a bear form that didn't protect or couldn't break.
#
# Entry fields (all optional):
#   keywords            Array  — keywords granted to the controller's HERO
#   atk_while_attacking int    — +N ATK to the HERO while it is attacking
#   break_tag           String — `form_break` tag: destroyed when its controller
#                                strikes with a weapon or plays an ability
#                                WITHOUT this tag. "" / absent = never breaks
#                                that way (Travel Form).
#
# It lives on GameState, beside hero_form_states, because being in a form IS
# game state and a continuous modifier has to read both from inside get_atk —
# and GameState must not depend on StackResolver.
#
# NOT for unnamed forms: Shadowform occupies the Form (1) slot but declares no
# `form_state`, and its inverted break (`form_break_on:Holy`) is genuinely its
# own text. Such cards keep their explicit segments.
const FORM_GRANTS := {
	"bear": {"keywords": ["protector"], "break_tag": "Feral"},
	"cat": {"atk_while_attacking": 1, "break_tag": "Feral"},
}


# The FORM_GRANTS entry for a form name, or {} when the name is unknown.
static func form_grants(form_name: String) -> Dictionary:
	if form_name == "":
		return {}
	return FORM_GRANTS.get(form_name.to_lower(), {})


# Every form name a DEF declares its controller's hero to be in (`form_state:X`).
# The def-side half of hero_form_states, split out so the resolver can ask what
# a card in hand would grant without it being in play yet.
static func def_form_states(def: CardDef) -> Array:
	var names: Array = []
	if not def or def.effects == "":
		return names
	for entry in def.effects.split("|"):
		var parts := entry.strip_edges().split(":")
		if parts.size() > 1 and parts[0].strip_edges() == "form_state":
			var n := parts[1].strip_edges().to_lower()
			if n != "" and not (n in names):
				names.append(n)
	return names


# ── Form state ("your hero is in bear form") ──────────────────────────────────
# Every form name the player's in-play Form cards declare their hero to be in.
# The single implementation of that read: StackResolver.hero_is_in_form (the
# gate for Thangal's power, Feral Rage's trigger and Natural Defenses' aura)
# delegates here, so a card keying on the form by NAME and an aura keying on it
# can never disagree. Live scan of the hero_row, so the answer changes the
# instant a Form arrives or breaks.
#
# It lives on GameState rather than on StackResolver because a continuous
# modifier has to ask it from inside get_atk, and GameState must not depend on
# the resolver.
func hero_form_states(player_id: String, db) -> Array:
	var names: Array = []
	if not db:
		return names
	for card in cards_in_zone(player_id + "_hero_row"):
		for n in def_form_states(effective_def(card.instance_id, db)):
			if not (n in names):
				names.append(n)
	return names


# True when a form the player's hero is currently in grants `keyword` to it
# (FORM_GRANTS → "keywords"). Read live off hero_form_states, so the grant lifts
# the instant the Form leaves play by any route — a break, a destroy, a second
# Form sacrificed to the 414.3b slot check. StackResolver._has_keyword funnels
# every hero keyword question through this, so bear form's protector needs no
# flag on the card and no branch of its own in get_legal_protectors.
func hero_form_keyword(player_id: String, keyword: String, db) -> bool:
	if keyword == "":
		return false
	for form_name in hero_form_states(player_id, db):
		if keyword in form_grants(form_name).get("keywords", []):
			return true
	return false


# Total "+N ATK while attacking" the player's live forms grant their hero
# (FORM_GRANTS → "atk_while_attacking") — cat form's +1. Summed across forms
# rather than short-circuited: the Form (1) slot allows only one today, but the
# arithmetic should not be the thing that assumes it. Defender-INdependent, so
# it is safe inside assume_attacking forecasts and the get_legal_attackers hero
# gate (unlike Bala's atk_vs_exhausted_defender). Never cached.
func hero_form_atk_while_attacking(player_id: String, db) -> int:
	var total := 0
	for form_name in hero_form_states(player_id, db):
		total += int(form_grants(form_name).get("atk_while_attacking", 0))
	return total


func _aura_atk_mods(inst: CardInstance, is_attacking: bool, db) -> int:
	var bonus := 0
	var def: CardDef = effective_def(inst.instance_id, db)
	var inst_zone := zones.get(inst.zone_id) as Zone
	var inst_is_ally := inst_zone != null and inst_zone.zone_type == "ally_row"
	for source in cards_in_zone(inst.controller + "_ally_row"):
		var src_def: CardDef = effective_def(source.instance_id, db)
		if not src_def:
			continue
		for seg in src_def.effects.split("|"):
			var p := seg.split(":")
			match p[0]:
				"party_atk_while_attacking":
					# Zorm Stonefury: "+X ATK while attacking" to your allies
					# (including the source itself) — card text says "allies",
					# so a hero attacking (with or without a weapon) does NOT
					# get this bonus. Stacks with multiple copies.
					if is_attacking and inst_is_ally:
						bonus += int(p[1]) if p.size() > 1 else 1
	for source in cards_in_zone(inst.controller + "_hero_row"):
		var src_def2: CardDef = effective_def(source.instance_id, db)
		if not src_def2:
			continue
		for seg in src_def2.effects.split("|"):
			var p := seg.split(":")
			match p[0]:
				"party_allies_atk_mod":
					# Battle Shout: "Ongoing: Allies in your party have +N ATK."
					# Controller-scoped and UNCONDITIONAL (unlike Zorm's
					# party_atk_while_attacking above, which only counts while
					# attacking), so it also applies while defending, protecting
					# and retaliating. "Allies in your party" is the controller's
					# ally_row read live, so TOTEMS are included (305.3a) while
					# the HERO and hero_row equipment are not. Stacks per copy;
					# lifts the instant the source leaves play. Never cached.
					if inst_is_ally:
						bonus += int(p[1]) if p.size() > 1 else 1
				"pet_atk_health_aura":
					# Master of the Hunt: "Ongoing: Your Pets have +X ATK and
					# +Y health." Lives in the hero row (rule 305.2c).
					if def and def.card_subtype == "Pet":
						bonus += int(p[1]) if p.size() > 1 else 0
				"hero_atk_while_attacking_in_form":
					# Predatory Strikes: "While your hero is in bear form or cat
					# form, it has +2 ATK while attacking." Cat Form's grant
					# below, gated on WHICH form the hero is in — field 1 is a
					# `+`-joined list of qualifying form names, so one segment
					# covers "bear form or cat form". The form is read LIVE, so
					# shapeshifting switches the bonus on and breaking the form
					# drops it, mid-combat included.
					#
					# Like the ungated version this is defender-INdependent, so
					# it is safe inside assume_attacking forecasts and inside the
					# get_legal_attackers hero gate (unlike Bala's
					# atk_vs_exhausted_defender). Hero only, never an ally, and
					# it applies whichever Form card grants the state — the
					# aura and the Form need not be the same card. Never cached.
					if is_attacking and p.size() > 2:
						var f_ps := players.get(inst.controller) as PlayerState
						if f_ps and f_ps.hero_instance_id == inst.instance_id:
							var in_form := false
							var live_forms := hero_form_states(inst.controller, db)
							for want in p[1].split("+"):
								if want.strip_edges().to_lower() in live_forms:
									in_form = true
							if in_form:
								bonus += int(p[2])
				"hero_atk_while_attacking_per_counter":
					# Blood Fury: "Ongoing: Your hero has +1 ATK while attacking
					# for each fury counter on Blood Fury." Cat Form's grant
					# below, scaled by a COUNTER count read live off the source
					# card (field 1 is the counter name, field 2 the per-counter
					# amount). Nothing adds or removes fury counters after the
					# card enters play — unlike Berserking, which cashes its own
					# in when the hero attacks — so the bonus is fixed for as
					# long as the card is in play, and stacks per copy.
					#
					# Like the ungated version this is defender-INdependent, so
					# it is safe inside assume_attacking forecasts and inside the
					# get_legal_attackers hero gate (unlike Bala's
					# atk_vs_exhausted_defender). Hero only, never an ally, and
					# controller-scoped ("YOUR hero"). Never cached.
					if is_attacking and p.size() > 2:
						var c_ps := players.get(inst.controller) as PlayerState
						if c_ps and c_ps.hero_instance_id == inst.instance_id:
							var n := int(source.counters.get(p[1].strip_edges(), 0))
							bonus += n * int(p[2])
				"hero_atk_while_attacking":
					# Cat Form: "Your hero is in cat form. (+1 ATK while
					# attacking.)" — the ongoing Form in the hero row grants the
					# HERO (only) +N while attacking. Defender-independent, so
					# it's safe inside assume_attacking forecasts and the
					# get_legal_attackers hero gate (unlike Bala's
					# atk_vs_exhausted_defender). Never cached.
					if is_attacking:
						var owner_ps := players.get(inst.controller) as PlayerState
						if owner_ps and owner_ps.hero_instance_id == inst.instance_id:
							bonus += int(p[1]) if p.size() > 1 else 1
	# Form-derived hero ATK (cat form's "+1 ATK while attacking"). Sourced from
	# the FORM_GRANTS table keyed on the form NAME, not from a segment on the
	# Form card — so Cat Form and Claw both grant it by declaring `form_state:cat`
	# and nothing else. The explicit `hero_atk_while_attacking` arm above stays
	# for a future NON-form card printing the same grant; no shipped card carries
	# both, so there is nothing to double-count.
	if is_attacking:
		var form_ps := players.get(inst.controller) as PlayerState
		if form_ps and form_ps.hero_instance_id == inst.instance_id:
			bonus += hero_form_atk_while_attacking(inst.controller, db)
	bonus += _opposing_atk_aura(inst, inst_is_ally, db)
	bonus += _marked_target_atk_aura(inst, inst_is_ally, db)
	return bonus


# ATK bonus from an ATTACHMENT the card's controller owns that buffs attacks
# against its host (`party_atk_vs_attached:N` — Marked for Death: "Allies in your
# party have +1 ATK while attacking attached character").
#
# Two live conditions, both re-read at every get_atk:
#   * this card is the actual combat attacker, and
#   * the current defender IS the attachment's host.
# So it is defender-dependent exactly like atk_vs_exhausted_defender, which is
# why it deliberately does NOT key on `is_attacking`: an assume_attacking
# forecast has no defender yet and must not claim the bonus. (Same known limit —
# the attack cursor can't preview it. The damage still lands at the conclusion.)
#
# "Allies in your party" is literal: the scan is the affected card's own
# controller's attachments, and a HERO attacking never gets it. Stacks per copy,
# and lifts the instant the attachment leaves play (its host dying takes it with
# it, per 400.5).
func _marked_target_atk_aura(inst: CardInstance, inst_is_ally: bool, db) -> int:
	if not db or not inst_is_ally or inst.instance_id != combat_attacker \
			or combat_defender == "":
		return 0
	var bonus := 0
	for source in cards_in_zone("attached"):
		if source.controller != inst.controller or source.attached_to != combat_defender:
			continue
		var src_def: CardDef = effective_def(source.instance_id, db)
		if not src_def or src_def.effects == "":
			continue
		for seg in src_def.effects.split("|"):
			var p := seg.split(":")
			if p[0] == "party_atk_vs_attached":
				bonus += int(p[1]) if p.size() > 1 else 1
	return bonus


# ATK modifier this card receives from OTHER players' static "opposing" auras
# (`opposing_characters_atk_mod:N` — Hootie: "Opposing heroes and allies have
# -1 ATK"). Controller-relative, so unlike Lust for Battle's board-wide
# _ally_keyword_aura this scans every player EXCEPT this card's controller.
#
# "Heroes and allies" is characters only: weapons live in the hero row and have
# printed ATK of their own (rule 303), so the gate below keeps the aura off
# them — otherwise Hootie would silently weaken every opposing weapon too.
# Stacks per copy; the caller's max(atk, 0) floor keeps ATK non-negative while
# leaving the raw value intact. Evaluated live, never cached.
func _opposing_atk_aura(inst: CardInstance, inst_is_ally: bool, db) -> int:
	if not db:
		return 0
	var ps := players.get(inst.controller) as PlayerState
	var is_hero := ps != null and ps.hero_instance_id == inst.instance_id
	if not inst_is_ally and not is_hero:
		return 0
	var bonus := 0
	for pid in players:
		if pid == inst.controller:
			continue
		for zone_suffix in ["_hero_row", "_ally_row"]:
			for source in cards_in_zone(pid + zone_suffix):
				var src_def: CardDef = effective_def(source.instance_id, db)
				if not src_def or src_def.effects == "":
					continue
				for seg in src_def.effects.split("|"):
					var p := seg.strip_edges().split(":")
					var key := p[0].strip_edges()
					if key == "opposing_characters_atk_mod" and p.size() > 1:
						bonus += int(p[1])
					# Demoralizing Shout: "Ongoing: Opposing allies have -N ATK."
					# Hootie's aura narrowed to ALLIES — an opposing HERO is
					# untouched, which is the whole difference between the two
					# keys. Totems are ally_row cards, so they get it (305.3a).
					elif key == "opposing_allies_atk_mod" and p.size() > 1 and inst_is_ally:
						bonus += int(p[1])
	return bonus

func get_max_hp(instance_id: String, db) -> int:
	var inst := get_card(instance_id)
	if not inst:
		return 0
	var def: CardDef = db.get_def(inst.card_def_id)
	if not def:
		return 0
	var hp := def.printed_health + inst.sum_stat("health")
	hp += _aura_health_mods(inst, db)
	hp += _attachment_stat_mods(inst, db, 2)
	# This card's own printed conditional self-modifier, health half (Kailis
	# Truearc's `buff_while_party_size`) — the same live read as get_atk's, so
	# both stats switch on and off together. A shrinking party can therefore put
	# an already-damaged card at or below 0 HP; that state-based death is swept
	# at the priority gate (StackResolver.drain_state_based_deaths).
	# Off the EFFECTIVE def (700.3), like get_atk's: the grant is a power, so a
	# blanked card keeps only its printed health.
	var hp_eff: CardDef = effective_def(instance_id, db)
	for segment in (hp_eff.effects if hp_eff else def.effects).split("|"):
		var parts := segment.split(":")
		if parts[0] == "buff_while_party_size":
			hp += _party_size_buff(inst, parts, 3)
	return max(hp, 0)


# One conditional self-grant shared by get_atk and get_max_hp:
# `buff_while_party_size:N:ATK:HP` — "+ATK ATK and +HP health while there are N
# or more allies in your party" (Kailis Truearc). The party is the controller's
# ally_row read LIVE, so it counts the source itself (she is an ally in your
# party) and totems too (305.3a), never the hero, and never the opponent's
# board. `field` picks which half to return: 2 = ATK, 3 = health.
func _party_size_buff(inst: CardInstance, parts: PackedStringArray, field: int) -> int:
	if parts.size() <= field:
		return 0
	var needed := int(parts[1])
	if cards_in_zone(inst.controller + "_ally_row").size() < needed:
		return 0
	return int(parts[field])


# Rule 503.2a max hand size, with live attachment modifiers: Arcane Intellect
# ("Ongoing: Attached hero's controller's maximum hand size is increased by
# three", `attached_max_hand:3`) raises it per copy attached to the player's
# hero. Live read — never cached.
func get_max_hand_size(player_id: String, db) -> int:
	var ps := players.get(player_id) as PlayerState
	var max_hand: int = ps.max_hand_size if ps else 7
	var hero := get_hero(player_id)
	if hero and db:
		for att_id in hero.attachments:
			var att := get_card(att_id)
			if not att or att.zone_id != "attached":
				continue
			var att_def: CardDef = db.get_def(att.card_def_id)
			if not att_def:
				continue
			for seg in att_def.effects.split("|"):
				var p := seg.split(":")
				if p[0] == "attached_max_hand" and p.size() > 1:
					max_hand += int(p[1])
	return max_hand


# Sum of one stat granted by this card's attachments' `attached_buff:ATK:HP`
# segments (rule 400 — Mark of the Wild). field: 1 = ATK, 2 = health.
# Live read on every stat query — never cached.
func _attachment_stat_mods(inst: CardInstance, db, field: int) -> int:
	var bonus := 0
	for att_id in inst.attachments:
		var att := get_card(att_id)
		if not att or att.zone_id != "attached":
			continue
		var att_def: CardDef = db.get_def(att.card_def_id)
		if not att_def:
			continue
		for seg in att_def.effects.split("|"):
			var p := seg.split(":")
			if p[0] == "attached_buff" and p.size() > field:
				bonus += int(p[field])
	return bonus

# Sum of max-health bonuses this card receives from static "aura" sources in
# its controller's party — continuous modifiers that live on another card in
# play and affect a dynamic set. New party health auras add a match arm here.
func _aura_health_mods(inst: CardInstance, db) -> int:
	var bonus := 0
	var def: CardDef = db.get_def(inst.card_def_id)
	if def and def.card_type == "Hero":
		# "Ongoing: Your hero has +N health." (Last Stand) — the ONLY health aura
		# that reaches a hero, so it is answered here and the ally-scoped auras
		# below are skipped entirely (they are explicitly "allies in your party"
		# and a hero is not an ally). Controller-scoped: the scan reads only this
		# hero's own controller's hero_row, so the opponent's hero is never
		# touched. Stacks per copy.
		#
		# Read LIVE, never cached, so the bonus lifts the instant the source
		# leaves play — which can leave an already-damaged hero at 0 or fewer
		# effective health. That is a state-based death (118.4/704) and it ENDS
		# THE GAME; it is swept by StackResolver._check_aura_loss_deaths (the
		# source being destroyed) and by drain_state_based_deaths at the priority
		# gate (every other way it could leave play).
		for source in cards_in_zone(inst.controller + "_hero_row"):
			var hero_src: CardDef = effective_def(source.instance_id, db)
			if not hero_src or hero_src.effects == "":
				continue
			for seg in hero_src.effects.split("|"):
				var hp_parts := seg.strip_edges().split(":")
				if hp_parts[0] == "hero_health_bonus" and hp_parts.size() > 1:
					bonus += int(hp_parts[1])
		return bonus
	for source in cards_in_zone(inst.controller + "_ally_row"):
		if source.instance_id == inst.instance_id:
			continue
		var src_def: CardDef = effective_def(source.instance_id, db)
		if not src_def:
			continue
		for seg in src_def.effects.split("|"):
			var p := seg.split(":")
			match p[0]:
				"party_health_aura":
					# Nerra Lifeboon: "Other allies in your party have +X health."
					# "An ally in your party" is the controller's ally_row read
					# live — the same convention as atk_per_damage_party and
					# _party_size_buff — so TOTEMS are included (305.3a: they are
					# ability allies and count as both in all zones), while the
					# hero and hero_row equipment/abilities are not. "Other"
					# excludes only the source, skipped by the loop above.
					if inst.zone_id == inst.controller + "_ally_row":
						bonus += int(p[1]) if p.size() > 1 else 1
	for source in cards_in_zone(inst.controller + "_hero_row"):
		var src_def2: CardDef = effective_def(source.instance_id, db)
		if not src_def2:
			continue
		for seg in src_def2.effects.split("|"):
			var p := seg.split(":")
			match p[0]:
				"pet_atk_health_aura":
					# Master of the Hunt: "Ongoing: Your Pets have +X ATK and
					# +Y health." Lives in the hero row (rule 305.2c).
					if def and def.card_subtype == "Pet":
						bonus += int(p[2]) if p.size() > 2 else 0
	return bonus

func get_current_hp(instance_id: String, db) -> int:
	var inst := get_card(instance_id)
	if not inst:
		return 0
	return max(get_max_hp(instance_id, db) - inst.damage_taken, 0)

# Cost of playing a card from hand, after applying any cost-reduction buffs.
# For X-cost cards (Aimed Shot, cost "1+X") the announced X (action params
# "x_value") must be passed in — the printed cost alone is cost_base.
func get_play_cost(instance_id: String, db, x: int = 0) -> int:
	var inst := get_card(instance_id)
	if not inst:
		return 0
	var def: CardDef = db.get_def(inst.card_def_id)
	if not def:
		return 0
	if def.cost_x:
		return _next_card_discount(inst,
			_type_cost_auras(inst, def, max(def.cost_base + x + inst.sum_stat("cost"), 0), db))
	return _next_card_discount(inst,
		_type_cost_auras(inst, def, max(def.cost + inst.sum_stat("cost"), 0), db))


# Nature's Swiftness: "You pay (5) less to play your next card this turn."
# A one-shot, player-scoped, this-turn discount held on PlayerState and read
# here — the single choke point every cost path goes through (affordability
# gating, payment, refund, the AI's cost math, the router's preview), so the
# discount covers all of them at once. Applied AFTER Elemental Focus' aura and
# floored at 0: EF's "to a minimum of (1)" restricts EF's own reduction, not a
# later one. Consumed at chain entry by whichever card is played next (see
# StackResolver.submit_action), so while it is live it shows on EVERY card in
# hand — any one of them could be the next card played.
func _next_card_discount(inst: CardInstance, cost: int) -> int:
	var ps := players.get(inst.controller) as PlayerState
	if not ps or ps.next_card_cost_mod == 0:
		return cost
	return max(cost + ps.next_card_cost_mod, 0)


# The play-cost auras, in one place: Elemental Focus' tag-filtered ability
# discount and Diplomacy's card-type-filtered ally discount. Both are read LIVE
# off the costed card's controller's hero_row, so neither is ever cached.
func _type_cost_auras(inst: CardInstance, def: CardDef, cost: int, db) -> int:
	return _ally_cost_aura(inst, def, _ability_cost_aura(inst, def, cost, db), db)


# Diplomacy: "Ongoing: You pay (1) less to play allies, to a minimum of (1)."
# Recipe `ally_cost_mod:DELTA:FLOOR` — Elemental Focus' aura with the type-line
# TAG filter swapped for a card-TYPE one. "Allies" is CardDef.is_ally_card, so a
# Totem card counts (305.3a) and an Instant Ally does too; an Ability, Equipment
# or Quest never does. Controller-scoped ("YOU pay"), so the opponent's allies
# are untouched, and stacks per copy in play. As with Elemental Focus the FLOOR
# is on the REDUCTION, not on the cost: a printed-0 or printed-1 ally is returned
# untouched (never raised), the discount simply can't take a dearer one below it.
func _ally_cost_aura(inst: CardInstance, def: CardDef, cost: int, db) -> int:
	if not db or not def.is_ally_card():
		return cost
	var delta := 0
	var floor_cost := 0
	for c in cards_in_zone(inst.controller + "_hero_row"):
		var a_def: CardDef = effective_def(c.instance_id, db)
		if not a_def:
			continue
		for seg in a_def.effects.split("|"):
			var p := seg.strip_edges().split(":")
			if p[0] != "ally_cost_mod" or p.size() < 3:
				continue
			delta += int(p[1])
			floor_cost = max(floor_cost, int(p[2]))
	if delta == 0 or cost <= floor_cost:
		return cost
	return max(cost + delta, floor_cost)


# Elemental Focus: "Ongoing: You pay (1) less to play Elemental abilities, to a
# minimum of (1)." Recipe `ability_cost_mod_by_tag:TAG:DELTA:FLOOR`, read LIVE
# off the card controller's hero_row (never cached) — so it covers cards drawn
# after the aura resolved and lifts the instant the aura leaves play.
# The floor is on the REDUCTION, not on the cost: a printed-0 or printed-1
# ability is left alone entirely (the early return), the discount simply can't
# take a more expensive one below FLOOR. TAG matches the def's type line by
# substring the way form_break does — but the CSV splits a type line across TWO
# columns (subtype_detail is card_def.gd:46 "tags"; subtype is card_def.gd:50),
# and the school name (e.g. "Instant Ability — Elemental, Shaman") lands in
# `card_subtype`, not `tags` — `tags` only carries it for a "TAG Talent" card
# (Elemental Focus itself: "Elemental Talent"). Both are checked so a plain
# Elemental ability (Purge, Lightning Bolt, Earthbind/Searing Totem — 305.3a,
# a Totem's type line carries the school in card_subtype too) is discounted,
# not just a same-named Talent. Stacks per copy in play.
func _ability_cost_aura(inst: CardInstance, def: CardDef, cost: int, db) -> int:
	if not db or def.card_type != "Ability":
		return cost
	var delta := 0
	var floor_cost := 0
	for c in cards_in_zone(inst.controller + "_hero_row"):
		var a_def: CardDef = effective_def(c.instance_id, db)
		if not a_def:
			continue
		for seg in a_def.effects.split("|"):
			var p := seg.strip_edges().split(":")
			if p[0] != "ability_cost_mod_by_tag" or p.size() < 4:
				continue
			var tag := p[1].strip_edges()
			if tag == "" or not (tag in def.card_subtype or tag in def.tags):
				continue
			delta += int(p[2])
			floor_cost = max(floor_cost, int(p[3]))
	if delta == 0 or cost <= floor_cost:
		return cost
	return max(cost + delta, floor_cost)


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
		"token_counter":     token_counter,
		"turn_number":       turn_number,
		"turn_player":       turn_player,
		"phase":             phase,
		"priority_player":   priority_player,
		"turn_events":       turn_events.duplicate(true),
		"damage_watch_index": damage_watch_index,
		"ally_destroy_watch_index": ally_destroy_watch_index,
		"destroy_discard_marks": destroy_discard_marks,
		"draws_locked_this_turn": draws_locked_this_turn,
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
	gs.token_counter      = d.get("token_counter", 0)
	gs.turn_number        = d.get("turn_number", 0)
	gs.turn_player        = d.get("turn_player", "")
	gs.phase              = d.get("phase", "setup")
	gs.priority_player    = d.get("priority_player", "")
	gs.turn_events        = (d.get("turn_events", []) as Array).duplicate(true)
	gs.damage_watch_index = d.get("damage_watch_index", 0)
	gs.ally_destroy_watch_index = d.get("ally_destroy_watch_index", 0)
	for mark in d.get("destroy_discard_marks", []):
		gs.destroy_discard_marks.append(str(mark))
	gs.draws_locked_this_turn = d.get("draws_locked_this_turn", false)
	gs.consecutive_passes = d.get("consecutive_passes", 0)
	for a in d.get("pending_actions", []):
		gs.pending_actions.append(PendingAction.from_dict(a))
	return gs


func _serialize_pending_actions() -> Array:
	var result: Array = []
	for a in pending_actions:
		result.append((a as PendingAction).to_dict())
	return result
