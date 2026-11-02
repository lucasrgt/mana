# The Moments benchmark

Mana says it is built for agents working on a running system. This folder
measures that claim on a real product, Host Point (five Flutter apps and one
Ash API built on Mana): the same tasks, done by the same agent with the same
model and budget, once with Moments and once without them. It compares how
often the agent succeeds, how long it takes, how many tokens it spends and how
many bugs reach its pull request.

**Results: pending the first run.** No result is quoted until a run has been
made and its raw data published in [`results/`](results/README.md).

## Method

Each task is a real change from Host Point's history, pinned to its commit.
The agent starts from the tree just before that change (or with only the
task's own files put back, for a commit that made several unrelated fixes)
and gets a prompt describing the problem as an owner would report it. The
tests that commit added are the acceptance check, and the agent never sees
them.

| Task | Kind | What the agent is asked |
| --- | --- | --- |
| `team-account-sees-team-places` | rule | accounts with a team email become test accounts, through a reconciliation rule |
| `dashboard-counts-people` | rule | the municipal dashboard leaves test and store-review travelers out |
| `effects-after-commit` | rule | stored files are deleted only once their transaction commits |
| `booking-charges-in-flight` | bug | three payment bugs once platform checkout is on |
| `google-login-takeover` | bug | an account registered by a squatter, and a phone changed without the password |
| `stale-subscription-events` | bug | only the stored Stripe subscription changes a plan or an ad; erasure cancels subscriptions |
| `test-accounts-see-team-places` | bug | test accounts find the places other test accounts list |
| `free-pro-end-date` | feature | one configurable day when every host's free Pro ends |
| `money-input` | feature | every price field types reais from the cents (design system and two apps) |
| `location-refused` | feature | a location refused for good offers the phone's settings |
| `photos-keep-place-open` | ui | swiping a place's photos no longer reaches the map |
| `agenda-filters-and-order` | ui | five bugs in the hosts' agenda |

Every task folder holds `prompt.md` (what the agent reads) and `task.toml`:

- `commit`: the real change. The agent starts from it with the paths it
  changed that match `revert` (every path by default) put back as they were
  before it.
- `hidden`: the commit's test files. They are taken out of the agent's tree
  and laid over its result only to score it. Files under the task's
  `hidden/` folder are added the same way.
- `[[check]]`: the acceptance. The run succeeds when every check exits 0.
- `[[heldout]]`: the project's other tests (the whole API suite, or the
  app's whole Flutter suite), minus the hidden ones. A failure there is a
  bug that reaches the pull request. `count` reads the number of failing
  tests from the output; `except` leaves out files whose tests already fail
  on the task's own commit.
- `[[prepare]]`: commands run before the agent starts, not timed.

`mana eval benchmark validate` checks every task without a model: with the
built-in `noop` agent the checks must fail, and with `oracle` (the commit's
own change) they must pass with no held-out failure. All twelve tasks pass
it (Mana's harness on 2026-11-02, about three minutes of preparing and
scoring per run with warm caches).

Where a check calls a name the change introduced (an error code, a job, a
view model member), the prompt names it, as a real ask would: the checks
judge behaviour, not whether the agent guessed a name.

### The two conditions

- `moments`: Host Point as its developers have it, after `mana setup`:
  `AGENTS.md`, the `mana` skill and the Moments runner.
- `none`: every line naming Moments is removed from `AGENTS.md` and from the
  `mana` skill, and the runner (`mana/framework/moments/moments`) is replaced
  by a stub that refuses. The code, the Moments' declarations and the docs
  stay as they are.

The prompt is the same in both, after the same preamble (`benchmark.toml`),
which tells the agent how to run the API's and the apps' tests in this
environment.

### Isolation

- Every run gets a workspace of its own outside any other checkout: the
  task's tree, written from git with no history (one commit, `base`), so the
  real fix cannot be read from the log. The `mana` submodule is written the
  same way at the commit Host Point pinned.
- This folder is never in the workspace, so the agent cannot read the tasks
  or their checks.
- Build caches (`copy`) come from the repository's working tree; sources are
  dated now, so whatever the task changed rebuilds.
- The agent's environment drops this shell's Mana, Moments and Host Point
  variables (`drop_env`), except `MANA_LAB_POSTGRES`.
- The agent runs leading a process group of its own with a wall-clock
  timeout (`timeout`): when it expires, the group (test runs, servers) is
  stopped. Containers that mount the workspace or carry one of its projects'
  Moments labels are removed after the run.
- The lab databases are dropped before each run, so no run sees another's
  rows. Runs are sequential.

The default agent runs with `--permission-mode bypassPermissions`: run the
benchmark on a machine (or VM) kept for it.

### What a run records

One JSON line per run in `results.jsonl`: task, kind, condition, repetition,
agent and model, the task's commit and the submodule's, the harness commit,
`wallSeconds` (the agent's time only), `timedOut`, `agentExit`, `tokens`
(input, output, cache read, cache creation), `costUsd`, `turns`, the
agent's diff size, every check and held-out command with its status, exit
code and seconds, `success`, `heldoutFailures`, and `error` when the
harness itself failed (such a run is reported apart and left out of every
rate). Next to it, `runs/<task>-<condition>-<n>/` keeps the agent's diff
(`diff.patch`), its output and every command's log.

`summary.md` is computed from `results.jsonl` alone: per condition, the
success rate, the median wall time, the mean tokens and cost, the held-out
failures and the runs with at least one; then each task's successes per
condition. `mana eval benchmark report <results.jsonl>` recomputes it from
the published lines.

## Running it

Needs: a clone of Host Point with its history and its `mana` submodule
checked out (the harness reads both, and never writes to them), Docker,
`psql`, Flutter, the agent's CLI (signed in), and a PostgreSQL server kept
for the benchmark in `MANA_LAB_POSTGRES` (every run drops its lab
databases):

```sh
export MANA_LAB_POSTGRES=postgres://postgres:postgres@127.0.0.1:55433
cli=framework/cli/mana

# Every task fails untouched and passes on its own commit (no model runs).
$cli eval benchmark validate --repo ../hostpoint-monorepo

# The exact command each run would give the agent; nothing runs.
$cli eval benchmark --repo ../hostpoint-monorepo --dry-run

# The benchmark: tasks × conditions × repetitions (benchmark.toml: 3),
# results in framework/benchmark/results/<time>/. Stopped, the same --out
# resumes where it was.
$cli eval benchmark --repo ../hostpoint-monorepo [--tasks a,b] [--repetitions 1] \
  [--model opus] [--budget 15] [--timeout 45m] [--out <dir>]

# The summary, from the raw lines alone.
$cli eval benchmark report framework/benchmark/results/<time>/results.jsonl
```

`--agent noop` and `--agent oracle` (the task's own commit) are built in;
another agent is a `[agents.<name>]` entry in `benchmark.toml` whose
`command` takes `{prompt}`, `{model}`, `{budget}` and `{workspace}`.

## Limits

- The checks are the tests the real change came with. An agent that solves
  the problem another way can fail a check that pins a detail; the prompts
  name the interfaces the checks call to keep that rare, and the diffs are
  published so a reader can judge.
- Twelve tasks and three repetitions measure a difference of the size the
  claim implies, not a small one.
- The `none` condition removes Moments from the agent's instructions and its
  runner; the Moments' declarations and the docs still mention them.
