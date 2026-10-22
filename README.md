# SiriusXM for Omarchy

Listen to SiriusXM live channels from the Omarchy bar. Click the radio icon
for a panel with now playing (track, artist, art), transport and volume
controls, a searchable channel list, a genre filter, and favorites. Playback
runs in `mpv` with `mpv-mpris`, so `omarchy.media`, media keys and
`playerctl` all work. Next/previous step through your favorites, or the full
lineup if the channel isn't a favorite.

The volume slider sets the "SiriusXM" PipeWire stream directly, just as
Omarchy's audio panel does, so both always show the same percentage. mpv's own
software volume stays at 100, and the stream defaults to 100%.

Requires a SiriusXM subscription that includes streaming.

## Install

```bash
omarchy plugin add https://github.com/onesastr/omarchy-siriusxm.git --enable
```

Or, to hack on it, clone anywhere and link it in:

```bash
git clone https://github.com/onesastr/omarchy-siriusxm.git ~/Projects/omarchy-siriusxm
~/Projects/omarchy-siriusxm/install
```

`install` symlinks the checkout to `~/.config/omarchy/plugins/sastr.siriusxm`
and enables the bar widget. It uses `python3`, `mpv`, `mpv-mpris` and
`secret-tool` (libsecret), all of which ship with Omarchy. Move the widget with
`omarchy bar move sastr.siriusxm --section left|center|right`.

Sign in from the panel, or in a terminal:

```bash
~/.config/omarchy/plugins/sastr.siriusxm/sxm login
```

Credentials go to your keyring (GNOME Keyring via libsecret). They never land
in a file or on a command line.

## Bar widget

| Input | Action |
| --- | --- |
| Left click | Open/close the panel |
| Middle click | Play/pause (resumes the last channel) |
| Right click | Stop |
| Wheel | Volume ±5 |

## Panel keys

| Key | Action |
| --- | --- |
| `j`/`k`, arrows | Move through channels |
| `Enter` | Play the selected channel |
| `/` | Search (name, genre, description, or channel number) |
| `f` | Toggle favorite on the selected channel |
| `Space` | Play/pause |
| `n` / `p` | Next/previous channel |
| `s` | Stop |
| `Esc` | Clear search, then close |

Right-click a channel to favorite it.

## Keybindings

The widget registers an IPC target, so you can bind keys in
`~/.config/hypr/bindings.lua` to:

```bash
omarchy-shell shell toggle sastr.siriusxm '{}'           # open/close the panel
quickshell ipc -p "$OMARCHY_PATH/shell" call sastr.siriusxm playPause
quickshell ipc -p "$OMARCHY_PATH/shell" call sastr.siriusxm next
```

Or call the CLI directly: `sxm toggle`, `sxm next`, `sxm play 2`.

## CLI

```
sxm login | logout
sxm status [--json]
sxm channels [--refresh] [--json]
sxm play <number | name | id>
sxm toggle | stop | next | prev
sxm volume <0-100 | +5 | -5>
sxm fav <number | id>
sxm raw lineup | tune <ch> | live <ch>    # raw API responses, for debugging
```

## How it works

`sxm` is a single standard-library Python file. Any command starts
`sxm daemon` on demand. The daemon:

1. Signs in to SiriusXM's edge-gateway API (device grant → anonymous session →
   password identity grant → authenticated session). Tokens are cached in
   `~/.local/state/omarchy-siriusxm/session.json` and refreshed before they
   expire.
2. Serves a localhost HLS proxy, guarded by a random token in the path. It
   tunes channels, rewrites live playlists, fetches AES-128 keys with your
   session, and passes segments through. Only segment URLs it issued itself
   are proxied.
3. Owns `mpv`, follows it over JSON IPC, and polls `liveUpdate` for track
   metadata. It matches tracks against the playlist's program date-times, so
   now playing follows the audio you hear, not the live edge.
4. Writes `$XDG_RUNTIME_DIR/omarchy-siriusxm/status.json`, which the panel
   watches.

The daemon exits 15 minutes after playback stops.

Files:

| Path | Contents |
| --- | --- |
| `~/.local/share/omarchy-siriusxm/state.json` | favorites, last channel, volume |
| `~/.cache/omarchy-siriusxm/channels.json` | channel lineup (refreshed daily) |
| `~/.local/state/omarchy-siriusxm/session.json` | API tokens (0600) |
| `$XDG_RUNTIME_DIR/omarchy-siriusxm/` | status, daemon/mpv logs, sockets |

## Development

```bash
python3 -m unittest discover -s tests      # parsing/rewriting/token logic
node --test tests/model.test.mjs           # panel model
python3 tests/e2e_fake_upstream.py         # full proxy + mpv chain vs. a fake encrypted stream
./install                                  # re-run after edits to hot-reload the shell
```

The shell's plugin watcher doesn't follow symlinks. Re-running `./install`
recreates the link, and that triggers the reload.

## Troubleshooting

- `sxm status` shows the state and the last error.
- `$XDG_RUNTIME_DIR/omarchy-siriusxm/daemon.log` and `mpv.log` have details.
  Run `SXM_DEBUG=1 sxm daemon` in the foreground to log every proxied request.
- `sxm raw tune 2` dumps the raw tune response if SiriusXM changes its API.

## Remove

```bash
~/.config/omarchy/plugins/sastr.siriusxm/sxm logout
omarchy plugin remove sastr.siriusxm    # or, for a linked checkout: rm the symlink
rm -rf ~/.local/share/omarchy-siriusxm ~/.cache/omarchy-siriusxm ~/.local/state/omarchy-siriusxm
```

See [NOTICE.md](NOTICE.md) for attribution. This project is not affiliated
with Sirius XM Holdings Inc.
