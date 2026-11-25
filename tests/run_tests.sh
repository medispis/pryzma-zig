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
    debug_output="$(printf 'struct DebugPoint{x = 1}\ndebug\ntests/repl_debug.pryzma\nst\n!! py_answer = 42\n! print py_answer\n! answer = 41\n! print answer\nc\nexit\n' | script -q -c "$bin" /dev/null 2>&1)"
    if grep -Fq "Path to the file to debug ('exit' to quit debug mode):" <<<"$debug_output" &&
       grep -Fq 'Debug: Executing line' <<<"$debug_output" &&
       grep -Fq 'Structs: DebugPoint:' <<<"$debug_output" &&
       grep -Fq '42' <<<"$debug_output" &&
       grep -Fq '41' <<<"$debug_output" &&
       grep -Fq 'debug command loaded' <<<"$debug_output"; then
        printf '[OK] REPL debug command and struct inspection\n'
        ((passed+=1))
    else
        printf '[FAIL] REPL debug command and struct inspection\n'
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
    structs_output="$(printf 'struct Point{x = 1|y = 2}\ns\nexit\n' | script -q -c "$bin" /dev/null 2>&1)"
    if grep -Fq "'Point':" <<<"$structs_output" &&
       grep -Fq "'x': 1" <<<"$structs_output"; then
        printf '[OK] REPL struct inspection\n'
        ((passed+=1))
    else
        printf '[FAIL] REPL struct inspection\n'
        printf '%s\n' "$structs_output"
        ((failed+=1))
    fi
    locals_output="$(printf '#ngc\n/locals_probe{loc saved_local = 17}\n@locals_probe\nl\nexit\n' | script -q -c "$bin" /dev/null 2>&1)"
    if grep -Fq "'saved_local':" <<<"$locals_output" &&
       grep -Fq '17' <<<"$locals_output" &&
       grep -Fq 'locals_probe' <<<"$locals_output"; then
        printf '[OK] REPL local-variable inspection\n'
        ((passed+=1))
    else
        printf '[FAIL] REPL local-variable inspection\n'
        printf '%s\n' "$locals_output"
        ((failed+=1))
    fi
    breakpoint_output="$(printf 'debug\ntests/debug_breakpoints.pryzma\nb 4\nc\nl\nr 3\nl\ns\nexit\n' | script -q -c "$bin" /dev/null 2>&1)"
    if grep -Fq 'Debug: Executing line 3:' <<<"$breakpoint_output" &&
       ! grep -Fq 'Debug: Executing line 2:' <<<"$breakpoint_output" &&
       grep -Fq 'Breakpoints: [3]' <<<"$breakpoint_output" &&
       grep -Fq 'Breakpoints: []' <<<"$breakpoint_output" &&
       grep -Fq 'breakpoint line three' <<<"$breakpoint_output"; then
        printf '[OK] debugger breakpoint list, removal, and continue\n'
        ((passed+=1))
    else
        printf '[FAIL] debugger breakpoint list, removal, and continue\n'
        printf '%s\n' "$breakpoint_output"
        ((failed+=1))
    fi
    debug_log="$(mktemp)"
    printf 'debug\ntests/repl_debug.pryzma\nhelp\nclear\nlog\n%s\ns\nexit\n' "$debug_log" |
        script -q -c "$bin" /dev/null >/dev/null 2>&1
    debug_help_output="$(printf 'debug\ntests/repl_debug.pryzma\nhelp\nclear\nc\nexit\n' | script -q -c "$bin" /dev/null 2>&1)"
    if grep -Fq '!! <python code>: Run Python code' <<<"$debug_help_output" &&
       grep -Fq 'clear: Clear the screen' <<<"$debug_help_output" &&
       grep -q $'\033\[2J' <<<"$debug_help_output" &&
       grep -Fq "Log file set to: $debug_log" "$debug_log" &&
       grep -Fq 'User chose to step.' "$debug_log"; then
        printf '[OK] debugger help, clear, and logging\n'
        ((passed+=1))
    else
        printf '[FAIL] debugger help, clear, and logging\n'
        printf '%s\n' "$debug_help_output"
        cat "$debug_log"
        ((failed+=1))
    fi
    rm -f "$debug_log"
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
