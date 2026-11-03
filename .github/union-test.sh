#!/usr/bin/env bash
# Throwaway real-repository test of the PR manifest union. Phases run in
# separate workflow runs because the daemon only drains in the post step.
set -euo pipefail
phase="$1"
: "${SALT:?}"

expr() {
  printf 'derivation { name = "hestia-union-%s-%s"; system = "x86_64-linux"; builder = "/bin/sh"; args = ["-c" "echo %s-%s > $out"]; }' "$1" "$SALT" "$1" "$SALT"
}

# Must substitute from the local hestia daemon: --max-jobs 0 forbids a build.
expect_cached() {
  for name in "$@"; do
    log=$(nix build --impure --expr "$(expr "$name")" --max-jobs 0 --no-link --print-build-logs 2>&1) \
      || { echo "$log"; echo "FAIL: $name is not substitutable"; exit 1; }
    echo "$log" | grep -E "copying path '.*hestia-union-$name-.*' from 'http://127.0.0.1" \
      || { echo "$log"; echo "FAIL: $name was not copied from hestia"; exit 1; }
    echo "OK: $name substituted from hestia"
  done
}

expect_absent() {
  for name in "$@"; do
    if nix build --impure --expr "$(expr "$name")" --max-jobs 0 --no-link >/dev/null 2>&1; then
      echo "FAIL: $name is visible but must not be"
      exit 1
    fi
    echo "OK: $name is not visible"
  done
}

build() {
  nix build --impure --expr "$(expr "$1")" --no-link --print-build-logs
  echo "built $1"
}

list_manifests() {
  gh cache list --limit 100 --json key,ref,id,createdAt --jq \
    '.[] | select(.key|test("^m3(pr)?#")) | "\(.key)\t\(.ref)\tid=\(.id)\t\(.createdAt)"' | sort
}

echo "phase $phase, ref $GITHUB_REF"
case "$phase" in
  main1) build A ;;
  pr1) expect_cached A; expect_absent B; build B ;;
  main2) expect_cached A; expect_absent B; build C ;;
  pr2) expect_cached A B C; build D ;;
  pr3) expect_cached A B C D; build E ;;
  gc)
    echo "--- manifests before gc"; list_manifests | tee before.txt
    "$HESTIA_BIN" gc
    echo "--- manifests after gc"; list_manifests | tee after.txt
    # Each (family, ref) must keep exactly its newest entry.
    heads() { awk -F'\t' '{split($1,k,"#"); id=k[2]+0; key=k[1] "\t" $2; if (id>max[key]) max[key]=id} END {for (key in max) print key "\t" max[key]}' "$1" | sort; }
    heads before.txt > heads-before.txt
    heads after.txt > heads-after.txt
    echo "heads before:"; cat heads-before.txt
    echo "heads after:"; cat heads-after.txt
    diff heads-before.txt heads-after.txt || { echo "FAIL: a head changed"; exit 1; }
    [ "$(wc -l < after.txt)" = "$(wc -l < heads-after.txt)" ] \
      || { echo "FAIL: superseded manifests were left behind"; exit 1; }
    grep -qP '^m3#\d+\trefs/heads/' after.txt || { echo "FAIL: main chain gone"; exit 1; }
    grep -qP '^m3pr#\d+\trefs/pull/' after.txt || { echo "FAIL: PR chain gone"; exit 1; }
    echo "OK: per-ref heads preserved, superseded manifests deleted"
    ;;
  pr4) expect_cached A B C D E; build F ;;
  *) echo "unknown phase $phase"; exit 1 ;;
esac
