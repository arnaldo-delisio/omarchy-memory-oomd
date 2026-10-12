# Shared helpers for the shell tests. Source this file; call finish at the end.

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$TESTS_DIR")
SCRIPTS_DIR=$REPO_DIR/scripts
export LC_ALL=C

pass=0
fail=0

ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; shift; printf '       %s\n' "$@"; }

# assert_eq <description> <expected> <actual>
assert_eq() {
  if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1" "expected: $2" "actual:   $3"; fi
}

# assert_json <description> <json> <jq filter> <expected>: the filter's compact
# output must equal the expected text.
assert_json() {
  local actual
  # walk(+0) normalizes number literals (72.00 -> 72) so expectations stay plain.
  actual=$(jq -c "($3) | walk(if type == \"number\" then . + 0 else . end)" <<<"$2" 2>&1)
  if [[ $actual == "$4" ]]; then ok "$1"; else bad "$1" "filter:   $3" "expected: $4" "actual:   $actual"; fi
}

# assert_json_valid <description> <text>
assert_json_valid() {
  if jq -e . >/dev/null 2>&1 <<<"$2"; then ok "$1"; else bad "$1" "not valid JSON: ${2:0:200}"; fi
}

new_tmp() {
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/memory-oomd-test.XXXXXX")
  trap 'rm -rf "$TMP"' EXIT
}

# put <file> <content...>: create parent directories, write content with a newline.
put() {
  local file=$1; shift
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$*" > "$file"
}

finish() {
  printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
  (( fail == 0 ))
}
