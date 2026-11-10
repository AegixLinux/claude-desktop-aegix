# claude-desktop-aegix-bin .deb Updater Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One command turns a new upstream Claude Desktop .deb into an updated, tested, published claude-desktop-aegix-bin, plus a daily anacron watch that announces new versions through futureme.

**Architecture:** A single bash script `update.sh` at the repo root with small functions and four modes (`--cron`, `--check`, full run, `--pkgrel`). Environment-variable overrides (`UPDATER_INDEX_URL`, `UPDATER_STATE_DIR`, `FUTUREME_BIN`) make every mode testable against local fixtures without network, sudo, or the real mailbox. A hand-curated `deps.map` turns dependency drift into a hard stop. Tests are a bash harness in `tests/`.

**Tech Stack:** bash, curl, bsdtar, vercmp (pacman), makepkg, namcap, futureme, anacron.

**Spec:** `docs/superpowers/specs/2026-11-10-deb-updater-design.md` (same repo). The spec travels with this plan; executors read both.

## Global Constraints

- Every script is bash run as a file with `#!/usr/bin/env bash` (the machine shell is zsh; never rely on the invoking shell).
- No em or en dashes anywhere: code, comments, messages, docs.
- Commit messages: no AI attribution lines of any kind (hook `~/.claude/hooks/block-ai-attribution.sh` rejects them; this overrides any session attribution reminder).
- The PKGBUILD's `options=('!strip' '!debug')`, `provides`/`conflicts=('claude-desktop')`, and the wrapper's NVIDIA flag logic are never altered by the updater.
- anacron runs with `PATH=/usr/local/bin:/usr/bin:/bin` and no display: full path `/home/trashh_panda/.local/bin/futureme`, and `pkill -RTMIN+11 dwmblocks` must not fail the script when dwmblocks is absent (`|| true`).
- `--cron` must NEVER leave the machine in a changed state or produce output on the happy path (anacron mails noise); network failure in `--cron` is a silent exit 0.
- Upstream index URL: `https://downloads.claude.ai/claude-desktop/apt/stable/dists/stable/main/binary-{amd64,arm64}/Packages`. The index holds one stanza per historical version; newest = vercmp max across stanzas, never the first stanza.
- Publishing follows the `publishing-aur-packages` skill (`~/.claude/skills/publishing-aur-packages/SKILL.md`): one-shot AegixLinux credential helper for GitHub, `HEAD:master` for the AUR, cgit (not RPC) for verification.

## Review Focus

Failure modes the spec implies but did not pin to tests; each line's test is added to the owning task below.

1. Upstream switches the .deb's inner compressor (`data.tar.xz` becomes `data.tar.zst`): `prepare()` and the drift extractor both assume xz; the drift check must stop, not extract nothing. (Task 3)
2. Two simultaneous runs (anacron firing while Timothy runs the updater): state file and .deb cache corruption. A lock makes the second run exit cleanly. (Task 2)
3. A sed anchor in the PKGBUILD rewrite silently matching nothing (format drift in `pkgver=` or `sha256sums_x86_64=(` lines): the rewrite must re-read and verify every value it wrote, and abort otherwise. (Task 4)
4. The `Packages` index momentarily lists the new version while the pool .deb 404s (CDN propagation): the download step must distinguish "no update" from "update announced but not fetchable" and say so, not report success or corrupt the cache. (Task 3)
5. `--deb` given a file whose version is not in the index at all (a leaked or pulled build): must refuse, exactly like a hash mismatch. (Task 1)

---

### Task 1: Script skeleton, index parsing, version detection, `--check`

**Files:**
- Create: `update.sh` (repo root, mode 755)
- Create: `tests/run-tests.sh` (mode 755), `tests/fixtures/Packages.sample`
- Modify: `.gitignore` (ensure `tests/tmp/` ignored)

