# Pryzma in Zig — Implementation Plan

## 1. Goal

Rewrite the Pryzma programming language interpreter in Zig.

The reference implementation is the Python project at:

```
/home/medispis/clones/Pryzma-programming-language
```

The reference interpreter is `Pryzma.py` (4,600 lines), with documentation in `doc.txt`
and a 31-test corpus in `tests/`.

The new implementation lives in:

```
/home/medispis/projects/vibe/pryzma-zig
```

## 2. Locked decisions

| Area | Decision |
| --- | --- |
| Deliverable | Interpreter + CLI. `Pryzmac.py` (toy C transpiler) is out of scope. |
| Core implementation | Native Zig: preprocessor, values, parser, evaluator, statements, environment, builtins. |
| Python interoperability | Embed CPython 3.14 via `libpython3.14`. |
| CPython use | Only for compatibility layers: `pyeval`, `pyexec`, `py{}`, `pyextern`, `call`, `load`, plus `re`, `lzma`, `ctypes`, `json`, `datetime`, `requests`. |
| Fidelity | Bug-for-bug on the 31-test corpus: output, error text, line numbers, Python-style `repr`, dynamic locals, global `args`. |
| Inline asm | Default emulator plus a native x86-64 JIT selected by `#asm_native`. |
| Platform | Linux x86-64 only. |
| Zig version | 0.17.1 (installed). |
| CLI parity | Full: file mode, flags, REPL, debugger, ppm, HTTP imports, `-pk`/`-upk`. |
| Regex | CPython `re`. |
| FFI | CPython `ctypes`. |
| Packing | CPython `lzma`, same preset and `prz` prefix. |
| Dependencies | No new libraries beyond libc and libpython3.14. |
| Git | Target directory is not a git repository. Do not initialize one without approval. |

## 3. Reference inventory

### 3.1 Statements handled by `interpret()`

Dispatch order matters because the original uses `line.startswith(...)`.
Port the order exactly.

1. `print`
2. `input`
3. `#preproc`, `#insert`, `#shell`, other pragmas
4. `{a, b} = instance` struct destructuring
5. `struct Name { ... }`
6. `foreach(var, list){ ... }`
7. `for(var, start:end){ ... }`
8. `if(cond){...}elif(cond){...}else{...}`
9. `while(cond){...}`
10. `/name{ ... }` function definition
11. `@name(args)` function call
12. `pyeval(...)`
13. `pyexec(...)`
14. `exec(...)`
15. `eval(...)`
16. `isolate(...)`
17. `try{...}catch(code){...}`
18. `int name [= expr]`
19. `str name [= expr]`
20. `loc name = expr`
21. `assert condition, message`
22. `target = expr` (multiple targets, indexes, fields, dereference)
23. `target += expr`
24. `target -= expr`
25. `use path [as alias] [with #pragma]`
26. `from path use func[, func] [with #pragma]`
27. `copy list_a, list_b`
28. `append list, value`
29. `pop list, index`
30. `remove list, value`
31. `sys("command")`
32. `file_write(path, mode, content)`
33. `delvar(name)`
34. `delfunc(name)`
35. `disablekeyword(k1, k2, ...)`
36. `enablekeyword(k1, k2, ...)`
37. `name++` / `++name`
38. `name--` / `--name`
39. `move(old, new, list)`
40. `swap(i, j, list)`
41. `call(file, function, args...)`
42. `ccall(file, function, args...)`
43. `load(path)`
44. `wait(seconds)`
45. `push(dict, key, value)`
46. `dpop(dict, key)`
47. `defer{ ... }`
48. `return expr`
49. `break`
50. `asm{ ... }`
51. `py{ ... }`
52. `mkdir`, `makedirs`, `rmdir`, `removedirs`
53. `copy(src, dst)`, `copyfile(src, dst)`, `move(src, dst)`, `rename(src, dst)`
54. `remove_path(path)`, `symlink(src, dst)`, `unlink(path)`
55. `match(value){ case(x){...} case(_){...} }`
56. `write(address, byte)`
57. `patch(func_a, func_b)`
58. `json_dump(value[, path])`
59. `using [global] instance`
60. `object.@method(args)`
61. `extern "library" {symbol|symbol}` or `extern "library" *`
62. `pyextern "module" {function [as alias]}` or `pyextern "module" *`
63. `stop`

