#!/bin/bash
# test-helpers.sh — Simple test assertion helpers

_PASS=0 _FAIL=0 _TOTAL=0

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

test_summary() {
    echo
    printf "Results: %d/%d passed" "$_PASS" "$_TOTAL"
    if (( _FAIL > 0 )); then
        printf " (%d FAILED)" "$_FAIL"
    fi
    echo
    return "$_FAIL"
}
