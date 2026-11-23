# claude-desktop-aegix

Arch / Artix / [Aegix Linux](https://github.com/aegixlinux) packaging of Anthropic's
official **Claude Desktop** Linux build.

The PKGBUILD downloads the official `.deb` from Anthropic's signed apt repo
(`downloads.claude.ai`), checks its SHA256 against the hash published in that repo,
and repackages it for pacman. Nothing is rebuilt or modified.

Published on the AUR as [`claude-desktop-aegix-bin`](https://aur.archlinux.org/packages/claude-desktop-aegix-bin).

## Install

```sh
yay -S claude-desktop-aegix-bin
# or manually
git clone https://github.com/aegixlinux/claude-desktop-aegix && cd claude-desktop-aegix && makepkg -si
```

## Differences from the .deb

- Skips Debian/Ubuntu-only install steps: the AppArmor profile, the apt repo
  registration, unattended-upgrades, and the GNOME Shell search provider.
- `/usr/bin/claude-desktop` is a small wrapper that supports per-user flags.

## GPU flags

Put extra Chromium/Electron flags, one per line, in `~/.config/claude-desktop-flags.conf`.
If that file exists, it fully decides the flags.

If the file does not exist and the NVIDIA proprietary driver is running under X11, the
wrapper applies this automatically:

```
--ozone-platform=x11
--disable-gpu
```

That is software rendering. It costs some CPU (roughly 15 to 20% of one core with the
window idle on a 2560x1440 monitor) and it is the only configuration that has stayed
reliable on that driver. To opt out, create the conf file (even an empty one).

### Why not the GPU on NVIDIA

With no flags, the app's GPU process dies at startup with
`eglInitialize: Could not create a backing OpenGL context` /
`Exiting GPU process due to errors during initialization`.

With `--use-angle=gl-egl` (this package's default up to 6.28899.6-1) it starts, but
within minutes to hours the window stops being updated. It either turns see-through
or freezes on its last picture. The app itself keeps running and still receives
clicks and keystrokes you cannot see land. Seen on 4.23118.1 through 5.11492.2 with
NVIDIA 580 under X11 with a compositor. Software rendering ran for six days straight
without it happening.

If you run with GPU flags anyway and the window goes see-through or stops updating,
restart only the GPU process. Chromium respawns it, the window repaints, and your
sessions survive:

```
pkill -9 -f 'claude-desktop --type=gpu-process'
```

## Restarting the app

Closing the window does not quit the app; it keeps running in the background.
To restart it, force-quit:

```
pkill -9 -x claude-desktop
```

A plain `pkill` (SIGTERM) can leave it stuck shutting down, seen on 4.23118.1
with NVIDIA on X11: the main process loops relaunching its GPU process and never
exits, the window turns see-through, and every new launch hands off to the stuck
instance and exits. `~/.config/Claude/logs/main.log` shows
`GPU process gone (death 10000 while quitting)`. The updater's smoke test checks
for this and reports it as a warning.
It has not been seen with the software-rendering default: three quits on 5.x and
6.x each finished within four seconds.

File open dialogs need a working desktop portal (`xdg-desktop-portal` with a
backend such as `xdg-desktop-portal-gtk`). On window managers without their own
portal config, such as dwm, add `~/.config/xdg-desktop-portal/portals.conf`
containing `[preferred]` and `default=gtk`, and make sure the session bus knows
your display (`dbus-update-activation-environment DISPLAY XAUTHORITY` in
xprofile). Aegix ships both.

## Updating to a new upstream version

`update.sh` does the whole thing: detects the new version from Anthropic's
apt index, diffs the new .deb against the old for packaging drift (deps
against `deps.map`, maintainer scripts, file layout), rewrites the PKGBUILD,
regenerates `.SRCINFO`, builds, and pauses exactly twice, once before
`sudo pacman -U` plus a smoke test, once before publishing to GitHub and
the AUR.

```sh
./update.sh              # full run, two pauses
./update.sh --check      # report only; exit 1 if an update exists
./update.sh --no-publish # everything but the publish; prints those commands
./update.sh --deb PATH   # use a local .deb (hash-verified against the index)
./update.sh --pkgrel     # packaging-only release: bump pkgrel, build, publish
```

The watch half runs from user anacron (`~/.config/anacrontab`, job
`claude-desktop-check`, daily): `update.sh --cron` checks the index silently
and, on a new version, seals a futureme message, so the envelope shows up in
dwmblocks and the message says what to run. One message per version; state
lives in `~/.local/state/claude-desktop-updater/`.

Tests: `bash tests/run-tests.sh` (no network, no sudo, isolated futureme).
