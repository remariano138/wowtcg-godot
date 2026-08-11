# Rules deviations

Engine behavior that intentionally contradicts (or narrows) the printed card
text or `References/wow_rules.txt`, for traceability. Every entry here should
be reflected by a code comment at the enforcement site pointing back to this
file.

Do not add an entry for something that is merely an *implementation detail*
of a rule (e.g. how a window drains priority) — only for cases where the
engine deliberately behaves more restrictively (or more permissively) than
what the rules/card text alone would allow.

---

## For the Horde! (`azeroth_344`)

**Printed text:** "Pay (1) to complete this quest. Reward: Horde allies in
your party have +1 ATK while attacking this turn." No timing restriction is
printed — quest completion is normally usable any time a player has priority
(rule-legal, see `StackResolver._can_use_quest`).

**Deviation:** restricted to the quest controller's own turn
(`require_turn_player` effects flag, checked in
`StackResolver._can_use_quest` via `quest_requires_turn_player`).

**Why:** in a duel, a player can only attack on their own turn, so the
reward can never affect anything if completed off-turn. Letting it be
"legal but useless" off-turn had two costs: (1) it forced players to keep
manually checking/dismissing it every priority window instead of Turbo
autoskip handling their pass, and (2) the AI had to needlessly evaluate a
quest completion action every non-turn priority window with the
`use_quest` branch of `BaseAI.get_reasonable_actions` never doing anything
useful with it.

**Effect of the deviation:** Turbo autoskip can safely skip past this
quest's completion window whenever it's not the controller's turn; the AI
no longer offers/considers it off-turn either (it's simply not a legal
action, so `get_reasonable_actions` never returns it — no special-casing needed
in `base_ai.gd`).

**How to apply this pattern to future cards:** if a quest reward is
timing-gated in a way the printed text doesn't spell out but is true by
construction of the duel format (e.g. anything referencing "attacking",
"defending", or "this combat"), add `require_turn_player` to its `effects`
string and add an entry here — don't hardcode the card id in
`stack_resolver.gd`.

---

## Rayder (`azeroth_45`)

**Printed text:** "[activate] -> Allies in your party have +2 ATK while
attacking this turn." No "use only on your turn" clause is printed — ally
activated powers are normally usable on either player's turn by default
(see the "No turn_player restriction" convention note in
`StackResolver._can_use_ally_power`, e.g. Grimdron blocking during an
opponent's attack/defend window).

**Deviation:** restricted to Rayder's controller's own turn, via the
existing `on_your_turn` effects segment (reused from the genuine "use only
on your turn" printed-text convention, e.g. Acolyte Demia — see
`StackResolver._can_use_ally_power`).

**Why:** the buff only affects allies "while attacking," which can only
happen on the controller's turn in a duel — so activating it off-turn is
always a no-op reward-wise, while still exhausting Rayder. An exhausted
ally is a strictly worse board state against effects that punish exhausted
characters (e.g. destroy-exhausted-ally effects), so the AI would
sometimes activate the power off-turn for zero benefit and a real
downside. Restricting it to the controller's turn removes that trap for
both the AI and Turbo autoskip.

**How to apply this pattern to future cards:** if an ally/equipment
activated power's only effect is conditioned on something that's only ever
true on the controller's turn (e.g. "while attacking"), add `on_your_turn`
to its `effects` string and add an entry here. Note this reuses the same
flag as genuine "use only on your turn" printed text (Acolyte Demia) —
the effects string alone doesn't distinguish printed restriction from
engine deviation, which is exactly why this file exists.

---

## Infernal (`azeroth_127`)

**Printed text:** "At the start of your turn, discard a card, or target
opponent gains control of Infernal."

**Rule 501.1a:** "at the start of [this turn]" triggers fire during the
ready step, and the ready step's priority window must close (with nothing
left to resolve) before the draw step begins. In paper play, a start-of-turn
trigger like this one is added to the chain like any other triggered
ability — players get a priority window in which to respond with instants
*before* the triggered effect resolves and the discard-or-give-control
choice is actually made.

**Deviation:** the engine resolves the trigger immediately, with no
priority window before the choice is made — `TurnManager._enter_ready` sets
`pending_control_discard_player`/`_ids` and the choice must be resolved via
`StackResolver.choose_control_discard` / `decline_control_discard` before
anything else can happen (mirrors the pet-sacrifice and enter-play-target
immediate-choice pattern, see `can_submit`'s blocking guard and `CLAUDE.md`
§ "Mandatory immediate-resolution choices"). What's preserved from the
rules: the choice itself still resolves before the ready step's window
closes, so the draw step correctly cannot start until it's made.

**Why:** none of the currently implemented cards can interact with a
start-of-turn trigger before it resolves (no "in response to a trigger"
instants exist yet), so a full chain-based implementation would add
complexity with no observable difference in play. This matches the same
immediate-resolution shortcut already taken for pet uniqueness and
equipment slot uniqueness — both are also start-of-play-action mandatory
choices with no printed response window that matters yet.

**How to apply this pattern to future cards:** if a future card's
start-of-turn (or other) trigger is meant to be respondable — e.g. an
instant that says "in response to a triggered ability" — the immediate-
resolution shortcut here and in the pet/equipment-sacrifice flows will need
to be revisited to actually add the trigger to the chain instead of
resolving it inline.

