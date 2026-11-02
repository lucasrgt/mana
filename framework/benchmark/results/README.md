# Benchmark results

Each run of `mana eval benchmark` writes a folder here, named by its start
time (UTC):

- `results.jsonl`: one JSON line per run, the raw data (fields in
  [the benchmark's README](../README.md#what-a-run-records)).
- `summary.md`: the tables, recomputed from `results.jsonl` alone with
  `mana eval benchmark report <results.jsonl>`.
- `runs/<task>-<condition>-<n>/`: the agent's diff (`diff.patch`), its
  output (`agent.out`, `agent.err`) and the log of every prepare, check and
  held-out command.

No run has been published yet.
