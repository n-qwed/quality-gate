#!/bin/bash
# PreToolUse hook (Bash tool) -- block direct `git commit` only in repositories
# where Quality Gate has been explicitly enabled.
#
# Design notes:
#  * Default OFF. If anything is unknown, unparseable, or absent, this hook stays
#    silent (exit 0, no output) which leaves Claude Code's normal permission flow
#    untouched. It never emits "allow" for arbitrary commands.
#  * Only Claude Code's Bash tool passes through here. A `git commit` the user
#    types in their own terminal is not affected.
#  * Self-contained on purpose: it must not break if the skill directory moves.
#  * The repository is judged per `git commit` invocation, at the directory the
#    commit actually runs in: the hook cwd, followed through `cd <dir>`, subshells
#    `( ... )` and `git -C <dir>`. When that directory cannot be determined
#    (variables, `cd -`, pushd/popd, --git-dir/--work-tree, GIT_DIR=...), the
#    hook cwd is checked as well, so an uncertain command is never judged more
#    leniently than before.

set -uo pipefail

# No decision -> normal permission flow.
pass() { exit 0; }

emit() {
  # $1 = allow|deny, $2 = reason
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg d "$1" --arg r "$2" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  fi
  exit 0
}

command -v jq  >/dev/null 2>&1 || pass
command -v git >/dev/null 2>&1 || pass
command -v awk >/dev/null 2>&1 || pass

payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || pass

tool_name=$(printf '%s' "$payload"   | jq -r '.tool_name // empty' 2>/dev/null || true)
command_str=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
hook_cwd=$(printf '%s' "$payload"    | jq -r '.cwd // empty' 2>/dev/null || true)

[ "$tool_name" = "Bash" ] || pass
[ -n "$command_str" ]     || pass

if [ -z "$hook_cwd" ] || [ ! -d "$hook_cwd" ]; then
  hook_cwd="$PWD"
fi

