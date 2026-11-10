# claude-desktop-aegix-bin: .deb updater and watch system

Date: 2026-11-10
Status: DECIDED design, brainstormed with Timothy 2026-11-10. Supersedes the earlier draft of this file (which was a pre-brainstorm spec). Ready for planning and implementation.

## Intent

Anthropic ships new Claude Desktop Linux `.deb` releases on their apt repo with no announcement Timothy watches. Today, noticing a release and turning it into an updated `claude-desktop-aegix-bin` is entirely manual. This system has two halves:

1. **Watch** (automated): a daily anacron job checks the upstream apt index. When a new version appears, it seals a futureme message. The envelope icon (`fm-status`) shows up in dwmblocks within seconds, Timothy clicks it, reads the message, and knows to run the updater.
2. **Update** (manual, one command): `update.sh` detects the new version, diffs the new .deb against the old for packaging drift, rewrites the PKGBUILD, builds, installs, smoke tests, and publishes to GitHub and the AUR. It pauses exactly twice for a human: before `sudo pacman -U` and before publish.

## Goals, non-goals, anti-goals

- **Goals:** never miss an upstream release; one command from "new version exists" to "published on the AUR"; catch packaging drift (deps, maintainer scripts, file layout) instead of blindly bumping pkgver; keep the GitHub repo and AUR clone byte-identical.
- **Non-goals:** patching the app (faithful repack by design); arm64 build or test on this machine; ISO changes (BARBS installs from the AUR); the desktop app's bundled Claude Code version; GitHub tags or releases (v1 pushes `main` only; AUR is the distribution channel; this was Claude's call, easy to add later).
- **Anti-goals (failure even if it "works"):** publishing a package that was never installed and smoke-tested on this machine; publishing a .deb whose sha256 does not match Anthropic's `Packages` index; notifying about the same version every day (one futureme message per release, ever); losing the NVIDIA wrapper behavior or the `!strip`/`!debug` options in an update.

## Where things are today

