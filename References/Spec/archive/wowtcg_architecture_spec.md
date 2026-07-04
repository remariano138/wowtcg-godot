# WoW TCG (Godot) — Engine Architecture Specification

**Purpose of this document:** define the target architecture for the rewrite, so that implementation work (by Claude Code or otherwise) has a stable structural contract to build against. This is a *structural* spec, not a rules spec — actual card text/rules logic should be checked against the comprehensive rule set separately. Low-level code snippets below are illustrative starting points, not final schemas.

---

## 1. Core Principle

**Single source of truth = Game State.** Everything else is a consumer or mutator of it.

```
┌─────────────────┐      events      ┌──────────────┐
│  Game Logic /    │ ───────────────▶ │   Renderer   │
│  Rules Engine    │                  │ (Godot nodes)│
│  (mutates state) │                  └──────────────┘
└─────────▲────────┘
          │ actions (same API for both)
          │
   ┌──────┴──────┐         ┌─────────────┐
   │ Human Input  │         │  AI Player   │
   │ (clicks →    │         │ (evaluates   │
   │  proposals)  │         │  state → picks│
   └─────────────┘         │  action)     │
                            └─────────────┘
```

Five components, five responsibilities. None of them should know how to do another's job:

| Component | Owns | Must NOT do |
|---|---|---|
| **Game State** | The data: zones, cards, players, phase, stack | Any logic/rules |
| **Game Logic / Rules Engine** | Validating & resolving actions, phase/priority progression | Touch Godot nodes, animate anything, know about clicks |
| **Event Bus** | Transporting "what just happened" from logic to listeners | Contain logic, mutate state |
| **Renderer** | Godot nodes, visuals, animations, board layout | Decide game rules, mutate game state directly |
| **Input Layer (Human + AI)** | Turning intent into a proposed Action, submitted to the same queue | Mutate state directly, bypass the action/validation pipeline |

The single most important rule: **Human input and AI input produce the exact same object** (an `Action`/`ActionRequest`), submitted through the exact same entry point. If you ever find yourself writing a code path that only the AI uses, or only the human UI uses, to actually change game state — that's the seam that will produce desync bugs and untestable logic. Both are just "a source of proposed actions."

---

## 2. Game State

### 2.1 What it is
A tree of plain, serializable, typed objects (GDScript classes / Resources — not raw untyped `Dictionary` as the *working* representation). It should be exportable to a plain `Dictionary`/JSON at any time for save files, debugging, or future networking, but the code you actually write against should be typed classes so the editor and type-checker catch mistakes.

### 2.2 Top-level shape (illustrative)

```gdscript
class_name GameState
extends Resource

var players: Dictionary        # player_id (String) -> PlayerState
var zones: Dictionary          # zone_id (String) -> Zone
var cards: Dictionary          # card_instance_id (String) -> CardInstance
var turn_number: int
var turn_player: String
var phase: String              # "draw", "action", "combat", "wrapup"
var priority_player: String
var pending_actions: Array     # Array[PendingAction] — the interrupt stack (see §6)
var consecutive_passes: int = 0

func to_dict() -> Dictionary: ...   # for save/debug/network
static func from_dict(d: Dictionary) -> GameState: ...
```

### 2.3 CardInstance (illustrative — adjust fields to your real card model)

```gdscript
class_name CardInstance
extends Resource

var instance_id: String        # unique per physical card in this game
var card_def_id: String        # points to static card database entry (name, text, base stats)
var owner: String              # player_id — who started with this card
var controller: String         # player_id — who currently controls it (can differ via effects)
var zone_id: String            # where it currently is
var is_exhausted: bool = false
var current_hp: int
var current_atk: int
var damage_marked: int = 0
var active_buffs: Array        # Array[Buff] — modifiers with source/duration
var attachments: Array         # Array[String] — instance_ids of attached cards (equipment etc.)
```

Static card data (name, rules text, base stats, card type) should live in a separate read-only database keyed by `card_def_id` — not duplicated into every instance. `CardInstance` only holds what can *change* during a game.

