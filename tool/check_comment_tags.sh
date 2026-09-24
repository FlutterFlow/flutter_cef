#!/usr/bin/env bash
#
# Fail if a tracked file carries an audit or port-plan tag, or a line citation.
#
# Tags like audit ids and port-plan law/slice numbers mean nothing without the
# report that defined them, and a `file.ext:<line>` citation goes stale with
# the next edit. Say the reason in words, or name the function. The original
# plans and audits live in docs/history/, which is skipped along with the
# CHANGELOGs and binary files.
#
# Only unambiguous shapes are checked:
#   - "LAW" followed by a number, "slice" in capitals, the port's spike log file
#   - a line citation: a .mm/.cc/.cpp/.h/.swift/.dart file name, a colon, digits
#   - a comment (after //, ///, # or *) that opens with a label of one capital
#     letter, one or two digits and a colon, or two such labels joined by "/"
#   - such a label in parentheses, optionally after "audit "
#
# Prints `file:line: text` for each hit and exits 1 if there are any.
# Usage: tool/check_comment_tags.sh   (from anywhere in the repo)
set -eu

cd "$(git rev-parse --show-toplevel)"

# POSIX extended regexes, so git grep reads them the same on macOS and Linux.
# (Written so this file doesn't match itself.)
W='[^A-Za-z0-9_]'
L='[A-Z][0-9]{1,2}'
patterns=(
  "(^|$W)LAW ?[0-9]+"
  "(^|$W)SLIC[E]($W|\$)"
  'SPIKE[S]\.md'
  '[A-Za-z0-9_]\.(mm|cc|cpp|h|swift|dart):[0-9]+'
  "(//|#|\\*) ?$L(/$L)?:"
  "\\((audit )?$L\\)"
)

args=()
for p in "${patterns[@]}"; do args+=(-e "$p"); done

set +e
hits="$(git grep -n -I -E "${args[@]}" -- . \
  ':(exclude)docs/history/' ':(exclude,glob)**/CHANGELOG*')"
rc=$?
set -e
if [ "$rc" -gt 1 ]; then
  echo "check_comment_tags: git grep failed ($rc)" >&2
  exit 2
fi
if [ -n "$hits" ]; then
  printf '%s\n' "$hits" | sed 's/^\([^:]*:[0-9]*\):/\1: /'
  echo >&2
  echo "Audit/port tags or line citations found (see tool/check_comment_tags.sh):" >&2
  echo "replace each with the reason in plain words." >&2
  exit 1
fi
echo "check_comment_tags: clean"
