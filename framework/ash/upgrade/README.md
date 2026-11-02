# mana_upgrade

Codemods that move an app's code to newer Mana idioms, built on
[Sourceror](https://hexdocs.pm/sourceror): each edits only the source ranges it
changes, so comments and the layout of the rest of the file stay as written,
and a second run changes nothing.

```sh
framework/cli/mana upgrade verb-steps [paths...] [--dry-run]
framework/cli/mana upgrade timed-rules [paths...] [--dry-run]
# or, with {:mana_upgrade, path: ".../framework/ash/upgrade", only: :dev, runtime: false}:
mix mana.upgrade <verb_steps|timed_rules> [paths...] [--dry-run] [--mapping file.json]
```

Paths are files or directories (`lib` by default; `deps` and `_build` are not
walked). `--dry-run` prints a unified diff and writes nothing. What a codemod
leaves alone is printed as `skipped <file>:<line>: <reason>`.

## `verb_steps`

A Moments step that taps a key a `VerbGate` places on its control becomes a
step naming the verb:

```elixir
step :pay, tap: "booking-pay", until: [:paid]
# becomes
step :pay, verb: {:booking, :pay}, until: [:paid]
```

The key → verb mapping comes from the Flutter apps: `mana upgrade verb-steps`
reads every `VerbGate(verb: XVerbs.y, ...)` and the `Key('...')` on the gate or
on the widget its `builder` returns, and writes
`{"keys": {"booking-pay": "booking.pay"}, "conflicts": {...}}` for
`--mapping`. Only steps of a `moment` inside `moments do` are read, keyword and
block forms alike. A key placed for two verbs, or for a verb chosen at runtime
(`verb: verb`), is skipped, as is any interpolated key. A verb step without
`on:` taps the screen's first control of that verb: the keyed one, unless the
screen draws that verb twice.

## `timed_rules`

A `Mana.Reconcile` rule whose `holds:` only asks whether a timestamp plus a
fixed duration is still ahead of now becomes `within:`/`since:`:

```elixir
desired :accepted_resolves, "...", scope: expr(status == :accepted),
  holds: {MyApp.Bookings, :recent?}

def recent?(booking),
  do: DateTime.compare(DateTime.add(booking.accepted_at, 15, :minute), DateTime.utc_now()) == :gt

# the rule becomes
desired :accepted_resolves, "...", scope: expr(status == :accepted),
  within: {15, :minute}, since: :accepted_at
```

The function is looked up in the files given (through `alias` and
`__MODULE__`) and must be the single clause of a public `def` with a plain
argument, whose body is one of the shapes listed in `Mana.Upgrade.TimedRules`
(`compare`/`after?`/`before?`/`diff` of `DateTime` or `NaiveDateTime`).
Anything else, and a rule that already has `within:` or `since:`, is skipped.
The rewritten rule differs only at the boundary second and for a record
without the timestamp, which `Mana.Reconcile` reports as diverging where the
function would have raised. The function stays; delete it once nothing else
calls it.

## Adding a codemod

A module implementing `Mana.Upgrade` (`rewrite(sources, opts)` → the rewritten
sources and the skips), registered in `Mana.Upgrade.codemods/0`, with
before/after fixtures under `test/fixtures/<codemod>/` and a test that a second
run changes nothing.
