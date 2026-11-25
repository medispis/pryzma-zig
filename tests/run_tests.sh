#!/usr/bin/env bash
set -u
bin="${1:-zig-out/bin/pryzma}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
passed=0
failed=0
help_output="$("$bin" -h 2>&1)"
if grep -Fq 'flags:' <<<"$help_output" && grep -Fq -- '-upi unpack and interpret a file' <<<"$help_output"; then
    printf '[OK] CLI standalone help\n'
    ((passed+=1))
else
    printf '[FAIL] CLI standalone help\n'
    printf '%s\n' "$help_output"
    ((failed+=1))
fi
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
rm -f tests/file_write_output.tmp
mkdir_tmp="$(mktemp -d)"
mkdir_target="$mkdir_tmp/created"
mkdir_source="$mkdir_tmp/mkdir.pryzma"
printf 'mkdir("%s")\n' "$mkdir_target" >"$mkdir_source"
mkdir_output="$("$bin" "$mkdir_source" 2>&1)"
if [[ -d "$mkdir_target" && -z "$mkdir_output" ]]; then
    printf '[OK] mkdir statement\n'
    ((passed+=1))
else
    printf '[FAIL] mkdir statement\n'
    printf '%s\n' "$mkdir_output"
    ((failed+=1))
fi
makedirs_target="$mkdir_tmp/nested/path"
makedirs_source="$mkdir_tmp/makedirs.pryzma"
printf 'makedirs("%s")\n' "$makedirs_target" >"$makedirs_source"
makedirs_output="$("$bin" "$makedirs_source" 2>&1)"
if [[ -d "$makedirs_target" && -z "$makedirs_output" ]]; then
    printf '[OK] makedirs statement\n'
    ((passed+=1))
else
    printf '[FAIL] makedirs statement\n'
    printf '%s\n' "$makedirs_output"
    ((failed+=1))
fi
walk_root="$mkdir_tmp/walk-root"
mkdir -p "$walk_root/child"
printf 'root\n' >"$walk_root/root.txt"
printf 'child\n' >"$walk_root/child/child.txt"
walk_program="$mkdir_tmp/walk.pryzma"
printf 'rows = walk("%s")\nprint len(rows)\nprint rows[0][0]\n' "$walk_root" >"$walk_program"
walk_output="$("$bin" "$walk_program" 2>&1)"
if [[ "$walk_output" == "2$walk_root" ]]; then
    printf '[OK] walk expression\n'
    ((passed+=1))
else
    printf '[FAIL] walk expression\n'
    printf '%s\n' "$walk_output"
    ((failed+=1))
fi
rmdir_target="$mkdir_tmp/remove-me"
rmdir_source="$mkdir_tmp/rmdir.pryzma"
printf 'mkdir("%s")\nrmdir("%s")\n' "$rmdir_target" "$rmdir_target" >"$rmdir_source"
rmdir_output="$("$bin" "$rmdir_source" 2>&1)"
if [[ ! -e "$rmdir_target" && -z "$rmdir_output" ]]; then
    printf '[OK] rmdir statement\n'
    ((passed+=1))
else
    printf '[FAIL] rmdir statement\n'
    printf '%s\n' "$rmdir_output"
    ((failed+=1))
fi
removedirs_target="$mkdir_tmp/remove-tree/a/b"
removedirs_source="$mkdir_tmp/removedirs.pryzma"
printf 'makedirs("%s")\nremovedirs("%s")\n' "$removedirs_target" "$removedirs_target" >"$removedirs_source"
removedirs_output="$("$bin" "$removedirs_source" 2>&1)"
if [[ ! -e "$mkdir_tmp/remove-tree" && -d "$mkdir_tmp" && -z "$removedirs_output" ]]; then
    printf '[OK] removedirs statement\n'
    ((passed+=1))
else
    printf '[FAIL] removedirs statement\n'
    printf '%s\n' "$removedirs_output"
    ((failed+=1))
fi
copy_source="$mkdir_tmp/source.txt"
copy_destination="$mkdir_tmp/copy.txt"
copy_program="$mkdir_tmp/copyfile.pryzma"
printf 'copy parity source\n' >"$copy_source"
printf 'copyfile("%s", "%s")\n' "$copy_source" "$copy_destination" >"$copy_program"
copy_output="$("$bin" "$copy_program" 2>&1)"
if [[ -z "$copy_output" && -f "$copy_destination" ]] && cmp -s "$copy_source" "$copy_destination"; then
    printf '[OK] copyfile statement\n'
    ((passed+=1))
else
    printf '[FAIL] copyfile statement\n'
    printf '%s\n' "$copy_output"
    ((failed+=1))
fi
copy_method_destination="$mkdir_tmp/copy-method.txt"
copy_method_program="$mkdir_tmp/copy-method.pryzma"
printf 'copy("%s", "%s")\n' "$copy_source" "$copy_method_destination" >"$copy_method_program"
copy_method_output="$("$bin" "$copy_method_program" 2>&1)"
if [[ -z "$copy_method_output" && -f "$copy_method_destination" ]] && cmp -s "$copy_source" "$copy_method_destination"; then
    printf '[OK] copy statement\n'
    ((passed+=1))
else
    printf '[FAIL] copy statement\n'
    printf '%s\n' "$copy_method_output"
    ((failed+=1))
