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
`use_quest` branch of `BaseAI.get_legal_actions` never doing anything
useful with it.

**Effect of the deviation:** Turbo autoskip can safely skip past this
quest's completion window whenever it's not the controller's turn; the AI
no longer offers/considers it off-turn either (it's simply not a legal
action, so `get_legal_actions` never returns it — no special-casing needed
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

**Rule 501.1a / 410:** like Infernal above, a paper "at the start of each
turn" triggered ability is added to the chain during the ready step, with a
priority window before it resolves and its target is chosen.

**Deviation:** the engine resolves the trigger immediately, with no priority
window — `TurnManager._collect_ongoing_turn_triggers` (called from
`_enter_ready`) queues each in-play Totem's trigger and opens a mandatory
target choice resolved via `StackResolver.choose_totem_target()` (a direct
call, like the strike / reveal / control-discard choices;
`pending_totem_target_player` hard-blocks `can_submit` / `pass_priority`
while open). Turn player's totems fire first (501.1a ordering is preserved).

**Why:** identical reasoning to Infernal — no implemented card can respond to
a triggered ability before it resolves, so a chain-based implementation would
add complexity with no observable difference. This reuses the established
immediate-resolution mandatory-choice pattern.

**How to apply this pattern to future cards:** an ongoing "start of each turn"
targeted-damage Totem uses the `ongoing|totem[:element]|ongoing_damage_each_turn:AMOUNT:TYPE`
recipe. If a future trigger must be respondable, the same chain-based rework
noted under Infernal applies here.

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