### 3.2 Expressions handled by `evaluate_expression()`

The original checks special prefixes in a fixed order, then falls back to Python
`eval()`. Port the order for observable compatibility.

1. Integer literal
2. `read(address)`
3. `/lambda{...}`
4. `pyeval(...)`
5. `pyexec(...)`
6. `exec(...)`
7. `eval(...)`
8. `new_isolate(...)`
9. `isolate(...)`
10. `replace(value, old, new)`
11. `json_dump(...)`
12. `json_load(...)`
13. Struct construction `Name { ... }`
14. Custom `+` handling
15. String literal
16. `resplit(pattern, string)`
17. `in(list, value)`
18. `splitby(separator, string[, maxsplit])`
19. `type(value)`
20. `len(value)`
21. `splitlines(string)`
22. `file_read(path)`
23. `index(list, value)`
24. `all(list)`
25. `isanumber(value)`
26. `dirname(path)`
27. `timenow`
28. `startswith(prefix, string)`
29. `endswith(suffix, string)`
30. `randint(low, high)`
31. `strip(string)`
32. `get(dict, key)`
33. `@function(args)`
34. `char(code)`
35. `join(separator, list)`
36. `addr(reference)`
37. `defined(name)`
38. `is_file`, `is_dir`, `exists`, `file_size`
39. `join_path`, `abs_path`, `basename`, `split_ext`, `list_dir`, `walk`, `is_link`, `read_link`
40. `call(...)`, `ccall(...)`
41. Field access `object.field`
42. `&target`
43. `*reference`
44. `fields(instance)`
45. `is_func(value)`
46. `ascii(character)`
47. `~expression`
48. Comparisons `==`, `!=`, `<=`, `>=`, `<`, `>`
49. `pop list`
50. Variable/local lookup
51. Python `eval()` fallback

### 3.3 Test corpus

All 31 tests must pass.

```
asm
decrement_and_increment
defer
fib
for_test
func_ref
func_test
hello
if_test
index_test
json
libc_malloc
lists_test
locals
manual_memory
manual_memory_raw
match
mem
methods
pryzma
pyextern
ref_deref
replace_test
resplit_test
rule110
selection_sort
sort
struct
try_catch
using
while_test
```

Current Python baseline: 30 pass, `asm` fails because keystone is not installed.
The Zig implementation must pass `asm` using the emulator/JIT.

## 4. Compatibility contract

### 4.1 Output

- `print` evaluates comma-separated arguments at top level, concatenates them with
  no separator, and emits no trailing newline.
- Top-level strings print raw. `\n` inside a string is converted to a newline.
- Lists, dicts, and tuples use Python `repr` formatting:
  - `[1, 2, 3, 'text']`
  - `{'name': 'Alice', 'age': 30}`
  - `(1, 2)`
- Booleans print `True` / `False`.
- `None` prints `None`.
- Inside a `try` block, `None` parts are suppressed.
- Errors print exactly like the Python version, including `Error at line N: ...`.

### 4.2 Errors

- `err` is a global integer, initially `0`.
- Outside `try`, an error prints a message, sets `err`, and optionally exits when
  `#fail` is active.
- Inside `try`, the message is suppressed and only `err` is set.
- `catch(code)` runs only when `err == code`.
- If an error occurs inside a function, print
  `Error while calling function '<name>'` first.
- Unexpected exceptions are reported as error code `12` with the exception text.

### 4.3 Line numbers

Port `lines_map` exactly.

The preprocessor records `(source_line_text, source_line_number)` for every source
line. When a statement is interpreted, find the first map entry whose stripped text
is a prefix of the statement, set `current_line = number + 1`, and remove the entry
unless inside a loop.

This is quirky, but expected outputs such as `locals.expected` depend on it.

### 4.4 Python quirks to preserve

- The global `args` list is not saved or restored around nested calls.
- `for` and `foreach` leave their loop variable defined.
- Struct defaults are evaluated when the struct is defined and shared between
  instances.
- Dict assignment makes a shallow copy; list assignment shares the list.
- Local lookup searches all active function frames from innermost to outermost.
- The local garbage collector removes locals that are not referenced and whose
  function id is no longer active.
- `isanumber` uses Python `str.isnumeric()`, so `"1.5"` is not a number.
- `is_func("name")` returns true when a function with that name exists.
- `startswith(prefix, string)` and `endswith(suffix, string)` use reversed argument
  order compared with Python.
