#!/usr/bin/env bash
# run.sh: run scan.sh --strict on each fixture and check its expect.txt.
# expect.txt line formats:
#   hit ID       the check or guard ID has hits
#   missing ID   the guard ID prints NOT FOUND
#   has TEXT     TEXT appears in the output
#   absent TEXT  TEXT does not appear in the output
#   exit N       scan.sh --strict exits with N
# Usage: tests/run.sh

HERE=$(cd "$(dirname "$0")" && pwd)
SCAN="$HERE/../scripts/scan.sh"
FAILED=0

for dir in "$HERE"/fixtures/*/; do
  name=$(basename "$dir")
  out=$(bash "$SCAN" --strict "$dir" 2>/dev/null)
  code=$?
  errors=0
  while read -r kind arg; do
    case "$kind" in
      '' | \#*) continue ;;
      hit) printf '%s\n' "$out" | grep -qE "^### \[$arg\] .*\([0-9]+ hits\)$" ;;
      missing) printf '%s\n' "$out" | grep -qE "^### \[$arg\] .*: NOT FOUND$" ;;
      has) printf '%s\n' "$out" | grep -qF -- "$arg" ;;
      absent) ! printf '%s\n' "$out" | grep -qF -- "$arg" ;;
      exit) [ "$code" = "$arg" ] ;;
      *) echo "  $name: unknown line: $kind $arg"; false ;;
    esac || { echo "  FAIL $name: $kind $arg"; errors=$((errors + 1)); }
  done < "$dir/expect.txt"
  if [ "$errors" = 0 ]; then
    echo "PASS $name"
  else
    echo "FAIL $name ($errors)"
    FAILED=$((FAILED + 1))
  fi
done

[ "$FAILED" = 0 ] || { echo "$FAILED fixture(s) failed"; exit 1; }
