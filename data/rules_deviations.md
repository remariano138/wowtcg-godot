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

## Replacement-effect order — Chromatic Cloak before World in Flames

**Cards:** Chromatic Cloak (`azeroth_282`), World in Flames (`azeroth_61`)
**Enforcement site:** `StackResolver.defer_packets` (the packet-entry modifier loop)

Printed rule: when multiple replacement effects would modify the same damage
event, the affected player chooses the order they apply. The engine instead
applies a FIXED order: Chromatic Cloak's "+1 if your hero would deal damage
with an ability" first, then World in Flames' fire doubling. Both effects only
ever benefit the same player (both read "your hero"), and (X+1)*2 > X*2+1,
so the fixed order is exactly the order that player would always choose —
no meaningful choice is lost.

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
