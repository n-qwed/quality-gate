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
#    `( ... )`, command substitutions `$( ... )` / backticks, and `git -C <dir>`.
#  * Fail closed on doubt. When a directory cannot be determined (variables,
#    `cd -`, pushd/popd, --git-dir/--work-tree, GIT_DIR=..., a `cd` whose effect
#    depends on control flow: after &&/||, or before ||, | or &), every directory
#    the command visited -- including the hook cwd -- is checked as well.
#  * Here-document bodies fed to a shell are judged as commands (in their own
#    scope). Other bodies are data, but a body that looks like `git ... commit`
#    still counts as a commit at that point.

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
# Splits shell source into one token per line:
#   W-<TAB>word   plain word (quotes removed)
#   WE<TAB>word   word containing a $ / ` expansion (value not knowable)
#   O-<TAB>op     operator: ";" (also newline), "&&", "||", "|", "&", "(", ")"
#   S-<TAB>src    source of a command substitution $( ... ) or ` ... `, emitted
#                 at the end of the simple command that contains it
#   H-<TAB>src    body of a here-document fed to a shell (bash <<EOF, <<EOF | sh)
#   C-<TAB>       a data here-document body that looks like `git ... commit`
# S/H sources encode newlines as \036 and tabs as \037. Quotes, $( ... ) and backticks nest the way
# the shell nests them, so -m "$(cat <<'EOF' ... EOF)" stays one word.
tokenize() {
  printf '%s' "$1" | LC_ALL=C awk '
    function flush() {
      if (inword) { gsub(/[\t\n\r]/, " ", tok); printf "W%s\t%s\n", (ex ? "E" : "-"), tok }
      tok = ""; inword = 0; ex = 0
    }
    # Substitution sources wait until the end of the simple command, so they
    # never sit between a git option and its subcommand.
    function op(o) { printf "%s", pend; pend = ""; printf "O-\t%s\n", o }
    function addc(ch) { tok = tok ch; inword = 1 }
    function enc(x) { gsub(/\n/, "\036", x); gsub(/\t/, "\037", x); return x }
    function open_sub(kind, start) {
      if (subopen < 0) { subopen = d; sstart = start }
      st[++d] = kind; ex = 1
    }
    function close_sub(end) {
      d--
      if (d == subopen) { pend = pend "S-\t" enc(substr(s, sstart, end - sstart)) "\n"; subopen = -1 }
    }
    # Does the physical line around position p run a shell? Looks back to the
    # start of the simple command and forward to the end of the line, so both
    # `bash <<EOF` and `cat <<EOF | sh` count.
    function feeds_shell(p,    j, ch, e, seg, nw, w, k, b) {
      for (j = p - 1; j >= 1; j--) {
        ch = substr(s, j, 1)
        if (ch == ";" || ch == "&" || ch == "|" || ch == "\n" || ch == "(" || ch == BQ) break
      }
      e = index(substr(s, p), "\n")
      seg = (e == 0) ? substr(s, j + 1) : substr(s, j + 1, p - j - 1 + e)
      gsub(/[;&|()`<>"\047]/, " ", seg)
      nw = split(seg, w, /[ \t\n]+/)
      for (k = 1; k <= nw; k++) {
        b = w[k]; sub(/.*\//, "", b)
        if (b ~ /^(bash|sh|zsh|dash|ksh|fish|eval|source|\.)$/) return 1
      }
      return 0
    }
    # Register the heredoc whose "<<" ends just before position j.
    # Returns the index of the last character of the delimiter word.
    function read_heredoc(j, shell,    dash, w, ch) {
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
      if (w != "") { hd[nh] = w; hdash[nh] = dash; hsh[nh] = shell; nh++ }
      return j - 1
    }
    # Consume the bodies of pending heredocs; i is at the newline that starts
    # them. Emits H/C tokens only at top level (nested ones are re-tokenized
    # from the S source by the caller).
    function skip_bodies(i, emit_tokens,    pos, h, rest, e, line, cmp, lend, body) {
      pos = i + 1
      for (h = 0; h < nh; h++) {
        body = ""
        while (pos <= n) {
          rest = substr(s, pos); e = index(rest, "\n")
          if (e == 0) { line = rest; lend = n } else { line = substr(rest, 1, e - 1); lend = pos + e - 1 }
          cmp = line
          if (hdash[h]) sub(/^\t+/, "", cmp)
          pos = lend + 1
          if (cmp == hd[h]) break
          body = body line "\n"
        }
        if (emit_tokens) {
          if (hsh[h]) printf "H-\t%s\n", enc(body)
          else if (body ~ GITCOMMIT) printf "C-\t\n"
        }
      }
      nh = 0
      return pos - 1
    }
    BEGIN {
      RS = "\001"; SQ = "\047"; DQ = "\042"; BS = "\\"; BQ = "`"
      # git, then options (each optionally followed by one value), then commit
      GITCOMMIT = "(^|[^A-Za-z0-9_.-])git([ \t]+-[^ \t\n]*([ \t]+[^- \t\n][^ \t\n]*)?)*[ \t]+commit([^A-Za-z0-9_-]|$)"
    }
    {
      s = $0; n = length(s); tok = ""; inword = 0; ex = 0; d = 0; st[0] = "TOP"; nh = 0; subopen = -1; pend = ""
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1); nx = substr(s, i + 1, 1); cur = st[d]
        if (cur == "SQ") { if (c == SQ) d--; else addc(c); continue }
        if (cur == "DQ") {
          if (c == BS) { i++; addc(substr(s, i, 1)); continue }
          if (c == DQ) { d--; continue }
          if (c == "$" && nx == "(") { addc("$("); i++; open_sub("SUB", i + 1); continue }
          if (c == BQ) { addc(c); open_sub("BT", i + 1); continue }
          if (c == "$") ex = 1
          addc(c); continue
        }
        if (cur == "BT") {
          if (c == BS) { i++; addc(substr(s, i, 1)); continue }
          addc(c)
          if (c == BQ) close_sub(i)
          continue
        }
        # TOP or SUB: shell syntax
        if (c == BS) { i++; ch = substr(s, i, 1); if (ch != "\n") addc(ch); continue }
        if (c == SQ) { st[++d] = "SQ"; inword = 1; continue }
        if (c == DQ) { st[++d] = "DQ"; inword = 1; continue }
        if (c == "$" && nx == "(") { addc("$("); i++; open_sub("SUB", i + 1); continue }
        if (c == BQ) { addc(c); open_sub("BT", i + 1); continue }
        if (c == "<" && nx == "<" && substr(s, i + 2, 1) != "<") {
          if (cur == "TOP") flush()
          i = read_heredoc(i + 2, feeds_shell(i)); continue
        }
        if (c == "\n" && nh > 0) {
          if (cur == "TOP") { flush(); op(";") } else addc(" ")
          i = skip_bodies(i, cur == "TOP"); continue
        }
        if (cur == "SUB") {
          if (c == "(") { st[++d] = "SUB"; addc(c); continue }
          if (c == ")") { addc(c); close_sub(i); continue }
          if (c == "$") ex = 1
          addc(c); continue
        }
        if (c == " " || c == "\t" || c == "\r") { flush(); continue }
        if (c == "\n" || c == ";") { flush(); op(";"); continue }
        if (c == "(" || c == ")") { flush(); op(c); continue }
        if (c == "&") {
          p = substr(s, i - 1, 1)
          if (p == ">" || p == "<" || nx == ">") { addc(c); continue }
          flush()
          if (nx == "&") { i++; op("&&") } else op("&")
          continue
        }
        if (c == "|") {
          flush()
          if (nx == "|") { i++; op("||") } else op("|")
          continue
        }
        if (c == "$") ex = 1
        addc(c)
      }
      flush()
      printf "%s", pend
    }'
}

