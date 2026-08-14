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
existing `require_turn_player` effects segment (reused from the genuine "use
only on your turn" printed-text convention, e.g. Acolyte Demia — see
`StackResolver.requires_turn_player`).

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
true on the controller's turn (e.g. "while attacking"), add
`require_turn_player` to its `effects` string and add an entry here. Note this reuses the same
flag as genuine "use only on your turn" printed text (Acolyte Demia) —
the effects string alone doesn't distinguish printed restriction from
engine deviation, which is exactly why this file exists.

---

## Ryn Dreamstrider (`azeroth_214`)

**Printed text:** "[Activate] -> Target hero or ally has +2 ATK while
attacking this turn." No "use only on your turn" clause is printed — ally
activated powers are usable on either player's turn by default (see the
"No turn_player restriction" convention note in
`StackResolver._can_use_ally_power`).

**Deviation:** restricted to Ryn's controller's own turn, via the existing
`require_turn_player` effects segment — the same treatment as Rayder and For
the Horde! above.

**Why:** identical to Rayder's, with the buff pointed at a single target
instead of the party. The bonus only applies "while attacking," and in a
duel only the turn player can attack, so using the power off-turn can
never do anything — it merely exhausts Ryn (worse against
destroy-exhausted-ally effects) and forces both Turbo autoskip and the AI
to keep evaluating a dead action in every non-turn priority window. The
multiplayer formats where an off-turn ally could be attacking don't exist
in this digital version.

**Scope of the restriction:** the turn and nothing else. Per rule 701.1 a
"use only on your turn" power stays instant-speed, so Ryn can be activated
during his controller's own combat windows and in response to a link on the
chain — which is exactly when a "+2 ATK while attacking" buff is worth
using. (The stricter "non-combat action phase + empty chain" reading is the
separate *Basic* restriction, 701.1a, a printed keyword no card in this pool
carries; the engine deliberately has no flag for it.)

---

## Start-of-turn triggered effects — drained one at a time

**Rules:** 500.2 — "when a turn, phase, or step starts, any powers or modifiers
that trigger at the start of that turn, phase, or step trigger. Triggered
effects are added to the chain during PPP (410.5)." 501.1a's "None of this uses
the chain" covers the ready step's *automatic actions* (expiries, readying,
modifier creation) — **not** the effects those actions trigger. 708.1a: if
multiple triggered effects are waiting, the turn player chooses the order his go
on the chain, then the next player clockwise, and they all go on in that one
PPP, under a single priority window.

**Engine:** `TurnManager._collect_turn_start_triggers` builds one ordered queue
of every start-of-turn trigger on the board as the ready step's automatic
actions finish (turn player's first, then the opponent's — 708.1a). Nothing
resolves inline. `StackResolver.advance_turn_start_triggers` then drains the
queue **one trigger at a time**: the front trigger announces its targets
(707.1d, a direct-call choice via `choose_trigger_target`), goes on the chain as
a `resolve_turn_start_trigger` link, and a normal priority window opens before
it resolves. Only once the chain is empty again does the next trigger fire —
see the queue check in `pass_priority`'s window-close branch. Every
start-of-turn effect in the game goes through this one path: Searing Totem's
ping, Infernal's discard-or-control, Healing Stream Totem's party heal,
Fireball's attached burn, Spirit Bond, Tooga's self-removal, plain self-heals.

**Deviation:** paper adds *all* waiting triggers to the chain in one PPP under a
single window; the engine gives each trigger its own announcement and its own
window, in sequence.

**Why:** with everything stacked at once, every target must be chosen before any
of them resolves — you would pick Searing Totem's target without knowing what
the other trigger did. Sequential draining lets each choice be made with the
previous outcome known, which is strictly friendlier and offers *more*
interaction points rather than fewer. It cannot make a legal line illegal: the
501.1a/708.1a firing order (turn player first) is preserved, and each link still
gets a real window. The one thing it changes is that a player cannot respond to
trigger B *before* trigger A resolves — which matters only for a card that keys
off two simultaneous triggers, of which none exist.

**What is NOT deviating any more** (both were previously listed here as
deviations and are now rules-correct):