- `splitby(separator, string)` uses reversed argument order.
- `in(list, value)` checks whether `value` is in `list`.
- `replace` converts the literal strings `"\\n"` to newlines.
- `json_dump(value)` prints when no path is given; `json_dump(value, path)` writes.
- `pyeval` can see the interpreter through a `self.variables` proxy.
- `pyexec` and `py{}` write changes back into Pryzma variables.
- Manual memory supports booleans, signed 64-bit integers, doubles, and byte
  buffers. Pryzma strings are not managed by `#mm`.
- Inline asm captures only integer globals (booleans count as integers).

### 4.5 Intentional divergences

These are documented and will not be treated as regressions:

- `endswith` works instead of raising the Python typo error (`endsswith`).
- `copy(src, dst)` and `move(src, dst)` file operations are reachable. List forms
  `copy a, b` and `move(i, j, list)` remain unchanged.
- `join_path` is implemented correctly.
- Integers are `i64`; Python arbitrary-precision integers are not replicated.
- Heap values are not reclaimed during process lifetime. Local GC is ported, but
  container cycles and long REPL sessions can grow memory.
- Native string literals are raw. The CPython fallback uses Python escape rules.
- `pyeval`/`pyexec`/`py{}`/`pyextern`/`call`/`load` require libpython at runtime.

## 5. Architecture and file layout

```
pryzma-zig/
  build.zig
  build.zig.zon
  PLAN.md
  README.md
  doc.txt
  license.txt
  src/
    main.zig
    interp.zig
    preproc.zig
    value.zig
    expr.zig
    env.zig
    builtins.zig
    py.zig
    ffi.zig
    asm.zig
    debugger.zig
    ppm.zig
    json.zig
    fsops.zig
    tests.zig
  tests/
    *.pryzma
    *.expected
    pyextern_helper.py
    raw_helper.py
    run_tests.sh
  pryzma.pryzma
```

### 5.1 `main.zig`

- Parse command-line arguments.
- Dispatch file mode, stdin mode, and REPL.
- Handle `-h`, `-d`, `-p`, `-np`, `-l`, `-fd`, `-pk`, `-upk`, `-upi`.
- Initialize and finalize CPython.
- Set `argv`, `__file__`, `interpreter_path`.
- Implement REPL commands.

### 5.2 `interp.zig`

- `Interpreter` state.
- `interpret_file`, `pre_interpret`, `interpret`.
- Statement dispatch.
- Function calls, defers, break stack, try/catch, match, using, structs.
- Error handling.
- `exec`/`eval`/`isolate`.
- Manual memory toggles.
- Keyword deletion.
- Forward declaration.

### 5.3 `preproc.zig`

- `split_on_comment`.
- `preprocess`.
- `lines_map`.
- `process_args`.
- `#replace`, `#insert`.
- Struct field splitting.
- Top-level splitting helpers for `,`, `|`, `;` with string/brace awareness.

### 5.4 `value.zig`

- `Value` tagged union.
- Constructors and ownership helpers.
- Truthiness.
- Equality.
- Python-compatible `str`/`repr`.
- Numeric promotion and arithmetic.
- Conversion to and from `PyObject`.

### 5.5 `expr.zig`

- Lexer.
- Pratt parser.
- AST types.
- Evaluator.
- Special-form dispatch matching the original prefix order.
- CPython fallback for pure unsupported expressions.

### 5.6 `env.zig`

- Global variable map.
- Local stacks.
- Function table.
- Struct table.
- References and function references.
- Function tracker/id stacks.
- Local GC.
- Manual-memory pointer storage.

### 5.7 `builtins.zig`

- Native builtins listed in section 3.2.
- String, list, dict, tuple, type, and conversion helpers.
- Memory `read`/`write`.
- `patch`, `delvar`, `delfunc`, keyword toggles.
- `wait`, `randint`, `timenow`.

### 5.8 `py.zig`

- CPython initialization.
- GIL helpers.
- Value ↔ `PyObject` conversion.
- Embedded Python helper module.
- `pyeval`, `pyexec`, `py{}`.
- `pyextern`, `call`, `load`.
- `re`, `lzma`, `json`, `datetime` wrappers.

### 5.9 `ffi.zig`