fi
rename_source="$mkdir_tmp/rename-source.txt"
rename_destination="$mkdir_tmp/rename-destination.txt"
rename_program="$mkdir_tmp/rename.pryzma"
printf 'rename parity source\n' >"$rename_source"
printf 'rename("%s", "%s")\n' "$rename_source" "$rename_destination" >"$rename_program"
rename_output="$("$bin" "$rename_program" 2>&1)"
if [[ -z "$rename_output" && ! -e "$rename_source" && -f "$rename_destination" ]] &&
   grep -Fq 'rename parity source' "$rename_destination"; then
    printf '[OK] rename statement\n'
    ((passed+=1))
else
    printf '[FAIL] rename statement\n'
    printf '%s\n' "$rename_output"
    ((failed+=1))
fi
symlink_target="$mkdir_tmp/symlink-target.txt"
symlink_path="$mkdir_tmp/symlink-path.txt"
symlink_program="$mkdir_tmp/symlink.pryzma"
printf 'symlink parity target\n' >"$symlink_target"
printf 'symlink("%s", "%s")\nprint is_link("%s")\nprint read_link("%s")\n' \
    "$symlink_target" "$symlink_path" "$symlink_path" "$symlink_path" >"$symlink_program"
symlink_output="$("$bin" "$symlink_program" 2>&1)"
if [[ "$symlink_output" == "True$symlink_target" && -L "$symlink_path" ]] &&
   cmp -s "$symlink_target" "$symlink_path"; then
    printf '[OK] symlink statement\n'
    ((passed+=1))
else
    printf '[FAIL] symlink statement\n'
    printf '%s\n' "$symlink_output"
    ((failed+=1))
fi
unlink_target="$mkdir_tmp/unlink-me.txt"
unlink_program="$mkdir_tmp/unlink.pryzma"
printf 'unlink parity\n' >"$unlink_target"
printf 'unlink("%s")\n' "$unlink_target" >"$unlink_program"
unlink_output="$("$bin" "$unlink_program" 2>&1)"
if [[ -z "$unlink_output" && ! -e "$unlink_target" ]]; then
    printf '[OK] unlink statement\n'
    ((passed+=1))
else
    printf '[FAIL] unlink statement\n'
    printf '%s\n' "$unlink_output"
    ((failed+=1))
fi
rm -rf "$mkdir_tmp"
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
    if_debug_output="$(printf 'debug\ntests/debug_if.pryzma\ns\ns\ns\nexit\n' | script -q -c "$bin" /dev/null 2>&1)"
    if grep -Fq 'Debug: Executing line 1: if(1==1)' <<<"$if_debug_output" &&
       grep -Fq 'Debug: Executing line 1: print "inside branch"' <<<"$if_debug_output" &&
       ! grep -Fq 'Debug: Executing line 0:' <<<"$if_debug_output" &&
       grep -Fq 'Debug: Executing line 2: print "after branch"' <<<"$if_debug_output"; then
        printf '[OK] debugger if-branch stepping and line mapping\n'
        ((passed+=1))
    else
        printf '[FAIL] debugger if-branch stepping and line mapping\n'
        printf '%s\n' "$if_debug_output"
        ((failed+=1))
    fi
    for_debug_output="$(printf 'debug\ntests/debug_for.pryzma\ns\ns\ns\ns\nexit\n' | script -q -c "$bin" /dev/null 2>&1)"
    loop_steps="$(grep -Fc 'Debug: Executing line 2: print i' <<<"$for_debug_output" || true)"
    if [[ "$loop_steps" == 2 ]] &&
       grep -Fq 'Debug: Executing line 4: print "after loop"' <<<"$for_debug_output" &&
       grep -Fq 'after loop' <<<"$for_debug_output"; then
        printf '[OK] debugger for-loop iteration stepping\n'
        ((passed+=1))
    else
        printf '[FAIL] debugger for-loop iteration stepping\n'
        printf '%s\n' "$for_debug_output"
        ((failed+=1))
    fi
    for_continue_output="$(printf 'debug\ntests/debug_for_continue.pryzma\nc\ns\nc\ns\ns\ns\nexit\n' | script -q -c "$bin" /dev/null 2>&1)"
    loop_value_steps="$(grep -Fc 'Debug: Executing line 2: print i' <<<"$for_continue_output" || true)"
    loop_tail_steps="$(grep -Fc 'Debug: Executing line 3: print "tail"' <<<"$for_continue_output" || true)"
    if [[ "$loop_value_steps" == 2 && "$loop_tail_steps" == 2 ]] &&
       [[ "$(grep -Fc 'debug> tail' <<<"$for_continue_output" || true)" == 2 ]] &&
       grep -Fq 'after loop' <<<"$for_continue_output"; then
        printf '[OK] debugger continue resumes at next loop iteration\n'
        ((passed+=1))
    else
        printf '[FAIL] debugger continue resumes at next loop iteration\n'
        printf '%s\n' "$for_continue_output"
        ((failed+=1))
    fi
    foreach_output="$(printf 'debug\ntests/debug_foreach.pryzma\ns\nc\ns\nc\ns\ns\ns\nexit\n' | script -q -c "$bin" /dev/null 2>&1)"
    foreach_values="$(grep -Fc 'Debug: Executing line 3: print item' <<<"$foreach_output" || true)"
    foreach_tails="$(grep -Fc 'Debug: Executing line 4: print "tail"' <<<"$foreach_output" || true)"
    if [[ "$foreach_values" == 2 && "$foreach_tails" == 2 ]] &&
       [[ "$(grep -Fc 'debug> tail' <<<"$foreach_output" || true)" == 2 ]] &&
       grep -Fq 'after foreach' <<<"$foreach_output"; then
        printf '[OK] debugger foreach iteration stepping and continue\n'
        ((passed+=1))
    else
        printf '[FAIL] debugger foreach iteration stepping and continue\n'
        printf '%s\n' "$foreach_output"
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
