#!/bin/bash
# lib/skills.sh — Bash-native skill registry and dispatcher (ADR-010)
#
# Discovers skills by scanning SKILL.md files under configured scan paths.
# Each SKILL.md must start with a YAML frontmatter block (--- ... ---) that
# declares at minimum: name, hooks (list), timeout_seconds, fail_open.
#
# Registry cache: .orchestrator/state/skill-registry.json
# Rebuilt when: --rescan-skills flag passed, or cache is missing.
#
# Public functions:
#   skills_init [--force]                            — discover & cache
#   skill_invoke <name> <prompt>                     — invoke a skill by name
#   skill_invoke_hook <hook> <feat_id> [extra_args]  — fan-out to all skills for a hook
#   skill_list                                       — print registered skills
#
# Hook taxonomy (declared in SKILL.md frontmatter):
#   phase3.fix_hint      — called before Phase 3 fix loop to enrich prompt
#   phase4_5.summarize   — called during ingest to summarize review/CI text
#   learning.curate      — called after learning_write to curate entries
#   routing.suggest_agent — called by router to suggest agent overrides

SKILLS_REGISTRY_FILE="${STATE_DIR:-/tmp}/.skill-registry.json"

# Default scan paths (config can add more via SKILLS_SCAN_PATHS)
_skills_default_scan_paths() {
  echo "${ROOT_DIR:-.}/.claude/skills"
}

# ── skills_init ───────────────────────────────────────────────────────
# Discovers skills, parses frontmatter, writes registry cache.
# Usage: skills_init [--force]

