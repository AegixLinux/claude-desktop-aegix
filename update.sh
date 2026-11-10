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
cmd_full() { die "not implemented"; }

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
