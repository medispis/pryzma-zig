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
actual="$(mktemp)"
"$bin" pryzma.pryzma tests/if_test.pryzma >"$actual" 2>&1
status=$?
expected_text="$(cat tests/pryzma.expected)"
actual_text="$(cat "$actual")"
if [[ $status -eq 0 && "$expected_text" == "$actual_text" ]]; then
    printf '[OK] pryzma self-hosted interpreter\n'
    ((passed+=1))
else
    printf '[FAIL] pryzma self-hosted interpreter (exit %s)\n' "$status"
    diff -u tests/pryzma.expected "$actual" | head -40 || true
    ((failed+=1))
fi
rm -f "$actual"
if command -v script >/dev/null 2>&1; then
    repl_output="$(printf 'print "alpha"\nhistory\nhistory print\nhistory 1\nhistory clear\nhistory\nexit\n' | script -q -c "$bin" /dev/null 2>&1)"
    if grep -Fq '1. print "alpha"' <<<"$repl_output" &&
       grep -Fq "Searching for 'print' in history:" <<<"$repl_output" &&
       grep -Fq '2. history print' <<<"$repl_output" &&
       grep -Fq '1. history' <<<"$repl_output" &&
       grep -Fq 'alpha' <<<"$repl_output"; then
        printf '[OK] REPL history list, search, replay, and clear\n'
        ((passed+=1))
    else
        printf '[FAIL] REPL history list, search, replay, and clear\n'
        printf '%s\n' "$repl_output"
        ((failed+=1))
    fi
    info_output="$(printf 'info\nexit\n' | script -q -c "$bin" /dev/null 2>&1)"
    if grep -Fq 'Current Date and Time:' <<<"$info_output" &&
       grep -Fq 'Operating System:' <<<"$info_output" &&
       grep -Fq 'Processor:' <<<"$info_output"; then
        printf '[OK] REPL system information\n'
        ((passed+=1))
    else
        printf '[FAIL] REPL system information\n'
        printf '%s\n' "$info_output"
        ((failed+=1))
    fi
    errors_output="$(printf 'errors\nexit\n' | script -q -c "$bin" /dev/null 2>&1)"
    if grep -Fq '1 - Error keyword deleted' <<<"$errors_output" &&
       grep -Fq '44 - Field not found on object.' <<<"$errors_output"; then
        printf '[OK] REPL error-code table\n'
        ((passed+=1))
    else
        printf '[FAIL] REPL error-code table\n'
        printf '%s\n' "$errors_output"
        ((failed+=1))
    fi
    file_output="$(printf 'file\ntests/repl_file.pryzma\nn\nexit\n' | script -q -c "$bin" /dev/null 2>&1)"
    if grep -Fq 'Enter the file path of the program:' <<<"$file_output" &&
       grep -Fq 'file command loaded' <<<"$file_output" &&
       grep -Fq 'Clear variables, functions and structs dictionaries? (y/n):' <<<"$file_output"; then
        printf '[OK] REPL file command\n'
        ((passed+=1))
    else
        printf '[FAIL] REPL file command\n'
        printf '%s\n' "$file_output"
        ((failed+=1))
    fi
    debug_output="$(printf 'debug\ntests/repl_debug.pryzma\nc\nexit\n' | script -q -c "$bin" /dev/null 2>&1)"
    if grep -Fq "Path to the file to debug ('exit' to quit debug mode):" <<<"$debug_output" &&
       grep -Fq 'Debug: Executing line' <<<"$debug_output" &&
       grep -Fq 'debug command loaded' <<<"$debug_output"; then
        printf '[OK] REPL debug command\n'
        ((passed+=1))
    else
        printf '[FAIL] REPL debug command\n'
        printf '%s\n' "$debug_output"
        ((failed+=1))
    fi
    cls_output="$(printf 'x = 5\ncls\nprint x\nexit\n' | script -q -c "$bin" /dev/null 2>&1)"
    if grep -Fq 'Unknown variable or expression: x' <<<"$cls_output"; then
        printf '[OK] REPL cls clears interpreter state\n'
        ((passed+=1))
    else
        printf '[FAIL] REPL cls clears interpreter state\n'
        printf '%s\n' "$cls_output"
        ((failed+=1))
    fi
    variables_output="$(printf 'answer = 42\nv\nexit\n' | script -q -c "$bin" /dev/null 2>&1)"
    if grep -Fq "'answer': 42" <<<"$variables_output"; then
        printf '[OK] REPL variable inspection\n'
        ((passed+=1))
    else
        printf '[FAIL] REPL variable inspection\n'
        printf '%s\n' "$variables_output"
        ((failed+=1))
    fi
    functions_output="$(printf '/hello{print "hi"}\nf\nexit\n' | script -q -c "$bin" /dev/null 2>&1)"
    if grep -Fq "'hello':" <<<"$functions_output" &&
       grep -Fq 'print' <<<"$functions_output"; then
        printf '[OK] REPL function inspection\n'
        ((passed+=1))
    else
        printf '[FAIL] REPL function inspection\n'
        printf '%s\n' "$functions_output"
        ((failed+=1))
    fi
fi
if command -v python3 >/dev/null 2>&1; then
    if tests/test_http_import.sh "$bin"; then
        ((passed+=1))
    else
        ((failed+=1))
    fi
fi
printf '%d passed, %d failed\n' "$passed" "$failed"
((failed == 0))