- **Infernal's trigger is respondable and its choice is made at resolution.**
  707.1 locks in only X, modes and targets at announcement; a discard is none of
  those, so per 709.2b the discard-or-give-control choice is made as the link
  resolves. Playing an instant that draws in response therefore *can* save an
  empty hand. The rulebook's own 709.2b example (Last Stand: "destroy Last Stand
  unless you discard two cards") is the same shape.
- **Killing the source in the response window does not stop the effect.** 707.3:
  an effect exists independently of its source. Destroying Searing Totem after
  its ping is announced is too late — the damage still lands. Where a clause is
  genuinely impossible without the source (Infernal's control change: a card in
  a graveyard has no controller to give), 709.2c applies instead — the link
  resolves and only as much as possible is performed, so sacrificing the
  Infernal in response escapes it entirely without any "fizzle" special case.
- **Fireball's attached host is locked in at announcement** (709.2d), so
  bouncing Fireball in response still burns what it was attached to — the
  rulebook's Kryton Barleybeard example.

**Remaining minor deviation — AI doesn't respond in these windows.** Per the AI
convention the non-turn AI passes every priority window
(`get_reasonable_actions` returns nothing for the non-turn player), so an AI
opponent won't heal or save an ally that the turn player's totem targets. A
HUMAN opponent gets the full window. Extending the window AI to defensive
instant plays is the same open item noted for combat windows.

