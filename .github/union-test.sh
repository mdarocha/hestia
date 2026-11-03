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
    echo "--- manifests before gc"; list_manifests
    "$HESTIA_BIN" gc
    echo "--- manifests after gc"; list_manifests > after.txt; cat after.txt
    ref="refs/heads/${GITHUB_REF_NAME}"
    main_keys=$(awk -F'\t' -v r="$ref" '$2==r && $1 ~ /^m3#/ {print $1}' after.txt)
    echo "main chain: $main_keys"
    [ "$(echo "$main_keys" | wc -l)" = 1 ] && echo "$main_keys" | grep -q '^m3#2$' \
      || { echo "FAIL: main chain must be exactly m3#2"; exit 1; }
    pr_keys=$(awk -F'\t' '$2 ~ /^refs\/pull\// && $1 ~ /^m3pr#/ {print $1}' after.txt)
    echo "PR chain: $pr_keys"
    [ "$pr_keys" = 'm3pr#3' ] || { echo "FAIL: PR chain must be exactly m3pr#3"; exit 1; }
    ;;
  pr4) expect_cached A B C D E; build F ;;
  *) echo "unknown phase $phase"; exit 1 ;;
esac