### 2.4 Zone

```gdscript
class_name Zone
extends Resource

var zone_id: String
var zone_type: String          # "deck", "hand", "in_play", "graveyard", "removed", etc.
var owner: String               # player_id, or "shared" for e.g. a shared resource zone
var card_ids: Array[String]    # ordered list of CardInstance.instance_id
```

Moving a card between zones is **always**: remove id from source `card_ids`, append to destination `card_ids`, update `CardInstance.zone_id`. This should be a single reusable function (see §4.2) — never inlined ad hoc, because zone-change triggers (many TCG effects trigger "when this enters/leaves a zone") need one choke point to hook into.

### 2.5 PlayerState

```gdscript
class_name PlayerState
extends Resource

var player_id: String
var resources: Dictionary      # whatever your resource system is (mana equivalent)
var hero: CardInstance         # or reference, if heroes are special
```

---

## 3. Event System

### 3.1 Why events exist
Game logic must never call the renderer directly. It emits a description of what happened; anything can listen. This buys you: headless simulation (AI lookahead, unit tests, "resolve without animating"), replay capability, and a renderer that can be rebuilt or swapped without touching rules code.

### 3.2 Event shape

```gdscript
class_name GameEvent
extends RefCounted

var event_type: String   # "damage_dealt", "card_moved", "card_exhausted", "phase_changed", ...
var payload: Dictionary  # event-specific data, e.g. {"source": id, "target": id, "amount": 3}
```

Or, if you prefer stronger typing over a generic payload dict, define one subclass per event type (`DamageDealtEvent`, `CardMovedEvent`, ...) with named fields instead of a dict. Either is fine; pick one and be consistent — mixing generic and typed events is worse than either alone.

### 3.3 Event bus

```gdscript
# Autoload singleton
extends Node

signal game_event(event: GameEvent)

func emit_events(events: Array) -> void:
    for e in events:
        game_event.emit(e)
```

**Rule:** every state-mutating function returns (or appends to) an `Array[GameEvent]` describing exactly what it did. The caller is responsible for pushing those onto the bus *after* the state mutation is committed — mutation and event should be treated as one atomic unit, never "mutate now, maybe emit the event later."

### 3.4 Who listens
- **Renderer** (§5) — always.
- **Logging / replay recorder** — optional, but nearly free once the bus exists.
- **AI** — generally should NOT rely on events; it should evaluate `GameState` directly (see §7).

---

## 4. Game Logic / Rules Engine

### 4.1 Function contract
Every rules function has the same shape: **(state, args) → (mutated state, events)**. No side effects outside of the state object it's given.

```gdscript
# Signature convention
static func deal_damage(state: GameState, source_id: String, target_id: String, amount: int) -> Array[GameEvent]:
    var target := state.cards[target_id] as CardInstance
    target.damage_marked += amount
    var events: Array[GameEvent] = [
        GameEvent.new("damage_dealt", {"source": source_id, "target": target_id, "amount": amount})
    ]
    if target.damage_marked >= target.current_hp:
        events.append_array(move_card(state, target_id, target.zone_id, _graveyard_of(state, target)))
    return events
```

Notes on the contract, all deliberate:
- Takes `state` **by reference** (GDScript objects are references) and mutates it in place — no need to return a new copy, but the function must not reach outside `state` for anything (no reading global Godot nodes, no `get_tree()`, nothing).
- Returns events, never calls renderer/UI functions.
- Composable: `deal_damage` calling `move_card` internally and folding its events in is the expected pattern — build complex resolutions out of small state-mutating primitives, each with its own event(s).
- Pure enough to unit test with a hand-built `GameState` and no Godot scene running.

### 4.2 The zone-move primitive
Because so much rules text hinges on zone changes (dies → graveyard, bounced → hand, etc.), have exactly one function that performs a zone move, and route everything through it:

