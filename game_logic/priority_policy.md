# Priority policy — why we must NOT auto-pass after each announcement

Analysis notes, not a spec. Read this before "simplifying" the priority loop.

## The tempting simplification

Watching real play, a player almost never benefits from announcing a second
link while still holding priority. It looks like the engine (and the UI, and
the AI) could just **auto-pass after every announcement** and lose nothing.

That is *almost* true. It is wrong in one specific case, documented at the
bottom. Do not make that change without handling it.

## What the engine actually does (rule 410)

- `submit_action` pushes the link and **keeps priority with the proposer**
  (410.1) — `consecutive_passes = 0`, priority is NOT flipped.
  (`stack_resolver.gd`, "Rule 410.1: proposer keeps priority".)
- `pass_priority` flips priority to the other player and increments
  `consecutive_passes`. Two in a row: the top link resolves (410.4a) — exactly
  one — then `consecutive_passes = 0` and `priority_player = turn_player`.
  A fresh full priority round runs before the next link resolves.
- With an empty chain, two passes close the window (410.4b) → combat step
  transition or phase advance.

Consequences worth stating explicitly, because they kill most "I need to hold
priority" intuitions:

1. **A window can never close without the passing player's own pass.** Two
   consecutive passes require both players, so nobody is ever skipped. You do
   not lose your chance to act by letting a link resolve.
2. **Stacking does not shield the lower link.** The opponent gets a clean
   window after each resolution with the earlier links still on the chain, so
   they can interrupt link 1 just as well after link 2 has resolved.
3. **Relative resolution order is identical** whether the opponent responds
   between your two announcements or after your second link resolves (the
   chain is LIFO either way).
4. **Only instants can ever be the second link.** `_can_play_non_instant`,
   `_can_play_ability`, `_can_place_resource` and `_can_propose_combat` all
   require `pending_actions.is_empty()`, so allies / equipment / sorcery-speed
   abilities can never be stacked on top of anything.

So stacking normally only *costs* you: you commit the second card before
seeing whether the first resolved, and the opponent decides with strictly more
information. Announcing one thing and passing is weakly dominant, and often
strictly better — e.g. play an Instant Ally alone, bait the burn spell, then
respond with the pump so it resolves first and the ally survives. Stacked, the
pump resolves before the opponent commits and the burn simply never comes.

Ordering constraints are not a counterexample: choosing which card to lead
with achieves any order you want, sequentially, with better information. And
if the second card depends on the first one's resolution, it wasn't legal to
announce yet, so it couldn't have been stacked anyway.

## THE EXCEPTION — a non-empty chain locks the turn player out of sorcery speed

Holding priority does not protect a link from *instant* responses. It does
protect against everything gated on `pending_actions.is_empty()`.

Setup: **P1 is acting during P2's non-combat action phase** and wants two
links, c1 then c2.

- *Sequential.* P1 announces c1, passes; P2 passes; c1 resolves. Now
  `priority_player = turn_player` = P2 **and the chain is empty**. P2 is the
  turn player, phase is `action`, no combat window — every gate in
  `_can_play_non_instant` passes. P2 can play an ally, an equipment, or a
  sorcery-speed removal spell *before P1 ever announces c2*.
- *Stacked.* Chain is `c1, c2`. Both pass → c2 resolves → P2 has priority but
  `pending_actions` still holds c1, so P2 is locked to instant speed. Only
  after c1 also resolves does the chain empty.

Same resolution order; different opportunity set. Concretely: play Tristan
Rapidstrike and hold priority for Mark of the Wild, and P2 never gets the
chain-empty moment in which to Coup de Grâce the freshly-resolved 3/3.

The price is real too — c2 is committed blind — so this is a read, not a
dominant line. But it is a legitimate reason a competent player (or a future
AI) holds priority, and an auto-pass engine cannot express it.

### Scope of the exception

It only bites when **the chain emptying would hand the turn player a
sorcery-speed action**:

- P1 must be acting during P2's **action** phase, outside any combat window.
  In combat windows and in the ready / draw / end phases non-instants are
  already illegal, so the lockout buys nothing.
- The gap only opens because c1 fully resolved and emptied the chain. If P1 is
  responding to a link of P2's that is still on the chain, the chain never
  empties either way and nothing is lost by passing.

## If you still want to auto-pass

Acceptable narrowings, in rough order of safety:

- Auto-pass only when the acting player **is** the turn player. Their own
  sorcery-speed window isn't threatened by their own chain.
- Auto-pass in combat windows and in the ready / draw / end phases, where the
  lockout is worthless by construction.
- Never auto-pass for the non-turn player during the turn player's action
  phase — that is exactly the exception.

The current AI (`get_reasonable_actions` returns actions for the turn player
only, and combat instants are played one at a time) does not exploit the
exception. That is a missing capability, not a bug — but do not encode
"auto-pass always" into the engine or the router, or the capability becomes
unreachable.
