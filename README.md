# Docker Sandboxes harness with managed Chrome

This directory is the [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) (`sbx`) harness for `sandboxed-browser-use`. It declares a sandbox named `sandboxed-browser-use` that runs [Claude Code](https://docs.docker.com/ai/sandboxes/agents/claude-code/) (`agent: claude`) with a virtual desktop for graphical apps and Google Chrome on it. You watch and control the desktop from your Mac's browser through noVNC, and Claude drives the same Chrome through the Chrome DevTools MCP server.

⚠️ Chrome Stable 153.x.x.x running in an Arm64 Linux VM has a libyuv defect that can cause crashes on some websites, such as YouTube, due to incorrectly enabled CPU features (SVE/SVE2). Because Chrome 155.x.x.x was not available when this project was released, a workaround has been implemented.

| File | Role |
|------|------|
| [`sbxenv.yaml`](sbxenv.yaml) | Project environment: sandbox name, agent, workspace (`.` = this directory), kits, noVNC host port |
| [`kits/desktop/spec.yaml`](kits/desktop/spec.yaml) | Mixin: Xvfb + Openbox on `DISPLAY=:1`, x11vnc, and noVNC on port 6080; also `xdotool` and `scrot` so the agent can drive and screenshot the screen |
| [`kits/desktop/files/home/.local/bin/start-desktop`](kits/desktop/files/home/.local/bin/start-desktop) | Idempotent desktop startup script, run at every sandbox start |
| [`kits/chrome/spec.yaml`](kits/chrome/spec.yaml) | Mixin: Google Chrome stable (amd64 or arm64), `certutil`, Chrome DevTools MCP 1.9.0, and the Apple M4 crash workaround |
| [`kits/chrome/files/home/.local/bin/chrome`](kits/chrome/files/home/.local/bin/chrome) | Chrome launcher: display, proxy, proxy CA import, M4 crash workaround, persistent profile, DevTools on `127.0.0.1:9222` |
| [`kits/chrome/files/home/.local/bin/chrome-devtools-mcp-sandbox`](kits/chrome/files/home/.local/bin/chrome-devtools-mcp-sandbox) | MCP server command: starts Chrome if needed, then runs Chrome DevTools MCP attached to it |
| [`kits/chrome/files/home/.local/src/hide-sme.c`](kits/chrome/files/home/.local/src/hide-sme.c) | Source of the M4 crash workaround library |
| [`kits/chrome/files/home/.local/bin/start-chrome`](kits/chrome/files/home/.local/bin/start-chrome) | Opens Chrome on the desktop at every sandbox start, after clearing stale profile locks |
| [`kits/claude-persist/spec.yaml`](kits/claude-persist/spec.yaml) | Mixin: keeps the sandbox's own Claude Code config on the host mount, so it survives recreating the sandbox |
| [`kits/claude-persist/files/home/.local/bin/persist-claude-state`](kits/claude-persist/files/home/.local/bin/persist-claude-state) | Merges `settings.json` and links `~/.claude` config directories into `.persisted/claude` |
| [`sync-kits.sh`](sync-kits.sh) | Pushes edits to `kits/*/files/**` into the running sandbox, so iterating on them needs no recreate |
| [`.mcp.json`](./.mcp.json) | Registers the `chrome-devtools` MCP server for Claude Code in this project |

## Why noVNC and not `sandboxOptions.display`

`sbx` can provision a Wayland display socket (`sandboxOptions.display: true`) that renders windows on the host compositor, but it needs a graphical session on the host (`DISPLAY` or `WAYLAND_DISPLAY`). macOS has neither by default. The noVNC desktop runs entirely inside the sandbox and needs only a published port, so it works on any host.

## Prerequisites

1. Install `sbx` and sign in, see the [install guide](https://docs.docker.com/ai/sandboxes/install/).
2. Authenticate Claude Code: `sbx secret set anthropic`.

## Create and run

From the **project root** (the directory that contains `sbxenv.yaml`):

```bash
# Preview what will be created (no changes)
sbx env plan .

# Create if needed, then attach to Claude Code
sbx env run .
```

Then open **http://localhost:6080** in your browser. You land on the desktop directly; right-click the background for the Openbox menu (terminal, etc.).

Ask Claude to open a site, or start Chrome yourself:

```bash
sbx env exec . -- bash -c 'nohup chrome https://example.com > /tmp/chrome.log 2>&1 &'
```

Other options:

```bash
# Use a different host port (e.g. when another sandbox already has 6080)
sbx env run .sbx --env-arg novncPort=6081

# Change the desktop size (applies at creation)
sbx env run .sbx --kit-arg desktop.resolution=1920x1080x24
```

## Browser automation (Chrome DevTools MCP)

Claude Code in the sandbox gets browser tools (open pages, click, fill forms, read the page, take screenshots, inspect network and console) from the `chrome-devtools` server in the project's [`.mcp.json`](./.mcp.json). They drive the same Chrome you see in noVNC, so you can watch what Claude does.

- **First run:** Claude asks you to approve the `chrome-devtools` server. Approve it. If it's ever skipped, `/mcp` inside Claude shows the server and lets you enable it.
- **Chrome starts with Claude:** the server command, `chrome-devtools-mcp-sandbox`, starts Chrome if it isn't already running.
- **Privacy:** the server runs with `--no-usage-statistics` and `--no-performance-crux`, and its npm update checks are off, so it doesn't report to Google or check for updates. The version is pinned in the Chrome kit.
- **On your Mac:** Claude Code there reads the same `.mcp.json`. Don't approve the server there; its command exists only inside the sandbox.
- **Logged-in sites:** Claude can read and act on anything open in that Chrome, and a web page can contain instructions aimed at Claude. Keep sensitive accounts out of this browser, or narrow the Chrome kit's network allowlist.

Try asking: "Open news.ycombinator.com and summarize the top five stories."

## What survives recreating the sandbox

Only the project directory is bind-mounted from the host; everything else lives on the container's overlay and is destroyed by `sbx env rm`. State that has to outlive the sandbox therefore goes under `.persisted/`, which is git-ignored:

| Path | Holds |
|------|-------|
| `.persisted/chrome-profile` | Chrome's profile: logins, cookies, history |
| `.persisted/claude/settings.json` | The sandbox's Claude Code settings, including the `chrome-devtools` MCP approval |
| `.persisted/claude/{agents,commands,plugins,output-styles,hooks}` | Claude config directories, symlinked from `~/.claude` |

Two things to know:

- **Never commit `.persisted/`.** The Chrome profile holds live session cookies, and Claude's config carries account details.
- **This is one-way.** It moves the *sandbox's* configuration outward onto host disk. Your Mac's own `~/.claude` is not mounted into the sandbox and is not reachable from it.

Conversation transcripts (`~/.claude/projects`) are *not* persisted: `sbx` keeps them on a sandbox-scoped volume that is destroyed with the sandbox, and `sbx volume` is cloud-only.

Kit file edits don't need a recreate at all — `./sync-kits.sh` pushes them into the running sandbox. Changes to a kit's `setup.install` steps (packages, the M4 workaround build, the pinned MCP server) still do:

```bash
sbx env rm . && sbx env run .
```

## Notes

- **Security:** VNC has no password. x11vnc listens only inside the sandbox, and `sbx` binds the published port to `127.0.0.1` on the host, so only your Mac can reach it.
- **Network:** the Chrome kit allows `**` so the browser can reach arbitrary sites, matching the global `local-policy`. Narrow it in [`kits/chrome/spec.yaml`](kits/chrome/spec.yaml) if you want a tighter sandbox; `sbx policy log sandboxed-browser-use` shows what was blocked.
- **Apple M4 video crash:** the M4 has Arm's SME extension but no SVE. When Chrome sees SME it runs SVE instructions outside SME streaming mode, so its video code dies with an illegal instruction ("Aw, Snap! Error code: 4" on YouTube or Vimeo, sometimes taking the whole browser down). This is a Chrome bug; the sandbox VM handles SME correctly. The Chrome kit builds [`hide-sme.c`](kits/chrome/files/home/.local/src/hide-sme.c) into `/usr/local/lib/libhide-sme.so`, and the `chrome` launcher preloads it so Chrome takes its non-SME code paths. Always start Chrome through `chrome`, not `google-chrome-stable`.
- **DevTools port:** Chrome's DevTools protocol listens on `127.0.0.1:9222` inside the sandbox only. It is not published to your Mac.
- **Other GUI apps:** anything X11 works on `DISPLAY=:1`. Add its install step to a kit.
- Kits, ports, and install steps apply only at creation. After changing them: `sbx env rm . && sbx env run .`.

## Troubleshooting

```bash
# Black noVNC screen: almost always no window open, not a broken desktop.
# Openbox paints no wallpaper, so an empty display is a black framebuffer.
sbx env exec . -- bash -lc 'pgrep -af google-chrome-stable || start-chrome'

# Desktop logs
sbx env exec . -- bash -c 'cat /tmp/start-desktop.log /tmp/desktop/*.log'

# Restart any desktop piece that died
sbx env exec . -- start-desktop

# Chrome log
sbx env exec . -- cat /tmp/chrome.log

# MCP server status as Claude in the sandbox sees it
sbx env exec . -- bash -lc 'cd $(pwd) && claude mcp list'

# Published ports
sbx ports sandboxed-browser-use
```
