# lib.sh — shell helpers shared by uninstall.sh and upgrade.sh. Sourced, not executed.

# remove_file <path>
remove_file() {
  if [ -e "$1" ]; then
    rm -f "$1" && echo "✔ removed        $1"
  else
    echo "• not present    $1"
  fi
}

# strip_memory_section <file>: drop the installer's "## Persistent memory" section; delete
# the file when nothing but installer content remains.
strip_memory_section() {
  local file="$1"
  if ! [ -f "$file" ] || ! command -v python3 >/dev/null 2>&1; then
    echo "• $(basename "$file") -> not found or python3 missing; skipped section removal ($file)"
    return
  fi
  MEMFILE="$file" python3 - <<'PY'
import os, re

path = os.environ['MEMFILE']
label = os.path.basename(path)
with open(path) as f:
    lines = f.read().splitlines(keepends=True)

start = None
for i, l in enumerate(lines):
    if re.match(r'^##\s+Persistent memory\s*$', l.rstrip('\n')):
        start = i
        break
if start is None:
    print("• %s -> no '## Persistent memory' section; left as-is (%s)" % (label, path))
    raise SystemExit

# The section runs until the next top-level (# or ##) heading, or end of file.
end = len(lines)
for j in range(start + 1, len(lines)):
    if re.match(r'^#{1,2}\s+', lines[j]):
        end = j
        break

remaining = ''.join(lines[:start]) + ''.join(lines[end:])
remaining = re.sub(r'\n{3,}', '\n\n', remaining).rstrip()
stripped = remaining.strip()

# If the file was created wholesale from the installer template (its H1 intro is
# all that's left) or nothing meaningful remains, remove the file outright.
if stripped == '' or stripped.startswith('# memory — persistent-memory system'):
    os.remove(path)
    print("✔ %s -> only installer-added memory content remained; file removed (%s)" % (label, path))
else:
    with open(path, 'w') as f:
        f.write(remaining + '\n')
    print("✔ %s -> stripped the '## Persistent memory' section (%s)" % (label, path))
PY
}
