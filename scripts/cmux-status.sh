#!/bin/bash
# cmux-status.sh -- optional cmux sidebar feedback for a Quality Gate run.
#
# Every subcommand is best-effort: if cmux is not installed, not running, or the
# call fails, this script exits 0 silently. Quality Gate never depends on it.
#
# Usage:
#   cmux-status.sh phase <PhaseName>      # status pill + progress bar
#   cmux-status.sh log <message>
#   cmux-status.sh ok <message>
#   cmux-status.sh error <message>
#   cmux-status.sh notify-passed <body>   # the only notification we ever emit
#   cmux-status.sh codex <mm:ss> [activity]  # live pill while Codex is running
#   cmux-status.sh codex-clear
#   cmux-status.sh clear
#   cmux-status.sh available              # exit 0 if cmux usable
#
# Phase table (per Quality Gate spec):
#   Inspecting 10 / Testing 25 / Codex Review 45 / Fixing 60 / Re-testing 70
#   Final Review 85 / Approved 90 / Committing 95 / Completed 100

set -uo pipefail

QG_STATUS_KEY="quality_gate"
QG_CODEX_KEY="qg_codex"

have_cmux() { command -v cmux >/dev/null 2>&1; }

# Silently swallow every failure; cmux is decoration, not a dependency.
cx() {
  have_cmux || return 0
  cmux "$@" >/dev/null 2>&1 || true
  return 0
}

phase_percent() {
  case "$1" in
    Inspecting)     echo 10  ;;
    Testing)        echo 25  ;;
    "Codex Review") echo 45  ;;
    Fixing)         echo 60  ;;
    Re-testing)     echo 70  ;;
    "Final Review") echo 85  ;;
    Approved)       echo 90  ;;
    Committing)     echo 95  ;;
    Completed)      echo 100 ;;
    *)              echo -1  ;;
  esac
}

phase_color() {
  case "$1" in
    Completed|Approved) echo "#34c759" ;;
    "Codex Review"|"Final Review") echo "#0a84ff" ;;
    Fixing) echo "#ff9500" ;;
    *) echo "#8e8e93" ;;
  esac
}

case "${1:-}" in
  available)
    have_cmux || exit 1
    exit 0
    ;;

  phase)
    name="${2:-}"
    [ -n "$name" ] || exit 0
    pct=$(phase_percent "$name")
    if [ "$pct" -lt 0 ]; then
      cx set-status "$QG_STATUS_KEY" "QG: $name" --icon sparkle --priority 90
      exit 0
    fi
    frac=$(awk -v p="$pct" 'BEGIN{printf "%.2f", p/100}')
    cx set-status "$QG_STATUS_KEY" "QG: $name" --icon sparkle --color "$(phase_color "$name")" --priority 90
    cx set-progress "$frac" --label "Quality Gate: $name"
    cx log --level progress --source quality-gate -- "$name ($pct%)"
    ;;

  log)
    shift || true
    [ -n "${1:-}" ] || exit 0
    cx log --level info --source quality-gate -- "$*"
    ;;

  ok)
    shift || true
    [ -n "${1:-}" ] || exit 0
    cx log --level success --source quality-gate -- "$*"
    ;;

  error)
    shift || true
    msg="${*:-Quality Gate error}"
    cx set-status "$QG_STATUS_KEY" "QG: FAILED" --icon sparkle --color "#ff3b30" --priority 95
    cx log --level error --source quality-gate -- "$msg"
    ;;

  notify-passed)
    shift || true
    body="${*:-}"
    cx set-status "$QG_STATUS_KEY" "QG: passed" --icon sparkle --color "#34c759" --priority 90
    cx set-progress 1.0 --label "Quality Gate: Completed"
    if [ -n "$body" ]; then
      cx notify --title "Quality Gate Passed" --body "$body"
    else
      cx notify --title "Quality Gate Passed"
    fi
    cx log --level success --source quality-gate -- "Quality Gate passed"
    ;;

  codex)
    # A Codex review is one long blocking call. This pill is the only signal
    # that it is alive, so it carries the elapsed time and what Codex is doing.
    shift || true
    elapsed="${1:-}"
    shift || true
    activity="${*:-}"
    if [ -n "$activity" ]; then
      cx set-status "$QG_CODEX_KEY" "Codex ${elapsed} · ${activity}" --icon magnifyingglass --color "#0a84ff" --priority 92
    else
      cx set-status "$QG_CODEX_KEY" "Codex ${elapsed}" --icon magnifyingglass --color "#0a84ff" --priority 92
    fi
    ;;

  codex-clear)
    cx clear-status "$QG_CODEX_KEY"
    ;;

  clear)
    cx clear-status "$QG_STATUS_KEY"
    cx clear-status "$QG_CODEX_KEY"
    cx clear-progress
    ;;

  ""|-h|--help)
    sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
    ;;

  *)
    printf 'ERROR: unknown subcommand: %s\n' "$1" >&2
    exit 1
    ;;
esac
exit 0