**How to apply this pattern to future cards:** add the effects-segment key to
`TurnManager.EACH_TURN_TRIGGERS` (fires on every player's turn) or
`YOUR_TURN_TRIGGERS` (controller's turn only), and a `match` arm in
`StackResolver._resolve_turn_start_trigger`. It is respondable, armor-
preventable and 707.3-correct for free. If the trigger announces a target, add
its key to `TARGETED_TURN_START_TRIGGERS` as well. Do **not** resolve a
start-of-turn effect inline in `TurnManager` — that is the bug this framework
replaced.

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

## Combat triggered effects — drained one at a time

**Rule 602.1 / 602.3:** each ends with the same sentence — "a priority window …
opens. Any waiting triggered effects are added to the chain, and then the turn
player gets priority." So every waiting combat trigger is added to the chain
together, in one PPP, in rule-708.1a order, and they then resolve top-down.

The rulebook's worked example (602.3) is Grunt Baranka:

> You attack Grunt Baranka with High Overlord Saurfang. Immediately after the
> protect point, both powers trigger. Saurfang's effect is added to the chain
> first because it's your turn, so Baranka's resolves first.

**Deviation:** `StackResolver` announces combat triggers **one at a time**
(`GameState.pending_combat_triggers` → `advance_combat_triggers`), keeping the
window open and announcing the next only once the previous link has fully
resolved. This is the same deviation the start-of-turn queue already makes, for
the same reason — see "Start-of-turn triggered effects — drained one at a time"
above.

**Why:** it is strictly friendlier and never changes a legal line. It does,
however, invert the RESOLUTION ORDER of two simultaneous triggers relative to the
example: with both on the chain at once the turn player's is announced first and
therefore resolves LAST, whereas announced sequentially the turn player's is
announced first and resolves FIRST. Nothing shipped exercises this — Saurfang is
not implemented, and no two implemented combat triggers can fire off one combat —
but a future "when an ally enters combat with this" card would make it visible,
and that is the point at which the queue should announce the whole batch in one
PPP instead.

**Not a deviation any more:** Morik (`dark_portal_224`), Donna Calister
(`azeroth_181`) and Berserking (`dark_portal_134`) used to resolve inline in
`_resolve_propose_combat` on the grounds that they were free, non-targeted and
choiceless. They are ordinary chain links now, so all three are respondable and
707.3-correct — killing Morik in response no longer stops the draws. Donna still
readies in time to protect the combat that triggered her, since the attack window
(where her link resolves) closes before the protect point.

**How to apply this pattern to future cards:** add the effects key to
`StackResolver.COMBAT_TRIGGERS` with its `moment` ("attack"/"defend") and `scope`
("self" for "when THIS attacks/defends", "board" for a watcher, whose condition
then goes in `_combat_trigger_watches`), plus a `match` arm in
`_resolve_combat_trigger`. Do NOT resolve a combat trigger inline in
`_resolve_propose_combat` / `_open_defend_window` — that is the bug this
framework replaced. Note the strike points (602.1/602.3) and the protect point
(602.2) are deliberately NOT part of this: the rules say of each, in so many
words, "none of this uses the chain".

**Still resolved outside the chain:** the "you may pay COST" attack points
(Windseer Tarus, Windfury Totem) and the optional targeted attack-exhaust points
(Chops / Voss Treebender / Gartok Skullsplitter). These are genuine triggered
effects and belong on the chain too, but each carries a direct-call choice with
its own UI and AI flow — see their own entries above and below.

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
`equipment:melee_weapon:0|weapon:1|power_weapon|activated_power:3:discard_opponent:1:::exhaust_hero|require_turn_player`.

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

**Cards:** Chops (`dark_portal_32`), Voss Treebender (`azeroth_266`) — "When
[this] attacks, you may exhaust target hero or ally", recipe flag
`on_attack_exhaust_target`; Gartok Skullsplitter (`azeroth_238`) — "When Gartok
Skullsplitter attacks, you may exhaust target armor", recipe flag
`on_attack_exhaust_armor`. Only the target pool differs; both open the same
point and this deviation covers both.

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
controller discards a card per damage actually DEALT — armor prevention reduces
the count, 405.2 overkill does not, exactly like Steal Essence's drain heal). But the AI, which plays these cards for the damage via the normal
targeted-damage machinery (`_targeted_instant_actions` / ally-power actions),
does NOT model the extra discard when scoring — it treats them as plain damage.

**Why:** the discard is a strict bonus on a card the AI already values for its
damage, so ignoring it never causes a wrong play, only a slight undervaluation.
Enforcement site: `_apply_discard_per_damage` in `game_logic/stack_resolver.gd`
(called from the `deal_damage_to_target` branches of `_resolve_play_instant`
and `_resolve_use_ally_power`).

---

## Skorn, Mistress of Shadow (`azeroth_259`) — reflect resolved immediately, target auto-chosen

**Printed text:** "When an ally is dealt damage, Skorn deals that amount of
shadow damage to target hero in that ally's party."
Recipe: `ally_damaged_reflect_hero:shadow`.

**Rules 501.1 / 410 / 707.1d:** in paper play this is a triggered effect that
goes on the chain when the damage is dealt, announcing a target hero, with a
priority window before the shadow damage lands.

**Deviation, two parts:**

1. **The target is auto-chosen.** "Target hero in that ally's party" has exactly
   one legal answer in a two-player duel — the damaged ally's controller's hero
   — so no target point is opened. Same reasoning as Hypnotic Blade's "target
   player" and Thwarting Kolkar Aggression's "target opponent".
2. **The reflect resolves inline, not on the chain** — swept in
   `StackResolver._fire_skorn` at the two points damage has just landed
   (`_apply_packet_group` and `_do_combat_conclusion`), with no chain link and
   no priority window. Same reasoning as Watcher Mal'wi / Thysta Spiritlasher:
   the trigger is mandatory, free, choiceless and has no announced target, so
   there is nothing a response could change except killing Skorn — and per
   707.3 an effect exists independently of its source, so that would not stop
   the reflect anyway.

**Note — NOT a deviation:** the amount reflected is the damage actually DEALT,
which per 405.2 may exceed the damaged ally's health ("a character CAN be dealt
damage in excess of its health"; only *put* damage is capped at fatal). A
4-damage hit on a 1-health ally reflects 4. Prevention DOES reduce it (717.2b —
a fully absorbed packet was never dealt, so it reflects nothing). Enforcement
site: `GameLogic.deal_damage`, which reports the dealt amount while placing only
what fits.

**Also not a deviation:** the trigger is symmetric. "An ally" is every ally on
the board — Skorn's controller's own, and Skorn herself — and the hero pinged is
always the damaged ally's own. Damaging your own ally burns your own hero.

**AI:** none. Skorn is played as a vanilla 5-cost 3/2, and the AI does not model
the self-harm side (its own allies taking combat damage burning its own hero).

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

## Tooga — the delayed self-removal is carried by the token

**Card:** Tooga's Quest (`azeroth_359`) → the Tooga token (`token_tooga`)
**Enforcement site:** `StackResolver._resolve_turn_start_trigger`
(the `rfg_self_next_turn` arm)

Not a deviation any more — kept here because the mechanism is worth recording.
"At the start of your next turn, remove Tooga from the game. If you do, draw
two cards" goes on the chain like every other start-of-turn trigger (see
"Start-of-turn triggered effects" above), so an opponent CAN kill Tooga in
response to the trigger to deny the two cards: 709.2c performs only as much as
possible, and with the token gone there is no removal and — "if you do" — no
draw.

The trigger is carried by the token itself rather than remembered by the quest,
which is what makes the fizzle free: a Tooga that is already gone is never
collected into the turn-start queue at all. The removal is a plain move to RFG
with no `card_destroyed` event, so it correctly triggers nothing, unlike an
opponent destroying the token.

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

## Venomstrike — an inline end-of-turn burn, and why a dead scorpid burns nothing

**Card:** Venomstrike (`dark_portal_41`, 4-cost 1/5 Scorpid Pet, Hunter).
Printed text: "At the end of each turn, Venomstrike deals 4 nature damage to
each hero and ally it dealt damage to this turn."

**Deviation:** the trigger resolves **inline** in `TurnManager._enter_end`
rather than going on the chain with a priority window, exactly as Thysta
Spiritlasher's does and for the same reason — it is mandatory, free, has no
choice and no announced target, so nothing a response could do changes what
happens. The damage still goes through `StackResolver.defer_packets`, so every
victim's controller keeps the armor prevention point (717.2c), which is the one
decision the trigger does present.

**NOT a deviation — the ruling this card is most often misread on.** The burn
looks like a delayed effect planted at the moment damage is dealt, which would
fire whether or not Venomstrike survives. It isn't. The printed text is a single
triggered power (703.1) whose trigger event is *the end of turn*; "it dealt
damage to this turn" merely selects the victims. And:

> **703.3** — "A card's triggered power is active only while that card is face
> up in play and that power hasn't been lost. Otherwise, it's inactive."

So a Venomstrike destroyed before the end phase never triggers and burns
nothing — killing the scorpid is the answer to the card. This needs no code: the
sweep in `_enter_end` only visits `state.cards_in_play(pid)`.

The distinction that does survive his death is **707.3**: once the power HAS
triggered and its packets exist, they are independent of their source. Killing
him in a response window after the burn has gone out changes nothing — the same
ruling as the totem ping.

**Other rulings pinned alongside it:**

- **The victim list is turn history**, read off the `damage_dealt` entries in
  `GameState.turn_events` filtered to `source_id` == this card (see
  `game_logic/turn_state_flags.md`). Every damage source in the game records
  there, so combat damage, ability damage and power damage all feed it by
  construction, and "this turn" is free — the log is cleared at every turn start.
- **Victims are de-duplicated.** "Each hero and ally it dealt damage to" is a
  set: damaging one ally three times burns it once, for the flat printed amount.
- **The amount is flat**, not the damage dealt — a 1-point poke sets up a
  4-point hit, which is what makes his 1 ATK body dangerous.
- **408.2b**: no packet is created for a character no longer in play, so an ally
  he killed in combat is not burned again, and one dead victim does not cancel
  the rest of the group.
- **Not restricted to opposing characters.** "Each hero and ally" is literal —
  damage your own side (an AoE, a stray packet) and you burn your own side.
- **Copies never cross-feed**: the filter is the instance's own `source_id`, not
  the card name, so two Venomstrikes each burn only what they personally damaged.
- Damage prevented in full was never dealt (717.2b), so a victim whose damage
  was entirely absorbed is not on the list at all.

**AI:** none. Venomstrike is played as a vanilla 4-cost 1/5 Pet; the AI does not
seek out chip damage to set the burn up, and does not weigh the self-harm side.

Enforcement site: the `end_of_turn_damage_own_victims` arm of
`TurnManager._apply_each_turn_end_effects`.

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
