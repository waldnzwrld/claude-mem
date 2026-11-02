#!/usr/bin/env bash
#
# verify-model.sh — memory-model selection: memory-agent's model commands and precedence, and
# install/uninstall's model + skill handling. Offline and deterministic: the harness CLIs are
# stubs, so it needs no login or model quota.
#
#   tests/verify-model.sh
#
# Exit status is non-zero if any assertion fails.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

# Stub CLIs. `pi --list-models` and `omp models --json` list fixed models (omp lists nothing
# when STUB_OMP_EMPTY is set); any other call records its arguments in $STUB_ARGS and exits
# with $STUB_RC.
BIN="$TMPROOT/bin"; mkdir -p "$BIN"
for h in claude omp pi; do
  cat > "$BIN/$h" <<'EOF'
#!/usr/bin/env bash
case "$(basename "$0")" in
  pi)
    if [ "${1:-}" = "--list-models" ]; then
      printf 'provider  model  context\nlocal  vendor/model-a  64K\nlocal  model-b  64K\n'; exit 0
    fi ;;
  omp)
    if [ "${1:-}" = "models" ]; then
      if [ -n "${STUB_OMP_EMPTY:-}" ]; then echo '{"models":[]}'
      else echo '{"models":[{"kind":"chat","selector":"anthropic/claude-haiku-4-5"},{"kind":"embed","selector":"x/embedder"},{"kind":"chat","selector":"openai/gpt-x"}]}'
      fi
      exit 0
    fi ;;
esac
printf '%s\n' "$@" > "$STUB_ARGS"
exit "${STUB_RC:-0}"
EOF
  chmod +x "$BIN/$h"
done
export CLAUDE_BIN="$BIN/claude" OMP_BIN="$BIN/omp" PI_BIN="$BIN/pi"
export STUB_ARGS="$TMPROOT/args"
unset MEMORY_MODEL MEMORY_MODELS_FILE MEMORY_HARNESS MEMORY_WS STUB_RC STUB_OMP_EMPTY

MA="$REPO/memory-agent"
F="$TMPROOT/models"
ma() { MEMORY_MODELS_FILE="$F" "$MA" "$@"; }
get() { ma --harness "$1" --get-model | cut -f2,3 | sed "s|$F|FILE|"; }
args() { tr '\n' ' ' < "$STUB_ARGS" | sed 's/ $//'; }

echo "== memory-agent: model commands"
rm -f "$F"
check "claude default"        "$(get claude)" "$(printf 'claude-sonnet-5\tdefault')"
check "pi default is harness" "$(get pi)"     "$(printf '(harness default)\tdefault')"

ma --harness pi --set-model local/vendor/model-a >/dev/null 2>&1
check "pi: exact selector stored" "$(get pi)" "$(printf 'local/vendor/model-a\tFILE')"
ma --harness pi --set-model model-b >/dev/null 2>&1
check "pi: bare id matches a provider/id entry" "$(get pi)" "$(printf 'model-b\tFILE')"
ma --harness pi --set-model nonsense >/dev/null 2>&1; rc=$?
check "pi: unknown model rejected"     "$rc" "1"
check "pi: rejection leaves the stored model" "$(get pi)" "$(printf 'model-b\tFILE')"
ma --harness pi --set-model 'a b' >/dev/null 2>&1; check "whitespace rejected" "$?" "2"
ma --harness pi --set-model 'a=b' >/dev/null 2>&1; check "'=' rejected"        "$?" "2"

ma --harness omp --set-model claude-haiku-4-5 >/dev/null 2>&1
check "omp: bare id matches chat selector" "$(get omp)" "$(printf 'claude-haiku-4-5\tFILE')"
ma --harness omp --set-model embedder >/dev/null 2>&1; check "omp: non-chat model not offered" "$?" "1"
ma --harness claude --set-model anything-goes >/dev/null 2>&1
check "claude: any id accepted" "$(get claude)" "$(printf 'anything-goes\tFILE')"

check "--list-models omp: chat models only" \
  "$(ma --harness omp --list-models 2>/dev/null | tr '\n' ' ')" "anthropic/claude-haiku-4-5 openai/gpt-x "
check "--list-models claude: aliases" \
  "$(ma --harness claude --list-models 2>/dev/null | tr '\n' ' ')" "sonnet opus haiku "

before="$(cat "$F")"
ma --harness pi --check-model local/vendor/model-a >/dev/null 2>&1; check "--check-model valid" "$?" "0"
ma --harness pi --check-model nonsense >/dev/null 2>&1;             check "--check-model invalid" "$?" "1"
check "--check-model never stores" "$(cat "$F")" "$before"

STUB_OMP_EMPTY=1 ma --harness omp --set-model whatever >/dev/null 2>&1; rc=$?
check "omp lists nothing: stored unchecked" "$rc:$(get omp)" "0:$(printf 'whatever\tFILE')"