---

## Searing Totem (`azeroth_116`)

**Printed text:** "Ongoing: At the start of each turn, Searing Totem deals 1
fire damage to target hero or ally."

**Rule 501.1a / 410:** a paper "at the start of each turn" triggered ability is
added to the chain during the ready step, with its target chosen and a priority
window before it resolves.

**Now chain-based (respondable):** `TurnManager._collect_ongoing_turn_triggers`
(called from `_enter_ready`) queues each in-play Totem's trigger (turn player's
first — 501.1a) and opens a mandatory target choice resolved via
`StackResolver.choose_totem_target()`. The target choice is still a direct-call
point (`pending_totem_target_player` hard-blocks `can_submit` / `pass_priority`
while open — the target is chosen as the trigger goes on the chain, 410). Once
picked, the trigger becomes a `resolve_totem_trigger` **chain link** and a normal
priority window opens (turn player first); either player may respond with an
instant (heal the target, use its activated power) before the damage lands.
`_resolve_totem_trigger` re-checks the target (709.2a) and deals the damage
through the prevention pipeline (717.2c); the `totem_next` after-hook then opens
the next queued trigger, so triggers drain one window at a time.

**Remaining minor deviations:**

1. **Sequential windows, not one shared window.** Paper puts ALL simultaneous
   start-of-turn triggers on the chain at once (turn player orders theirs), then a
   single priority window. The engine chooses each trigger's target, opens a
   window, resolves it, then moves to the next — a window *after each* trigger
   rather than one window over all of them. Observably this only differs with
   multiple simultaneous totems and gives *more* interaction points, not fewer;
   501.1a firing order (turn player first) is preserved.

2. **AI doesn't respond in the window.** Per the AI convention, the non-turn AI
   passes every priority window (`get_reasonable_actions` returns nothing for the
   non-turn player), so an AI opponent won't heal/save an ally its opponent's
   totem targets. A HUMAN opponent gets the full window. Extending the window AI
   to defensive instant plays is the same open item noted for combat windows.

**How to apply this pattern to future cards:** an ongoing "start of each turn"
targeted-damage Totem uses the `ongoing|totem[:element]|ongoing_damage_each_turn:AMOUNT:TYPE`
recipe and is respondable for free via the chain path above.

---

## Watcher Mal'wi (`azeroth_269`)

**Printed text:** "When an opposing ally enters play, Watcher Mal'wi deals 1
ranged damage to it."

**Rule 501.1a / 410:** this is a triggered ability that, in paper play, is
added to the chain when the opposing ally enters play, with a priority window
before the 1 damage is dealt.

**Deviation:** the engine resolves the ping immediately, inline in
`StackResolver._bring_ally_into_play` (the same place the entering ally's own
`on_enter` effects resolve), with no chain link or priority window. Any
in-play card an *opponent of the entering ally* controls with the
`damage_opposing_ally_on_enter:AMOUNT:DMG_TYPE` flag deals its damage, then the
entering ally is checked for destruction.

**Why:** identical reasoning to Infernal / Searing Totem — no implemented card
can respond to a triggered ability before it resolves, and `on_enter` enter-play
effects already resolve inline, so a chain-based implementation would add
complexity with no observable difference. (`deal_damage` doesn't track a
combat/effect damage type, so the `:ranged` field is flavor only.)

**How to apply this pattern to future cards:** a "when an opposing ally enters
play, deal N to it" trigger uses the data-driven
`damage_opposing_ally_on_enter:N:TYPE` flag — no card id is hardcoded in
`stack_resolver.gd`. If a future trigger must be respondable, the chain-based
rework noted under Infernal applies here.

**Same deviation, same site — Stone Guard Rashun (`dark_portal_234`),** "When an
opposing ally enters play, exhaust it" (`exhaust_opposing_ally_on_enter`): also
resolved inline with no chain link or priority window, in the same watcher loop.

