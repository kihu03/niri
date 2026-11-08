# niri + Noctalia config backup

Versioned snapshot of my Wayland desktop config (niri window manager, Noctalia
bar/shell) from `cachyos-x8664`. Paths mirror `$HOME`, so restoring is a plain
copy.

## Contents

| Path | Source |
|---|---|
| `.config/niri/` | `~/.config/niri` — `config.kdl` + `cfg/*.kdl` fragments, with pre-edit `.bak` copies |
| `.config/noctalia/` | `~/.config/noctalia` — `config.toml`, `templates.toml` |
| `.local/state/noctalia/settings.toml` | `~/.local/state/noctalia` — the real Noctalia settings |
| `.local/share/noctalia/plugins/synthetic-usage/` | `~/.local/share/noctalia` — custom Luau bar widget |

## Deliberately excluded

Private or regenerable runtime state, also enforced in `.gitignore`:

- `notification_history.enc` — encrypted notification log
- `clipboard/`, `recently_used.json`
- `community-palettes/`, `community-templates/` — re-downloaded from the community repo
- plugin runtime data (cached SVG gauges)

## Restore

```fish
cp -r .config .local ~/
niri validate
```

Then restart niri (`Mod+Shift+E` by default) or re-login.

## Updating the backup

```fish
rsync -a --delete ~/.config/niri/ ~/repos/niri/.config/niri/
rsync -a ~/.config/noctalia/ ~/repos/niri/.config/noctalia/
cp ~/.local/state/noctalia/settings.toml ~/repos/niri/.local/state/noctalia/
cd ~/repos/niri && git add -A && git commit -m "Update configs" && git push
```