```gdscript
static func move_card(state: GameState, card_id: String, from_zone: String, to_zone: String) -> Array[GameEvent]:
    state.zones[from_zone].card_ids.erase(card_id)
    state.zones[to_zone].card_ids.append(card_id)
    state.cards[card_id].zone_id = to_zone
    return [GameEvent.new("card_moved", {"card": card_id, "from": from_zone, "to": to_zone})]
```

### 4.3 Validation vs. resolution
Split "can this action legally happen" from "what happens when it does." This matters a lot once interrupts exist, because an action can be proposed, sit on the stack, and only get validated for legality again right before it actually resolves (state may have changed in between — the proposed attacker might have been removed by an interrupt).

```gdscript
static func can_declare_attack(state: GameState, attacker_id: String, defender_id: String) -> bool: ...
static func resolve_declare_attack(state: GameState, attacker_id: String, defender_id: String) -> Array[GameEvent]: ...
```

Both Human and AI action submissions go through `can_*` before being accepted onto the stack; `resolve_*` runs only when the stack pops that action.

### 4.4 Folder structure (illustrative)

```
/game_logic
    /actions          # one file per action family (combat.gd, resource.gd, card_play.gd...)
    /state             # GameState, CardInstance, Zone, PlayerState class defs
    /events            # GameEvent + bus
    stack_resolver.gd  # priority/stack loop (see §6)
/renderer
    board_renderer.gd
    /animations
/input
    human_input.gd
    ai_player.gd
/data
    card_database.gd   # static card definitions
```

---

## 5. Renderer

### 5.1 Responsibility
Godot scene tree, visual layout, and animation **only**. It is a pure function of "current state + incoming events" → visuals. It should be possible, in principle, to delete the entire renderer and still have a fully functional (headless) game.

### 5.2 Pattern

```gdscript
extends Node2D  # BoardRenderer

func _ready():
    EventBus.game_event.connect(_on_game_event)

func _on_game_event(event: GameEvent) -> void:
    match event.event_type:
        "card_moved":
            await _animate_move(event.payload.card, event.payload.from, event.payload.to)
        "damage_dealt":
            await _animate_damage(event.payload.target, event.payload.amount)
        "card_exhausted":
            await _animate_exhaust(event.payload.card)
```

### 5.3 Node ↔ instance mapping
Keep a single lookup table (`instance_id -> Node`) inside the renderer so it can find "the visual thing representing card X" when an event arrives. This table is renderer-internal state — it must never be read by game logic.

```gdscript
var card_nodes: Dictionary  # instance_id -> CardNode
```

### 5.4 Animation queue
Because events can arrive faster than animations play (e.g. a board wipe kills 5 creatures at once), decide early whether animations play sequentially (queued) or in parallel, per event type. A simple queue + `await` chain (as sketched above) is a reasonable default; revisit only if a specific interaction needs simultaneity (e.g. "all creatures take damage at once" should probably animate in parallel, not one after another).

### 5.5 What the renderer is allowed to read
Read-only access to `GameState` for initial layout / resync (e.g. reconnecting, or building the board from scratch at game start), but ongoing updates during play should come from **events**, not from polling state. If you find the renderer diffing state to figure out what changed, that's the anti-pattern flagged earlier in this design process — stop and fix the emitting function instead.

---

## 6. Turn Structure, Priority, and the Interrupt Stack

This is the part of the architecture most specific to WoW TCG's interrupt-heavy design, and the part most likely to have subtle bugs — get the skeleton right before layering real cards on top.

### 6.1 Model
- `phase`: draw / action / wrap-up (extend as needed).
- `pending_actions`: a **stack** (last in, first resolved) of proposed-but-not-yet-resolved actions.
- `priority_player`: whose turn it is to either act or pass.
- `consecutive_passes`: resets to 0 any time someone acts; when it hits 2 (both players passed back-to-back with nothing new proposed), the top of the stack resolves.

```gdscript
class_name PendingAction
extends Resource

var action_type: String       # "declare_attack", "play_card", "activate_ability", ...
var source_player: String
var params: Dictionary        # action-specific: attacker_id, target_id, etc.
```

