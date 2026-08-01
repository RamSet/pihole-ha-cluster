#!/bin/bash
# test-helpers.sh — Simple test assertion helpers

_PASS=0 _FAIL=0 _TOTAL=0

# Pull a single function definition out of a script so tests run against the
# real production implementation instead of a copy that can drift. Sourcing
# pihole-ha or pihole-ha-dash directly is not an option — both start doing work
# at load time. Assumes `name() {` and a closing `}` at the same indentation,
# which is how every function in those two scripts is written.
extract_fn() {
    local file="$1" name="$2" start first indent
    start="$(grep -n "^[[:space:]]*${name}()[[:space:]]*{" "$file" | head -1 | cut -d: -f1)"
    [[ -z "$start" ]] && { echo "extract_fn: $name not found in $file" >&2; return 1; }
    first="$(sed -n "${start}p" "$file")"
    indent="${first%%[! ]*}"
    # NB: `close` is an awk built-in, so the end marker needs another name.
    awk -v s="$start" -v endmark="${indent}}" 'NR>=s { print; if (NR>s && $0==endmark) exit }' "$file"
}

# Assert a command does not blow up on an unbound variable under `set -u`.
# Checks stderr rather than the exit status, because returning false is a
# legitimate result for the predicates this is used on — only the abort is a
# failure. Runs in a subshell so an abort cannot kill the suite.
no_unbound_error() {
    local err
    err="$( ( set -u; "$@" ) 2>&1 >/dev/null )"
    [[ "$err" != *"unbound variable"* ]]
}

assert_true() {
    local desc="$1"; shift
    (( _TOTAL++ ))
    if "$@" >/dev/null 2>&1; then
        (( _PASS++ ))
        printf "  PASS  %s\n" "$desc"
    else
        (( _FAIL++ ))
        printf "  FAIL  %s\n" "$desc"
    fi
}

assert_false() {
    local desc="$1"; shift
    (( _TOTAL++ ))
    if "$@" >/dev/null 2>&1; then
        (( _FAIL++ ))
        printf "  FAIL  %s (expected false, got true)\n" "$desc"
    else
        (( _PASS++ ))
        printf "  PASS  %s\n" "$desc"
    fi
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    (( _TOTAL++ ))
    if [[ "$expected" == "$actual" ]]; then
        (( _PASS++ ))
        printf "  PASS  %s\n" "$desc"
    else
        (( _FAIL++ ))
        printf "  FAIL  %s (expected='%s' actual='%s')\n" "$desc" "$expected" "$actual"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    (( _TOTAL++ ))
    if [[ "$haystack" == *"$needle"* ]]; then
        (( _PASS++ ))
        printf "  PASS  %s\n" "$desc"
    else
        (( _FAIL++ ))
        printf "  FAIL  %s (does not contain '%s')\n" "$desc" "$needle"
    fi
}

assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    (( _TOTAL++ ))
    if [[ "$haystack" != *"$needle"* ]]; then
        (( _PASS++ ))
        printf "  PASS  %s\n" "$desc"
    else
        (( _FAIL++ ))
        printf "  FAIL  %s (unexpectedly contains '%s')\n" "$desc" "$needle"
    fi
}

test_summary() {
    echo
    printf "Results: %d/%d passed" "$_PASS" "$_TOTAL"
    if (( _FAIL > 0 )); then
        printf " (%d FAILED)" "$_FAIL"
    fi
    echo
    return "$_FAIL"
}