**Interfaces:**
- Produces (used by every later task):
  - `fetch_index <amd64|arm64>` prints the index to stdout; source is `${UPDATER_INDEX_URL_BASE:-https://downloads.claude.ai/claude-desktop/apt/stable/dists/stable/main}/binary-<arch>/Packages`, fetched with `curl -fsS --max-time 30` (file:// URLs work for tests).
  - `latest_version <index-file>` prints the vercmp-greatest `Version:` in the file.
  - `stanza_field <index-file> <version> <field>` prints that version's stanza's field value (SHA256, Filename, Depends, Recommends).
  - `pkgbuild_get <pkgver|pkgrel>` reads `$REPO_DIR/PKGBUILD` (`REPO_DIR` defaults to the script's own directory).
  - `deb_control_version <deb-path>` prints `Version:` from the .deb's control member (bsdtar twice).
  - `die <msg>` (stderr, exit 1), `confirm <prompt>` (reads /dev/tty, default no).
  - Arg parsing for `--cron`, `--check`, `--deb PATH`, `--no-publish`, `--pkgrel`; unknown flag dies with usage.
- `tests/run-tests.sh`: sources `update.sh` with `UPDATER_TEST=1` (which suppresses main dispatch), runs `t_<name>` functions, prints PASS/FAIL per test, exit 1 on any failure.

- [ ] **Step 1: Write failing tests** in `tests/run-tests.sh`:

```bash
t_latest_version_picks_vercmp_max   # fixture has 1.17180.0, 1.17282.0, 4.23118.1 stanzas out of order; expect 4.23118.1
t_stanza_field_sha256               # expect the fixture's SHA256 for 1.17282.0
t_pkgbuild_get_pkgver               # against the real PKGBUILD; expect current pkgver
t_check_mode_current                # UPDATER_INDEX_URL_BASE=file://tests/fixtures with newest == pkgver; expect exit 0, output contains "up to date"
t_check_mode_update                 # fixture with a higher version; expect exit 1, output contains that version
t_deb_refused_when_not_in_index     # --deb with a .deb whose version is absent from the fixture index; expect die, message contains "not in the Packages index"
```

Build `tests/fixtures/Packages.sample` by taking three real stanzas from the live index (curl once, keep it small) and editing versions as needed. The `--deb` test can reuse `~/code/claude-desktop-aegix/claude-desktop_4.23118.1_amd64.deb` with a fixture index that omits 4.23118.1.

- [ ] **Step 2: Run tests, verify they fail** (`bash tests/run-tests.sh`; expect every test FAIL, update.sh missing)
- [ ] **Step 3: Implement the functions and arg parsing in `update.sh`**; `--check` and the guts of detection complete, other modes are stubs that die "not implemented"
- [ ] **Step 4: Run tests, verify PASS; also run `./update.sh --check` live once** (expect "up to date" today)
- [ ] **Step 5: Commit** `update.sh tests/ .gitignore`, message `updater: skeleton, index parsing, --check`

### Task 2: `--cron` mode (watch, futureme, state, lock)

**Files:**
- Modify: `update.sh`
- Modify: `tests/run-tests.sh`

**Interfaces:**
- Consumes: Task 1's `fetch_index`, `latest_version`, `pkgbuild_get`.
- Produces:
  - `state_dir` = `${UPDATER_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/claude-desktop-updater}`; file `last-notified` holds one version string.
  - `notify_futureme <text>`: runs `${FUTUREME_BIN:-/home/trashh_panda/.local/bin/futureme}` `write --deliver "$(date -u -d '-1 minute' +%Y-%m-%dT%H:%M:%SZ)" --tag claude-desktop --message <text>`, then `tick`, then `pkill -RTMIN+11 dwmblocks || true`.
  - `cmd_cron`: whole-run `flock -n` on `$state_dir/lock` (exit 0 silently if held); fetch amd64 index (any curl failure: exit 0 silently); if newest == pkgver exit 0; if newest == last-notified exit 0; else seal message and write state. vercmp direction picks the text: newer gets "claude-desktop <v> is out (packaged: <pkgver>). Run: ~/code/claude-desktop-aegix/update.sh"; lower gets "claude-desktop upstream regressed to <v> (packaged: <pkgver>). Look manually; the updater never downgrades."

- [ ] **Step 1: Write failing tests** (every cron test sets `UPDATER_STATE_DIR` to a temp dir, `UPDATER_INDEX_URL_BASE` to fixtures, and `FUTUREME_BIN` to the real futureme wrapped in `XDG_DATA_HOME`/`XDG_CONFIG_HOME`/`XDG_STATE_HOME` pointed at a temp dir, the isolation pattern verified in the spec):

```bash
t_cron_no_update_silent        # newest == pkgver: exit 0, no output, no state file, mailbox empty
t_cron_new_version_notifies    # higher version: exit 0, state file holds it, isolated `futureme check --count` prints 1
t_cron_dedup                   # run twice: still count 1
t_cron_downgrade_notifies_once # fixture lower than pkgver: message sealed (count 1), second run silent
t_cron_network_failure_silent  # UPDATER_INDEX_URL_BASE=file:///nonexistent: exit 0, no output, no state write
t_cron_lock                    # hold the lock with flock in a background sleep; cron run exits 0 silently
```

- [ ] **Step 2: Run tests, verify the new ones fail**
- [ ] **Step 3: Implement `cmd_cron`, `notify_futureme`, `state_dir`, locking**
- [ ] **Step 4: Run tests, verify PASS**
- [ ] **Step 5: Commit**, message `updater: --cron watch with futureme notification`

### Task 3: `deps.map` and the drift check

**Files:**
- Create: `deps.map` (repo root)
- Modify: `update.sh`, `tests/run-tests.sh`

**Interfaces:**
- Consumes: Task 1's `stanza_field`, `deb_control_version`.
- Produces:
  - `deps.map` format: `# comment` lines and `<debian-name> <arch-name-or-->` lines; `-` means intentionally dropped/unneeded on Arch.
  - `deb_tokens <control-file> <Depends|Recommends>` prints one Debian package name per line: split the field on commas then `|`, strip version constraints `(...)` and architecture qualifiers, trim.
  - `extract_deb <deb> <destdir>` extracts control, postinst/prerm/postrm (if present), and the full `data.tar.*` file listing to `<destdir>/{control,scripts/,files.txt}`. It must detect the data member's actual name (`data.tar.xz|zst|gz`) and STOP with a clear message if it is not `data.tar.xz` (the PKGBUILD's `prepare()` would also break; Review Focus 1).
  - `drift_check <old-deb> <new-deb>` prints a report and returns 0 (continue) or 1 (stop). Stops on: any `deb_tokens` token in the new .deb absent from `deps.map` column 1; disappearance of any path the PKGBUILD names (`usr/lib/claude-desktop/chrome-sandbox`, `usr/share/applications/com.anthropic.Claude.desktop`, `usr/lib/claude-desktop/resources/linux-mime/com.anthropic.Claude.xml`, `usr/lib/claude-desktop/LICENSES.chromium.html`, `usr/share/icons/`); non-xz data member. Prints but continues on: maintainer-script diffs, new/vanished top-level `usr/` paths not named by the PKGBUILD.
  - `fetch_deb <version> <destdir>` downloads the amd64 .deb for `<version>` from the pool, verifies SHA256 against the index, and distinguishes its errors: a 404/curl failure dies "announced but not yet fetchable, try again later" (Review Focus 4); a hash mismatch dies "hash mismatch, refusing". Cache: the verified .deb lands in `$state_dir/debs/` and the previous one is kept for the next drift diff; first run falls back to the repo-root `claude-desktop_4.23118.1_amd64.deb`, then `~/Applications/claude-desktop/claude-desktop_amd64.deb`.

- [ ] **Step 1: Build `deps.map`** from the cached 4.23118.1 .deb: run `deb_tokens` logic by hand (bsdtar the control out), map every token using the current PKGBUILD's depends/optdepends plus known pairs (`libgbm1 mesa`, `libuuid1 util-linux-libs`, `ovmf edk2-ovmf`, `libc6 glibc`, `libxtst6 libxtst`, `libasound2 alsa-lib`, `libnss3 nss`, `libatspi2.0-0 at-spi2-core`); kde/gvfs/trash alternation tokens and `lsb-release`-class entries map to `-`. Every token in the current control MUST appear.
- [ ] **Step 2: Write failing tests**:

```bash
t_deb_tokens_splits_alternation   # fixture control line with "a | b, c (>= 1)" yields a, b, c
t_drift_same_deb_passes           # drift_check old=new=current .deb: exit 0
t_drift_new_dep_stops             # synthetic .deb (see below): exit 1, output names the unmapped token
t_drift_moved_desktop_file_stops  # synthetic with the .desktop path renamed in data listing: exit 1
t_drift_zst_data_stops            # synthetic with data.tar.zst: exit 1, message mentions prepare()
t_fetch_deb_unfetchable_message   # UPDATER_POOL_URL_BASE on an empty file:// dir, version present in fixture index: dies, message contains "not yet fetchable"
```

(`fetch_deb` derives the pool URL from `${UPDATER_POOL_URL_BASE:-https://downloads.claude.ai/claude-desktop/apt/stable}` plus the stanza's `Filename:` field, so tests can point it at local files.)

The synthetic .debs are built by a `make_synthetic_deb` helper inside `tests/run-tests.sh`: unpack the real .deb's control.tar.xz into `tests/tmp/`, edit (bump Version to 9.0.0.1, add `libfoo1` to Depends), repack with `ar`/bsdtar. For the layout and zst cases it is enough to fabricate a minimal .deb with the altered member names and a tiny data archive; drift_check reads listings, not contents.
- [ ] **Step 3: Run tests, verify the new ones fail**
- [ ] **Step 4: Implement `deb_tokens`, `extract_deb`, `drift_check`, `fetch_deb`**
- [ ] **Step 5: Run tests, verify PASS**
- [ ] **Step 6: Commit** `deps.map update.sh tests/`, message `updater: dependency map and .deb drift check`

### Task 4: PKGBUILD rewrite and .SRCINFO regeneration

**Files:**
- Modify: `update.sh`, `tests/run-tests.sh`

**Interfaces:**
- Consumes: Task 1's `stanza_field` (SHA256 from both arch indexes).
- Produces: `rewrite_pkgbuild <pkgver> <sha_amd64> <sha_arm64> [pkgbuild-path]` edits in place: `pkgver=`, `pkgrel=1`, the single-value `sha256sums_x86_64=('...')` and `sha256sums_aarch64=('...')` lines. After editing it re-reads the file and dies unless all four values read back exactly as written (Review Focus 3). `regen_srcinfo [dir]` runs `makepkg --printsrcinfo > .SRCINFO` there. A separate `bump_pkgrel [path]` increments `pkgrel` only (for `--pkgrel` mode).

- [ ] **Step 1: Write failing tests** (each copies `PKGBUILD` to `tests/tmp/` and operates on the copy):

```bash
t_rewrite_sets_all_four       # rewrite to 9.0.0.1 with two dummy 64-hex sums; grep each back
t_rewrite_resets_pkgrel       # pre-set pkgrel=3 in the copy; expect 1 after
t_rewrite_anchor_missing_dies # delete the sha256sums_aarch64 line from the copy; expect die, nonzero exit
t_bump_pkgrel                 # pkgrel 1 becomes 2, pkgver untouched
t_srcinfo_matches             # after rewrite, regen_srcinfo; .SRCINFO contains pkgver = 9.0.0.1
```

- [ ] **Step 2: Run tests, verify the new ones fail**
- [ ] **Step 3: Implement the three functions**
- [ ] **Step 4: Run tests, verify PASS**
- [ ] **Step 5: Commit**, message `updater: PKGBUILD rewrite with readback verification`

### Task 5: Full-run pipeline, build, install, smoke test (pause 1)

**Files:**
- Modify: `update.sh`, `tests/run-tests.sh`

**Interfaces:**
- Consumes: everything above.
- Produces: `cmd_full` wiring steps 1 to 6 of the spec in order: detect (vercmp; equal exits 0, lower dies "never downgrades"; arch skew between the two indexes stops with the wait recommendation and needs `confirm` to continue), running-app warning (`pgrep -f /usr/lib/claude-desktop` + `confirm`), fetch_deb + drift_check, rewrite_pkgbuild + regen_srcinfo, `namcap PKGBUILD` (die on lines matching `^PKGBUILD E:`, print W:), `makepkg -f`, informational namcap on the built `*.pkg.tar.zst`. Then `confirm "Install and smoke test (sudo)?"` gates `smoke_test`, which runs: `sudo pacman -U` the built package; `timeout 12 claude-desktop` capturing output, failing on `Exiting GPU process|eglInitialize` and checking `pgrep` for survival rather than exit code; `stat -c %a /usr/lib/claude-desktop/chrome-sandbox` is 4755 and owner root; `xdg-mime query default x-scheme-handler/claude` is `com.anthropic.Claude.desktop`; wrapper flag check `sed 's/^exec /echo /' /usr/bin/claude-desktop | sh` with and without `WAYLAND_DISPLAY`, asserting `--ozone-platform=x11` appears in the X11 case (this machine has `/proc/driver/nvidia/version`); installed app self-reports pkgver (extract `version` from `/usr/lib/claude-desktop/resources/app.asar` via `bsdtar -xOf ... package.json` piped to grep, or if app.asar proves unreadable, `pacman -Q` plus the .desktop's reported version; builder's call). On any smoke failure: offer reinstall of the previous package from `/var/cache/pacman/pkg/` via `confirm`, then die before publish. `--pkgrel` mode: skip detect/fetch/drift, `bump_pkgrel`, then join the pipeline at regen_srcinfo. `--deb PATH` mode: skip fetch_deb's download, verify the file's sha256 against the index entry for its `deb_control_version` (refusing per Task 1), then continue identically. `cmd_full` ends by printing a report block: old and new version, dependency and maintainer-script drift summary, smoke checks run, publish result or dry-run notice, and the fixed line that aarch64 is published unverified.

- [ ] **Step 1: Write failing tests** for the decision logic only (sudo paths are not unit-testable):

```bash
t_full_equal_versions_exits_zero   # fixtures equal: cmd_full exits 0 before any download
t_full_downgrade_dies              # fixture lower: dies, message contains "never downgrades"
t_full_arch_skew_stops             # amd64 fixture newer than arm64 fixture: non-interactive run (UPDATER_ASSUME_NO=1 makes confirm return false) exits nonzero, output contains "arm64"
t_namcap_gate                      # feed a fake namcap output with a PKGBUILD E: line through the gate function: dies
```

Add `UPDATER_ASSUME_NO=1` support to `confirm` for tests.
- [ ] **Step 2: Run tests, verify the new ones fail**
- [ ] **Step 3: Implement `cmd_full` and `smoke_test`**
- [ ] **Step 4: Run tests, verify PASS**
- [ ] **Step 5: Dress rehearsal of pause 1 on the live machine**: run `./update.sh --pkgrel --no-publish`, answer yes at the install gate (sudo in a terminal tab if a password is needed). Expect: 4.23118.1-2 builds, installs, full smoke test passes. Then reinstall 4.23118.1-1 from the pacman cache and `git checkout PKGBUILD .SRCINFO` so nothing bumped remains.
- [ ] **Step 6: Commit**, message `updater: full pipeline with install and smoke test`

### Task 6: Publish step (pause 2)

**Files:**
- Modify: `update.sh`, `tests/run-tests.sh`

**Interfaces:**
- Consumes: the `publishing-aur-packages` skill's exact mechanics.
- Produces: `cmd_publish` (called by `cmd_full` after the smoke test, or skipped under `--no-publish` after printing every command it would run): in `$REPO_DIR`: `git add PKGBUILD .SRCINFO claude-desktop.sh && git commit -m "Update to <ver>-<rel>"` and push `main` with the one-shot credential helper `git -c credential.helper='!f(){ echo username=AegixLinux; echo password=$(gh auth token -u AegixLinux); }; f' push origin main`; copy the three files to `$AUR_DIR` (`~/code/claude-desktop-aegix-bin-aur`), `cmp` each pair (die on difference), commit, `git push origin HEAD:master`; verify with `git ls-remote` hash equality and the cgit `.SRCINFO` URL containing the new pkgver. The whole function is gated by `confirm "Publish to GitHub and the AUR?"`.

- [ ] **Step 1: Write failing test**:

```bash
t_no_publish_prints_plan   # cmd_publish with UPDATER_DRY_RUN=1 (set by --no-publish): executes nothing, output contains "HEAD:master", "credential.helper", and both repo paths; git log in both repos unchanged
```

- [ ] **Step 2: Run test, verify it fails**
- [ ] **Step 3: Implement `cmd_publish`** (every external command routed through a `run()` wrapper that echoes instead of executing when `UPDATER_DRY_RUN=1`)
- [ ] **Step 4: Run tests, verify PASS; run `./update.sh --pkgrel --no-publish` end to end once more**, answering no at the install gate, and read the printed publish plan for sanity
- [ ] **Step 5: Commit**, message `updater: publish step with dry run`

### Task 7: Anacron entry, docs, land the plane

**Files:**
- Modify: `~/.config/anacrontab` (outside the repo)
- Modify: `README.md` (short "Updating" section: the watch, the two pauses, the flags)
- Modify: `update.sh` only if the live `--cron` run demands it

**Interfaces:**
- Consumes: Task 2's `cmd_cron`.

- [ ] **Step 1: Live `--cron` verification, isolated**: run with `UPDATER_STATE_DIR` and the futureme XDG triple pointed at a temp dir but the REAL network index. Expect silent exit 0 today (4.23118.1 is current). Then rerun with `UPDATER_INDEX_URL_BASE` on the higher-version fixture: expect one message in the isolated mailbox.
- [ ] **Step 2: Add the anacron line** to `~/.config/anacrontab`, matching its existing column style:

```
1               10          claude-desktop-check  /home/trashh_panda/code/claude-desktop-aegix/update.sh --cron
```

- [ ] **Step 3: Verify anacron accepts it**: `anacron -T -t ~/.config/anacrontab` (syntax check), then force one real run `anacron -fn -t ~/.config/anacrontab -S ~/.local/var/spool/anacron claude-desktop-check` and check the spool timestamp file appeared and the real mailbox gained nothing (version is current).
- [ ] **Step 4: Write the README section; commit** docs + spec + plan (`docs/superpowers/`), message `updater: anacron watch, docs`
- [ ] **Step 5: Push `main`** with the one-shot AegixLinux credential helper; verify with `git status` showing up to date and `git ls-remote` matching HEAD.
