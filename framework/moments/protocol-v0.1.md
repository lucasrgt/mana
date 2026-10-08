# Moments — specification v0.1

A **moment** is a named point of a running system. A project describes its moments in a single text file, `MOMENTS.md`, versioned with the code: a navigable map of the system's behaviour.

Moments is a pattern of **navigation by meaning**. Instead of rebuilding a situation through its mechanics (the clicks, the calls, the setup data), people and agents go to it by name ("checkout with a coupon"), look, step back, branch and compare. Verifying is one of the verbs, and it is optional: a moment without any verification is still useful to understand, show, explore, edit or coordinate. End-to-end tests are one of many uses, not the purpose.

## The moment

A moment has a stable **name** that serves as its address, a **parent** and a **recipe** (the transition from the parent to it, versioned with the code). A moment is not a value: it is a coordinate in the runtime's time that only becomes a concrete **situation** when it is evaluated under a version of the code, so that *moment × version = situation*.

Every situation is **observable** through one or more **projections** (the screen as text, the database rows, the logs, what each actor sees). The comparison between two situations is the difference between their **normalized** projections, without timestamps, generated identifiers, irrelevant list order or session secrets.

A moment is **reproducible**: evaluated twice under the same version, it produces the same normalized projections. It declares the **mode** by which it can be revived: direct restoration of a snapshot, or replaying the recipe (required when the situation lives only in memory, such as a fight on a game server).

A moment is **forkable**: from one situation, independent continuations can coexist without affecting each other.

Comparing across moments, at the same version, shows what an action does. Comparing across versions, at the same moment, shows what a code change does; in that case both evaluations use the **same recipe**, and if the recipe changed between versions the comparison declares that the moment was redefined, so that a redefinition is never mistaken for a change in behaviour.

## The map: `MOMENTS.md`

```markdown
# Market moments
moments: 0.1
layers: db=sqlite, client=browser

## empty
run: playwright moments/recipes.mjs#empty
check: the screen shows "Enter the Market"
Freshly created database with products, coupons and two users. Nobody signed in.
To get here: create the database from scratch, start the server and open the app root.

## checkout-with-coupon
from: cart-3-items
run: playwright moments/recipes.mjs#checkout-with-coupon
check: the discount is the larger of the coupon and the buy-3 promotion, never both
verify: playwright moments/checks.mjs#discountDoesNotStack
A cart of 3 items with the MARKET10 coupon applied, ready to check out.
To get here: in the cart, type MARKET10 in the "Coupon" field and click "Apply".
```

The header has a `#` title and `key: value` lines:

- `moments`: the version of the format the map follows (`0.1` for this specification).
- `layers`: the layers that make up a situation, as `name=type`. The type says which driver captures and restores that layer (`sqlite`, `postgres`, `browser`, `files`…). When there are several actors (two players, two users), each one is a layer with its own name.

Each `##` is a moment. The name is the address: lowercase letters, digits and hyphens, unique in the file. The keys are:

- `from:` the parent moment. Without `from`, it is a root.
- `run:` optional. The executor and the reference of the recipe, from the parent to here (`playwright file#export`, `node file#export`, `shell command`…). The format does not interpret the code; it only points to it.
- `check:` optional, repeatable. Something observable that must be true at the moment, in free text.
- `verify:` optional, repeatable. An executable verification of a `check:`, with the same syntax as `run:`.
- `memory:` optional. Declares that the situation lives only in memory and is revived by replaying the recipe from the last persistent moment.
- `expires:` optional (for example `50m`, `1h`). Declares that the moment's snapshot is only valid for that long after it is captured, for situations the system itself makes expire (a pending charge that runs out). Once expired, the snapshot is rebuilt from the parent on the next open. Prefer `expires:` over `memory:` when the situation can be captured: opening a moment should be the cheapest move.
- The rest is the description: what is true there and, in natural language, how to get there from the parent.

Unknown keys are kept and ignored. Extensions for a niche use the `x-` prefix (for example `x-game-map:`).

## Rules

1. **The text is enough.** The description must let someone (or an agent) reach the moment without the `run:`. The executable recipe is a shortcut, not the definition.
2. **Moments are live starting points.** Opening a moment hands over the system running at that point, ready to continue. It is not a recording.
3. **Recipes are source; snapshots are cache.** The map and the recipes are versioned in the repository. Snapshots are derived and can be regenerated at any time.
4. **State in files, disposable process.** An open instance is its directory (the layers on disk). If the system's process dies, the implementation revives it from those files, or by replaying the recipe when the moment lives in memory.
5. **Observing changes nothing.** No observation operation may alter the situation.
6. **The right move is the cheapest one.** Verbs that hand over ready navigation (opening already showing the place, walking a path while showing the effect of each step) are preferable to making the navigator compose several operations; agents tend to redo paths by hand when navigation requires composition.

## Verbs

An implementation offers, at least, the navigation verbs (open, observe, act, go back, fork, compare and save) and, optionally, verify:

| Operation | What it does |
|---|---|
| `ls` | lists the map and whether each snapshot is up to date |
| `up <moment>` | opens an isolated instance already at that moment |
| `fork <moment> -n N` | N independent instances of the same moment |
| `look <instance>` | observes the projections |
| `step <instance> <action>` | acts from the moment and observes again |
| `check <instance>` | runs the moment's executable verifications |
| `save <instance> <name>` | turns the exploration into a new entry of the map |
| `reset <instance>` | goes back to the original moment, with the current code |
| `diff <a> <b>` | difference between normalized projections, per layer |
| `trace <moment>` | walks the path from the root and shows, in a single operation, what each step changes in the projections |

## Conformance

An implementation conforms when it passes these checks, for any valid map:

| Property | Check |
|---|---|
| Name | the name is unique in the map and stable across versions (renaming is removing and creating) |
| Reproducible | two evaluations under the same version produce identical normalized projections |
| Observable | every situation exposes at least one projection, and the normalization is declared |
| Forkable | N continuations from the same situation do not affect each other |
| Comparable (derived) | `diff(a, a)` is empty; `diff` across versions uses the same recipe and flags a redefined recipe |

## Layer drivers

A driver implements, for one layer type: `project` (reads the normalized projection of the live layer, without stopping or changing the system), `materialize` (prepares an instance's layer from a snapshot, or empty at a root), `capture` (photographs the layer after a transition, with the system stopped), `diff` (compares two photographs in terms of the layer) and `dispose` (releases the resources). Actor layers add `open`, `observe`, `close` and `expose`. Drivers and executors are plugins; the specification depends on none of them.

## What is not part of the specification

Tools, snapshot engines, oracles, PR review, bisect, effect catalogs and benchmarks are implementations and uses. The Mana Moments runner is one implementation.
