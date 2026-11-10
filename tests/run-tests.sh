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

# --- Task 2 tests ------------------------------------------------------------

# make_isolated_futureme <dir>: prints the path of a wrapper that runs the real
# futureme with its XDG dirs pointed inside <dir>, so no test touches the real
# mailbox (isolation pattern verified in the design doc).
make_isolated_futureme() {
  local wrap="$1/futureme-isolated"
  mkdir -p "$1"
  cat > "$wrap" <<EOF
#!/usr/bin/env bash
export XDG_DATA_HOME="$1/share" XDG_CONFIG_HOME="$1/config" XDG_STATE_HOME="$1/state" HOME="$1"
exec /home/trashh_panda/.local/bin/futureme "\$@"
EOF
  chmod +x "$wrap"
  printf '%s\n' "$wrap"
}

# run_cron <fixture-base-url>: run --cron with isolated state + mailbox already
# set up in $TMP by the caller.
run_cron() {
  UPDATER_STATE_DIR="$TMP/state" UPDATER_INDEX_URL_BASE="$1" \
    FUTUREME_BIN="$TMP/futureme-isolated" bash "$UPDATE" --cron 2>&1
}

mailbox_count() { "$TMP/futureme-isolated" check --count 2>/dev/null || echo 0; }

t_cron_no_update_silent() {
  fresh_tmp; make_isolated_futureme "$TMP" > /dev/null
  local out rc
  out=$(run_cron "file://$FIX/current"); rc=$?
  expect_exit 0 "$rc" || return 1
  expect_eq "$out" "" || return 1
  [[ ! -e $TMP/state/last-notified ]] || _t_fail "state file written on no-update" || return 1
  expect_eq "$(mailbox_count)" "0"
}

t_cron_new_version_notifies() {
  fresh_tmp; make_isolated_futureme "$TMP" > /dev/null
  local out rc
  out=$(run_cron "file://$FIX/newer"); rc=$?
  expect_exit 0 "$rc" || return 1
  expect_eq "$(cat "$TMP/state/last-notified")" "9.0.0.1" || return 1
  expect_eq "$(mailbox_count)" "1"
}

t_cron_dedup() {
  fresh_tmp; make_isolated_futureme "$TMP" > /dev/null
  run_cron "file://$FIX/newer" > /dev/null
  run_cron "file://$FIX/newer" > /dev/null
  expect_eq "$(mailbox_count)" "1"
}

t_cron_downgrade_notifies_once() {
  fresh_tmp; make_isolated_futureme "$TMP" > /dev/null
  run_cron "file://$FIX/old" > /dev/null   # old fixture max 1.17282.0 < pkgver
  expect_eq "$(mailbox_count)" "1" || return 1
  local out
  out=$(run_cron "file://$FIX/old")
  expect_eq "$out" "" || return 1
  expect_eq "$(mailbox_count)" "1"
}

t_cron_network_failure_silent() {
  fresh_tmp; make_isolated_futureme "$TMP" > /dev/null
  local out rc
  out=$(run_cron "file:///nonexistent-dir-for-test"); rc=$?
  expect_exit 0 "$rc" || return 1
  expect_eq "$out" "" || return 1
  [[ ! -e $TMP/state/last-notified ]] || _t_fail "state written on network failure"
}

t_cron_lock() {
  fresh_tmp; make_isolated_futureme "$TMP" > /dev/null
  mkdir -p "$TMP/state"
  ( exec 9>"$TMP/state/lock"; flock 9; sleep 3 ) &
  local holder=$!
  sleep 0.3
  local out rc
  out=$(run_cron "file://$FIX/newer"); rc=$?
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  expect_exit 0 "$rc" || return 1
  expect_eq "$out" "" || return 1
  expect_eq "$(mailbox_count)" "0"
}

# --- Task 3 tests ------------------------------------------------------------

REAL_DEB="$REPO/claude-desktop_4.23118.1_amd64.deb"