- `extern` and `ccall` via `ctypes`.
- Default signatures for `malloc`, `calloc`, `realloc`, `free`, `memcpy`,
  `memmove`, `memset`.
- Wildcard library registration and lazy symbol resolution.
- Manual memory slots via libc `malloc`/`free`.

### 5.10 `asm.zig`

- Parse asm lines.
- Resolve variable operands to addresses.
- Emulator backend.
- x86-64 encoder for the documented subset.
- RWX mmap execution.
- Sync integer values back.

### 5.11 `debugger.zig`

- Step/continue.
- Breakpoints.
- Inspect variables, functions, structs.
- Execute Pryzma/Python snippets.
- Logging.
- Debug variants of `if`, `for`, `foreach`, `while`, and function calls.

### 5.12 `ppm.zig`

- `remove`, `list`, `from`, `install`, `update`, `show`, `help`, `exit`, `clear`.
- Primary package server.
- GitHub fallback.
- `metadata.json` display.

### 5.13 `json.zig`, `fsops.zig`

- Python-compatible JSON dump/load.
- File and directory operations used by statements and expressions.

## 6. Value model

```zig
const Value = union(enum) {
    none,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    list: *List,
    dict: *Dict,
    tuple: *Tuple,
    reference: Reference,
    func_ref: []const u8,
    extern_fn: *ExternFn,
    py_object: *py.PyObject,
    lazy: *Lazy,
    isolate: *Interpreter,
    timestamp: i64,
    duration: i64,
};
```

Rules:

- Lists and dicts are heap pointers. Assignment aliases them, matching Python.
- Dict assignment makes a shallow copy, matching `value.copy()` in the Python code.
- Dicts preserve insertion order.
- Struct instances are dicts with an optional type name.
- `reference` stores a variable name and an optional manual-memory address.
- `func_ref` stores a function name.
- `extern_fn` wraps a `ctypes` callable or a resolved C symbol.
- `py_object` wraps arbitrary Python values returned by interop.
- `lazy` stores expression text and is re-evaluated on every read.
- Strings are immutable and allocated from the interpreter allocator.
- `timestamp` and `duration` back `timenow` and subtraction results. If exact
  `datetime`/`timedelta` behavior is needed, use `py_object` instead.

### 6.1 `repr` rules

- `none` → `None`
- `bool` → `True` / `False`
- `int` → decimal
- `float` → Python float formatting
- `string` → single-quoted with Python escaping when nested
- `list` → `[item, item]`
- `dict` → `{key: value, key: value}`
- `tuple` → `(item, item)` and `(item,)` for one element
- `py_object` → `PyObject_Repr` or `PyObject_Str`

## 7. Interpreter state

Port these fields directly from `PryzmaInterpreter`:

```
variables
functions
structs
locals
custom_handlers
deleted_keywords
err
in_try_block
in_func
function_tracker
function_ids
current_func_name
preprocess_only
no_preproc
forward_declare
nan
return_stops
return_val / ret_val
break_stack
main_file
mem (4096 bytes)
fail
unpack_
lines_map
lines_map_done
defer_stack
escape
in_loop
debug
gc
manual_memory_manager
manual_memory_enabled
c_extern_wildcards
asm_backend
file_path
current_line
```

`args` is a global variable, overwritten by each call. Do not save/restore it.

## 8. Preprocessor

### 8.1 Comment stripping

Scan characters, track double-quote strings and backslash escapes. Outside strings,
`//` starts a comment and truncates the line.

### 8.2 Line assembly

1. Split source into lines.
2. Strip comments.
3. Record each line in `lines_map` if not already done.
4. Detect `#np` / `#preproc` with `np`.
5. Toggle `in_str` for each `"`; append `;` to lines that do not end inside a string.
6. Join all lines.
7. Unless `no_preproc`, replace `;` with `|` when inside braces and outside strings.
8. Split on `;` when outside strings.
9. Trim and drop empty statements.

### 8.3 Splitting helpers

Implement depth-aware splitters:

