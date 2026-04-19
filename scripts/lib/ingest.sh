#!/bin/bash
# lib/ingest.sh — Phase 4.5 review-ingest stub (ADR-010 PID tracking layer)
#
# ADR-009 adds full review-ingest logic (PR comments + CI logs → summarizer → learning store).
# This file provides the PID-tracking infrastructure (ADR-010) so that background jobs
# do not accumulate as zombies across long orchestrator sessions.
#
# ADR-009 will extend this file with:
#   ingest_reviews <feat_id>   — full review-ingest pass (PR review comments + CI failures)
#
# ADR-010 adds:
#   ingest_trigger_if_merged   — fires background job and writes PID file
#   ingest_reap_stale          — called at startup to collect finished background jobs
#   ingest_status              — list active/stale background ingests
#
# Confidence threshold (used by ADR-009 extension):
INGEST_CONFIDENCE_THRESHOLD="${INGEST_CONFIDENCE_THRESHOLD:-0.7}"

# ── ingest_trigger_if_merged ──────────────────────────────────────────
# Called by runner.sh after PR creation.
# Fires a background ingest job and records its PID for later reaping.
# When ADR-009 is not present, logs a no-op info message.

ingest_trigger_if_merged() {
  local feat_id="$1"

  [ "${LOCAL_MODEL_ENABLED:-false}" != "true" ] && return 0

  local results_file="$STATE_DIR/$feat_id/results.json"
  [ ! -f "$results_file" ] && return 0

  local pr_url
  pr_url=$(node -p "
    try { JSON.parse(require('fs').readFileSync('$results_file','utf-8')).pr_url || ''; }
    catch(e) { ''; }
  " 2>/dev/null || echo "")

  [ -z "$pr_url" ] && return 0

  local pid_file="$STATE_DIR/$feat_id/ingest.pid"
  local log_file="$STATE_DIR/$feat_id/ingest-bg.log"
  mkdir -p "$STATE_DIR/$feat_id"

  if declare -f ingest_reviews &>/dev/null; then
    (ingest_reviews "$feat_id" >> "$log_file" 2>&1; echo "exit:$?" >> "$log_file") &
    local bg_pid=$!
    node -e "
      require('fs').writeFileSync('$pid_file', JSON.stringify({
        pid: $bg_pid,
        feat_id: '$feat_id',
        started_at: new Date().toISOString()
      }, null, 2));
    " 2>/dev/null || true
    info "Ingest: background review-ingest triggered for $feat_id (PID $bg_pid)"
  else
    info "Ingest: ingest_reviews not available — skipping (merge ADR-009 to enable)"
  fi
}

# ── ingest_reap_stale ─────────────────────────────────────────────────
# Called at orchestrate.sh startup.
# For each .pid file, checks if the process is still alive.
# If dead, cleans up the pid file and logs the completion status.

ingest_reap_stale() {
  [ ! -d "$STATE_DIR" ] && return 0

  local reaped=0
  for pid_file in "$STATE_DIR"/*/ingest.pid; do
    [ -f "$pid_file" ] || continue

    local pid feat_id started_at
    pid=$(node -p "try{JSON.parse(require('fs').readFileSync('$pid_file','utf-8')).pid||0}catch(e){0}" 2>/dev/null || echo "0")
    feat_id=$(node -p "try{JSON.parse(require('fs').readFileSync('$pid_file','utf-8')).feat_id||''}catch(e){''}" 2>/dev/null || echo "")
    started_at=$(node -p "try{JSON.parse(require('fs').readFileSync('$pid_file','utf-8')).started_at||''}catch(e){''}" 2>/dev/null || echo "")

    [ "$pid" -eq 0 ] && { rm -f "$pid_file"; continue; }

    if kill -0 "$pid" 2>/dev/null; then
      # Still running
      continue
    fi

    # Process finished — clean up
    rm -f "$pid_file"
    reaped=$((reaped + 1))

    # Log the completion
    local log_file="$STATE_DIR/$feat_id/ingest-bg.log"
    local exit_line=""
    [ -f "$log_file" ] && exit_line=$(grep "^exit:" "$log_file" | tail -1 || echo "")

    info "Ingest: reaped finished background job (feat: $feat_id, PID: $pid, started: $started_at, ${exit_line:-exit: unknown})"
  done

  [ "$reaped" -gt 0 ] && info "Ingest: reaped $reaped stale background job(s)"
  return 0
}

# ── ingest_status ─────────────────────────────────────────────────────
# Lists active and recently completed background ingest jobs.

ingest_status() {
  [ ! -d "$STATE_DIR" ] && { info "No state directory found."; return 0; }

  local found=0
  for pid_file in "$STATE_DIR"/*/ingest.pid; do
    [ -f "$pid_file" ] || continue
    found=1

    local pid feat_id started_at
    pid=$(node -p "try{JSON.parse(require('fs').readFileSync('$pid_file','utf-8')).pid||0}catch(e){0}" 2>/dev/null || echo "0")
    feat_id=$(node -p "try{JSON.parse(require('fs').readFileSync('$pid_file','utf-8')).feat_id||''}catch(e){''}" 2>/dev/null || echo "")
    started_at=$(node -p "try{JSON.parse(require('fs').readFileSync('$pid_file','utf-8')).started_at||''}catch(e){''}" 2>/dev/null || echo "")

    local status="running"
    kill -0 "$pid" 2>/dev/null || status="zombie (not yet reaped)"

    echo "  feat: $feat_id | PID: $pid | started: $started_at | status: $status"
  done

  [ "$found" -eq 0 ] && info "No active background ingest jobs."
}
