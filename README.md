# Pilotlight

A tiny macOS menu bar light for every Claude Code session. It stays quiet while Claude works and tells you when a session needs you.

Pilotlight puts one small light in your menu bar for each Claude Code session running in VS Code. **Blue** means working, **amber** means it needs you, **green** means done, and **red** means it failed.

You can answer permission prompts (Allow / Deny / Always) straight from the menu bar or a banner. Anything else takes you to the right VS Code window in one click. You can also drag the lights out of the menu bar into a floating strip and put it anywhere on screen.

It's a native Swift app with no Electron and no web view. Claude Code's own hooks send it events, so it uses about 20 MB of memory and 0% CPU when idle.

## Install

Requires macOS 14+ and Xcode (Swift 6 toolchain).

```sh
./scripts/install.sh
```

This builds the app, copies it to `/Applications`, adds its hooks to `~/.claude/settings.json` (after backing that file up, and without touching your other hooks) and starts it. Restart any Claude Code sessions that are already open so they pick up the hooks.

To remove it again, run `./scripts/uninstall.sh`.

## Using it

- **Click the lights**, or press **⌥Space**, to open the board.
- **⏎ / ⌫ / A** allow, deny or always-allow the oldest permission ask.
- **1–9** jump to a session's VS Code window.
- **Drag the lights** out of the menu bar to float them. Drag one light out of the strip to pin a single session, and drop it on the menu bar to dock it again.
- **Right-click** for settings and quit.

## How it works

```
Claude Code ──hook──▶ pilot emit / ask ──unix socket──▶ Pilotlight.app ──▶ menu bar · banners
                                       ◀──── allow / deny (permission asks only)
```

`pilot` is a ~55 KB Darwin-only binary that Claude Code runs for each hook event. It forwards the event and exits in about 5 ms, and exits silently if the app isn't running. Pilotlight registers 8 events: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PermissionRequest`, `Stop`, `StopFailure` and `SessionEnd`.

When a permission ask comes in and you're already looking at that session's window, Pilotlight steps aside so VS Code shows its normal prompt. Otherwise it holds the ask for up to 30 s (configurable) and then hands it back to VS Code.

## Layout

| Path | What's there |
|---|---|
| `Sources/Pilotlight` | the menu bar app (AppKit + SwiftUI) |
| `Sources/pilot` | the hook command |
| `scripts/` | build, install, uninstall, icon |
| `demo/index.html` | interactive design mock and design notes |