kinds=()
vals=()
# load <source> -> fills tk_kinds/tk_vals with its tokens
load() {
  tk_kinds=()
  tk_vals=()
  local k v
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] || continue
    tk_kinds[${#tk_kinds[@]}]="$k"
    tk_vals[${#tk_vals[@]}]="$v"
  done <<EOF
$(tokenize "$1")
EOF
}

load "$command_str"
[ "${#tk_kinds[@]}" -gt 0 ] || pass
kinds=("${tk_kinds[@]}")
vals=("${tk_vals[@]}")
n=${#kinds[@]}

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

# splice_at <index> <source>: replace token <index> with "(" + tokens of <source> + ")"
splice_at() {
  local at="$1" src j
  src=$(printf '%s' "$2" | tr '\036\037' '\n\t')
  load "$src"
  local -a nk=() nv=()
  j=0
  while [ "$j" -lt "$at" ]; do nk[${#nk[@]}]="${kinds[$j]}"; nv[${#nv[@]}]="${vals[$j]}"; j=$((j + 1)); done
  nk[${#nk[@]}]="O-"; nv[${#nv[@]}]="("
  j=0
  while [ "$j" -lt "${#tk_kinds[@]}" ]; do nk[${#nk[@]}]="${tk_kinds[$j]}"; nv[${#nv[@]}]="${tk_vals[$j]}"; j=$((j + 1)); done
  nk[${#nk[@]}]="O-"; nv[${#nv[@]}]=")"
  j=$((at + 1))
  while [ "$j" -lt "$n" ]; do nk[${#nk[@]}]="${kinds[$j]}"; nv[${#nv[@]}]="${vals[$j]}"; j=$((j + 1)); done
  kinds=("${nk[@]}")
  vals=("${nv[@]}")
  n=${#kinds[@]}
}

# --- walk the command --------------------------------------------------------
cur="$hook_cwd"
stack=()
uncertain=0
cmdpos=1
prev_op=";"
splices=0
commit_dirs=()
wrapper_dirs=()
visited=("$hook_cwd")

i=0
while [ "$i" -lt "$n" ]; do
  k="${kinds[$i]}"
  w="${vals[$i]}"

  case "$k" in
    S-|H-)
      splices=$((splices + 1))
      if [ "$splices" -gt 64 ]; then
        # Too deeply nested to follow: fail closed.
        uncertain=1
        commit_dirs[${#commit_dirs[@]}]="$cur"
        break
      fi
      splice_at "$i" "$w"
      continue
      ;;
    C-)
      commit_dirs[${#commit_dirs[@]}]="$cur"
      i=$((i + 1))
      continue
      ;;
  esac
  i=$((i + 1))

  if [ "$k" = "O-" ]; then
    case "$w" in
      "(") stack[${#stack[@]}]="$cur"; prev_op=";" ;;
      ")")
        if [ "${#stack[@]}" -gt 0 ]; then
          last=$((${#stack[@]} - 1))
          cur="${stack[$last]}"
          unset "stack[$last]"
        else
          uncertain=1
        fi
        prev_op=";"
        ;;
      *) prev_op="$w" ;;
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
        # A cd whose effect depends on control flow is not certain:
        # `x && cd d`, `x || cd d`, `x | cd d`, `cd d || y`, `cd d | y`, `cd d & y`.
        case "$prev_op" in "&&"|"||"|"|"|"&") uncertain=1 ;; esac
        j="$i"
        while [ "$j" -lt "$n" ] && [ "${kinds[$j]}" != "O-" ]; do j=$((j + 1)); done
        if [ "$j" -lt "$n" ]; then
          case "${vals[$j]}" in "||"|"|"|"&") uncertain=1 ;; esac
        fi
        # skip -P / -L style options
        while [ "$i" -lt "$n" ] && [ "${kinds[$i]}" != "O-" ] && [ "${vals[$i]}" != "-" ] \
              && [ "${vals[$i]#-}" != "${vals[$i]}" ]; do
          i=$((i + 1))
        done
        if [ "$i" -ge "$n" ] || [ "${kinds[$i]}" != "W-" ]; then
          uncertain=1                      # bare `cd`, `cd $(...)`, `cd "$X"`
        else
          target="${vals[$i]}"
          if [ "$target" = "-" ]; then
            uncertain=1
          elif newdir=$(resolve_dir "$cur" "$target"); then
            cur="$newdir"
            visited[${#visited[@]}]="$cur"
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
        if [ $((i + 1)) -lt "$n" ] && [ "${kinds[$((i + 1))]}" = "W-" ] \
           && newdir=$(resolve_dir "$eff" "${vals[$((i + 1))]}"); then
          eff="$newdir"
          visited[${#visited[@]}]="$eff"
        else
          uncertain=1
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
  [ "$uncertain" -eq 1 ] && candidates=("${candidates[@]}" "${visited[@]}")
  if top=$(enabled_among "${candidates[@]}"); then
    emit deny "Quality Gate is enabled for this repository ($top).

Direct git commit is disabled.

Keep changes uncommitted and run /qg:gate.
The reviewed commit will be created at the end of the quality gate."
  fi
  pass
fi

# The sanctioned reviewed-commit wrapper, with no bare `git commit` anywhere in
# the command (substitutions and shell-fed heredocs included, see above).
if [ "${#wrapper_dirs[@]}" -gt 0 ]; then
  candidates=("${wrapper_dirs[@]}")
  [ "$uncertain" -eq 1 ] && candidates=("${candidates[@]}" "${visited[@]}")
  if enabled_among "${candidates[@]}" >/dev/null; then
    emit allow "Quality Gate: reviewed-commit wrapper (approval is verified by the script itself)."
  fi
fi

pass