**Totems and tokens both trigger these watchers — this is NOT a deviation, it's
rule 305.3a:** "Totems are ability allies and count as both in all zones", so an
entering opposing Totem is an entering opposing ally. Because a Totem resolves
via `_resolve_play_ongoing_ability` straight into the ally_row and never passes
through `_bring_ally_into_play`, the watcher scan lives in its own function,
`StackResolver.fire_opposing_ally_enter_watchers`, called from **both** entry
paths. A new "opposing ally enters play" trigger must be added to that function
rather than inline in either caller, or it will silently miss Totems. Tokens
(Mya's Mechanical Dragonling, Tooga) need no special handling —
`_put_token_into_play` brings them in through `_bring_ally_into_play`.

---

## Windseer Tarus (`azeroth_271`)

**Printed text:** "When Windseer Tarus attacks for the first time each turn,
you may pay (1). If you do, ready him."

**Rule 501.1a / 602.1:** in paper play this triggered ability goes on the chain
as the combat step starts, with a priority window before its "may pay (1)"
choice is made.

**Deviation:** the engine resolves it immediately as a mandatory-style pending
choice, mirroring the weapon strike point (602.1). In
`StackResolver._resolve_propose_combat`, after the attacker exhausts and before
the attack window opens, `_open_ready_on_attack_point` sets
`pending_ready_player`/`_card_id`/`_cost` and emits `ready_on_attack_opened`;
`pending_ready_player` hard-blocks `can_submit` / `pass_priority` until resolved
via `StackResolver.choose_ready_on_attack(state, pay, db)` (a direct call, like
`choose_strike`). Readying happens inline (the attacker stays the
`combat_attacker`, so this combat proceeds; it's ready again afterward). The
"first time each turn" gate is the `attacked_this_turn` card counter, set when
the point opens and cleared at each turn's ready step.

**Why:** identical reasoning to the strike point it's modeled on — no
implemented card responds to the trigger before its choice, so a chain-based
implementation would add complexity with no observable difference.

**How to apply this pattern to future cards:** a "when this attacks for the
first time each turn, you may pay X to ready it" trigger uses the data-driven
`ready_on_attack:COST` flag — no card id is hardcoded in `stack_resolver.gd`.

**Windfury Totem (`azeroth_118`)** grants the same trigger party-wide via the
`party_ready_on_attack:COST` flag: `_open_ready_on_attack_point` falls back to
`_party_ready_on_attack_cost` (the lowest such flag among the controller's
in-play cards) when the attacker has no own `ready_on_attack`. Both sources
share the ONE `attacked_this_turn` card counter, so a character covered by both
(Windseer Tarus under a Windfury Totem) still readies at most once per turn — it
can attack + ready once, never three attacks over.

---

## Windfury Weapon (`azeroth_119`) — ready-on-strike point

**Card text:** "Attach to one of your Melee weapons. Ongoing: When you strike
with attached weapon for the first time each turn, you may pay (1). If you do,
ready that weapon and your hero."

**Rule 303.2 / 602.1 / 602.3:** in paper play this triggered ability goes on the
chain as you strike, with a priority window before its "may pay (1)" choice.

**Deviation:** the engine resolves it immediately as a pending choice, exactly
like the ready-on-attack point it mirrors. Inside `StackResolver.choose_strike`,
after a successful strike, `_open_strike_ready_point` (the struck weapon carries
a `ready_on_strike:COST` attachment, first strike this turn, affordable) sets
`pending_strike_ready_*` and emits `ready_on_strike_opened`; `can_submit` /
`pass_priority` hard-block until resolved via
`StackResolver.choose_ready_on_strike(state, pay, db)` (direct call). Paying
readies the weapon AND the striking hero inline, then opens the held combat
window (the side the strike was in). The "first time each turn" gate is the
`windfury_struck_this_turn` weapon counter, set when the point opens and cleared
at each turn's ready step.

**Why:** identical reasoning to the strike / ready-on-attack points — no
implemented card responds before the choice, so a chain implementation adds
complexity with no observable difference.

---

## Donna Calister (`azeroth_181`)

**Printed text:** "When an opposing hero or ally attacks, ready Donna Calister."

**Rule 703 / 708:** in paper play this triggered power creates a triggered
effect that goes on the chain as the attack happens, resolving with a priority
window.

**Deviation:** the engine resolves it immediately in
`StackResolver._resolve_propose_combat`, right after `combat_started` is emitted
and before the strike point / attack window. `_ready_on_opposing_attack` scans
the non-attacking player's ally_row + hero_row for the data-driven
`ready_on_opposing_attack` effect flag and calls `GameLogic.ready_card` on each.
No pending choice — the effect is non-targeted with no cost, so there is nothing
to decide. Readying before the attack window means she is available to protect
the very combat that triggered her (the intended use).

**Why:** the effect has no target and no cost, and no implemented card responds
to the trigger before it resolves, so a chain-based implementation would add
complexity with no observable difference.

**How to apply this pattern to future cards:** a "when an opposing hero/ally
attacks, ready this" trigger uses the `ready_on_opposing_attack` effects flag —
no card id is hardcoded in `stack_resolver.gd`.

---

## Morik (`dark_portal_224`)

**Printed text:** "When Morik attacks, each player draws a card."

**Rule 703 / 708:** in paper play this triggered power creates a triggered effect
that goes on the chain as the attack happens, resolving with a priority window
before the cards are drawn.

**Deviation:** the engine resolves it immediately in
`StackResolver._resolve_propose_combat`, right after `combat_started` is emitted
and before the strike point / attack window — the same site and for the same
reason as Donna Calister above. `_fire_attack_draw_each_player` reads the
data-driven `on_attack_draw_each_player:N` flag off the ATTACKER's own def, so it
fires only when the flagged card is itself attacking.

**Why:** the effect has no target, no cost and no choice, so a chain-based
implementation would add complexity with no observable difference. The only
visible consequence of the timing is that both players hold the drawn card
during the attack/defend windows and may play it there — which is what the
printed timing gives you anyway, since the trigger resolves before those windows
open.

**Draw order:** "each player" is resolved in turn order — the attacker's
controller first, then the opponent. This only matters when both players would
be decked by the same trigger; the forced draws go through `GameLogic.draw_one`,
so the decked rule (410.6b) applies normally and attacking with Morik on an
empty deck loses you the game.

**How to apply this pattern to future cards:** an on-attack, non-targeted,
costless trigger belongs inline at this site behind its own effects flag — do
not hardcode a card id in `stack_resolver.gd`.

---

## Frostbolt / Frost Shock — AI ignores the "can't attack (or protect)" rider

**Cards:** Frostbolt (`azeroth_56`, 3 frost) and Frost Shock (`azeroth_109`,
2 frost). Printed text: "Your hero deals N frost damage to target hero or ally.
A character dealt damage this way can't attack this turn." (Frost Shock adds
"or protect".)

**Implemented:** the damage AND the restriction rider. The recipe carries an
optional 4th field on `deal_damage_to_target` — `deal_damage_to_target:3:frost:cannot_attack`
(Frostbolt), `deal_damage_to_target:2:frost:cannot_attack+cannot_protect`
(Frost Shock). On resolution, a character that survives the damage gets a
restriction Buff (duration `turns:1`, swept at end of turn) via
`_apply_damage_riders`, reusing the same `cannot_attack` / `cannot_protect`
machinery as Litori Frostburn's `target_cant_attack` flip. `cannot_protect` is
enforced in `get_legal_protectors`.

**Deviation:** only the AI heuristic ignores the rider. Both cards stay tagged
`combat_instant_dmg`, so the AI plays them purely as targeted-damage combat
instants — it does not value or plan around the "can't attack / protect"
effect. Rules-correct in the engine; simply not modeled in AI scoring.

---

## Augustus Corpsemonger — the 3 exiled graveyard allies are auto-chosen

**Card:** Augustus Corpsemonger (`azeroth_177`, 5-cost Ally). Printed text:
"[Activate], Remove three ally cards in your graveyard from the game: Destroy
target ally." Recipe `activated_power:0:destroy_ally:0::ally:rfg_allies:3`.

**Deviation:** rule 216.2 lets the paying player choose *which* three ally
cards leave their graveyard. The engine instead removes the first three ally
cards in graveyard order automatically (`rfg_allies` payment in
`_resolve_use_ally_power`) — the player picks only the destroy target, not the
cost.

**Why:** no implemented card cares which specific cards sit in the RFG zone
vs. the graveyard (nothing recurs a *named* card from either), so exposing a
second multi-select just for the cost adds UI/flow complexity with no
observable difference. The count and the type filter (Ally only) are still
enforced, so the cost's legality is exact — only the identity of the exiled
cards is auto-picked. If a future card ever returns a specific card from
either zone, wire the graveyard-select UI (already used by quests) to this
cost and drop this deviation.

---

## Hypnotic Blade — "target player" is auto-chosen as the opponent

**Card:** Hypnotic Blade (`azeroth_327`, 2-cost Weapon—Dagger). Printed text:
"3, [Activate], Exhaust your hero → Target player discards a card. Use only
on your turn." Recipe
`equipment:melee_weapon:0|weapon:1|power_weapon|activated_power:3:discard_opponent:1:::exhaust_hero|on_your_turn`.

**Deviation:** the printed text targets any player — including yourself. The
`discard_opponent` effect (shared with Mias the Putrid, whose printed text has
the same wording) always targets the opponent, with no target choice.

**Why:** in the duel format there are only two players, and forcing your OWN
discard with a 3-cost activation is never useful; no implemented card rewards
self-discard. If a discard-synergy card ever appears, generalize
`discard_opponent` to a targeted `discard_player` with a real target pick and
drop this deviation. Enforcement site: `_resolve_use_ally_power`
("discard_opponent" branch) in `game_logic/stack_resolver.gd`.

---

## Attack-exhaust triggers — resolved immediately, not on the chain

**Cards:** Chops (`dark_portal_32`), Voss Treebender (`azeroth_266`). Printed
text: "When [this] attacks, you may exhaust target hero or ally." Recipe flag
`on_attack_exhaust_target`.

**Deviation:** by the rules this is a triggered effect (703/708) that should
be ADDED TO THE CHAIN as the attack window opens (602.1) — targeted at
announce, respondable, resolvable after responses. The engine instead resolves
it as a direct-call choice point (`pending_attack_exhaust_*`,
`choose_attack_exhaust`) at combat-step start, after the strike /
ready-on-attack points and BEFORE the attack window opens — the same
immediate-resolution pattern as Windseer Tarus. The opponent cannot respond
to the trigger itself (they still get the full attack window afterward).

**Why:** the engine has no generic chain-based triggered-effect machinery yet;
every triggered choice (strike, Windseer, Whelp Armor, totems) uses direct-call
points. The gameplay-relevant timing is preserved exactly: the exhaust lands
before the protect point (602.2), so exhausting a ready Protector denies the
protect, and exhausting the proposed defender does NOT cancel the combat
(601.3 already passed). Enforcement site: `_open_attack_exhaust_point` /
`choose_attack_exhaust` in `game_logic/stack_resolver.gd`.

---

## Mind Spike / Mind Blast / Dark Cleric Ismantal — AI ignores the discard rider

**Cards:** Mind Spike (`azeroth_82`, 1 shadow), Mind Blast (`azeroth_80`, 2
shadow), Dark Cleric Ismantal (`dark_portal_204`, ally power, 1 shadow).
Printed text: "…deals N shadow damage to target hero or ally. Its controller
discards a card for each damage dealt." Recipe: a `discard_per_damage:1`
segment paired with a `deal_damage_to_target` segment (Mind cards) or an
`activated_power:...:deal_damage_to_target` power (Ismantal).

**Deviation:** the discard is implemented faithfully (the damaged character's
controller discards a card per damage actually DEALT — armor prevention and
405.3 excess-beyond-fatal reduce the count, exactly like Steal Essence's drain
heal). But the AI, which plays these cards for the damage via the normal
targeted-damage machinery (`_targeted_instant_actions` / ally-power actions),
does NOT model the extra discard when scoring — it treats them as plain damage.

**Why:** the discard is a strict bonus on a card the AI already values for its
damage, so ignoring it never causes a wrong play, only a slight undervaluation.
Enforcement site: `_apply_discard_per_damage` in `game_logic/stack_resolver.gd`
(called from the `deal_damage_to_target` branches of `_resolve_play_instant`
and `_resolve_use_ally_power`).

---

## Boneshanks — death trigger resolved immediately, not on the chain

**Card:** Boneshanks (`dark_portal_201`, 3-cost 3/2 Horde Undead Warrior Ally).
Printed text: "When Boneshanks is destroyed, destroy target ally." Recipe flag
`on_destroyed:destroy_target:ally`.

**Deviation:** by the rules this is a triggered ability (703) that should be
ADDED TO THE CHAIN when Boneshanks is destroyed — targeted at trigger time,
respondable, resolved after responses. The engine instead resolves it as a
direct-call mandatory choice (`pending_death_triggers` queue +
`pending_death_target_player`, resolved via `choose_death_target`) fired at the
moment of destruction, the same immediate-resolution pattern as the totem
start-of-turn trigger. The opponent cannot respond to the trigger itself. The
choice is mandatory whenever any ally is in play (it may be forced onto the
controller's own board); it fizzles only when no ally exists.

**Hotseat:** unlike some off-screen choices that auto-resolve on the shared
screen, this one is PROMPTED for a human controller even when they are the
off-screen player — the router is pointed at the controller for the pick. This
is safe because the choice is fully board-public (no hidden hand information).

**Why:** the engine has no generic chain-based triggered-effect machinery yet;
every triggered choice (strike, totems, Whelp Armor, attack-exhaust) uses
direct-call points. Enforcement site: `_fire_on_destroyed` (`destroy_target`
branch) / `_open_next_death_trigger` / `choose_death_target` in
`game_logic/stack_resolver.gd`.

---

## Armor prevention — packet pipeline

**Rule:** 717.2c — each ready equipment with DEF ≥ 1 generates an optional
prevention modifier usable against ANY preventable damage packet that would be
dealt to the controller's hero, at the moment the packet would be dealt.

**Engine model:** rules-faithful via the packet pipeline. Effect resolutions
never call `GameLogic.deal_damage` directly — they hand packets to
`StackResolver.defer_packets`, which opens the prevention point
(`choose_prevention`, direct call, never the chain) whenever a packet would
hit a hero whose controller has ready DEF armor, then lands the (pool-reduced)
group with its per-damage hooks (restriction riders, discard-per-damage,
drain heal). Combat conclusion has its own open site
(`_combat_prevention_offers`) because its two packets are simultaneous and
strike-modified. New damage effects are preventable by construction —
**implementers must emit packets via `defer_packets`, never `deal_damage`**
(see the INVARIANT comment on `GameLogic.deal_damage`).

**Remaining deviation:** none in coverage. Timing nuance: for chain links the
point opens mid-resolution (after non-damage parts of the effect, e.g. an
unconditional heal on a deal-and-heal card, which lands before the damage
packet), rather than strictly "as the packet would be dealt" — observable
order only, no rules-visible difference identified.

Enforcement sites: `defer_packets` / `_apply_packet_group` /
`_combat_prevention_offers` / `choose_prevention` in
`game_logic/stack_resolver.gd`.

---

## Form return timing (Bear Form / Cat Form)

**Rule:** printed text + CR 1582 example — "When [this] is destroyed, you may
pay (2). If you do, put it into your hand at the next end of turn," and only if
the card stayed in the graveyard continuously until then.

**Engine model:** `on_destroyed:pay_return_hand:2` opens a direct-call choice
(`choose_form_return`, like the whelp bounce) immediately after the destruction;
paying returns the card to hand **immediately** instead of at end of turn, and
no graveyard-continuity watch exists. The continuity clause only matters if
something exiles/recurs the card from the graveyard between destruction and end
of turn — nothing in the current pool does. The choice also only OPENS when the
cost is affordable at destruction time (rules would let you wait until the
trigger resolves).

Enforcement site: the `pay_return_hand` branch of `_fire_on_destroyed` +
`choose_form_return` in `game_logic/stack_resolver.gd`.

---

## Form break timing ("play a non-Feral ability")

**Rule:** glossary Bear Form / Cat Form — "When you play a non-Feral ability or
strike with a weapon, destroy each ability that's the source of a modifier
granting your hero bear or cat form." A triggered effect fires when the ability
is PLAYED (announced).

**Engine model:** `form_break:TAG` destroys the controller's Forms as part of
the played ability's **resolution** (`_check_form_break_ability`, called from
`_resolve_play_instant` and `_resolve_play_ongoing_ability`), not at announce —
and consequently not at all if the play fizzles (card left the chain). The
weapon-strike branch (`_check_form_break_strike` in `choose_strike`) is
timing-faithful. Observable difference: while a non-Feral ability sits on the
chain the form is still in play (e.g. the hero could still protect with Bear
Form against something resolving first); by strict rules the form would already
be destroyed. Accepted for v1.

Enforcement sites: `_check_form_break_ability` / `_check_form_break_strike` in
`game_logic/stack_resolver.gd`.

## Replacement-effect order — flat bonuses before World in Flames

**Cards:** Chromatic Cloak (`azeroth_282`), Shadowform (`azeroth_88`),
World in Flames (`azeroth_61`)
**Enforcement site:** `StackResolver.defer_packets` (the packet-entry modifier loop)

Printed rule: when multiple replacement effects would modify the same damage
event, the affected player chooses the order they apply. The engine instead
applies a FIXED order: the flat bonuses first — Chromatic Cloak's "+1 if your
hero would deal damage with an ability", then Shadowform's "+1 if your hero
would deal shadow damage" — and World in Flames' fire doubling last. All three
only ever benefit the same player (all read "your hero"), and (X+1)*2 > X*2+1,
so the fixed order is exactly the order that player would always choose —
no meaningful choice is lost.

Cloak and Shadowform are both additive, so their relative order never matters.
Shadowform and World in Flames can never meet on the same packet at all (a
packet carries one `dmg_type`, so it is shadow or fire, never both); their
relative order is a convention for a hypothetical future dual-type card.

Also note: "with an ability" is tracked by a `from_ability` packet tag set at
ability-resolution packet sites (instants/abilities, ongoing-ability on-play
damage, attachments including Fireball's turn-start burn). Hero flip POWERS,
ally/equipment activated powers, totem triggers, enter-play ally effects, and
combat damage are not abilities and never get the bonus.

## Tokens — "ceases to exist" is modelled as the RFG zone

**Cards:** Mechanical Dragonling (`token_mechanical_dragonling`, from Mya),
Tooga (`token_tooga`, from Tooga's Quest)
**Enforcement site:** `GameLogic.move_card` (the `card.is_token` redirect)

Printed rule: a token that leaves play ceases to exist — it is not a card in
any zone afterwards. The engine instead moves it to its owner's RFG zone and
leaves the `CardInstance` registered in `state.cards`. This is unobservable in
play: nothing in the engine reads an RFG zone as a resource (it is only ever a
destination), so a voided token can never be recurred, exiled, counted or
targeted. Keeping the instance means the renderer can animate the card away and
no already-captured `instance_id` can dangle into a null lookup mid-resolution.

The redirect deliberately lives in `move_card` rather than in each removal
effect, so it covers destruction, bounce (Withdraw), discard and any future
"put into its owner's hand/deck" by construction. It only changes the
DESTINATION: `GameLogic.destroy_card` still emits `card_destroyed` before the
move, so `on_destroyed` triggers and every "when an ally is destroyed" watcher
fire on a token exactly as on a real card.

## Tooga — delayed self-removal fires inline, not on the chain

**Card:** Tooga's Quest (`azeroth_359`) → the Tooga token (`token_tooga`)
**Enforcement site:** `TurnManager._apply_start_of_turn_effects`
(the `rfg_self_next_turn` branch)

"At the start of your next turn, remove Tooga from the game. If you do, draw
two cards" is a delayed triggered effect, which by rule 501.1a would go on the
chain with a priority window before it resolves. The engine resolves it inline
during the ready step instead — the same deviation (and for the same reason)
as every other start-of-turn trigger here: there is no cost, no choice and no
target, so nothing an opponent could respond to changes the outcome. The one
observable difference is that an opponent cannot kill Tooga *in response to the
trigger* to deny the two cards; killing it any time before the ready step works
normally.

The trigger is carried by the token itself rather than remembered by the quest,
which is what makes the fizzle free: a Tooga that is already gone is not in
play to be scanned, so there is no removal and — "if you do" — no draw. The
removal is a plain move to RFG with no `card_destroyed` event, so it correctly
triggers nothing, unlike an opponent destroying the token.

---

## The Princess Trapped — "target opponent" is auto-chosen

**Card:** The Princess Trapped (`azeroth_357`, Quest). Printed text: "Pay (2) to
complete this quest. Reward: Reveal the top two cards of your deck. Target
opponent chooses one. Put that card into your hand and the other one on the
bottom of your deck." Recipe `reveal_pick:Any:2:opponent`.

**Deviation:** "target opponent" is a real target in the printed rules (a
multiplayer game picks one, and 706 Untargetable-style restrictions could in
principle apply to players). Here the sole opponent is chosen automatically,
with no target pick and no fizzle path — the same treatment as Hypnotic Blade's
"target player".

**Why:** the duel format has exactly one opponent, so the choice is degenerate.
This is the first card where the DECIDER of a mandatory choice differs from its
owner, so the engine now carries both explicitly:
`GameState.pending_reveal_pick_player` is the owner (whose deck was revealed and
whose hand the pick goes to) and `pending_reveal_pick_chooser` is the decider.
Every blocker (`can_submit` / `pass_priority`) still keys off the owner field;
only input routing and AI pick-quality key off the chooser. Enforcement site:
the `reveal_pick` branch of `_apply_quest_reward` in
`game_logic/stack_resolver.gd` (4th recipe field `opponent`).


## Innervate — "target player" is always the controller

**Card:** Innervate (`azeroth_23`, 4, Instant Ability — Restoration, Druid).
Printed text: "Target player draws three cards." Recipe `draw:3`.

**Deviation:** "target player" is a real target in the printed rules — in a
multiplayer game you pick which player draws, and you may legally pick an
opponent. Here the effect always resolves as "the controller draws three
cards": no target is announced, no target picker opens, and there is no fizzle
path.

**Why:** the card is a self-serving draw spell in every duel line of play —
handing three cards to the sole opponent is never a play anyone makes — so the
choice is degenerate, the same treatment as Hypnotic Blade's and The Princess
Trapped's "target player". Enforcement site: the `draw` branch of
`_resolve_play_instant` in `game_logic/stack_resolver.gd`, which draws for
`action.source_player` (shared with Arcane Shot's and Blink's draw riders).
A future multiplayer build would add a `draw:N:target_player` variant rather
than change this one.


## Quest reward choices — unavailable modes can't be picked

**Cards:** Hidden Enemies (`dark_portal_302`), A New Plague (`dark_portal_304`),
Thwarting Kolkar Aggression (`dark_portal_309`), Crown of the Earth
(`dark_portal_289`) — the "Choose one: …; or draw a card. If your hero is
[Race], you may choose both" quests (`qmode:` recipes).

**Deviation:** a mode whose requirement can't currently be met — no ally in
play for Hidden Enemies' ferocity target, no ally in the completer's party for
A New Plague, no opposing face-up quest for Kolkar — is UNAVAILABLE: it can't
be chosen (greyed out for humans, filtered for the AI) rather than chosen and
fizzled. With only one mode available, "you may choose both" is also off. A
chosen mode is still re-checked when its turn in the queue comes (the board may
have changed while the earlier mode resolved) and silently fizzles then.

**Why:** picking an effect that visibly does nothing is a trap choice with no
strategic content in the duel format; the printed outcome (fizzle) and the
engine outcome (can't pick) are identical game states. Enforcement site:
`StackResolver.quest_mode_available` / `_open_quest_choice` and the run-time
re-checks in `_run_quest_mode_queue` (`game_logic/stack_resolver.gd`).


## Thwarting Kolkar Aggression — "target player" is always the opponent

**Card:** Thwarting Kolkar Aggression (`dark_portal_309`, Quest, pay 3).
Printed reward: "Target player turns one of his quests face down."

**Deviation:** the target player is auto-chosen as the opponent — no target
announcement. The TARGET player (the opponent) still picks WHICH of their
face-up quests flips, per the printed wording. Turning face down is the same
spent state as a completed quest, but no reward is applied.

**Why:** flipping your own quest for no reward is never a play anyone makes in
a duel — the same degenerate-choice treatment as Hypnotic Blade / The Princess
Trapped / Innervate. Enforcement site: the `opponent_quest_face_down` branch of
`StackResolver._run_quest_mode_queue` in `game_logic/stack_resolver.gd`.


## Brigg — "an ally with damage on it" means damage it ALREADY had

**Card:** Brigg (`azeroth_231`, 1-cost 1/2 Horde Orc Warrior Ally).
Printed text: "When Brigg deals combat damage to an ally with damage on it,
destroy that ally."

**Interpretation (not strictly a deviation, but a ruling worth pinning):** the
victim must have carried damage BEFORE Brigg's combat damage landed. Brigg's own
damage does not qualify the target. The engine samples `damage_taken > 0` on both
combatants in `_do_combat_conclusion` ahead of the damage packets, and
`_fire_combat_dmg_destroys_damaged_ally` gates on that sample.

**Why:** the condition is embedded in the trigger event ("deals combat damage to
[an ally with damage on it]"), not a comma-set-off double-check clause (703.2),
so it describes the ally as the damage is dealt — its state before that damage.
The alternative reading also makes the clause vacuous: any surviving ally Brigg
deals damage to trivially "has damage on it" afterwards, which would turn a
1-cost 1/2 into "destroy any ally this touches" and leave the printed words doing
nothing. The rules text has no template for "with damage on it" to settle it
outright, so this is the reading the engine commits to.

**Consequences:** the trigger is mandatory (no cost, no choice) and is a no-op
when the victim died to the combat damage anyway — it matters when a already-
damaged ally SURVIVES the hit. It fires in BOTH combat roles, since the text says
"deals combat damage" rather than "attacks": Brigg attacking into a damaged ally
defender, and Brigg defending and retaliating onto a damaged attacking ally.
Enforcement site: `StackResolver._fire_combat_dmg_destroys_damaged_ally` in
`game_logic/stack_resolver.gd`.

---

## Lightning Storm — "any number of target allies" means at least one

Card: Lightning Storm (`dark_portal_98`), 2+X, Ability — Elemental.
Printed text: "Your hero deals X nature damage divided as you choose to any
number of target allies."

**Deviation:** "any number" literally includes ZERO, so the printed card can be
cast with no targets at all (paying 2+X to do nothing). The engine refuses that
cast: `_can_play_divided_damage` requires at least one announced target, and the
highlight probe (`_targeted_play_has_legal_target`, via the ally-only branch)
goes dark when no legal ally is in play, so the card is unplayable on an empty
board. The engine also requires the announce to spend EVERY point of the
announced X — the player can't buy X=5 and assign only 3 — since X is chosen
freely at announcement and under-assigning is only ever a way to overpay.

**Why:** the only reachable difference is a strictly self-harming line of play
(burning a card and resources for no effect), and allowing it would mean the
targeting UI has to offer a "cast at nothing" exit from a flow whose entire
shape is "click once per point of damage".

**Consequences:** with no ally on either board Lightning Storm can't be played
at all; a player who wants to dump resources must do it some other way.
Enforcement site: `StackResolver._can_play_divided_damage` in
`game_logic/stack_resolver.gd`.

---

## Thysta Spiritlasher — an inline "each player's turn" trigger

**Card:** Thysta Spiritlasher (`dark_portal_236`, 5-cost 3/5 Horde Orc Warlock).
Printed text: "At the end of each player's turn, if no damage was dealt this
turn, Thysta Spiritlasher deals 3 fire damage to that player's hero."

**Deviation:** by 501.1a/410 the trigger should go on the chain and open a
priority window before its damage resolves. It resolves **inline** in
`TurnManager._enter_end` instead, exactly like Watcher Mal'wi's and Morik's
triggers: it is mandatory, free, has no choice and no target, so nothing about
the window changes what happens. The damage still goes through
`StackResolver.defer_packets`, so the hero's controller keeps the armor
prevention point (717.2c) — the one decision the trigger does present.

**Rulings pinned alongside it:**

- **"That player" is the turn player**, i.e. the hero of whoever's turn just
  ended — not Thysta's controller and not their opponent. On her controller's
  own idle turn she burns their own hero. The clock is symmetric, and that is
  the point of the card: it punishes whoever wastes a turn.
- **"No damage was dealt" is global** — any damage, from any source, to any
  character on either side, at any point in the turn. Answered from the turn
  event log (`GameState.turn_events`, `damage_dealt` entries recorded in
  `GameLogic.deal_damage` — see `game_logic/turn_state_flags.md`).
- **Damage prevented in full does not count as dealt** (717.2b — the packet
  ceases to exist), so a hit fully absorbed by armor leaves Thysta live. This
  matches every other "damage actually dealt" rider in the engine (whelp bounce,
  `discard_per_damage`, `drain_heal_per_damage`). Self-damage paid as a cost via
  `put_damage` (405.3) likewise doesn't count, the same call made for
  Berserking's counters.
- **The condition is sampled once** for all copies, before any of them fire, so
  two Thystas both burn a clean turn for 3 each rather than the first silencing
  the second.

**Why the log is kept unconditionally**, in every game, whether or not such a
card is on the board: the condition is retroactive. A Thysta entering play
mid-turn must still see damage dealt *before* she arrived, and there is nothing
on the board to reconstruct that from — damage that killed an ally leaves no
trace at all. Gating the tracking on her presence would not be an optimization,
it would be a wrong answer.

**Consequences:** the end-phase trigger sweep in `TurnManager._enter_end` now has
two passes — the original turn-player-scoped one for "at the end of YOUR turn"
(Infernal), and a second all-players pass for "each player's turn" triggers. New
each-player end triggers belong in `_apply_each_turn_end_effects`, not the
turn-player one. Enforcement sites: `TurnManager._apply_each_turn_end_effects`
and the `damage_dealt` record in `GameLogic.deal_damage`.

---

## Operation Recombobulation — reward trigger resolved immediately, not on the chain

**Card:** Operation Recombobulation (`dark_portal_292`, Quest, Alliance, Gnome
Hero Required). Printed text: "Pay (4) to complete this quest. Reward: When an
opposing non-token ally is destroyed this turn, you may put an ally card from
your graveyard into your hand." Recipe flag
`recursion_on_opposing_ally_death:1`.

**Deviation:** by the rules the reward's watcher is a triggered ability (703)
that should be ADDED TO THE CHAIN each time a qualifying ally dies, respondable
before it resolves. The engine instead opens it as a direct-call optional choice
(`pending_recomb_queue` + `pending_recomb_player`, resolved via
`choose_recombobulation`; `""` declines) at the moment of destruction — the same
immediate-resolution pattern as Boneshanks' death trigger, and for the same
reason: there is no generic chain-based triggered-effect machinery. Nothing is
lost in practice, since the effect takes no target in play and moving a card out
of a graveyard cannot be responded to meaningfully.

**Multiple deaths in one event** (an AoE clearing the opposing board, or a
combat where both allies die) queue one choice each and are answered
front-first, one browser at a time.

**Hotseat:** prompted for a human completer even off-seat, routed
`_route_choice(player, "public")` — a graveyard is open information, so no hand
hiding and no handoff.

**Why:** see Boneshanks. Enforcement sites: `StackResolver._fire_recombobulation`
/ `_open_next_recomb` / `choose_recombobulation` in
`game_logic/stack_resolver.gd`, fed by the `ally_destroyed` turn-log entry
recorded in `GameLogic.check_destroyed` / `destroy_card` (see
`game_logic/turn_state_flags.md`).