| What | Where |
|---|---|
| Source repo (GitHub) | `~/code/claude-desktop-aegix/`, remote `https://github.com/aegixlinux/claude-desktop-aegix.git`, branch `main`. Holds `PKGBUILD`, `.SRCINFO`, `claude-desktop.sh` (launcher wrapper), `README.md`. |
| AUR clone | `~/code/claude-desktop-aegix-bin-aur/`, remote `ssh://aur@aur.archlinux.org/claude-desktop-aegix-bin.git`, branch `master`. Same three files, byte-identical copies. |
| Upstream apt repo | `https://downloads.claude.ai/claude-desktop/apt/stable/` (found via the .deb's `postinst`, `APT_REPO_URL`) |
| Package index | `.../apt/stable/dists/stable/main/binary-amd64/Packages` (and `binary-arm64`) |
| .deb URL pattern | `.../apt/stable/pool/main/c/claude-desktop/claude-desktop_<ver>_{amd64,arm64}.deb` |
| Installed now | `claude-desktop-aegix-bin 4.23118.1-1` |
| Cron infrastructure | User crontab triggers `anacron -t ~/.config/anacrontab -S ~/.local/var/spool/anacron` at boot and 05:00 daily. `futureme tick` already runs hourly from the same crontab. |
| futureme | `~/.local/bin/futureme` (Rust CLI). `fm-status` is the dwmblocks block (signal 11), shows `✉ N` for delivered-but-unread messages. |

The PKGBUILD downloads the .deb itself (`source_x86_64` / `source_aarch64`), extracts `data.tar.xz` in `prepare()`, and in `package()` copies the app tree to `/usr/lib/claude-desktop`, sets `chmod 4755` on `chrome-sandbox`, installs the wrapper as `/usr/bin/claude-desktop`, and copies icons, the `.desktop` file, the MIME XML and the Chromium license. Nothing inside the app is patched. The .deb's `postinst` work (AppArmor, apt repo/keyring, unattended-upgrades, GNOME search provider) is deliberately dropped.

## Half 1: the watch (anacron + futureme)

### Verified mechanics (tested 2026-11-10)

- `futureme write --deliver <ISO datetime> --tag <tag> --message <text>` seals a message. The string `today` is NOT a supported date. A date-only ISO value (`2026-11-10`) seals for today but does NOT deliver on the next tick (delivery time lands later in the day). An ISO datetime one minute in the past (`date -u -d '-1 minute' +%Y-%m-%dT%H:%M:%SZ`) delivers on the very next `futureme tick`. Use that.
- futureme respects XDG env vars for its data dir, not just `$HOME` (isolation in tests needs `XDG_DATA_HOME` etc. overridden).
- `fm-status` shows the count only after a tick delivers; `pkill -RTMIN+11 dwmblocks` refreshes the block.
- GPG: `commit.gpgsign=true` is set globally with key `0D46FA83EADB2394`, and the key signs non-interactively (verified with `--batch --pinentry-mode error`). The existing AUR import commit IS signed (status `G`). The updater does nothing special for signing; it just commits.

### The anacron job

One new line in `~/.config/anacrontab`, following the existing pattern:

```
1    5    claude-desktop-check    /home/trashh_panda/code/claude-desktop-aegix/update.sh --cron
```

Period 1 day (Timothy approved daily; the check is one HTTP request), small delay so it does not race timbeach-autodeploy. anacron's PATH is `/usr/local/bin:/usr/bin:/bin`, so the script must use full paths for anything in `~/.local/bin` (futureme) and must not assume a display (no notify-send dependency; futureme finds the session bus itself).

### `--cron` mode behavior

1. Fetch the amd64 `Packages` index (curl, short timeout, fail silently on network errors: a desktop in Thailand has flaky moments, and a missed day is fine because the next run catches it).
2. Parse the newest `Version:` for package `claude-desktop`.
3. Compare against the PKGBUILD's `pkgver` in `~/code/claude-desktop-aegix/PKGBUILD`.
4. If equal: exit 0 silently.
5. If new: check the state file (`$XDG_STATE_HOME/claude-desktop-updater/last-notified`, default `~/.local/state/...`). If this exact version was already announced, exit 0 silently.
6. Otherwise seal the message, deliver it, refresh the bar, record the state:

```
futureme write \
  --deliver "$(date -u -d '-1 minute' +%Y-%m-%dT%H:%M:%SZ)" \
  --tag claude-desktop \
  --message "claude-desktop <newver> is out (packaged: <pkgver>). Run: ~/code/claude-desktop-aegix/update.sh"
futureme tick
pkill -RTMIN+11 dwmblocks
echo "<newver>" > "$state_file"
```

The state file is written only after the message is sealed, so a crash between steps re-notifies rather than silently losing a release.

## Half 2: the updater (`update.sh`)

A single POSIX-leaning bash script at the repo root, `update.sh`, suckless in spirit: no runtime deps beyond `curl`, `bsdtar`, `makepkg`, `namcap`, `updpkgsums`-class tooling already on the machine. It is committed to the GitHub repo (and NOT copied to the AUR, which only ever gets `PKGBUILD`, `.SRCINFO`, `claude-desktop.sh`).

### Inputs

Two ways in, same pipeline after step 1:

1. **Check upstream** (default): read both `Packages` indexes (amd64 and arm64), take `Version:` and `SHA256:` for each arch.
2. **A local .deb** (`--deb PATH`, for when Timothy downloads one by hand): read its version from `control.tar.xz` -> `control` -> `Version:`, sha256 it, and verify that hash against the `Packages` index for that version. Refuse if they do not match: a local file that is not what Anthropic published must not get published under this package.

### Flags

- `--cron`: the watch mode described above (check + futureme, no build).
- `--check`: human-run check only; prints status, exit 1 if an update exists, exit 0 if current.
- `--deb PATH`: use a local .deb as the source (hash-verified against the index).
- `--no-publish`: run everything but stop before the publish step (prints the git commands it would run).
- `--pkgrel`: packaging-only bump; leaves `pkgver`, increments `pkgrel`, skips the .deb drift diff (there is no new .deb), still builds, tests, and publishes.

No `--yes` in v1. The two pauses are the design, not an inconvenience.

### Steps (default full run)

1. **Detect.** Compare upstream `Version:` to the PKGBUILD's `pkgver` with `vercmp`, and report the installed version from `pacman -Q` separately; they can differ. If equal, say so and exit 0. If upstream is LOWER than `pkgver` (upstream pulled a release), say so and stop: the updater never downgrades and never introduces `epoch=` (Claude's call; rollback stays manual). In `--cron` mode a downgrade still produces one futureme message ("upstream regressed to <ver>, look manually"), deduped by the same state file.
   **Arch skew:** if the amd64 and arm64 indexes disagree on the newest version (arm64 lagging or missing), stop and say so, recommending waiting a day; proceeding needs an explicit yes and the report must say aarch64 users get a broken source entry until upstream catches up (Claude's call: surface it, human decides per event; the watch keys off amd64 only).
2. **Warn if running.** If `claude-desktop` is running (pgrep against the installed app path), warn that replacing `/usr/lib/claude-desktop` under a live Electron app breaks new windows until restart, and recommend quitting. Proceed if told to.
3. **Drift check.** Download the new amd64 .deb, verify its sha256 against the index, and diff it against the previous .deb (kept in a local cache dir from the last run; first run can fall back to `~/Applications/claude-desktop/claude-desktop_amd64.deb`):
   - `control`: `Depends` / `Recommends` changes. Print each added or removed Debian package with its Arch mapping from `deps.map`. **Stop for a human decision** if any dependency is new or unmapped.
   - `postinst` / `prerm` / `postrm`: show the diff. New maintainer-script behavior may need packaging work.
   - File layout of `data.tar.xz`: new or vanished paths under `usr/` at the depth the PKGBUILD copies by name (the `.desktop` file, icons, MIME XML, the app dir, `chrome-sandbox`). A moved path silently drops a file.
   - `chrome-sandbox` still present (the `chmod 4755` line depends on it).
   Drift that is informational (maintainer-script diff, new files the PKGBUILD already copies wholesale) prints and continues; drift that changes packaging (deps, moved/missing named paths, missing chrome-sandbox) stops the script.
4. **Update the PKGBUILD.** Set `pkgver`, reset `pkgrel=1`, write both sha256 sums from the `Packages` index (not from a local download, so arm64 is right without downloading it). Regenerate `.SRCINFO` with `makepkg --printsrcinfo`.
5. **Build and lint.** `namcap PKGBUILD`: `E:` lines stop the run, `W:` lines print and continue (same rule as the monorepo's `aur-publish.sh`). Then `makepkg -f` (x86_64), then `namcap` on the built `.pkg.tar.zst` informationally only (a repacked Electron blob with `!strip` and a setuid chrome-sandbox warns on every run, forever). arm64 is not buildable here: note it as unverified in the report, as today.
6. **PAUSE 1: install + smoke test** (needs sudo; asks before proceeding):
   - `sudo pacman -U` the built package.
   - `timeout 12 claude-desktop` with output captured; fail on `Exiting GPU process` or `eglInitialize` errors. Check `pgrep` for the app surviving, not just the exit code (the app hands off to an already-running instance and exits 0).
   - `chrome-sandbox` is `-rwsr-xr-x root`.
   - `xdg-mime query default x-scheme-handler/claude` is `com.anthropic.Claude.desktop`.
   - Wrapper flag choice without launching: `sed 's/^exec /echo /' /usr/bin/claude-desktop | sh`, with and without `WAYLAND_DISPLAY` set, asserting the NVIDIA flags appear in the X11 case on this machine.
   - The app's own reported version matches `pkgver` (read `resources/app.asar` package.json version, or wherever it proves findable; builder's call on mechanism, requirement is "installed app self-reports the new version").
   - On failure: offer to reinstall the previous package from `/var/cache/pacman/pkg/` (or the build dir) and stop before publishing.
7. **PAUSE 2: publish** (explicit yes required):
   - Commit and push the source repo `main` over HTTPS with the AegixLinux credential (SSH selects the timbeach key and fails; see `~/.claude/projects/-home-trashh-panda-Applications-claude-desktop/memory/aegixlinux-github-push.md`).
   - Copy `PKGBUILD`, `.SRCINFO`, `claude-desktop.sh` into the AUR clone (byte-identical, verify with cmp), commit, `git push origin HEAD:master` (key `~/.ssh/id_ed25519_aur`, account `timothason`, mapped in `~/.ssh/config`). Commits sign automatically via global git config; no special handling.
   - Verify: `curl -s 'https://aur.archlinux.org/cgit/aur.git/plain/.SRCINFO?h=claude-desktop-aegix-bin'` shows the new `pkgver`. (The AUR RPC search lags; do not use it for verification.)
8. **Report** what changed (version, deps, maintainer scripts, layout), what was tested, what was published, and anything left manual (arm64 unverified). Cache the new .deb as "previous" for the next run's drift diff.

## Dependency mapping (`deps.map`)

Debian `Depends` and `Recommends` were translated to Arch by hand; `Recommends` became `optdepends`. Keep that table in the source repo as data, `deps.map`, one `debian-name arch-name` pair per line (comments allowed), so the drift check can say "new dependency libfoo1, no mapping" and stop. Known mappings from the first conversion include `libgbm1 -> mesa`, `libuuid1 -> util-linux-libs`; recover the full table from the current PKGBUILD's `depends`/`optdepends` and the original .deb's `control` when building the file.

## Gotchas already paid for (keep them fixed)

- **NVIDIA proprietary driver on X11:** the app's GPU process dies (`eglInitialize: Could not create a backing OpenGL context`). Only `--ozone-platform=x11 --use-angle=gl-egl` works; vulkan / gl / desktop ANGLE all failed. The wrapper auto-adds these when `/proc/driver/nvidia/version` exists and the session is not Wayland, unless `~/.config/claude-desktop-flags.conf` exists (then it alone decides). Every update must keep this wrapper behavior and the smoke test must exercise it.
- **`-bin` suffix is required** for a prebuilt AUR package, and the AUR already has `claude-desktop`, hence `provides`/`conflicts=('claude-desktop')`.
- **`!strip` and `!debug`** must stay: stripping breaks the prebuilt Electron binaries.
- **Commit trailers:** `~/.claude/hooks/block-ai-attribution.sh` rejects AI attribution lines; commit messages must not have them.
- **A smoke run can exit 0 early** without crashing (hand-off to a running instance). Check `pgrep`, not the exit code alone.
- **The desktop app spawns its own bundled Claude Code** from `~/.config/Claude/claude-code/<ver>/`, not from this package. Do not conflate the two versions in the report.
- **Version mapping:** Debian `Version:` maps to `pkgver` exactly (`4.23118.1` -> `pkgver=4.23118.1`), `pkgrel` resets to 1 on every new pkgver; packaging-only changes bump `pkgrel` only.

## Testing the updater itself

- Run the drift check and PKGBUILD rewrite against two real .debs: the current 4.23118.1 at `~/Applications/claude-desktop/claude-desktop_amd64.deb`, and a synthetic "next version" made by editing a copy's `control` (version bump, an added dependency, a removed file) to prove the drift check stops where it must.
- `--cron` mode is tested against an XDG-isolated futureme (set `XDG_DATA_HOME`/`XDG_CONFIG_HOME`/`XDG_STATE_HOME` to a temp dir) so no test messages land in the real mailbox.
- Publishing is tested with `--no-publish` (prints the git commands).

## Decisions made in the brainstorm (whose, and what)

- Timothy: automated daily-ish check via cron/anacron, surfaced through futureme's envelope in dwmblocks; he then runs the updater manually. The check fires `futureme tick` itself rather than waiting for the hourly cron tick.
- Timothy: exactly two pauses in the updater (install, publish); otherwise it runs straight through.
- Timothy: AUR commits signed, non-interactively. Verified this already works today with the existing global git config; no new work.
- Claude's calls: daily anacron period; no GitHub tags/releases in v1; one futureme message per version via a state file; the updater script lives in the source repo root as `update.sh` and does not ship to the AUR; no `--yes` flag in v1. From the builder review: arch-skew stops for a per-event human decision (watch keys off amd64); downgrades are notify-once, never auto-applied, no `epoch`; namcap gates on `E:` for the PKGBUILD only, informational on the built package.
- Known local state the builder will hit: the AUR clone `~/code/claude-desktop-aegix-bin-aur` is on local branch `main` with its tracking ref gone, so pushes must use `git push origin HEAD:master` (or rename the branch to `master` once). The `gh` credential helper serves the ACTIVE account (timbeach by default): pushing the source repo needs `gh auth switch -u AegixLinux` first or a one-shot inline credential helper. Both are captured in the `publishing-aur-packages` skill at `~/.claude/skills/publishing-aur-packages/SKILL.md`, created alongside this design.

## Out of scope

- Patching the app itself (faithful repack by design).
- Building or testing arm64 on this machine.
- Updating the ISO (BARBS pulls from the AUR).
- The desktop app's bundled Claude Code version.
- GitHub releases/tags, `--yes`, and notify-send fallbacks (all possible later).
