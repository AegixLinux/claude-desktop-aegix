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
--use-angle=gl-egl
```

That fixes `eglInitialize: Could not create a backing OpenGL context` /
`Exiting GPU process due to errors during initialization`.
To opt out, create the conf file (even an empty one).

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