### 6.2 The loop (conceptual, not final code)

```gdscript
func submit_action(state: GameState, action: PendingAction) -> Array[GameEvent]:
    if not _can_propose(state, action):
        return []  # rejected, resubmit or ignore
    state.pending_actions.push_back(action)
    state.consecutive_passes = 0
    state.priority_player = _other_player(state.priority_player)
    return [GameEvent.new("action_proposed", {"action": action})]

func pass_priority(state: GameState) -> Array[GameEvent]:
    state.consecutive_passes += 1
    if state.consecutive_passes >= 2 and not state.pending_actions.is_empty():
        var top: PendingAction = state.pending_actions.pop_back()
        state.consecutive_passes = 0
        return _resolve(state, top)
    state.priority_player = _other_player(state.priority_player)
    return [GameEvent.new("priority_passed", {"player": state.priority_player})]
```

`_resolve(state, action)` dispatches to the matching `resolve_*` function from §4.3, re-validating legality first (things may have changed while it sat on the stack).

### 6.3 Nested example (your combat case, mapped to the model)
1. Active player submits `declare_attack` → pushed to stack, priority to opponent.
2. Opponent submits `play_interrupt(cant_attack_this_turn)` → pushed **on top** of `declare_attack`, priority back to active player.
3. Active player passes, opponent... wait, opponent just acted, so priority is with active player; if active player also has nothing, that's 2 consecutive passes → top of stack (`cant_attack_this_turn`) resolves first.
4. Now back to checking whether `declare_attack` (now underneath) is still legal — if the attacker is now unable to attack, it fizzles rather than resolving.

This nesting — resolve top-of-stack, re-check what's now exposed underneath — is exactly why a stack rather than a flat phase variable is required once interrupts-on-interrupts exist. It falls out of the model above for free; it would need to be special-cased endlessly with a flat enum.

### 6.4 Sub-phases as data, not code branches
Multi-step resolutions (e.g. your combat sequence: exhaust attacker → defender may declare protector → calculate damage → apply damage → check deaths → exhaust protector) are naturally modeled as a **sequence of discrete resolve steps**, each of which can itself open a priority window if the rules allow interrupts at that step. Two reasonable implementation options — decide once you see how many multi-step actions you have:
- Each step is its own small `resolve_*` function, called in sequence by a `resolve_combat` orchestrator, with priority windows opened between steps that allow interrupts.
- Steps are pushed onto `pending_actions` themselves, so the *same* stack machinery handles "steps of one action" and "response to an action" uniformly.

The second is more elegant but more upfront work; the first is easier to reason about early. Given you're rebuilding from scratch, I'd lean toward starting with the first and only generalizing to the second if you find yourself duplicating the priority-window logic across many multi-step actions.

---

## 7. Input Layer — Human and AI

### 7.1 The shared contract
Both produce a `PendingAction` (or a rejected/no-op) and submit it to `submit_action()` / `pass_priority()` from §6.2. Neither ever touches `GameState` fields directly.

```gdscript
# Shared interface both input sources conform to, conceptually:
func propose_action() -> PendingAction   # or null if passing
```

### 7.2 Human input
Godot nodes (card visuals, zone highlight areas) are purely about **capturing intent**, then translating it into the same `PendingAction` shape the AI would produce.

```gdscript
# On a CardNode (rendering layer)
func _on_card_clicked():
    InputRouter.handle_card_selection(instance_id)

# InputRouter (input layer, not renderer) accumulates clicks into a legal action:
# e.g. "select attacker" -> highlight legal targets (read-only query against GameState)
#      -> "select target" -> build PendingAction -> submit_action(state, action)
```

Key discipline: **legal-target highlighting is a read-only query against `GameState`** (via the `can_*` validators from §4.3), not a separate copy of the rules. If "can this creature attack" logic exists both in the rules engine and separately in the UI's highlight code, they will drift and disagree — call the same validator from both places.

### 7.3 AI input
The AI evaluates `GameState` directly (no need to go through events or the renderer) and produces the same `PendingAction`.