skills_init() {
  local force=false
  [ "${1:-}" = "--force" ] && force=true

  SKILLS_REGISTRY_FILE="$STATE_DIR/skill-registry.json"

  if [ -f "$SKILLS_REGISTRY_FILE" ] && [ "$force" != "true" ]; then
    return 0
  fi

  local scan_paths="${SKILLS_SCAN_PATHS:-$(_skills_default_scan_paths)}"
  local registry_entries="[]"

  # Split colon-separated scan paths
  local IFS_ORIG="$IFS"
  IFS=":"
  for scan_path in $scan_paths; do
    IFS="$IFS_ORIG"
    [ -z "$scan_path" ] && continue
    [ ! -d "$scan_path" ] && { IFS=":"; continue; }

    # Find SKILL.md files one level deep
    while IFS= read -r skill_file; do
      [ -z "$skill_file" ] && continue
      local parsed
      parsed=$(_skills_parse_frontmatter "$skill_file")
      if [ -n "$parsed" ] && [ "$parsed" != "null" ]; then
        registry_entries=$(node -e "
          const entries = JSON.parse('$(_js_escape_for_arg "$registry_entries")');
          const entry = JSON.parse('$(_js_escape_for_arg "$parsed")');
          entries.push(entry);
          process.stdout.write(JSON.stringify(entries));
        " 2>/dev/null || echo "$registry_entries")
      fi
    done < <(find "$scan_path" -name "SKILL.md" -maxdepth 2 2>/dev/null)

    IFS=":"
  done
  IFS="$IFS_ORIG"

  mkdir -p "$(dirname "$SKILLS_REGISTRY_FILE")"
  node -e "
    const fs = require('fs');
    const entries = JSON.parse(process.argv[1]);
    fs.writeFileSync('$SKILLS_REGISTRY_FILE', JSON.stringify({
      generated_at: new Date().toISOString(),
      skills: entries
    }, null, 2));
    console.log('  Skill registry: ' + entries.length + ' skill(s) registered');
  " "$(cat "$SKILLS_REGISTRY_FILE" 2>/dev/null | node -e "
    let d=''; process.stdin.on('data',c=>d+=c);
    process.stdin.on('end',()=>{
      try { process.stdout.write(JSON.stringify(JSON.parse(d).skills||[])); }
      catch(e) { process.stdout.write('[]'); }
    });
  " 2>/dev/null || echo "[]")" 2>/dev/null || true

  # Write directly
  node -e "
    const fs = require('fs');
    let entries;
    try { entries = JSON.parse(process.argv[1]); } catch(e) { entries = []; }
    fs.writeFileSync('$SKILLS_REGISTRY_FILE', JSON.stringify({
      generated_at: new Date().toISOString(),
      skills: entries
    }, null, 2));
    console.log('  Skill registry: ' + entries.length + ' skill(s) registered');
  " "$registry_entries" 2>/dev/null || true
}

# ── _skills_parse_frontmatter ─────────────────────────────────────────
# Internal: parse YAML frontmatter from a SKILL.md file.
# Prints a JSON object or empty string on parse failure.

_skills_parse_frontmatter() {
  local skill_file="$1"
  local skill_dir
  skill_dir="$(dirname "$skill_file")"
  local skill_path_escaped
  skill_path_escaped=$(printf '%s' "$skill_file" | sed "s/'/\\\\'/g")

  node -e "
    const fs = require('fs');
    const path = require('path');

    let raw;
    try { raw = fs.readFileSync('${skill_path_escaped}', 'utf-8'); } catch(e) { process.exit(0); }

    const fmMatch = raw.match(/^---\n([\s\S]*?)\n---/);
    if (!fmMatch) { process.exit(0); }

    const fm = fmMatch[1];

    // Minimal YAML parser for our frontmatter subset
    const lines = fm.split('\n');
    const obj = { skill_file: '${skill_path_escaped}', skill_dir: '${skill_dir}' };
    let currentListKey = null;

    for (const line of lines) {
      const listItem = line.match(/^  - (.+)$/);
      if (listItem && currentListKey) {
        obj[currentListKey] = obj[currentListKey] || [];
        obj[currentListKey].push(listItem[1].trim());
        continue;
      }
      const kv = line.match(/^(\w[\w_]*)\s*:\s*(.*)$/);
      if (!kv) { currentListKey = null; continue; }
      const key = kv[1];
      const val = kv[2].trim();
      if (val === '') {
        currentListKey = key;
        obj[key] = [];
      } else if (val === 'true') {
        obj[key] = true;
        currentListKey = null;
      } else if (val === 'false') {
        obj[key] = false;
        currentListKey = null;
      } else if (/^\d+$/.test(val)) {
        obj[key] = parseInt(val, 10);
        currentListKey = null;
      } else {
        obj[key] = val.replace(/^[\"']|[\"']$/g, '');
        currentListKey = null;
      }
    }

    if (!obj.name) { process.exit(0); }
    obj.hooks = obj.hooks || [];
    obj.timeout_seconds = obj.timeout_seconds || 60;
    obj.fail_open = obj.fail_open !== false;

    process.stdout.write(JSON.stringify(obj));
  " 2>/dev/null || echo ""
}

# Internal: escape a string so it can be passed as a single-quoted JS string argument.
# Only used for small, controlled strings (not user input).
_js_escape_for_arg() {
  printf '%s' "$1" | sed "s/'/\\\\'/"
}

# ── skill_invoke ──────────────────────────────────────────────────────
# Usage: skill_invoke <name> <prompt> [--input-file <path>]
# Wraps `claude --skill <name> <prompt>` with op_timeout.
# Logs output to .orchestrator/state/{feat_id}/skill-{name}-{ts}.log.
# Returns non-zero on failure. If fail_open=true, logs and returns 0.

skill_invoke() {
  local skill_name="$1"
  local prompt="$2"
  local input_file=""

  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --input-file) shift; input_file="$1" ;;
    esac
    shift
  done

  SKILLS_REGISTRY_FILE="${SKILLS_REGISTRY_FILE:-$STATE_DIR/skill-registry.json}"

  # Look up skill in registry
  local skill_meta
  skill_meta=$(node -e "
    const fs = require('fs');
    let reg;
    try { reg = JSON.parse(fs.readFileSync('$SKILLS_REGISTRY_FILE','utf-8')); } catch(e) { process.exit(1); }
    const s = (reg.skills||[]).find(s => s.name === '$skill_name');
    if (!s) { process.exit(1); }
    process.stdout.write(JSON.stringify(s));
  " 2>/dev/null || echo "")

  local timeout_secs=60
  local fail_open=true

  if [ -n "$skill_meta" ]; then
    timeout_secs=$(echo "$skill_meta" | node -p "JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8')).timeout_seconds||60" 2>/dev/null || echo "60")
    local fo_str
    fo_str=$(echo "$skill_meta" | node -p "JSON.parse(require('fs').readFileSync('/dev/stdin','utf-8')).fail_open===false?'false':'true'" 2>/dev/null || echo "true")
    [ "$fo_str" = "false" ] && fail_open=false
  fi

  local feat_id="${FEATURE_ID:-unknown}"
  local ts
  ts=$(date -u +%Y%m%d-%H%M%S)
  local log_file="$STATE_DIR/$feat_id/skill-${skill_name}-${ts}.log"
  mkdir -p "$(dirname "$log_file")"

  local exit_code=0
  if command -v claude &>/dev/null; then
    local model_flag=""
    [ -n "${MODEL_DEFAULT:-}" ] && model_flag="--model $MODEL_DEFAULT"

    if [ -n "$input_file" ]; then
      op_timeout "$timeout_secs" claude $model_flag --skill "$skill_name" "$prompt" < "$input_file" 2>&1 | tee "$log_file" || exit_code=$?
    else
      op_timeout "$timeout_secs" claude $model_flag --skill "$skill_name" "$prompt" 2>&1 | tee "$log_file" || exit_code=$?
    fi
  else
    info "skill_invoke: claude CLI not found — skipping $skill_name"
    exit_code=1
  fi

  if [ "$exit_code" -ne 0 ]; then
    if [ "$fail_open" = "true" ]; then
      info "skill_invoke: $skill_name failed (exit $exit_code) — fail_open=true, continuing"
      return 0
    else
      err "skill_invoke: $skill_name failed (exit $exit_code)"
      return "$exit_code"
    fi
  fi

  return 0
}

# ── skill_invoke_hook ─────────────────────────────────────────────────
# Usage: skill_invoke_hook <hook_name> <feat_id> [extra_prompt_suffix]
# Fan-out: invokes every skill registered for the given hook in sequence.
# Failures are handled per-skill (fail_open respected by skill_invoke).

skill_invoke_hook() {
  local hook_name="$1"
  local feat_id="$2"
  local extra="${3:-}"

  SKILLS_REGISTRY_FILE="${SKILLS_REGISTRY_FILE:-$STATE_DIR/skill-registry.json}"
  [ ! -f "$SKILLS_REGISTRY_FILE" ] && return 0

  local matching_skills
  matching_skills=$(node -e "
    const fs = require('fs');
    let reg;
    try { reg = JSON.parse(fs.readFileSync('$SKILLS_REGISTRY_FILE','utf-8')); } catch(e) { process.exit(0); }
    const matched = (reg.skills||[]).filter(s => (s.hooks||[]).includes('$hook_name'));
    matched.forEach(s => console.log(s.name));
  " 2>/dev/null || echo "")

  [ -z "$matching_skills" ] && return 0

  local prompt="hook:$hook_name feat_id:$feat_id"
  [ -n "$extra" ] && prompt="$prompt $extra"

  while IFS= read -r sname; do
    [ -z "$sname" ] && continue
    info "skill_invoke_hook: $hook_name → $sname"
    skill_invoke "$sname" "$prompt"
  done <<< "$matching_skills"
}

# ── skill_list ────────────────────────────────────────────────────────
# Usage: skill_list
# Prints all registered skills and their hooks.

skill_list() {
  SKILLS_REGISTRY_FILE="${SKILLS_REGISTRY_FILE:-$STATE_DIR/skill-registry.json}"

  if [ ! -f "$SKILLS_REGISTRY_FILE" ]; then
    info "No skill registry found. Run: ./scripts/orchestrate.sh --rescan-skills"
    return
  fi

  node -e "
    const fs = require('fs');
    let reg;
    try { reg = JSON.parse(fs.readFileSync('$SKILLS_REGISTRY_FILE','utf-8')); } catch(e) { reg = {skills:[]}; }
    const skills = reg.skills || [];
    if (skills.length === 0) { console.log('  No skills registered.'); return; }
    skills.forEach(s => {
      console.log('  ' + s.name + '  (timeout: ' + s.timeout_seconds + 's, fail_open: ' + s.fail_open + ')');
      (s.hooks||[]).forEach(h => console.log('    hook: ' + h));
    });
  " 2>/dev/null || info "Could not read skill registry"
}
