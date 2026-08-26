#!/usr/bin/env bash
# Fails when GameVersion reuses the base branch's number for a DIFFERENT rule.
#
# The number alone cannot detect the collision: two branches can both read "1".
# What distinguishes them is the RULE the number is attached to, so this diffs
# the HEADLINE on the prepend-only changelog comment, not the digits.
set -euo pipefail

base="${1:-origin/main}"
branch="${2:-HEAD}"
file="src/pistonball/sim_types.nim"

version_of() {
  git show "$1:${file}" 2>/dev/null |
    grep -m1 'GameVersion\* =' | grep -o '"[0-9]*"' | tr -d '"'
}
headline_of() {
  git show "$1:${file}" 2>/dev/null |
    grep -A1 -m1 'GameVersion\* =' | tail -n1 | sed 's/^[[:space:]]*##[[:space:]]*//'
}

base_version="$(version_of "${base}" || true)"
branch_version="$(version_of "${branch}" || true)"

if [ -z "${branch_version}" ]; then
  echo "no GameVersion in ${branch}:${file}" >&2
  exit 1
fi
if [ "${base_version}" != "${branch_version}" ]; then
  echo "GameVersion moved ${base_version:-?} -> ${branch_version}: ok"
  exit 0
fi

base_headline="$(headline_of "${base}")"
branch_headline="$(headline_of "${branch}")"
if [ "${base_headline}" = "${branch_headline}" ]; then
  echo "GameVersion ${branch_version} untouched: ok"
  exit 0
fi

echo "::error::GameVersion ${branch_version} is already spent by ${base} for a" >&2
echo "::error::different rule. Base:   ${base_headline}" >&2
echo "::error::         This branch: ${branch_headline}" >&2
echo "::error::Take the next free number and re-record any fixtures." >&2
exit 1