```gdscript
# ai_player.gd
func decide_action(state: GameState, player_id: String) -> PendingAction:
    var legal_actions = _enumerate_legal_actions(state, player_id)  # calls the same can_* validators
    if legal_actions.is_empty():
        return null  # pass
    return _pick_best(state, legal_actions)  # whatever heuristic/search you use
```

Because the AI works purely off `GameState` and the same validators as the human path, you get a free headless test bench: you can pit two AIs against each other with no scene tree loaded at all, which is the fastest way to shake out rules bugs before touching visuals.

### 7.4 What AI complexity to plan for later (not now)
Starting point: simple heuristic/greedy decision-making is enough to validate the architecture. Real deck-strength AI (minimax/MCTS over the interrupt tree, since "should I interrupt this?" is a real strategic question in this game) is a separate, much later project — don't let AI sophistication block getting the state/event/stack skeleton working first.

---

## 8. Suggested Build Order

Rebuilding the whole thing before it runs again is riskier than it needs to be. Suggested incremental order, each step playable/testable before moving on:

1. **State classes only** (`GameState`, `CardInstance`, `Zone`, `PlayerState`) + `to_dict`/`from_dict`. No logic, no rendering. Write a script that builds a sample state and prints it.
2. **A handful of primitive rules functions** (`move_card`, `deal_damage`, `exhaust_card`) with events, unit-tested headlessly (no Godot scene needed beyond the script runner).
3. **Event bus + minimal renderer** for just those primitives — get a card moving between zones on screen, driven entirely by an event, with no interrupts yet involved.
4. **Priority/stack loop** (§6) with one trivial interrupt card, to prove the model before building real card text on it.
5. **Human input path** wired to the same `submit_action`, replacing whatever direct node manipulation exists today.
6. **AI input path**, starting with "always pass" then a simple heuristic, to validate the shared contract.
7. Only then, start porting real card text/effects at volume — the plumbing above should not need to change per-card, only the library of `resolve_*` functions grows.

Steps 1–4 are the highest-risk, highest-payoff work — they're where the architecture either proves itself or reveals a gap. Everything from step 5 onward is comparatively mechanical once that core holds.


ACTION PLAN

Phase 1 — State classes (/game_logic/state/)
Define GameState, CardInstance, Zone, PlayerState as typed GDScript classes with to_dict/from_dict. No logic. Write a small test script that builds a 2-player game state from a shuffled deck and prints it. This is the foundation everything else stands on — don't skip it.

Phase 2 — Primitive rules functions (/game_logic/actions/)
move_card, deal_damage, exhaust_card, ready_card — each as a pure static function (state, args) → Array[GameEvent]. Unit-testable with no scene. The zone-move primitive is the most critical to get right first because zone-change triggers are everywhere.

Phase 3 — Event bus + minimal renderer
Wire EventBus autoload. Build a BoardRenderer that listens and animates only the Phase 2 primitives (card moves, damage numbers, exhaust tilt). Verify a card can move between zones on-screen driven entirely by an event, with no rules code in the renderer.

Phase 4 — Priority/stack loop
Implement submit_action, pass_priority, PendingAction, consecutive_passes. Test with one trivial card that can interrupt another (the spec's cant_attack_this_turn example). This is the highest-risk step — if the stack model has a flaw it'll show up here on a simple case, not buried in a complex board state.

Phase 5 — Human input path
Wire clicks on CardNode visuals to InputRouter, which calls the can_* validators for highlighting and builds PendingAction objects submitted to submit_action. Human and AI must be calling the same entry point from this step forward.

Phase 6 — AI input path
BasicAI.decide_action(state, player_id) enumerates legal actions via can_* validators (the same ones human highlighting uses), picks by heuristic, submits. Start with "always pass" to prove the contract, then port the existing heuristics.

Phase 7 — Port card effects at volume
Only now does re-implementing cards make sense. Each card effect is a resolve_* function; the plumbing above doesn't change per card.