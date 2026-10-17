# Mana

Mana is an opinionated framework for building full-stack apps with
[Ash](https://ash-hq.org) on Elixir and [Flutter](https://flutter.dev), built so that
people and AI agents can work on a running system instead of guessing at it.

The product declares its intent once, in Ash resources. From that declaration Mana
derives the HTTP contract, the typed Dart client, forms, permissions the client can ask
about (verbs), live updates, history, privacy rules and the **Moments** that prove each
journey.

## Moments

A moment is a named situation of a running app: "checkout with a coupon", "a booking
paid with the chat open". Instead of clicking your way there every time, you open it by
name and it is ready in seconds, with database, session and screen in place. From there
you can:

- **navigate**: open a situation, switch to another and come back to the same filters
  and scroll position;
- **edit**: save a Dart file and see the new screen in about a second, still in the same
  situation, without logging in again;
- **verify**: check the criteria declared for that situation against the UI and the
  database, or run a whole journey of real gestures;
- **audit**: hand an agent the situation, the files of that screen and the exact Ash
  declaration behind it, instead of the whole codebase;
- **profile**: measure a journey, request by request and query by query;
- **fork**: open several isolated copies of the same situation, each with its own
  database, to try things in parallel.

Every run leaves a short receipt of what code ran, what was observed and what passed.
The protocol is written down in
[framework/moments/protocol-v0.1.md](framework/moments/protocol-v0.1.md).

## Start a project

```sh
git clone https://github.com/lucasrgt/mana.git
mana/framework/cli/mana new notes          # writes ./notes and sets it up
cd notes
mana/framework/moments/moments suite --headless --project app
```

`mana new` writes a whole project around Mana: an Ash backend (`backend/`), a
Flutter app (`app/`) with its generated API client (`packages/api/`), and two
Moments that prove the stack end to end. Mana itself goes in as a git submodule at
`mana/`, pinned to the release you ran the command from. It fetches the
dependencies, writes the first migration, generates the client, syncs the Moments
and commits, so the suite above passes at once. The project's README lists the
everyday commands; `mana lab` runs its backend against a Moments sandbox.

The starter is a list of notes, small on purpose: replace `Notes` with your domain
and keep the wiring.

To move a project to a newer Mana, check the submodule out at the new release and
commit it: `git -C mana checkout v0.2.0`.

## Layout

| Path | What it is |
| --- | --- |
| [`framework/cli`](framework/cli/README.md) | the `mana` CLI: setup, doctor, contracts, client and form generation, catalog, features, sensors, agents |
| [`framework/moments`](framework/moments/README.md) | the Moments runner (`moments`) |
| [`framework/ash`](framework/README.md) | Elixir packages: core primitives, Moments DSL, session, runtime, presentation, contracts |
| [`framework/flutter`](framework/README.md) | Dart packages: session, queries, commands, live entities, primitives, storage, lints, the Moments bridge |
| [`framework/AGENTS.md`](framework/AGENTS.md) | the architecture contract for agents working in a Mana app |
| [`framework/catalog.toml`](framework/catalog.toml) | every piece of the framework, how to use it and what it replaces |

## Requirements

Linux (the runner uses `/proc`, `flock` and user systemd for some features), Docker,
the Flutter SDK (Dart 3.9+) and Node for a few scripts. Elixir runs inside a pinned
Docker image, so it does not need to be installed on the host.

```sh
framework/cli/mana --help
framework/moments/moments --help
```

Both commands compile themselves on first use.

## Status

Mana is young and used by a very small team. APIs and file formats still change
without notice, and the docs describe current behaviour and its limits honestly rather
than promises. Issues and ideas are welcome.

## License

[Apache License 2.0](LICENSE).