# --- Quality Gate enabled for the repository/worktree containing <dir>? ------
# Prints the repository top level and returns 0 when enabled.
qg_enabled_at() {
  (
    cd "$1" 2>/dev/null || exit 1
    git rev-parse --git-dir >/dev/null 2>&1 || exit 1
    marker=$(git rev-parse --path-format=absolute --git-path quality-gate-enabled 2>/dev/null) || marker=""
    if [ -z "$marker" ]; then
      rel=$(git rev-parse --git-path quality-gate-enabled 2>/dev/null) || exit 1
      case "$rel" in
        /*) marker="$rel" ;;
        *)  marker="$PWD/$rel" ;;
      esac
    fi
    [ -f "$marker" ] || exit 1
    git rev-parse --show-toplevel 2>/dev/null || pwd
  )
}

# --- tokenizer ---------------------------------------------------------------
# Quote-aware split of the command into one token per line:
#   W-<TAB>word   plain word (quotes removed)
#   WE<TAB>word   word containing a $ or ` expansion (value not knowable)
#   O-<TAB>op     operator: ";" (also &&, ||, |, &, newline), "(" or ")"
# Quotes, $( ... ) and backticks nest the way the shell nests them, and stay
# part of the surrounding word, so -m "$(cat <<'EOF' ... EOF)" is one token.
# Here-document bodies are skipped (they are data), except when the heredoc
# feeds a shell (bash/sh/zsh/... <<EOF), where the body is parsed as commands.
tokenize() {
  printf '%s' "$1" | LC_ALL=C awk '
    function flush() {
      if (inword) { gsub(/[\t\n\r]/, " ", tok); printf "W%s\t%s\n", (ex ? "E" : "-"), tok }
      tok = ""; inword = 0; ex = 0
    }
    function op(o) { printf "O-\t%s\n", o }
    function addc(ch) { tok = tok ch; inword = 1 }
    # Does the simple command that contains position p run a shell?
    function feeds_shell(p,    j, ch, seg, nw, w, k, b) {
      for (j = p - 1; j >= 1; j--) {
        ch = substr(s, j, 1)
        if (ch == ";" || ch == "&" || ch == "|" || ch == "\n" || ch == "(" || ch == "`") break
      }
      seg = substr(s, j + 1, p - j - 1)
      nw = split(seg, w, /[ \t]+/)
      for (k = 1; k <= nw; k++) {
        b = w[k]; sub(/.*\//, "", b)
        if (b ~ /^(bash|sh|zsh|dash|ksh|fish|eval|source)$/) return 1
      }
      return 0
    }
    # Register the heredoc whose "<<" ends just before position j.
    # Returns the index of the last character of the delimiter word.
    function read_heredoc(j,    dash, w, ch) {
      dash = 0
      if (substr(s, j, 1) == "-") { dash = 1; j++ }
      while (j <= n && (substr(s, j, 1) == " " || substr(s, j, 1) == "\t")) j++
      w = ""
      while (j <= n) {
        ch = substr(s, j, 1)
        if (ch ~ /[ \t\n;&|()<>]/) break
        if (ch == SQ || ch == DQ) {
          j++
          while (j <= n && substr(s, j, 1) != ch) { w = w substr(s, j, 1); j++ }
        } else if (ch == BS) {
          j++; w = w substr(s, j, 1)
        } else {
          w = w ch
        }
        j++
      }
      if (w != "") { hd[nh] = w; hdash[nh] = dash; nh++ }
      return j - 1
    }
    # Skip the bodies of pending heredocs; i is at the newline that starts them.
    function skip_bodies(i,    pos, h, rest, e, line, lend) {
      pos = i + 1
      for (h = 0; h < nh; h++) {
        while (pos <= n) {
          rest = substr(s, pos); e = index(rest, "\n")
          if (e == 0) { line = rest; lend = n } else { line = substr(rest, 1, e - 1); lend = pos + e - 1 }
          if (hdash[h]) sub(/^\t+/, "", line)
          pos = lend + 1
          if (line == hd[h]) break
        }
      }
      nh = 0
      return pos - 1
    }
    BEGIN { RS = "\001"; SQ = "\047"; DQ = "\042"; BS = "\\"; BQ = "`" }
    {
      s = $0; n = length(s); tok = ""; inword = 0; ex = 0; d = 0; st[0] = "TOP"; nh = 0
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1); nx = substr(s, i + 1, 1); cur = st[d]
        if (cur == "SQ") { if (c == SQ) d--; else addc(c); continue }
        if (cur == "DQ") {
          if (c == BS) { i++; addc(substr(s, i, 1)); continue }
          if (c == DQ) { d--; continue }
          if (c == "$" && nx == "(") { i++; st[++d] = "SUB"; ex = 1; addc("$("); continue }
          if (c == BQ) { st[++d] = "BT"; ex = 1; addc(c); continue }
          if (c == "$") ex = 1
          addc(c); continue
        }
        if (cur == "BT") {
          if (c == BS) { i++; addc(substr(s, i, 1)); continue }
          if (c == BQ) d--
          addc(c); continue
        }
        # TOP or SUB: shell syntax
        if (c == BS) { i++; ch = substr(s, i, 1); if (ch != "\n") addc(ch); continue }
        if (c == SQ) { st[++d] = "SQ"; inword = 1; continue }
        if (c == DQ) { st[++d] = "DQ"; inword = 1; continue }
        if (c == "$" && nx == "(") { i++; st[++d] = "SUB"; ex = 1; addc("$("); continue }
        if (c == BQ) { st[++d] = "BT"; ex = 1; addc(c); continue }
        if (c == "<" && nx == "<" && substr(s, i + 2, 1) != "<" && !feeds_shell(i)) {
          if (cur == "TOP") flush()
          i = read_heredoc(i + 2); continue
        }
        if (c == "\n" && nh > 0) {
          if (cur == "TOP") { flush(); op(";") } else addc(" ")
          i = skip_bodies(i); continue
        }
        if (cur == "SUB") {
          if (c == "(") st[++d] = "SUB"
          else if (c == ")") d--
          if (c == "$") ex = 1
          addc(c); continue
        }
        if (c == " " || c == "\t" || c == "\r") { flush(); continue }
        if (c == "\n" || c == ";") { flush(); op(";"); continue }
        if (c == "(" || c == ")") { flush(); op(c); continue }
        if (c == "&") {
          p = substr(s, i - 1, 1)
          if (p == ">" || p == "<" || nx == ">") { addc(c); continue }
          flush(); if (nx == "&") i++; op(";"); continue
        }
        if (c == "|") { flush(); if (nx == "|") i++; op(";"); continue }
        if (c == "$") ex = 1
        addc(c)
      }
      flush()
    }'
}

kinds=()
vals=()
while IFS=$'\t' read -r k v; do
  kinds[${#kinds[@]}]="$k"
  vals[${#vals[@]}]="$v"
done <<EOF
$(tokenize "$command_str")
EOF
n=${#kinds[@]}
[ "$n" -gt 0 ] || pass

# resolve_dir <base> <path> -> prints absolute dir, returns 1 if it does not exist
resolve_dir() {
  local base="$1" p="$2"
  case "$p" in
    "~")    p="$HOME" ;;
    "~/"*)  p="$HOME/${p#\~/}" ;;
    "~"*)   return 1 ;;
    /*)     ;;
    *)      p="$base/$p" ;;
  esac
  [ -d "$p" ] || return 1
  (cd "$p" 2>/dev/null && pwd)
}

# --- walk the command --------------------------------------------------------
cur="$hook_cwd"
stack=()
uncertain=0
cmdpos=1
commit_dirs=()
wrapper_dirs=()

i=0
while [ "$i" -lt "$n" ]; do
  k="${kinds[$i]}"
  w="${vals[$i]}"
  i=$((i + 1))

  if [ "$k" = "O-" ]; then
    case "$w" in
      "(") stack[${#stack[@]}]="$cur" ;;
      ")")
        if [ "${#stack[@]}" -gt 0 ]; then
          last=$((${#stack[@]} - 1))
          cur="${stack[$last]}"
          unset "stack[$last]"
        else
          uncertain=1
        fi
        ;;
    esac
    cmdpos=1
    continue
  fi

  case "$w" in
    *commit-reviewed.sh*) wrapper_dirs[${#wrapper_dirs[@]}]="$cur" ;;
    # GIT_DIR=... git commit, env GIT_DIR=..., export GIT_WORK_TREE=...
    GIT_DIR=*|GIT_WORK_TREE=*) uncertain=1 ;;
  esac

  if [ "$cmdpos" -eq 1 ]; then
    # Leading VAR=value assignments and transparent prefixes keep command position.
    if printf '%s' "$w" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*='; then
      continue
    fi
    case "$w" in
      env|command|builtin|time|nohup|exec|sudo|noglob) continue ;;
    esac
    cmdpos=0
    case "$w" in
      cd)
        # skip -P / -L style options
        while [ "$i" -lt "$n" ] && [ "${kinds[$i]}" != "O-" ] && [ "${vals[$i]}" != "-" ] \
              && [ "${vals[$i]#-}" != "${vals[$i]}" ]; do
          i=$((i + 1))
        done
        if [ "$i" -ge "$n" ] || [ "${kinds[$i]}" = "O-" ]; then
          uncertain=1                      # bare `cd` -> $HOME, treat as unknown
        else
          target="${vals[$i]}"
          if [ "${kinds[$i]}" = "WE" ] || [ "$target" = "-" ]; then
            uncertain=1
          elif newdir=$(resolve_dir "$cur" "$target"); then
            cur="$newdir"
          else
            uncertain=1
          fi
          i=$((i + 1))
        fi
        continue
        ;;
      pushd|popd) uncertain=1; continue ;;
    esac
  fi

  # A git invocation anywhere in the command (also after xargs and the like).
  case "$w" in
    git|*/git) ;;
    *) continue ;;
  esac
  eff="$cur"
  while [ "$i" -lt "$n" ] && [ "${kinds[$i]}" != "O-" ]; do
    a="${vals[$i]}"
    case "$a" in
      -C)
        if [ $((i + 1)) -lt "$n" ] && [ "${kinds[$((i + 1))]}" != "O-" ]; then
          if [ "${kinds[$((i + 1))]}" = "WE" ]; then
            uncertain=1
          elif newdir=$(resolve_dir "$eff" "${vals[$((i + 1))]}"); then
            eff="$newdir"
          else
            uncertain=1
          fi
        fi
        i=$((i + 2)); continue ;;
      --git-dir|--work-tree)
        uncertain=1; i=$((i + 2)); continue ;;
      --git-dir=*|--work-tree=*)
        uncertain=1; i=$((i + 1)); continue ;;
      -c|--exec-path|--namespace|--config-env|--super-prefix)
        i=$((i + 2)); continue ;;
      -*) i=$((i + 1)); continue ;;
      commit) commit_dirs[${#commit_dirs[@]}]="$eff"; i=$((i + 1)); break ;;
      *) break ;;
    esac
  done
done

# --- decide ------------------------------------------------------------------
# enabled_among <dir>... -> prints the first enabled repository top level
enabled_among() {
  local d top
  for d in "$@"; do
    [ -n "$d" ] || continue
    if top=$(qg_enabled_at "$d"); then
      printf '%s' "$top"
      return 0
    fi
  done
  return 1
}

if [ "${#commit_dirs[@]}" -gt 0 ]; then
  candidates=("${commit_dirs[@]}")
  [ "$uncertain" -eq 1 ] && candidates[${#candidates[@]}]="$hook_cwd"
  if top=$(enabled_among "${candidates[@]}"); then
    emit deny "Quality Gate is enabled for this repository ($top).

Direct git commit is disabled.

Keep changes uncommitted and run /qg:gate.
The reviewed commit will be created at the end of the quality gate."
  fi
  pass
fi

# The sanctioned reviewed-commit wrapper, with no bare `git commit` alongside it.
if [ "${#wrapper_dirs[@]}" -gt 0 ]; then
  candidates=("${wrapper_dirs[@]}")
  [ "$uncertain" -eq 1 ] && candidates[${#candidates[@]}]="$hook_cwd"
  if enabled_among "${candidates[@]}" >/dev/null; then
    emit allow "Quality Gate: reviewed-commit wrapper (approval is verified by the script itself)."
  fi
fi

pass
