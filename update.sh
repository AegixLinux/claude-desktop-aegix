#!/usr/bin/env bash
# update.sh: keep claude-desktop-aegix-bin current with Anthropic's .deb.
#
# Modes:
#   --cron        silent watch for anacron; futureme message on a new version
#   --check       human-run check; exit 1 if an update exists
#   (no flag)     full pipeline: detect, drift check, rewrite, build, install,
#                 smoke test, publish (two interactive pauses)
#   --deb PATH    use a local .deb, hash-verified against the Packages index
#   --no-publish  stop before publishing; print the commands instead
#   --pkgrel      packaging-only bump: no new .deb, bump pkgrel, build, publish
#
# Design: docs/superpowers/specs/2026-11-10-deb-updater-design.md
set -u

REPO_DIR=${UPDATER_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
INDEX_URL_BASE=${UPDATER_INDEX_URL_BASE:-https://downloads.claude.ai/claude-desktop/apt/stable/dists/stable/main}
POOL_URL_BASE=${UPDATER_POOL_URL_BASE:-https://downloads.claude.ai/claude-desktop/apt/stable}
FUTUREME_BIN=${FUTUREME_BIN:-/home/trashh_panda/.local/bin/futureme}

die() { echo "update.sh: $*" >&2; exit 1; }

# Interactive yes/no, default no. UPDATER_ASSUME_NO=1 answers no (for tests).
confirm() {
  local reply
  [[ ${UPDATER_ASSUME_NO:-0} == 1 ]] && return 1
  read -r -p "$1 [y/N] " reply < /dev/tty || return 1
  [[ $reply == y || $reply == Y ]]
}

# fetch_index <amd64|arm64>: print that arch's Packages index.
fetch_index() {
  curl -fsS --max-time 30 "$INDEX_URL_BASE/binary-$1/Packages"
}

# latest_version <index-file>: vercmp-greatest Version: in the file.
latest_version() {
  local best="" v
  while IFS= read -r v; do
    if [[ -z $best ]] || [[ $(vercmp "$v" "$best") -gt 0 ]]; then best=$v; fi
  done < <(sed -n 's/^Version: //p' "$1")
  [[ -n $best ]] || return 1
  printf '%s\n' "$best"
}

# stanza_field <index-file> <version> <field>: that version's field value.
stanza_field() {
  awk -v RS= -v ver="$2" -v field="$3" '
    $0 ~ "\nVersion: " ver "\n" {
      n = split($0, lines, "\n")
      for (i = 1; i <= n; i++)
        if (index(lines[i], field ": ") == 1) {
          print substr(lines[i], length(field) + 3); exit
        }
    }' "$1"
}

# pkgbuild_get <pkgver|pkgrel>: read the variable from the repo PKGBUILD.
# UPDATER_REPO_DIR is honored at call time so tests can point at fixtures.
pkgbuild_get() {
  sed -n "s/^$1=//p" "${UPDATER_REPO_DIR:-$REPO_DIR}/PKGBUILD" | head -1
}

# deb_control_version <deb>: Version: from the .deb's control member.
deb_control_version() {
  local member
  member=$(bsdtar -tf "$1" | grep '^control\.tar' | head -1) || return 1
  bsdtar -xOf "$1" "$member" | bsdtar -xO -f - '*control' | sed -n 's/^Version: //p' | head -1
}

# validate_local_deb <deb> <index-file>: version must be in the index and the
# file's sha256 must match. Prints the version on success.
validate_local_deb() {
  local ver want got
  ver=$(deb_control_version "$1") || die "cannot read a version from $1"
  want=$(stanza_field "$2" "$ver" SHA256)
  [[ -n $want ]] || die "version $ver (from $1) is not in the Packages index; refusing to publish an unverifiable .deb"
  got=$(sha256sum "$1" | awk '{print $1}')
  [[ $got == "$want" ]] || die "sha256 mismatch for $1: index has $want, file is $got; refusing"
  printf '%s\n' "$ver"
}

# Paths inside the .deb that package() copies BY NAME; losing any of them
# silently drops a file from the package, so drift on these is a hard stop.
NAMED_PATHS=(
  usr/lib/claude-desktop/chrome-sandbox
  usr/share/applications/com.anthropic.Claude.desktop
  usr/lib/claude-desktop/resources/linux-mime/com.anthropic.Claude.xml
  usr/lib/claude-desktop/LICENSES.chromium.html
  usr/share/icons/
)

# deb_tokens <control-file> <Depends|Recommends>: one Debian package name per
# line; alternation groups split, version and arch qualifiers stripped.
deb_tokens() {
  sed -n "s/^$2: //p" "$1" \
    | tr ',|' '\n\n' \
    | sed 's/([^)]*)//g; s/\[[^]]*\]//g; s/^[[:space:]]*//; s/[[:space:]]*$//' \
    | sed '/^$/d'
}

# extract_deb <deb> <destdir>: control, maintainer scripts, data file listing.
# Dies if the data member is not data.tar.xz (prepare() would break too).
extract_deb() {
  local deb=$1 dest=$2 cmember dmember
  mkdir -p "$dest/scripts"
  cmember=$(bsdtar -tf "$deb" | grep '^control\.tar' | head -1) || die "no control member in $deb"
  dmember=$(bsdtar -tf "$deb" | grep '^data\.tar' | head -1) || die "no data member in $deb"
  [[ $dmember == data.tar.xz ]] \
    || die "data member of $deb is $dmember, not data.tar.xz: the PKGBUILD's prepare() extracts data.tar.xz by name and must be updated first"
  bsdtar -xOf "$deb" "$cmember" | bsdtar -xO -f - '*control' > "$dest/control"
  local s
  for s in postinst prerm postrm preinst; do
    bsdtar -xOf "$deb" "$cmember" | bsdtar -xO -f - "*$s" > "$dest/scripts/$s" 2> /dev/null || rm -f "$dest/scripts/$s"
  done
  bsdtar -xOf "$deb" "$dmember" | bsdtar -t -f - | sed 's|^\./||' > "$dest/files.txt"
}

# drift_check <old-deb> <new-deb>: print a report; return 0 continue, 1 stop.
# Stops: unmapped dependency token, a NAMED_PATHS entry missing, non-xz data.
# Informational: maintainer script diffs, top-level usr/ layout changes.
drift_check() {
  local olddir newdir stop=0 depsmap tok p
  depsmap="${UPDATER_REPO_DIR:-$REPO_DIR}/deps.map"
  [[ -f $depsmap ]] || die "deps.map not found at $depsmap"
  olddir=$(mktemp -d) && newdir=$(mktemp -d) || die "mktemp failed"
  extract_deb "$1" "$olddir" || { rm -rf "$olddir" "$newdir"; return 1; }
  extract_deb "$2" "$newdir" || { rm -rf "$olddir" "$newdir"; return 1; }

  echo "== dependency drift =="
  local field
  for field in Depends Recommends; do
    while IFS= read -r tok; do
      if ! grep -q "^$tok " "$depsmap"; then
        echo "STOP: new $field token '$tok' has no mapping in deps.map"
        stop=1
      fi
    done < <(deb_tokens "$newdir/control" "$field")
    diff <(deb_tokens "$olddir/control" "$field") <(deb_tokens "$newdir/control" "$field") \
      | sed -n "s/^</removed $field:/p; s/^>/added $field:/p"
  done

  echo "== named paths =="
  for p in "${NAMED_PATHS[@]}"; do
    if ! grep -q "^$p" "$newdir/files.txt"; then
      echo "STOP: $p is gone from the new .deb; package() copies it by name"
      stop=1
    fi
  done

  echo "== maintainer scripts (informational) =="
  local s
  for s in postinst prerm postrm preinst; do
    if [[ -f $olddir/scripts/$s || -f $newdir/scripts/$s ]]; then
      diff -u "$olddir/scripts/$s" "$newdir/scripts/$s" 2>&1 | head -40 || true
    fi
  done

  echo "== top-level usr/ layout (informational) =="
  diff <(cut -d/ -f1-3 "$olddir/files.txt" | sort -u) \
       <(cut -d/ -f1-3 "$newdir/files.txt" | sort -u) \
    | sed -n 's/^</vanished:/p; s/^>/new:/p'

  rm -rf "$olddir" "$newdir"
  return $stop
}

# fetch_deb <index-file> <version> <destdir>: download the amd64 .deb for
# <version>, verify its sha256 against the index, cache it under the state
# dir, and print the cached path. Distinguishes "announced but the pool does
# not serve it yet" from a hash mismatch.
fetch_deb() {
  local idx=$1 ver=$2 dest=$3 fname want got pool cache out
  fname=$(stanza_field "$idx" "$ver" Filename)
  want=$(stanza_field "$idx" "$ver" SHA256)
  [[ -n $fname && -n $want ]] || die "version $ver has no Filename/SHA256 in the index"
  pool="${UPDATER_POOL_URL_BASE:-$POOL_URL_BASE}"
  mkdir -p "$dest"
  out="$dest/$(basename "$fname")"
  if ! curl -fsS --max-time 600 -o "$out" "$pool/$fname"; then
    rm -f "$out"
    die "version $ver is announced in the index but not yet fetchable from the pool ($pool/$fname); try again later"
  fi
  got=$(sha256sum "$out" | awk '{print $1}')
  [[ $got == "$want" ]] || { rm -f "$out"; die "sha256 mismatch for $out: index has $want, download is $got; refusing"; }
  printf '%s\n' "$out"
}

# rewrite_pkgbuild <pkgver> <sha_amd64> <sha_arm64> [pkgbuild]: set pkgver,
# reset pkgrel=1, write both sums, then re-read and die unless every value
# reads back exactly (a sed anchor that matched nothing must not ship).
rewrite_pkgbuild() {
  local ver=$1 sha64=$2 shaarm=$3 pb=${4:-${UPDATER_REPO_DIR:-$REPO_DIR}/PKGBUILD}
  sed -i \
    -e "s/^pkgver=.*/pkgver=$ver/" \
    -e "s/^pkgrel=.*/pkgrel=1/" \
    -e "s/^sha256sums_x86_64=.*/sha256sums_x86_64=('$sha64')/" \
    -e "s/^sha256sums_aarch64=.*/sha256sums_aarch64=('$shaarm')/" \
    "$pb"
  grep -qx "pkgver=$ver" "$pb" || die "rewrite verification failed: pkgver anchor did not take in $pb"
  grep -qx "pkgrel=1" "$pb" || die "rewrite verification failed: pkgrel anchor did not take in $pb"
  grep -qx "sha256sums_x86_64=('$sha64')" "$pb" || die "rewrite verification failed: sha256sums_x86_64 anchor did not take in $pb"
  grep -qx "sha256sums_aarch64=('$shaarm')" "$pb" || die "rewrite verification failed: sha256sums_aarch64 anchor did not take in $pb"
}

# bump_pkgrel [pkgbuild]: increment pkgrel only (packaging-only release).
bump_pkgrel() {
  local pb=${1:-${UPDATER_REPO_DIR:-$REPO_DIR}/PKGBUILD} rel
  rel=$(sed -n 's/^pkgrel=//p' "$pb" | head -1)
  [[ $rel =~ ^[0-9]+$ ]] || die "cannot read pkgrel from $pb"
  sed -i "s/^pkgrel=.*/pkgrel=$((rel + 1))/" "$pb"
  grep -qx "pkgrel=$((rel + 1))" "$pb" || die "pkgrel bump did not take in $pb"
}

# regen_srcinfo [dir]: regenerate .SRCINFO from the PKGBUILD there.
regen_srcinfo() {
  local dir=${1:-${UPDATER_REPO_DIR:-$REPO_DIR}}
  ( cd "$dir" && makepkg --printsrcinfo > .SRCINFO ) || die ".SRCINFO regeneration failed in $dir"
}

# --- modes -------------------------------------------------------------------

cmd_check() {
  local idx ver cur
  idx=$(mktemp) || die "mktemp failed"
  fetch_index amd64 > "$idx" || { rm -f "$idx"; die "cannot fetch the Packages index"; }
  ver=$(latest_version "$idx") || { rm -f "$idx"; die "no versions in the index"; }
  rm -f "$idx"
  cur=$(pkgbuild_get pkgver)
  if [[ $ver == "$cur" ]]; then
    echo "up to date: upstream $ver == PKGBUILD $cur"
    return 0
  fi
  echo "update available: upstream $ver, PKGBUILD has $cur"
  return 1
}

state_dir() {
  printf '%s\n' "${UPDATER_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/claude-desktop-updater}"
}

# notify_futureme <text>: seal a message that delivers on the tick we fire.
# Returns nonzero if sealing failed (caller must then NOT record state).
notify_futureme() {
  "$FUTUREME_BIN" write --deliver "$(date -u -d '-1 minute' +%Y-%m-%dT%H:%M:%SZ)" \
    --tag claude-desktop --message "$1" > /dev/null 2>&1 || return 1
  "$FUTUREME_BIN" tick > /dev/null 2>&1 || true
  pkill -RTMIN+11 dwmblocks 2> /dev/null || true
}

# --cron: anacron-driven watch. NEVER noisy, NEVER nonzero on the happy or the
# unreachable path; one futureme message per version, state written only after
# the message sealed.
cmd_cron() {
  local sdir idx ver cur last msg
  sdir=$(state_dir)
  mkdir -p "$sdir" 2> /dev/null || exit 0
  exec 9> "$sdir/lock" || exit 0
  flock -n 9 || exit 0
  idx=$(mktemp) || exit 0
  if ! fetch_index amd64 > "$idx" 2> /dev/null; then rm -f "$idx"; exit 0; fi
  ver=$(latest_version "$idx") || { rm -f "$idx"; exit 0; }
  rm -f "$idx"
  cur=$(pkgbuild_get pkgver)
  [[ $ver == "$cur" ]] && exit 0
  last=$(cat "$sdir/last-notified" 2> /dev/null || true)
  [[ $ver == "$last" ]] && exit 0
  if [[ $(vercmp "$ver" "$cur") -gt 0 ]]; then
    msg="claude-desktop $ver is out (packaged: $cur). Run: ~/code/claude-desktop-aegix/update.sh"
  else
    msg="claude-desktop upstream regressed to $ver (packaged: $cur). Look manually; the updater never downgrades."
  fi
  notify_futureme "$msg" || exit 0
  printf '%s\n' "$ver" > "$sdir/last-notified"
  exit 0
}
# namcap_gate: pass namcap PKGBUILD output through; die on E: lines, W: flows.
namcap_gate() {
  local out
  out=$(cat)
  [[ -n $out ]] && printf '%s\n' "$out"
  if printf '%s\n' "$out" | grep -q '^PKGBUILD E:'; then
    die "namcap reported errors on the PKGBUILD; fix before building"
  fi
  return 0
}

smoke_fail() {
  echo "SMOKE TEST FAILED: $*" >&2
  local prev
  prev=$(ls -t /var/cache/pacman/pkg/claude-desktop-aegix-bin-*.pkg.tar.zst 2> /dev/null | sed -n 2p)
  if [[ -n $prev ]] && confirm "Reinstall previous package $prev?"; then
    sudo pacman -U --noconfirm "$prev" || echo "rollback failed; fix by hand" >&2
  fi
  die "stopping before publish"
}

# smoke_test <pkgfile>: install and prove the app works on this machine.
smoke_test() {
  local pkg=$1 out rc start dur ver cur
  sudo pacman -U --noconfirm "$pkg" || die "pacman -U failed"

  start=$(date +%s)
  out=$(timeout 12 claude-desktop 2>&1); rc=$?
  dur=$(( $(date +%s) - start ))
  if grep -qE 'Exiting GPU process|eglInitialize' <<< "$out"; then
    smoke_fail "GPU process errors in launch output: $(grep -m2 -E 'Exiting GPU process|eglInitialize' <<< "$out")"
  fi
  if [[ $rc -ne 124 ]] && ! pgrep -f /usr/lib/claude-desktop > /dev/null; then
    smoke_fail "app exited after ${dur}s with no surviving instance (exit $rc)"
  fi
  echo "launch: ok (${dur}s, exit $rc, instance running: $(pgrep -cf /usr/lib/claude-desktop))"

  [[ $(stat -c '%a %U' /usr/lib/claude-desktop/chrome-sandbox) == "4755 root" ]] \
    || smoke_fail "chrome-sandbox is not setuid root"
  echo "chrome-sandbox: 4755 root"

  [[ $(xdg-mime query default x-scheme-handler/claude) == "com.anthropic.Claude.desktop" ]] \
    || smoke_fail "claude: URL scheme handler is not com.anthropic.Claude.desktop"
  echo "scheme handler: ok"

  local flags_x11 flags_way
  flags_x11=$(sed 's/^exec /echo /' /usr/bin/claude-desktop | env -u WAYLAND_DISPLAY sh)
  flags_way=$(sed 's/^exec /echo /' /usr/bin/claude-desktop | env WAYLAND_DISPLAY=wayland-0 sh)
  if [[ -e /proc/driver/nvidia/version && ! -f $HOME/.config/claude-desktop-flags.conf ]]; then
    grep -q -- '--ozone-platform=x11' <<< "$flags_x11" \
      || smoke_fail "wrapper did not add the NVIDIA X11 flags: $flags_x11"
  fi
  echo "wrapper flags x11: $flags_x11"
  echo "wrapper flags wayland: $flags_way"

  cur=$(pkgbuild_get pkgver)
  ver=$(head -c 300000 /usr/lib/claude-desktop/resources/app.asar 2> /dev/null \
    | grep -oam1 '"version": *"[0-9][0-9.]*"' | grep -oam1 '[0-9][0-9.]*')
  if [[ -n $ver ]]; then
    [[ $ver == "$cur" ]] || smoke_fail "app.asar reports $ver, PKGBUILD says $cur"
    echo "app version: $ver (matches pkgver)"
  else
    echo "app version: could not read from app.asar; pacman says $(pacman -Q claude-desktop-aegix-bin)"
  fi
  echo "smoke test: PASS"
}

# build_and_test <no_publish>: lint, build, pause 1 (install + smoke).
build_and_test() {
  local no_publish=$1 rd pkgfile
  rd=${UPDATER_REPO_DIR:-$REPO_DIR}
  ( cd "$rd" && namcap PKGBUILD 2>&1 ) | namcap_gate || exit 1
  ( cd "$rd" && makepkg -f ) || die "makepkg failed"
  pkgfile=$(ls -t "$rd"/claude-desktop-aegix-bin-*.pkg.tar.zst | head -1)
  [[ -n $pkgfile ]] || die "no built package found"
  echo "== namcap on the built package (informational; a repacked Electron blob always warns) =="
  namcap "$pkgfile" 2>&1 || true
  confirm "PAUSE 1: install $(basename "$pkgfile") and run the smoke test (needs sudo)?" \
    || die "stopped before install"
  smoke_test "$pkgfile"
}

# cmd_full <deb_path> <no_publish> <pkgrel_only>
cmd_full() {
  local deb_path=$1 no_publish=$2 pkgrel_only=$3
  local sdir idxa idxr ver cur sha64 shaarm newdeb olddeb report
  sdir=$(state_dir); mkdir -p "$sdir/debs"

  if [[ $pkgrel_only == 1 ]]; then
    echo "packaging-only release: bumping pkgrel"
    bump_pkgrel
    regen_srcinfo
    build_and_test "$no_publish"
    cmd_publish "$(pkgbuild_get pkgver)" "$no_publish"
    return
  fi

  idxa=$(mktemp) || die "mktemp failed"
  fetch_index amd64 > "$idxa" || die "cannot fetch the amd64 Packages index"
  ver=$(latest_version "$idxa") || die "no versions in the index"
  cur=$(pkgbuild_get pkgver)
  if [[ $ver == "$cur" ]]; then
    echo "up to date: upstream $ver == PKGBUILD $cur"
    rm -f "$idxa"; exit 0
  fi
  if [[ $(vercmp "$ver" "$cur") -lt 0 ]]; then
    rm -f "$idxa"
    die "upstream newest is $ver, below packaged $cur: upstream pulled a release. The updater never downgrades; handle this by hand if it must happen."
  fi
  echo "update: $cur -> $ver"

  idxr=$(mktemp) || die "mktemp failed"
  fetch_index arm64 > "$idxr" || die "cannot fetch the arm64 Packages index"
  shaarm=$(stanza_field "$idxr" "$ver" SHA256)
  if [[ -z $shaarm ]]; then
    echo "the arm64 index does not have $ver yet (amd64 does): the arches are skewed."
    echo "Recommended: wait a day and rerun. Proceeding publishes a PKGBUILD whose"
    echo "aarch64 source entry is broken until upstream catches up."
    confirm "Proceed anyway?" || die "stopping on arch skew; rerun when arm64 catches up"
    shaarm=$(sed -n "s/^sha256sums_aarch64=('\(.*\)')$/\1/p" "${UPDATER_REPO_DIR:-$REPO_DIR}/PKGBUILD")
  fi

  if pgrep -f /usr/lib/claude-desktop > /dev/null; then
    echo "claude-desktop is RUNNING: replacing /usr/lib/claude-desktop under it breaks new windows until restart."
    confirm "Proceed with it running?" || die "stopped; quit the app and rerun"
  fi

  if [[ -n $deb_path ]]; then
    newdeb=$deb_path
  else
    newdeb=$(fetch_deb "$idxa" "$ver" "$sdir/debs") || exit 1
  fi
  olddeb=""
  for olddeb in "$sdir/debs/claude-desktop_${cur}_amd64.deb" \
                "${UPDATER_REPO_DIR:-$REPO_DIR}/claude-desktop_${cur}_amd64.deb" \
                "$HOME/Applications/claude-desktop/claude-desktop_amd64.deb"; do
    [[ -f $olddeb ]] && break
  done
  [[ -f $olddeb ]] || die "no previous .deb found for the drift diff"
  echo "== drift check: $(basename "$olddeb") vs $(basename "$newdeb") =="
  drift_check "$olddeb" "$newdeb" || die "drift check stopped the run; resolve the STOP lines (deps.map, PKGBUILD) and rerun"

  sha64=$(stanza_field "$idxa" "$ver" SHA256)
  rm -f "$idxa" "$idxr"
  rewrite_pkgbuild "$ver" "$sha64" "$shaarm"
  regen_srcinfo
  build_and_test "$no_publish"
  cmd_publish "$ver" "$no_publish"

  cp -f "$newdeb" "$sdir/debs/" 2> /dev/null || true
  echo "== report =="
  echo "updated: $cur -> $ver (pkgrel 1); aarch64 published UNVERIFIED (not buildable here)"
  echo "drift, smoke checks, and publish output are above"
}

cmd_publish() { die "publish not implemented"; }

# --- dispatch ----------------------------------------------------------------

main() {
  local mode=full deb_path="" no_publish=0 pkgrel_only=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --cron) mode=cron ;;
      --check) mode=check ;;
      --deb) shift; deb_path=${1:-}; [[ -n $deb_path ]] || die "--deb needs a path" ;;
      --no-publish) no_publish=1 ;;
      --pkgrel) pkgrel_only=1 ;;
      *) die "unknown flag: $1 (modes: --cron --check --deb PATH --no-publish --pkgrel)" ;;
    esac
    shift
  done
  case $mode in
    check) cmd_check ;;
    cron) cmd_cron ;;
    full)
      if [[ -n $deb_path ]]; then
        local idx
        idx=$(mktemp) || die "mktemp failed"
        fetch_index amd64 > "$idx" || die "cannot fetch the Packages index"
        validate_local_deb "$deb_path" "$idx" > /dev/null
        rm -f "$idx"
      fi
      cmd_full "$deb_path" "$no_publish" "$pkgrel_only"
      ;;
  esac
}

[[ ${UPDATER_TEST:-0} == 1 ]] || main "$@"