ma --harness omp --unset-model >/dev/null 2>&1
check "unset drops that harness" "$(get omp)" "$(printf 'claude-sonnet-5\tdefault')"
check "unset keeps the others"   "$(get pi)|$(get claude)" "$(printf 'model-b\tFILE')|$(printf 'anything-goes\tFILE')"
check "no temp files left behind" "$(ls "$TMPROOT" | grep -c '^models\.')" "0"
ma --harness pi --unset-model >/dev/null 2>&1; ma --harness claude --unset-model >/dev/null 2>&1
check "file empty once all are unset" "$(wc -c < "$F" | tr -d ' ')" "0"

echo "== memory-agent: precedence and command line"
printf 'claude=haiku\nomp=anthropic/claude-haiku-4-5\npi=model-b\n' > "$F"
for h in claude omp pi; do
  MEMORY_HARNESS=$h ma PROMPT >/dev/null 2>&1
  case "$h" in
    claude) want="-p PROMPT --model haiku --dangerously-skip-permissions" ;;
    omp)    want="-p --model anthropic/claude-haiku-4-5 --approval-mode yolo --no-session --no-title -- PROMPT" ;;
    pi)     want="-p --no-session --approve --model model-b -- PROMPT" ;;
  esac
  check "$h: stored model reaches the CLI" "$(args)" "$want"
done
MEMORY_HARNESS=omp MEMORY_MODEL=envmodel ma PROMPT >/dev/null 2>&1
check "MEMORY_MODEL beats the stored model" "$(args | cut -d' ' -f1-3)" "-p --model envmodel"
: > "$F"
MEMORY_HARNESS=pi ma PROMPT >/dev/null 2>&1
check "pi with nothing stored passes no --model" "$(args)" "-p --no-session --approve -- PROMPT"
MEMORY_HARNESS=claude ma PROMPT >/dev/null 2>&1
check "claude with nothing stored uses Sonnet 5" "$(args | cut -d' ' -f1-4)" "-p PROMPT --model claude-sonnet-5"
printf 'pi=model-b\n' > "$F"
ma --harness pi PROMPT >/dev/null 2>&1
check "--harness selects the harness"  "$(args | grep -c model-b)" "1"

echo "== memory-agent: argument parsing"
rm -f "$STUB_ARGS"
check "no environment detection (OMPCODE set, claude still default)" \
  "$(OMPCODE=1 PI_CODING_AGENT=true ma --get-model | cut -f1)" "claude"
ma --ws /tmp/w --harness pi PROMPT >/dev/null 2>&1
check "--ws before --harness: harness and prompt both honoured" "$(args)" "-p --no-session --approve --model model-b -- PROMPT"
rm -f "$STUB_ARGS"
for bad in "--harness" "--ws" "--set-model" "--bogus PROMPT" "--get-model --list-models" "--get-model extra"; do
  # shellcheck disable=SC2086
  ma $bad >/dev/null 2>&1; rc=$?
  check "'$bad' is a usage error (exit 2)" "$rc" "2"
done
check "usage errors never invoke a CLI" "$([ -e "$STUB_ARGS" ] && echo ran || echo none)" "none"
ma --harness omp -- -dashed >/dev/null 2>&1
check "a prompt starting with '-' passes after --" "$(args | grep -c -- '-- -dashed')" "1"
for f in memory-consolidate memory-dump; do
  check "$f prompt cannot start with '-'" "$(grep -cE '^prompt="-' "$REPO/$f")" "0"
done

echo "== memory-agent: failed run on a stored model"
err="$(MEMORY_HARNESS=pi STUB_RC=3 ma PROMPT 2>&1 >/dev/null)"; rc=$?
check "run's exit status is preserved" "$rc" "3"
check "hint names the stored model"    "$(printf '%s' "$err" | grep -c "stored model 'model-b'")" "1"
err="$(MEMORY_HARNESS=pi STUB_RC=3 MEMORY_MODEL=envmodel ma PROMPT 2>&1 >/dev/null)"
check "no hint when MEMORY_MODEL was used" "$err" ""
err="$(MEMORY_HARNESS=pi STUB_RC=0 ma PROMPT 2>&1 >/dev/null)"
check "no hint on success" "$err" ""

echo "== install / uninstall"
newhome() { H="$TMPROOT/home$1"; rm -rf "$H"; mkdir -p "$H"; }
inst() { HOME="$H" ./install.sh "$@" </dev/null >"$TMPROOT/inst.out" 2>&1; }
cd "$REPO" || exit 1
mf() { cat "$H/.llm-harness-memory/.memory-models" 2>/dev/null; }

