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

```sh
curl -sL https://downloads.claude.ai/claude-desktop/apt/stable/dists/stable/main/binary-amd64/Packages \
  | grep -E '^(Version|SHA256):' | tail -2
```

Bump `pkgver`, set the new hashes (amd64 + arm64), reset `pkgrel=1`, then
`makepkg --printsrcinfo > .SRCINFO`.
