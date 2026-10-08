# Mana CLI: setup and agents per project

`mana.toml` is the authoring source. `mana setup` installs local artifacts with a
verified SHA-256 and runs the declared tasks, in order, with no implicit shell.
`mana agent claude|codex` loads only the extensions Mana declares for that project.
It installs nothing into the global profile. Personal settings, authentication and
native policies stay the clients' responsibility; this is not a sandbox against
global plugins.

Each launch gets an exclusive directory in `.mana/sessions/`. Claude mods are
copied there, with MCP configured for the session. Claude skills live in a
temporary plugin. Codex skills are exposed through managed links in
`.agents/skills/`; authoring stays in `agents/skills/`. No `.claude/` is needed.
The launcher copies no credentials and disables no permissions.

`[products.<name>]` declares the topology: each product's `backend` and `frontend`
(a path or a list). `mana doctor` lists the products and fails if a declared
directory does not exist.

`mana doctor` checks configuration, artifacts and executables without inference.
It does not replace the app's own gate. `mana agent --print` shows the plan without
starting the agent. `--` separates the native arguments. `--project` selects a
root; without it, Mana looks for the nearest `mana.toml` among the ancestors.

Invariants: invalid TOML fails before running dependencies; corrupted artifacts are
not published; repeated setup keeps the user's files; links Mana does not own are
never overwritten; concurrent projects do not share mods or MCP state; the child
process's errors and signals are propagated. Dependency tasks can have partial
effects and must be idempotent. Mana promises no rollback of external commands.

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
| `mana forms generate --server --resource --output` | compiles the Ash presentation forms |
| `mana mix <project> [args]` | `mix` in the pinned Elixir image (Docker), with the Moments ownership labels |
| `mana web version <build/web>` | gives a Flutter web build's entrypoints content-specific names |
| `mana capabilities [topic]` | the framework catalog (`framework/catalog.toml`): what exists, how to use it, what it replaces; `skill` generates the agents' skill |
| `mana features list\|show\|which\|check\|changed` | the `feature:<name>` address from `features.toml`: each feature's files and Moments |
| `mana sense --changed\|list\|run` | the sensors in `sensors.toml`: picks those covering the change and runs them cheapest first; the result is an AVP verdict |

A project can include a small `./mana` script as a local entry point. When `command` is
just the agent's name, the launcher tries `mise which` to use the version already installed,
without installing or changing global versions. `MANA_CLAUDE_BIN` and
`MANA_CODEX_BIN` override the executable. Explicit commands with arguments are kept.

```toml
version = 1

[[setup.tasks]]
name = "frontend"
cwd = "app"
command = ["flutter", "pub", "get", "--enforce-lockfile"]
timeout_seconds = 600

[[setup.artifacts]]
source = "${FFF_MCP_SOURCE}"
path = ".mana/bin/fff-mcp"
sha256 = "BINARY_SHA256"

[agents.claude]
command = ["claude"]
mods = ["agents/mods/claude/fff-search", "agents/mods/claude/pi-efficiency"]
skills = ["agents/skills/mana-project"]
disallowed_tools = ["Grep", "Glob"]

[agents.codex]
command = ["codex"]
skills = ["agents/skills/mana-project"]
mcp = ["fff"]

[mcp.fff]
command = ["${MANA_PROJECT}/.mana/bin/fff-mcp", "--no-update-check",
  "--frecency-db", "${MANA_SESSION}/frecency", "--log-file", "${MANA_SESSION}/fff.log"]
```

A Claude mod can declare `.mcp.toml`, whose tables are server names with `command`
(argv) and optional `env`. Mana turns it into `.mcp.json` in the session copy. Do
not declare both. `${MANA_PROJECT}` and `${MANA_SESSION}` are resolved by the
launcher; other variables must exist in the environment. Secrets should be
inherited by the server, not interpolated into the manifest or the printed plan.

`setup --agents claude,codex` selects the adapters. `--skip-tasks` prepares only
artifacts and agents. `setup --runtime-only` runs only the tasks in `setup.tasks`,
without requiring `setup.artifacts`, loading mods or installing skills. That mode is
exclusive: it accepts neither `--agents` nor `--skip-tasks`, and does not apply to
`doctor`/`agent`. Use it to prepare the app without an AI client or a local search
binary. Tasks/artifacts are never run implicitly when the agent opens: run setup
first. Settings and skills are refreshed on every launch. Restart a session to apply
changes to mods.

Codex uses MCP through CLI overrides and does not run Claude's TypeScript hooks. FFF
and Pi are experimental: the launcher working does not prove gains in quality, time,
tokens or subscription duration. That requires a real benchmark.

Reproducible validation:

```sh
(cd framework/cli && dart test)
MANA_TEST_CLAUDE="$(mise which claude)" \
MANA_TEST_CODEX="$(command -v codex)" \
MANA_TEST_FFF="$PWD/.mana/bin/fff-mcp" \
MANA_TEST_PROJECT="$PWD/<project-with-agents>" \
  (cd framework/cli && dart test test/native_test.dart)
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