# make_synthetic_deb <out.deb> <version> [extra-dep] [data-member] [desktop-path]
# Builds a tiny structurally valid .deb: real control fields with the version
# swapped (and an optional extra Depends token), plus a minimal data archive
# holding every path the PKGBUILD names (the .desktop path is overridable).
make_synthetic_deb() {
  local out=$1 ver=$2 extradep=${3:-} datamember=${4:-data.tar.xz} desktop=${5:-usr/share/applications/com.anthropic.Claude.desktop}
  local w; w=$(mktemp -d)
  local cmember; cmember=$(bsdtar -tf "$REAL_DEB" | grep '^control\.tar' | head -1)
  bsdtar -xOf "$REAL_DEB" "$cmember" | bsdtar -xO -f - '*control' \
    | sed "s/^Version: .*/Version: $ver/" > "$w/control"
  if [[ -n $extradep ]]; then
    sed -i "s/^Depends: /Depends: $extradep, /" "$w/control"
  fi
  ( cd "$w" && bsdtar -cJf control.tar.xz control )
  mkdir -p "$w/data/usr/lib/claude-desktop/resources/linux-mime" \
           "$w/data/usr/share/icons/hicolor/512x512/apps" \
           "$w/data/$(dirname "$desktop")"
  touch "$w/data/usr/lib/claude-desktop/chrome-sandbox" \
        "$w/data/usr/lib/claude-desktop/LICENSES.chromium.html" \
        "$w/data/usr/lib/claude-desktop/resources/linux-mime/com.anthropic.Claude.xml" \
        "$w/data/usr/share/icons/hicolor/512x512/apps/claude.png" \
        "$w/data/$desktop"
  case $datamember in
    data.tar.xz)  ( cd "$w/data" && bsdtar -cJf "../$datamember" usr ) ;;
    data.tar.zst) ( cd "$w/data" && bsdtar -c --zstd -f "../$datamember" usr ) ;;
  esac
  printf '2.0\n' > "$w/debian-binary"
  rm -f "$out"
  ( cd "$w" && ar qc "$out" debian-binary control.tar.xz "$datamember" )
  rm -rf "$w"
}

t_deb_tokens_splits_alternation() {
  fresh_tmp
  printf 'Depends: a | b, c (>= 1)\n' > "$TMP/control"
  local got
  got=$(deb_tokens "$TMP/control" Depends | tr '\n' ' ')
  expect_eq "$got" "a b c "
}

t_drift_same_deb_passes() {
  fresh_tmp
  local rc=0
  drift_check "$REAL_DEB" "$REAL_DEB" > "$TMP/report" 2>&1 || rc=$?
  expect_exit 0 "$rc" || { cat "$TMP/report" >&2; return 1; }
}

t_drift_new_dep_stops() {
  fresh_tmp
  make_synthetic_deb "$TMP/next.deb" 9.0.0.1 libfoo1
  local out rc=0
  out=$(drift_check "$REAL_DEB" "$TMP/next.deb" 2>&1) || rc=$?
  expect_exit 1 "$rc" || return 1
  expect_contains "$out" "libfoo1"
}

t_drift_moved_desktop_file_stops() {
  fresh_tmp
  make_synthetic_deb "$TMP/next.deb" 9.0.0.1 "" data.tar.xz usr/share/applications/claude-moved.desktop
  local out rc=0
  out=$(drift_check "$REAL_DEB" "$TMP/next.deb" 2>&1) || rc=$?
  expect_exit 1 "$rc" || return 1
  expect_contains "$out" "com.anthropic.Claude.desktop"
}

t_drift_zst_data_stops() {
  fresh_tmp
  make_synthetic_deb "$TMP/next.deb" 9.0.0.1 "" data.tar.zst
  local out rc=0
  out=$(drift_check "$REAL_DEB" "$TMP/next.deb" 2>&1) || rc=$?
  expect_exit 1 "$rc" || return 1
  expect_contains "$out" "prepare()"
}

t_fetch_deb_unfetchable_message() {
  fresh_tmp
  mkdir -p "$TMP/emptypool"
  local out rc=0
  out=$(UPDATER_POOL_URL_BASE="file://$TMP/emptypool" UPDATER_STATE_DIR="$TMP/state" \
        fetch_deb "$FIX/newer/binary-amd64/Packages" 9.0.0.1 "$TMP/dest" 2>&1) || rc=$?
  [[ $rc -ne 0 ]] || _t_fail "expected nonzero exit" || return 1
  expect_contains "$out" "not yet fetchable"
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