newhome 1
inst --harness all --model pi=model-b --model omp=claude-haiku-4-5 --model claude=haiku
check "install --model stores each choice" "$(mf | sort | tr '\n' ' ')" "claude=haiku omp=claude-haiku-4-5 pi=model-b "
check "skill installed for each harness" \
  "$(ls "$H/.claude/skills/memory-model/SKILL.md" "$H/.omp/agent/skills/memory-model/SKILL.md" "$H/.pi/agent/skills/memory-model/SKILL.md" 2>/dev/null | wc -l | tr -d ' ')" "3"
check "skills have no unfilled placeholder" "$(cat "$H"/.claude/skills/memory-model/SKILL.md "$H"/.omp/agent/skills/memory-model/SKILL.md "$H"/.pi/agent/skills/memory-model/SKILL.md | grep -c '{{')" "0"
check "skill is bound to its harness" "$(grep -c -- '--harness omp' "$H/.omp/agent/skills/memory-model/SKILL.md" | awk '$1 > 0 { print "yes" }')" "yes"

inst --harness all
check "reinstall without --model keeps the choices" "$(mf | sort | tr '\n' ' ')" "claude=haiku omp=claude-haiku-4-5 pi=model-b "

MEMORY_MODELS_FILE="$TMPROOT/ambient" MEMORY_MODEL=leak inst --harness pi --model pi=local/vendor/model-a
check "ambient MEMORY_MODELS_FILE does not redirect"  "$([ -e "$TMPROOT/ambient" ] && echo redirected || echo pinned)" "pinned"
check "choice lands in the install's workspace"       "$(mf | grep '^pi=')" "pi=local/vendor/model-a"

HOME="$H" ./uninstall.sh --harness all >/dev/null 2>&1
check "uninstall removes the skills" \
  "$(ls "$H/.claude/skills/memory-model" "$H/.omp/agent/skills/memory-model" "$H/.pi/agent/skills/memory-model" 2>&1 | grep -c 'No such file')" "3"
check "uninstall keeps the models file" "$([ -s "$H/.llm-harness-memory/.memory-models" ] && echo kept || echo gone)" "kept"

newhome 2
inst --harness pi --model pi=nonsense; rc=$?
check "bad --model: install fails"          "$rc" "1"
check "bad --model: nothing was installed"  "$(ls -A "$H" | wc -l | tr -d ' ')" "0"

newhome 3
inst --model omp=claude-haiku-4-5; rc=$?
check "--model for an unselected harness: install fails" "$rc" "2"
check "--model for an unselected harness: nothing installed" "$(ls -A "$H" | wc -l | tr -d ' ')" "0"
check "--model for an unselected harness: says why" "$(grep -c 'add --harness omp' "$TMPROOT/inst.out")" "1"

newhome 4
inst --harness pi
check "no terminal, no flag: nothing asked or stored" "$(mf | wc -l | tr -d ' '):$(grep -c 'Model for' "$TMPROOT/inst.out")" "0:0"

# The prompt itself needs a terminal: drive install.sh through a pty.
drive() { # drive <home> <answers, |-separated> <install args...>; prints the transcript
  python3 - "$@" <<'PY'
import os, pty, select, signal, sys, time
home, answers, args = sys.argv[1], sys.argv[2].split("|"), sys.argv[3:]
env = dict(os.environ, HOME=home)
pid, fd = pty.fork()
if pid == 0:
    os.execvpe("./install.sh", ["./install.sh"] + args, env)
out = b""; seen = 0; end = time.time() + 60
while time.time() < end:
    if select.select([fd], [], [], 1)[0]:
        try: d = os.read(fd, 4096)
        except OSError: break
        if not d: break
        out += d
        if out.count(b"lists): ") > seen:
            a = answers[min(seen, len(answers) - 1)]
            seen += 1
            os.write(fd, a.encode() + b"\r")
os.kill(pid, signal.SIGKILL)
os.waitpid(pid, 0)
print(out.decode(errors="replace").replace("\r", ""))
PY
}
newhome 5
t="$(drive "$H" "model-b" --harness pi)"
check "prompt on a terminal: answer is stored" "$(mf)" "pi=model-b"
t="$(drive "$H" "" --harness pi)"
check "prompt: Enter keeps and shows the current model" \
  "$(printf '%s' "$t" | grep -c 'memory agents \[model-b\]')|$(mf)" "1|pi=model-b"
t="$(drive "$H" "nonsense|" --harness pi)"
check "prompt: a bad answer is refused" "$(printf '%s' "$t" | grep -c 'is not a model pi can run')" "1"
newhome 6
t="$(drive "$H" "model-b" --harness pi --no-prompt)"
check "--no-prompt: no question even on a terminal" "$(printf '%s' "$t" | grep -c 'Model for')|$(mf | wc -l | tr -d ' ')" "0|0"

echo
printf 'TOTAL: \033[32m%d passed\033[0m, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
