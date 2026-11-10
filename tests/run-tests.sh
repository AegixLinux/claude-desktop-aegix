#!/usr/bin/env bash
# Test harness for update.sh. Run: bash tests/run-tests.sh [t_name ...]
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
FIX="$HERE/fixtures"
TMP="$HERE/tmp"
UPDATE="$REPO/update.sh"

pass=0 fail=0

if [[ ! -f $UPDATE ]]; then
  echo "FAIL: $UPDATE does not exist; nothing to test" >&2
  exit 1
fi
# Source for unit-level tests; UPDATER_TEST=1 suppresses main dispatch.
UPDATER_TEST=1 source "$UPDATE" || { echo "FAIL: cannot source update.sh" >&2; exit 1; }

# --- assertion helpers -------------------------------------------------------
_t_fail() { echo "  FAIL: $*" >&2; return 1; }
expect_eq() { [[ $1 == "$2" ]] || _t_fail "expected '$2', got '$1'"; }
expect_contains() { [[ $1 == *"$2"* ]] || _t_fail "output lacks '$2': $1"; }
expect_exit() { # expect_exit <want> <got>
  [[ $2 -eq $1 ]] || _t_fail "expected exit $1, got $2"
}

fresh_tmp() { rm -rf "$TMP"; mkdir -p "$TMP"; }

# Fixture PKGBUILD so pkgbuild_get tests do not depend on the live version.
make_fixture_pkgbuild() { # make_fixture_pkgbuild <dir> [pkgver] [pkgrel]
  mkdir -p "$1"
  printf 'pkgver=%s\npkgrel=%s\n' "${2:-1.2.3}" "${3:-1}" > "$1/PKGBUILD"
}

# --- Task 1 tests ------------------------------------------------------------
t_latest_version_picks_vercmp_max() {
  local v
  v=$(latest_version "$FIX/current/binary-amd64/Packages") || return 1
  expect_eq "$v" "4.23118.1"
}

t_stanza_field_sha256() {
  local s
  s=$(stanza_field "$FIX/current/binary-amd64/Packages" 1.17282.0 SHA256) || return 1
  expect_eq "$s" "1c2bab32bac58dd7994e39190f370131790342409f201cf7c7133120a5b5c8df"
}

t_pkgbuild_get_pkgver() {
  fresh_tmp
  make_fixture_pkgbuild "$TMP/repo" 1.2.3 7
  local v r
  v=$(UPDATER_REPO_DIR="$TMP/repo" pkgbuild_get pkgver) || return 1
  r=$(UPDATER_REPO_DIR="$TMP/repo" pkgbuild_get pkgrel) || return 1
  expect_eq "$v" "1.2.3" && expect_eq "$r" "7"
}

t_check_mode_current() {
  local out rc
  out=$(UPDATER_INDEX_URL_BASE="file://$FIX/current" bash "$UPDATE" --check 2>&1); rc=$?
  expect_exit 0 "$rc" && expect_contains "$out" "up to date"
}

t_check_mode_update() {
  local out rc
  out=$(UPDATER_INDEX_URL_BASE="file://$FIX/newer" bash "$UPDATE" --check 2>&1); rc=$?
  expect_exit 1 "$rc" && expect_contains "$out" "9.0.0.1"
}

t_deb_refused_when_not_in_index() {
  local out rc
  out=$(UPDATER_INDEX_URL_BASE="file://$FIX/old" bash "$UPDATE" --deb "$REPO/claude-desktop_4.23118.1_amd64.deb" 2>&1); rc=$?
  [[ $rc -ne 0 ]] || _t_fail "expected nonzero exit" || return 1
  expect_contains "$out" "not in the Packages index"
}

# --- runner ------------------------------------------------------------------
all_tests=$(declare -F | awk '$3 ~ /^t_/ {print $3}')
tests=${*:-$all_tests}
for t in $tests; do
  if ( set -e; "$t" ); then
    echo "PASS $t"; pass=$((pass+1))
  else
    echo "FAIL $t"; fail=$((fail+1))
  fi
done
echo "----"
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
