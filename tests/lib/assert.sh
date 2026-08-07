# Assertion helpers. Source this, call finish at the end.
# shellcheck shell=sh
ASSERT_FAILURES=0

pass() { printf '  ok   %s\n' "$1"; }
fail() {
    printf '  FAIL %s\n       %s\n' "$1" "$2" >&2
    ASSERT_FAILURES=$((ASSERT_FAILURES + 1))
}

assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1"
    else fail "$1" "expected [$2] got [$3]"; fi
}

assert_ne() {
    if [ "$2" != "$3" ]; then pass "$1"
    else fail "$1" "expected difference, both were [$2]"; fi
}

# -- so a pattern beginning with a dash is an operand, not an option. CLI flags
# are exactly what these suites assert on, and grep's error goes to stderr while
# the assertion just reports a mismatch, which reads as a product bug.
assert_match() {
    if printf '%s' "$3" | grep -Eq -- "$2"; then pass "$1"
    else fail "$1" "[$3] does not match /$2/"; fi
}

assert_no_match() {
    if printf '%s' "$3" | grep -Eq -- "$2"; then fail "$1" "[$3] unexpectedly matches /$2/"
    else pass "$1"; fi
}

assert_fails() {
    name=$1; shift
    if "$@" >/dev/null 2>&1; then fail "$name" "expected non-zero exit, got 0"
    else pass "$name"; fi
}

finish() {
    if [ "$ASSERT_FAILURES" -gt 0 ]; then
        printf '%s assertion(s) failed\n' "$ASSERT_FAILURES" >&2
        exit 1
    fi
    printf 'all assertions passed\n'
}
