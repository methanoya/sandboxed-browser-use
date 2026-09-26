#!/usr/bin/env bash
# Push kit script edits into the RUNNING sandbox, so iterating on them doesn't
# need `sbx env rm` + `sbx env run`.
#
# This covers kits/*/files/** only. Changes to a kit's setup.install steps —
# packages, the SME workaround build, the pinned MCP server — still need a real
# recreate, because those steps run once at creation:
#
#   sbx env rm . && sbx env run .
set -euo pipefail

cd "$(dirname "$0")"
env_dir="$PWD"
staged="$(mktemp -d)"
trap 'rm -rf "$staged"' EXIT

# Kit files may contain ${{ kit.args.NAME }}, which sbx expands when it installs
# them. Copying the raw source would install a broken script, so expand the same
# placeholders here, using each kit's declared defaults.
echo "==> expanding kit templates"
python3 - "$staged" <<'PY'
import pathlib, re, shutil, sys

staged = pathlib.Path(sys.argv[1])
placeholder = re.compile(r"\$\{\{\s*kit\.args\.([A-Za-z0-9_]+)\s*\}\}")

for spec in sorted(pathlib.Path("kits").glob("*/spec.yaml")):
    kit = spec.parent
    text = spec.read_text()

    # Defaults from the kit's own args: block, read without a YAML dependency.
    args, block = {}, re.search(r"^args:\n((?:[ \t].*\n|\n)*)", text, re.M)
    if block:
        name = None
        for line in block.group(1).splitlines():
            if re.match(r"^  [A-Za-z0-9_]+:\s*$", line):
                name = line.strip().rstrip(":")
            elif name and (m := re.match(r"^\s+default:\s*(.*?)\s*$", line)):
                args[name] = m.group(1).strip("'\"")
                name = None

    for src in sorted((kit / "files").rglob("*")):
        if not src.is_file():
            continue
        body = src.read_text()
        missing = [n for n in placeholder.findall(body) if n not in args]
        if missing:
            sys.exit(f"{src}: no default for kit arg(s) {', '.join(sorted(set(missing)))}")
        rel = src.relative_to(kit / "files")
        out = staged / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(placeholder.sub(lambda m: args[m.group(1)], body))
        shutil.copymode(src, out)
        if body != out.read_text():
            print(f"    {rel.name}: expanded {', '.join(sorted(set(placeholder.findall(body))))}")
PY

echo "==> copying kit files into the sandbox"
# A kit lays its files out as files/home/... , which sbx installs under
# /home/agent/... . Keep that mapping instead of flattening, so sources like
# hide-sme.c land in ~/.local/src and don't get installed as executables.
while IFS= read -r src; do
  rel="${src#"$staged"/}"
  dest="/${rel/#home/home/agent}"
  name="$(basename "$rel")"
  # Refuse to install a script that doesn't parse: a broken launcher in the
  # sandbox is worse than an unsynced one.
  case "$name" in
    *.c) : ;;
    *) bash -n "$src" || { echo "    $name: SYNTAX ERROR, not copied" >&2; exit 1; } ;;
  esac
  sbx env exec "$env_dir" -- bash -c "mkdir -p \"\$(dirname '$dest')\" && cat > '$dest'" < "$src"
  # Only launchers on PATH are installed system-wide; the kits do the same.
  case "$rel" in
    home/.local/bin/*)
      # < /dev/null: without it this would eat the loop's stdin and the file list.
      sbx env exec "$env_dir" -- bash -c "sudo install -m 0755 '$dest' '/usr/local/bin/$name'" < /dev/null
      echo "    $name -> /usr/local/bin/$name" ;;
    *)
      echo "    $name -> $dest" ;;
  esac
done < <(find "$staged" -type f | sort)

echo "==> re-running startup scripts"
sbx env exec "$env_dir" -- bash -lc '
  start-desktop
  persist-claude-state
  nohup start-chrome > /tmp/chrome.log 2>&1 &
  sleep 3
'

echo "==> state"
sbx env exec "$env_dir" -- bash -lc '
  printf "    display:  "; DISPLAY=:1 xdpyinfo > /dev/null 2>&1 && echo up || echo DOWN
  printf "    windows:  "; DISPLAY=:1 xdotool search --onlyvisible --name ".+" getwindowname %@ 2>/dev/null | paste -sd", " -
  printf "    devtools: "; curl -s --max-time 3 --noproxy "*" http://127.0.0.1:9222/json/version 2>/dev/null \
    | python3 -c "import sys,json;print(json.load(sys.stdin)[\"Browser\"])" 2>/dev/null || echo DOWN
  printf "    profile:  "; ls -d "$(chrome-profile-dir)" 2>/dev/null || echo "not created yet"
  printf "    claude:   "; readlink "$HOME/.claude/settings.json" 2>/dev/null || echo "not linked"
'
echo "==> done. Reload http://localhost:6080"
