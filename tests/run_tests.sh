#!/usr/bin/env bash
set -u
bin="${1:-zig-out/bin/pryzma}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
passed=0
failed=0
for source in tests/*.pryzma; do
    name="${source%.pryzma}"
    expected="${name}.expected"
    [[ -f "$expected" ]] || continue
    actual="$(mktemp)"
    "$bin" "$source" >"$actual" 2>&1
    status=$?
    expected_text="$(cat "$expected")"
    actual_text="$(cat "$actual")"
    if [[ $status -eq 0 && "$expected_text" == "$actual_text" ]]; then
        printf '[OK] %s\n' "$(basename "$source")"
        ((passed+=1))
    else
        printf '[FAIL] %s (exit %s)\n' "$(basename "$source")" "$status"
        diff -u "$expected" "$actual" | head -40 || true
        ((failed+=1))
    fi
    rm -f "$actual"
done
printf '%d passed, %d failed\n' "$passed" "$failed"
((failed == 0))
