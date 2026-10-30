# Mana CLI: setup and agents per project

`mana.toml` is the authoring source. `mana setup` installs local artifacts with a
verified SHA-256, runs the declared tasks, in order, with no implicit shell, and
links each agent's declared skills where that agent finds project skills: Codex in
`.agents/skills/`, Claude in `.claude/skills/`. A plain `codex` or `claude` in the
project then loads them; authoring stays in `agents/skills/`. Mana owns only the
links its ledger (`.mana/<agent>-skills.json`) records and never replaces anything
else there. It installs nothing into the global profile.

`[products.<name>]` declares the topology: each product's `backend` and `frontend`
(a path or a list). `mana doctor` lists the products and fails if a declared
directory does not exist.

`mana doctor` checks configuration, artifacts, skill links and executables without
inference. It does not replace the app's own gate. `--project` selects a root;
without it, Mana looks for the nearest `mana.toml` among the ancestors.

Invariants: invalid TOML fails before running dependencies; corrupted artifacts are
not published; repeated setup keeps the user's files; links Mana does not own are
never overwritten. Dependency tasks can have partial effects and must be
idempotent. Mana promises no rollback of external commands.

Running the CLI itself, from the repository root:

```sh
framework/cli/mana --help
```

The CLI is Dart (`bin/mana.dart`). `framework/cli/mana` compiles the executable into
`.dart_tool/mana` on the first call and again when the sources or the lock change
(atomic swap, so concurrent calls never get a half-written binary). For your own
PATH, link to that script. There is no automatic global installation. The `toml`
package does the full parsing; `pubspec.lock` pins the versions.

The same CLI gathers the tools the other framework pieces use:

| Command | What it does |
| --- | --- |
| `mana contracts install` | downloads oasdiff and OpenAPI Generator pinned by SHA-256 in `contracts/toolchain.json` |
| `mana contracts compare --base --candidate` | compares OpenAPI contracts ([contracts](../contracts/README.md)) |
| `mana client generate --input --output --name` | generates and analyses the Dart client, with recorded provenance |
| `mana mix <project> [args]` | `mix` in the pinned Elixir image (Docker), with the Moments ownership labels |
| `mana web version <build/web>` | gives a Flutter web build's entrypoints content-specific names |
| `mana capabilities [topic]` | the framework catalog (`framework/catalog.toml`): what exists, how to use it, what it replaces; `skill` generates the agents' skill |
| `mana features list\|show\|which\|check\|changed` | the `feature:<name>` address from `features.toml`: each feature's files and Moments |
| `mana sense --changed\|list\|run` | the sensors in `sensors.toml`: picks those covering the change and runs them cheapest first; the result is an AVP verdict |

`mana doctor` runs each agent's `command` with `--version`. When `command` is just
the agent's name, it tries `mise which` to use the version already installed;
`MANA_CLAUDE_BIN` and `MANA_CODEX_BIN` override the executable.

```toml
version = 1

[[setup.tasks]]
name = "frontend"
cwd = "app"
command = ["flutter", "pub", "get", "--enforce-lockfile"]
timeout_seconds = 600

[agents.claude]
skills = ["mana/framework/agents/skills/mana", "agents/skills/project"]

[agents.codex]
skills = ["mana/framework/agents/skills/mana", "agents/skills/project"]
```

`setup --agents claude,codex` selects the agents. `--skip-tasks` prepares only
artifacts and skill links. `setup --runtime-only` runs only the tasks in
`setup.tasks`, without requiring `setup.artifacts` or linking skills; it accepts
neither `--agents` nor `--skip-tasks`. Tasks and artifacts never run implicitly: run
setup first, and again after a skill is added or renamed.

Reproducible validation:

```sh
(cd framework/cli && dart test)
```

The native suite uses a simulated loopback HTTP provider, disposable test settings
and real Claude/FFF/Codex processes. It never calls the remote model. Without those
variables, the two native tests are skipped explicitly. Sessions stay in
`.mana/sessions/` for diagnostics; remove them after the agents end. FFF keeps an
exclusive frecency database and log per session.

Adapter sources: [Claude plugins](https://code.claude.com/docs/en/plugins/create),
[Claude CLI](https://code.claude.com/docs/en/cli-reference),
[Codex configuration](https://developers.openai.com/codex/config-reference),
[Codex skills](https://developers.openai.com/codex/skills).

## New projects and the lab

`mana new <folder>` writes a project to start from (see the repository README):
an Ash backend, a Flutter app with its generated client, two Moments and Mana as a
submodule pinned to this checkout's commit. `--mana-url`/`--mana-ref` pick another
source or release; `--no-setup` only writes the files. The template lives in
`templates/new/`; `__name__`, `__Name__` and `__dash__` become the folder name, its
module name and its dashed form.

`mana lab prepare|serve|test|mix` runs a project's backend against a Moments
sandbox's PostgreSQL (`MANA_MOMENTS_INSTANCE`, the `instance.json` that
`moments up` writes). The database is `MANA_DATABASE` (`<backend>_dev`, or
`<backend>_test` for `test`); the backend reads `LAB_DATABASE_URL`, `LAB_PORT`,
`LAB_SECRET_KEY_BASE`, `LAB_TOKEN_SIGNING_SECRET`, `LAB_WEB_ORIGIN(S)`,
`LAB_SERVER` and `MOMENTS_RECIPE_TOKEN`, and any variable listed in
`MANA_LAB_PASS` is passed through.

On a machine that is itself the sandbox (a dev container, a CI job) the lab
needs no container engine: `MANA_LAB_POSTGRES=postgres://user:password@host:port`
names a PostgreSQL server already running there, used in place of the Moments
sandbox (`psql` must be installed), and `MANA_ELIXIR=local` runs `mix` on the
machine's own Elixir instead of the pinned image.

## Catalog, features and sensors

Mana is one system. `framework/catalog.toml` lists every piece with how to use it
and what it replaces; `mana capabilities <topic>` searches it (accent-insensitive)
and `mana capabilities skill` generates `framework/agents/skills/mana/SKILL.md`,
which the project's agents load. `mana doctor` fails if the skill is out of date.

`features.toml`, at the project root, gives each feature a `feature:<name>` address
with its paths and Moments (`<app>:<glob>`). `mana features check` (and `doctor`)
fail when a file under the `roots` has no owner, when a path matches no file or when
a cited Moment does not exist.

`sensors.toml` declares the verification signals: `run` (argv, no shell), `cwd`,
`covers` (globs, `feature:<glob>` or `moment:<app>:<glob>`), `proves`, `cost`,
`requires`, `env` (`${root}` is the root), `gate` and `output` (`exit` or `moments`,
where exit 2 is undecided). `mana sense --changed` uses the diff since `--base` plus
new files; a failing sensor with `gate` stops the more expensive ones (`--keep-going`
continues) and `--budget` leaves those that do not fit as `unresolved`. Logs and the
verdict live in `.mana/sense/<date>/`.
