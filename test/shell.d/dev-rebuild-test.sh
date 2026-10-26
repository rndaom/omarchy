#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

export HOME="$test_tmp/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME/.config/omarchy" "$test_tmp/bin"

cat >"$test_tmp/bin/omarchy-notification-send" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$HOME/notified"
SH
chmod +x "$test_tmp/bin/omarchy-notification-send"

upstream="$test_tmp/upstream"
checkout="$test_tmp/checkout"
patches="$HOME/.config/omarchy/dev-patches"

g() { git -C "$upstream" "$@" >/dev/null; }
commit_file() { # branch-from, branch, file, content
  g switch -qC "$2" "$1" && printf '%s\n' "$4" >"$upstream/$3" && g add -A && g commit -qm "$2"
}

# Upstream carries the rebuild tooling, as the branch that adds it would.
git init -q -b quattro "$upstream"
mkdir -p "$upstream/bin"
printf 'one\n' >"$upstream/a"
printf 'base\n' >"$upstream/shared"
printf '#!/bin/bash\n' >"$upstream/bin/omarchy-dev-rebuild"
chmod +x "$upstream/bin/omarchy-dev-rebuild"
printf 'exec omarchy-dev-rebuild\n' >"$upstream/bin/omarchy-update-dev"
g add . && g commit -qm base

commit_file quattro fix-b b b
commit_file quattro fix-c shared c
commit_file quattro fix-d shared d
commit_file quattro landed a two
g switch -qC drop-tooling quattro && g rm -q bin/omarchy-dev-rebuild && g commit -qm drop
commit_file quattro quattro a two

git clone -q "$upstream" "$checkout"
git -C "$checkout" switch -qc patched origin/quattro

rebuild() {
  OMARCHY_PATH="$checkout" PATH="$test_tmp/bin:$ROOT/bin:$PATH" "$ROOT/bin/omarchy-dev-rebuild" "$@" >"$test_tmp/out" 2>&1
}
newer_upstream() {
  g switch -q quattro && printf '%s\n' "$1" >"$upstream/a" && g add a && g commit -qm "$1"
}

printf '# fixes\norigin/fix-b\norigin/landed\norigin/fix-c\norigin/fix-d\norigin/gone\n' >"$patches"
rebuild || fail "rebuild failed" "$(cat "$test_tmp/out")"
[[ -f $checkout/b && $(cat "$checkout/shared") == "c" && $(cat "$checkout/a") == "two" ]] ||
  fail "the checkout is upstream with the listed branches merged" "$(cat "$test_tmp/out")"
grep -q "origin/landed: adds nothing" "$test_tmp/out" || fail "a branch that landed upstream is reported" "$(cat "$test_tmp/out")"
grep -q "origin/fix-d: conflicts in shared, left out" "$test_tmp/out" || fail "a conflicting branch is left out" "$(cat "$test_tmp/out")"
grep -q "origin/fix-d origin/gone" "$HOME/notified" || fail "left-out branches are reported in a notification" "$(cat "$HOME/notified" 2>/dev/null)"
[[ -z $(git -C "$checkout" worktree list | sed 1d) ]] || fail "the build worktree is removed"
pass "a rebuild merges the listed branches onto upstream and leaves out what conflicts"

# --resolve stops at the conflict in list order; the resolution is replayed from then on.
rebuild --resolve origin/fix-d || fail "resolve failed" "$(cat "$test_tmp/out")"
work="$HOME/.cache/omarchy-dev-resolve"
grep -q "^  shared$" "$test_tmp/out" && [[ -d $work ]] || fail "--resolve leaves the conflicted merge to resolve" "$(cat "$test_tmp/out")"
printf 'c\nd\n' >"$work/shared"
git -C "$work" add -A && git -C "$work" commit -q --no-edit
git -C "$checkout" worktree remove "$work"
newer_upstream three
: >"$HOME/notified"
rebuild || fail "rebuild failed" "$(cat "$test_tmp/out")"
[[ $(cat "$checkout/shared") == $'c\nd' && $(cat "$checkout/a") == "three" ]] ||
  fail "a resolved conflict is replayed on a newer upstream" "$(cat "$test_tmp/out")"
pass "a conflict resolved once with --resolve is replayed by later rebuilds"

# A commit made on the branch itself would be lost, so the rebuild stops for it.
before=$(git -C "$checkout" rev-parse HEAD)
printf 'mine\n' >"$checkout/mine" && git -C "$checkout" add mine && git -C "$checkout" commit -qm mine
newer_upstream four
rebuild || fail "a stray commit fails the update" "$(cat "$test_tmp/out")"
[[ -f $checkout/mine && $(cat "$checkout/a") == "three" ]] || fail "a branch with its own commit is left alone" "$(cat "$test_tmp/out")"
grep -q "commit(s) of its own" "$HOME/notified" || fail "a stray commit is reported" "$(cat "$HOME/notified")"
git -C "$checkout" reset -q --hard "$before"
pass "a commit made on the branch itself stops the rebuild instead of being lost"

# Edits in the way of the new build keep the checkout as it was, without failing the update.
printf 'edit\n' >"$checkout/a"
rebuild || fail "edits in the way fail the update" "$(cat "$test_tmp/out")"
[[ $(git -C "$checkout" rev-parse HEAD) == "$before" && $(cat "$checkout/a") == "edit" ]] ||
  fail "a checkout with edits in the way is left where it is" "$(cat "$test_tmp/out")"
grep -q "in the way of the new build" "$test_tmp/out" || fail "edits in the way are explained" "$(cat "$test_tmp/out")"
git -C "$checkout" checkout -q -- a
pass "edits in the way of the new build leave the checkout as it was"

# A build that loses the rebuild itself is never installed.
printf 'origin/fix-b\norigin/drop-tooling\n' >"$patches"
rebuild || fail "rebuild failed" "$(cat "$test_tmp/out")"
[[ $(git -C "$checkout" rev-parse HEAD) == "$before" ]] || fail "a build without the rebuild tooling is not installed" "$(cat "$test_tmp/out")"
grep -q "lost omarchy-dev-rebuild" "$HOME/notified" || fail "losing the tooling is reported" "$(cat "$HOME/notified")"
pass "a build that loses the rebuild tooling leaves the checkout as it was"

git -C "$checkout" switch -q --detach
rebuild || fail "a detached checkout fails the update" "$(cat "$test_tmp/out")"
grep -q "detached HEAD" "$test_tmp/out" || fail "a detached checkout is explained" "$(cat "$test_tmp/out")"
pass "a checkout off its branch is skipped without failing the update"