- `split_top_level(text, separator)` tracking `"`, `\`, `{`, `}`, `[`, `]`, `(`.
- `split_args(text)` for comma-separated arguments.
- `split_body(text)` for `|`-separated block bodies.

The original uses placeholder characters and regex; the result must match.

### 8.4 Pragmas

`#preproc = a,b,c` and individual pragmas:

```
fd, np, nan, an, rs, rds, esc, desc, fail, df, gc, ngc
asm_native, anat, asm_emu, asm_emulator, aemu
mm, mmraw, amm
```

`#replace a -> b` uses Python `re.sub` on every line.

`#insert "file"` reads and interprets another file, including packed `.prz`.

`#shell` opens the REPL during execution.

## 9. Statement semantics

### 9.1 Assignment

Parse the left side as:

```
[*] base [.field | [index]]...
```

- Evaluate the right side once per target.
- If the value is a dict, copy it.
- Dereference a leading `*`:
  - manual-memory address: write the slot;
  - otherwise use the reference's variable name.
- Resolve the base:
  - local first when the name is in `locals`;
  - otherwise global.
- Walk intermediate fields/indexes.
- Assign the final field/index, or rebind the base.

Multiple targets are split on commas at top level.

### 9.2 Increment / decrement

`+=` and `-=` use the same lvalue resolution. `++` and `--` remove all occurrences
of the operator and add/subtract `1`.

### 9.3 Functions

- Definition: `/name{body}` stores the body split into top-level `|` statements.
- Call: `@name(args)`:
  - evaluate arguments;
  - set global `args`;
  - resolve `FuncReference` indirection;
  - resolve wildcard extern functions;
  - invoke extern/pyextern callables;
  - otherwise execute the stored body;
  - push/pop `in_func`, `function_tracker`, `function_ids`;
  - run defers in LIFO order;
  - run local GC unless `escape` is set.
- `return` sets `ret_val`. With `#rs`, it stops the function body immediately.

### 9.4 Defers

Keyed by `(function_name, function_id)`. Deferred bodies are split on `|` and run
LIFO when the function exits.

### 9.5 Locals

- `loc name = expr` appends `(value, function_name, function_id)` to the local
  stack for `name`.
- Reading searches active frames from innermost to outermost.
- The local GC runs at the start of each statement when enabled.
- At function exit, entries for that function id are removed unless `#esc`.

### 9.6 Try / catch

- Split the body on top-level `|`.
- Interpret each instruction.
- Track the last non-zero `err`.
- If `catch(code)` matches, run its instructions.
- `in_try_block` suppresses error printing.

### 9.7 Match

- Parse `case(value){body}` entries.
- Evaluate each case value; `_` is the default.
- Run the first matching case; otherwise the default.

### 9.8 Structs

- Definition fields are split on `,` or `|` at depth 0.
- Fields without `=` default to `None`.
- Fields with `=` are evaluated immediately, except text starting with `@`, which
  is stored as a string.
- Construction supports positional values, `name=value` pairs, and nested struct
  literals separated by `|` or `,`.
- Missing fields use the stored default.
- Destructuring `{a, b} = instance` assigns fields in insertion order.
- `using` exports fields locally or globally.

### 9.9 Methods

`obj.@method(args)` rewrites to `@method(obj, args)` and interprets that.

## 10. Expression engine

### 10.1 Lexer

Tokens:

```
int, float, string, identifier
( ) [ ] { } , : . 
+ - * / // % **
== != < <= > >=
& | ^ ~ << >>
= 
@
```

Keywords: `if`, `else`, `and`, `or`, `not`, `in`, `is`, `True`, `False`, `None`.

String literals are raw; support escaped quotes and backslashes for parsing.

### 10.2 Pratt parser

Precedence, lowest to highest:

1. Ternary `a if condition else b`
2. `or`
3. `and`
4. `not`
5. Comparisons (`== != < <= > >= in not in is is not`)
6. Bitwise `|`
7. Bitwise `^`
8. Bitwise `&`
9. Shifts `<< >>`
10. `+ -`
11. `* / // %`
12. Unary `+ - ~`
13. `**` (right associative)
14. Postfix: call, index/slice, attribute

### 10.3 Postfix and containers

- Index: `obj[index]`.
- Slice: `obj[start:stop]`, `obj[start:stop:step]`.
- Attribute: `obj.field`.
- Calls: `name(args)`, used for native builtins.
- List: `[a, b]`.
- Dict: `{key: value}`.
- Tuple: `(a, b)`, `()`.
- Repetition: `[0] * 30`, `"ab" * 3`.

### 10.4 Special forms

Implement before general parsing, in the original order:

- `read(...)`, `/lambda`, `pyeval`, `pyexec`, `exec`, `eval`, `new_isolate`,
  `isolate`, `replace`, `json_dump`, `json_load`, struct construction.
- Custom `+` with `add_or_str` and `add_or_index` rules.
- String literal.
- `resplit`, `in`, `splitby`, `type`, `len`, `splitlines`, `file_read`, `index`,
  `all`, `isanumber`, `dirname`, `timenow`, `startswith`, `endswith`, `randint`,
  `strip`, `get`.
- `@call`, `char`, `join`, `addr`, `defined`, filesystem predicates,
  `call`/`ccall`, field access, `&`, `*`, `fields`, `is_func`, `ascii`, `~`.
- Comparisons.
- `pop list`.
- Variable/local lookup.
- CPython fallback.

### 10.5 Native builtins

Implement in Zig:

```
len, type, int, str, float, bool, list, tuple, dict
char, ascii, strip, join, splitby, replace, startswith, endswith
in, index, all, isanumber, defined, is_func, fields
addr, read, write
pop
```

Delegate to CPython:

```
pyeval, pyexec, exec, eval, isolate, new_isolate
resplit, json_dump, json_load
file_read, file_write
extern, ccall, call, pyextern, load
timenow, wait, randint (random values need not match Python)
```

### 10.6 CPython fallback

When the native parser fails on a pure expression:

1. Build a Python dict from current globals and locals.
2. Add a `self` object whose `variables` attribute is that dict.
3. Evaluate with `Py_eval_input`.
4. Convert the result back to `Value`.

Reject expressions containing side effects (`@`, `&`, `*` dereference, assignment,
function definitions).

## 11. CPython embedding

### 11.1 Initialization

- `Py_InitializeEx(0)`.
- Add the working directory and script directory to `sys.path`.
- Compile and execute an embedded helper module.
- Use `PyGILState_Ensure` / `PyGILState_Release` around API calls.
- Finalize on clean exit, but tolerate `exit()` paths.

### 11.2 Helper module

Embedded Python source provides:

```python
load_module(ref, base_dir)
resolve_attr(module, dotted_path)
public_callables(module)
call_file(path, function, *args)
c_load(path)
c_get(lib, name)
configure_c_function(callable, name)
re_split(pattern, string, maxsplit)
re_sub(pattern, replacement, string)
json_dumps(value)
json_loads(string)
lzma_compress(text)
lzma_decompress(data)
http_get(url)
```

This keeps C API code small and matches the original's use of `importlib`,
`ctypes`, `re`, `json`, `lzma`, and `requests`.

### 11.3 `pyeval`

- One argument: evaluate with a globals dict containing converted variables and
  `self`.
- Two arguments: use the supplied stack/dict as globals/locals.
- Return converted value.

### 11.4 `pyexec` and `py{}`

- Execute against a dict built from variables.
- Copy new/changed keys back to globals.
- Ignore `__builtins__` and `self`.

### 11.5 `pyextern`, `call`, `load`

- Resolve `.py` paths relative to the current Pryzma file and to the working
  directory.
- Resolve module names with `importlib.import_module`.
- Support nested attributes, aliases, and `*`.
- Store callables as `extern_fn` / `py_object`.
- `load` stores the module's `start` function as a custom line handler.

### 11.6 `extern` and `ccall`

- Load shared libraries with `ctypes.CDLL`.
- Apply default signatures for common libc functions.
- Store callables.
- Wildcard libraries resolve symbols lazily on first call.
- Convert native arguments to Python values; addresses are integers.

## 12. Manual memory

- Enable with `#mm` / `#mmraw`; disable with `#amm`.
- Use libc `malloc`/`free`.
- Slot metadata: type, capacity, length.
- Supported types: bool (`u8`), int (`i64`), float (`f64`), bytes.
- Pryzma strings are not supported and fall back to normal storage.
- `&var` captures the slot address; `*ptr` reads/writes it.
- Enabling moves existing eligible globals into slots.
- Disabling reads values back and frees slots.
- `addr(ptr)` returns the integer address.

## 13. Inline asm

### 13.1 Input

`asm{ "mov rax, a" "add rax, b" "mov c, rax" }`

The preprocessor turns newlines into `|`. Each line is evaluated as a string.

### 13.2 Variable resolution

- Allocate one 8-byte slot per integer global (booleans count).
- Replace variable operands with address loads/stores, matching the Python
  `_resolve_inline_asm_vars` logic.
- After execution, write slots back to globals.

### 13.3 Emulator

Interpret the parsed instructions directly:

```
mov reg, reg|imm|[r11]
mov [r11], reg
add/sub/imul/and/or/xor reg, reg|imm|[r11]
push/pop/ret
```

64-bit registers only.

### 13.4 Native JIT

- Encode the same subset to x86-64 machine code.
- `mmap` with `PROT_READ | PROT_WRITE | PROT_EXEC`.
- Call through a C function pointer.
- `munmap` after execution.
- On encoding or mmap failure, print an asm error and return.

### 13.5 Backend selection

- Default `emu`.
- `#asm_native` / `#anat` selects native.
- `#asm_emu` / `#aemu` selects emulator.

## 14. CLI and REPL

### 14.1 File mode

```
pryzma file.pryzma [args...]
```

- `argv` contains the file path plus arguments, as in the Python version.
- `__file__` is the absolute file path.
- `interpreter_path` is the executable path.

Flags:

```
-h    help
-d    debugger
-p    preprocess only
-np   no preprocessing
-l    execute a single line
-fd   forward declare functions
-pk   pack to stdout
-upk  unpack to stdout
-upi  unpack and interpret
```

### 14.2 stdin mode

If stdin is not a TTY, read all input and interpret it.

### 14.3 REPL

Banner:

```
Pryzma 6.2
To show the license type "license" or "help" to get help.
```

Prompt: `/// `

Commands:

```
file, cls, clear, debug, history, info, ppm, errors, exit, reboot,
v, f, s, l, help, license
```

History supports list, index, clear, and search.

## 15. Debugger

Port `Debuger`:

- Load and preprocess a file.
- Print `Debug: Executing line N: ...`.
- Commands: `s`, `c`, `b N`, `r N`, `l`, `v`, `f`, `st`, `! code`, `!! python`,
  `log`, `exit`, `help`, `clear`.
- Custom debug handlers for `if`, `for`, `foreach`, `while`, and `@function`.
- Breakpoints.
- Optional log file.

## 16. Package manager and HTTP imports

### 16.1 ppm

Commands:

```
remove <name>
list [avaliable] [url]
from <url> <name...>
install <name...>
update [name...]
show [name...]
help
exit
clear
```

Paths:

- Packages live under `<executable-dir>/packages/`.
- Primary API: `http://pryzma.dzordz.pl/download`.
- Package list: `http://pryzma.dzordz.pl/api/fetch`.
- GitHub fallback: `https://github.com/IgorCielniak/Pryzma-packages`.

Use the CPython helper (`requests`, `zipfile`, `shutil`) for exact behavior.

### 16.2 HTTP imports

`use https://...` fetches source text, preprocesses it, applies automatic
namespacing, and interprets it. Use the CPython helper for requests.

## 17. Build system

### 17.1 `build.zig`

- Zig 0.17.1.
- Executable `pryzma`.
- Link libc.
- Link `python3.14`.
- Add Python include path from `python3-config --embed --cflags` or `sysconfig`.
- Install to `zig-out/bin/pryzma`.
- `test` step runs `tests/run_tests.sh` with the built binary.

### 17.2 Zig 0.17 notes

The installed toolchain uses the new I/O API:

- `std.Io.Threaded.global_single_threaded.io()`
- `std.Io.File.stdout().writeStreamingAll(io, bytes)`
- `std.heap.DebugAllocator`
- `std.process.Init.Minimal` for argv
- `std.Io.Dir.cwd().readFileAlloc(io, ...)`
- `std.compress.xz` for XZ decompression
- `std.http.Client`, `std.zip`, `std.DynLib`

Verify each API during the scaffold phase.

### 17.3 Test runner

`tests/run_tests.sh`:

1. Iterate `tests/*.pryzma`.
2. Run the binary.
3. Compare trimmed stdout with `tests/<name>.expected`.
4. Print pass/fail with color.
5. Exit non-zero on failure.

Run from the repository root so relative paths and `tests/test.json` work.

## 18. Test strategy

### 18.1 Integration tests

All 31 corpus tests, including:

- `asm` via emulator/JIT
- `sort` via `pyeval`
- `pyextern` via embedded CPython
- `manual_memory_raw` via `pyextern`
- `libc_malloc` via `extern` + `pyextern`
- `pryzma` self-hosted interpreter

### 18.2 Unit tests

- Value `repr` and truthiness.
- Parser precedence and associativity.
- Preprocessor splitting and line map.
- Top-level argument splitting.
- Struct construction and destructuring.
- Reference and local resolution.
- Manual memory roundtrip.
- Asm encoding for the documented instructions.
- CPython conversion roundtrips.

### 18.3 Manual checks

- REPL commands.
- Debugger step/continue/breakpoints.
- ppm list/install/remove with a local test server.
- HTTP import.
- `-pk` / `-upk` roundtrip.
- stdin mode.

## 19. Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Python `eval()` fallback semantics are broad. | Native parser covers documented syntax; CPython fallback for pure expressions. |
| CPython embedding lifecycle and GIL. | Single-threaded; `PyGILState_Ensure/Release`; init once; finalize at exit. |
| Value conversion across the boundary. | Recursive converters with tests for every supported type. |
| Native JIT encoding/ABI. | Small instruction subset; emulator is the default; test `asm.pryzma`. |
| Line-number quirks. | Port `lines_map` literally. |
| Dynamic locals and `args` quirks. | Port the algorithms; tests `locals`, `ref_deref`, `pryzma` cover them. |
| Memory growth. | Document. Local GC is ported. Add reclamation later if needed. |
| libpython version dependency. | Resolve paths at build time; document 3.14 requirement. |
| Platform-specific JIT. | Linux x86-64 only. |
| Undocumented Python bugs. | Preserve corpus behavior; document intentional fixes. |

## 20. Delivery phases

### Phase 0 — Scaffold

- `build.zig`, `build.zig.zon`.
- CPython init/finalize.
- CLI skeleton.
- `Value` and `repr`.
- Test runner.

Exit: `pryzma tests/hello.pryzma` prints `hello`.

### Phase 1 — Preprocessor and core statements

- Comments, line assembly, splitting, line map.
- `print`, `input`, `int`, `str`, `loc`.
- Assignment, `+=`, `-=`, `++`, `--`.
- `if`, `while`, `for`, `foreach`.
- Functions, `@call`, `return`, `break`.

Exit: hello, fib, for_test, while_test, if_test, func_test, func_ref,
decrement_and_increment, lists_test pass.

### Phase 2 — Expressions and data

- Lexer, Pratt parser, evaluator.
- Lists, dicts, tuples, indexing, slicing, attributes.
- Structs, construction, destructuring, `using`, `match`.
- JSON, replace, resplit.

Exit: index_test, struct, match, using, json, replace_test, resplit_test pass.

### Phase 3 — Memory and control

- References, dereference, locals, local GC.
- Defer, try/catch, methods.
- Lambdas, lazy expressions.
- `exec`, `eval`, `isolate`, `patch`.
- Memory `read`/`write`.
- Manual memory.

Exit: ref_deref, methods, defer, try_catch, mem, manual_memory,
manual_memory_raw, locals pass.

### Phase 4 — CPython interop

- `pyeval`, `pyexec`, `py{}`.
- `pyextern`, `call`, `load`.
- `extern`, `ccall`.
- Regex, pack, JSON, time via CPython.

Exit: sort, pyextern, libc_malloc, pryzma self-host pass.

### Phase 5 — Inline asm

- Parser, emulator, native JIT.
- Backend pragmas.

Exit: asm passes.

### Phase 6 — Full CLI parity

- All flags.
- REPL and history.
- Debugger.
- ppm.
- HTTP imports.
- `#shell`.
- Pack/unpack.

Exit: manual checks pass.

### Phase 7 — Final verification

- `zig fmt`.
- `zig build`.
- `zig build test`.
- Review diffs and docs.
- Update `README.md` and `doc.txt`.
- Report remaining divergences.

No commit unless the directory becomes a git repository and the user asks.

## 21. Open assumptions

- `libpython3.14` development headers remain installed at `/usr/include/python3.14`.
- The embedded interpreter uses the system site-packages, so `requests` is
  available for ppm and HTTP imports.
- Tests run from the repository root.
- The target directory is intentionally empty; no existing user work is
  overwritten.
- The reference Python repository is read-only and must not be modified.
