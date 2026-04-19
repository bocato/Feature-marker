# ADR-010: Skill Pluggability & Stuck-State Elimination

## Status

Proposed

## Context

A system audit against the ADR-008 + ADR-009 codebase revealed two interlocking problems:

**1. Skills are not pluggable.** The only `claude --skill` invocation in the entire CLI (`runner.sh:377-379`) is hardcoded. There is no registry, no discovery, no hook taxonomy — skills cannot be added or removed without editing source code.

**2. The orchestrator can get stuck.** Several confirmed hang risks exist in the codebase:

| Risk                                                                                      | Location                | Severity |
| ----------------------------------------------------------------------------------------- | ----------------------- | -------- |
| `\| while` pipe subshell: `break`/`continue`/mutations silently don't propagate to parent | `runner.sh:99`          | HIGH     |
| Unbounded `read -p` prompt in supervised mode                                             | `size_gate.sh:168`      | HIGH     |
| `--resume` flag parsed but never wired up; paused features have no operator path back     | `orchestrate.sh:79,111` | HIGH     |
| Background ingest jobs: no PID file, no reaper, zombies accumulate                        | `ingest.sh:220`         | MEDIUM   |
| `claude --skill` invocation has no timeout                                                | `runner.sh:377`         | MEDIUM   |
| `gh pr view`, `gh run view --log-failed` have no timeout                                  | `ingest.sh:58-75`       | MEDIUM   |
| Sentinel files (`retry-count`, `phase3-fix-attempts`) survive across runs silently        | `runner.sh:417-465`     | MEDIUM   |
| JSON injection: `node -p "JSON.stringify('$var')"` breaks on single quotes                | multiple                | LOW      |

## Decisions

### D1 — Bash-native skill registry (`scripts/lib/skills.sh`)

A new `skills.sh` module discovers SKILL.md files by scanning configured paths under `.claude/skills/`. Each SKILL.md carries a YAML frontmatter block declaring: `name`, `hooks`, `timeout_seconds`, `fail_open`.

The registry is cached to `.orchestrator/state/skill-registry.json` and rebuilt with `--rescan-skills`. Any directory containing a SKILL.md file is a valid skill — no changes to orchestrator source required to add a new skill.

Public API:

- `skills_init [--force]` — discover and cache
- `skill_invoke <name> <prompt>` — dispatch with timeout and fail_open
- `skill_invoke_hook <hook> <feat_id>` — fan-out to all skills for a hook

Hook taxonomy: `phase3.fix_hint`, `phase4_5.summarize`, `learning.curate`, `routing.suggest_agent`.

### D2 — Portable timeout helper (`op_timeout` in `scripts/lib/util.sh`)

`op_timeout <seconds> <command...>` wraps every external call that can block: `claude --skill`, `gh pr view`, `gh run view --log-failed`. Falls back from `timeout` → `gtimeout` → `perl alarm`.

The existing `local_model.sh` `curl --max-time` pattern is unchanged (already timed).

### D3 — Subshell-pipe fix (`runner.sh` main loop)

Replace:

```bash
echo "$items" | node -e "..." | while IFS= read -r item_json; do
  break  # only breaks subshell — parent loop continues
done
```

With process substitution:

```bash
while IFS= read -r item_json; do
  break  # breaks parent loop correctly
done < <(echo "$items" | node -e "...")
```

All `| while` patterns in `scripts/lib/` are audited and fixed where loop-control or variable mutation crosses the pipe.

### D4 — `--resume-paused <feat-id>` operator command

The dead `OPT_RESUME` boolean is removed. A real `--resume-paused <feat-id>` subcommand re-enters `runner.sh` at the checkpoint phase for a paused feature. Human-class pauses require `--ack`.

### D5 — Pause taxonomy (`pause_kind: human | transient`)

Every pause record in `.orchestrator/state/<feat-id>/pause.json` carries a `pause_kind` field:

- `human` — requires operator decision (size gate declined, breaking change, supervised checkpoint). `--skip-blocked` skips these. `--resume-paused` requires `--ack`.
- `transient` — pipeline error that may resolve on retry. Auto-retried on next run with backoff.

The size gate prompt gets `read -t 120` so unattended runs auto-decline (recorded as `pause_kind:"human", action:"timeout_skipped"`) instead of hanging indefinitely.

### D6 — Background ingest reaping (`scripts/lib/ingest.sh`)

`ingest_trigger_if_merged` now writes a PID file to `.orchestrator/state/<feat-id>/ingest.pid`. `ingest_reap_stale` (called at `sub_run` startup) walks all PID files, checks liveness with `kill -0`, and cleans up finished jobs. `ingest-status` subcommand lists active jobs.

### D7 — Sentinel cleanup on resume

`runner_clear_sentinels <feat-id> <class>` removes `retry-count` and `phase3-fix-attempts` sentinel files. On `--resume-paused` for a `transient` pause, transient sentinels are cleared; human sentinels are preserved until `--ack` is passed.

### D8 — Learning-curator skill

The first real consumer of the skill registry. Registered with hooks `phase4_5.summarize` and `learning.curate`. Accepts PR review text or CI logs as input and returns the same JSON contract as `local_model::summarize` — so `ingest.sh` can select between `local`, `skill`, or `both` via `local_model.summarizer_strategy`.

### D9 — JSON-injection hardening (`js_string` in `scripts/lib/util.sh`)

`js_string <value>` pipes the value through `node` via stdin (never argv), producing a safe JSON string literal. The fragile `node -p "JSON.stringify('$var')"` pattern is replaced at the highest-risk sites in `ingest.sh` and `learning.sh`.

## Consequences

- Skills become first-class, drop-in units: add a `SKILL.md` file, done.
- `full_auto` and `checkpoint` modes can run unattended without operator intervention to unstick them.
- `--resume-paused <feat-id>` gives operators a clean, typed recovery path.
- Background ingest jobs no longer accumulate as zombies across long sessions.
- New `ingest-status` and `skills` subcommands improve operational visibility.
- `util.sh` is a new shared module; all future shell modules should source it.

## Compatibility

- ADR-009 modules (`local_model.sh`, full `ingest.sh`) are sourced conditionally (`[ -f ... ] && source ...`). ADR-010 degrades gracefully when ADR-009 is not present.
- The `learning-curator` skill mirrors the `local_model::summarize` JSON contract, so `ingest.sh` switch logic is minimal.
