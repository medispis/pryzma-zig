const std = @import("std");
const Allocator = std.mem.Allocator;
const value = @import("value.zig");
const py_mod = @import("py.zig");
const Value = value.Value;
const List = value.List;
const Dict = value.Dict;
extern "c" fn rand() c_int;
extern "c" fn malloc(usize) ?*anyopaque;
extern "c" fn free(?*anyopaque) void;
extern "c" fn mmap(?*anyopaque, usize, c_int, c_int, c_int, i64) ?*anyopaque;
extern "c" fn munmap(?*anyopaque, usize) c_int;

pub const LineMap = struct {
    text: []const u8,
    num: usize,
};

pub const LocalEntry = struct {
    val: Value,
    func_name: ?[]const u8,
    func_id: i64,
};

pub const Function = struct {
    body: std.ArrayList([]const u8) = .empty,
};

pub const Interpreter = struct {
    allocator: Allocator,
    io: std.Io,
    python: ?*py_mod.Py = null,

    variables: std.StringHashMap(Value),
    functions: std.StringHashMap(*Function),
    structs: std.StringHashMap(*Dict),
    locals: std.StringHashMap(std.ArrayList(LocalEntry)),

    deleted_keywords: std.ArrayList([]const u8) = .empty,
    custom_handlers: std.StringHashMap(*anyopaque) = undefined,

    err: i64 = 0,
    eval_error: bool = false,
    in_try_block: bool = false,
    in_func: std.ArrayList(bool) = .empty,
    function_tracker: std.ArrayList(?[]const u8) = .empty,
    function_ids: std.ArrayList(i64) = .empty,
    current_func_name: ?[]const u8 = null,
    return_stops: bool = false,
    ret_val: Value = .none,
    break_stack: std.ArrayList(bool) = .empty,
    defer_stack: std.StringHashMap(std.ArrayList([]const u8)),
    current_line: usize = 0,
    next_func_id: i64 = 1,

    preprocess_only: bool = false,
    no_preproc: bool = false,
    forward_declare: bool = false,
    nan: bool = false,
    fail: bool = false,
    escape: bool = false,
    gc: bool = true,
    debug: bool = false,
    debug_continue: bool = false,
    debug_step_once: bool = false,
    debug_log_file: ?[]const u8 = null,
    debug_session_started: bool = false,
    unpack_: bool = false,
    in_loop: bool = false,
    main_file: i64 = 1,
    asm_backend: []const u8 = "emu",
    manual_memory_enabled: bool = false,
    memory_slots: std.StringHashMap(usize),
    asm_slots: std.StringHashMap(usize),
    asm_slot_names: std.ArrayList([]const u8) = .empty,
    breakpoints: std.ArrayList(usize) = .empty,

    lines_map: std.ArrayList(LineMap) = .empty,
    lines_map_done: bool = false,

    mem: [4096]u8 = @splat(0),

    file_path: []const u8 = "",
    stdin_buf: [65536]u8 = undefined,
    stdin_reader: ?std.Io.File.Reader = null,

    pub fn init(allocator: Allocator, io: std.Io, python: ?*py_mod.Py) !*Interpreter {
        const self = try allocator.create(Interpreter);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .python = python,
            .variables = std.StringHashMap(Value).init(allocator),
            .functions = std.StringHashMap(*Function).init(allocator),
            .structs = std.StringHashMap(*Dict).init(allocator),
            .locals = std.StringHashMap(std.ArrayList(LocalEntry)).init(allocator),
            .defer_stack = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
            .custom_handlers = std.StringHashMap(*anyopaque).init(allocator),
            .memory_slots = std.StringHashMap(usize).init(allocator),
            .asm_slots = std.StringHashMap(usize).init(allocator),
        };
        try self.in_func.append(allocator, false);
        try self.function_tracker.append(allocator, null);
        try self.function_ids.append(allocator, 0);
        try self.variables.put("err", .{ .int = 0 });
        try self.variables.put("interpreter_path", .{ .string = "pryzma" });
        return self;
    }

    pub fn out(self: *Interpreter, bytes: []const u8) void {
        std.Io.File.stdout().writeStreamingAll(self.io, bytes) catch {};
    }

    pub fn printFmt(self: *Interpreter, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        self.out(s);
    }

    pub fn dup(self: *Interpreter, s: []const u8) ![]const u8 {
        return try self.allocator.dupe(u8, s);
    }

    pub fn setVar(self: *Interpreter, name: []const u8, val: Value) !void {
        const key = try self.dup(name);
        if (self.manual_memory_enabled and value.isNumber(val)) {
            if (self.memory_slots.get(name)) |addr| {
                const slot: *i64 = @ptrFromInt(addr);
                slot.* = value.asInt(val) orelse 0;
                try self.variables.put(key, val);
                return;
            }
            if (malloc(@sizeOf(i64))) |ptr| {
                const addr: usize = @intFromPtr(ptr);
                const slot: *i64 = @ptrCast(@alignCast(ptr));
                slot.* = value.asInt(val) orelse 0;
                try self.memory_slots.put(key, addr);
            }
        }
        try self.variables.put(key, val);
    }

    pub fn getGlobal(self: *Interpreter, name: []const u8) ?Value {
        return self.variables.get(name);
    }

    pub fn setGlobal(self: *Interpreter, name: []const u8, val: Value) !void {
        try self.setVar(name, val);
    }

    pub fn pushLocal(self: *Interpreter, name: []const u8, val: Value) !void {
        const key = try self.dup(name);
        const gop = try self.locals.getOrPut(key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.allocator, .{
            .val = val,
            .func_name = self.function_tracker.items[self.function_tracker.items.len - 1],
            .func_id = self.function_ids.items[self.function_ids.items.len - 1],
        });
    }

    pub fn lookupLocal(self: *Interpreter, name: []const u8) ?Value {
        const entries = self.locals.get(name) orelse return null;
        var frame = self.function_tracker.items.len;
        while (frame > 0) {
            frame -= 1;
            const fname = self.function_tracker.items[frame];
            const fid = self.function_ids.items[frame];
            var i = entries.items.len;
            while (i > 0) {
                i -= 1;
                const e = entries.items[i];
                if (optionalNameEql(e.func_name, fname) and e.func_id == fid) return e.val;
            }
        }
        return null;
    }

    pub fn lookupVar(self: *Interpreter, name: []const u8) ?Value {
        if (self.lookupLocal(name)) |v| return v;
        if (self.manual_memory_enabled) {
            if (self.memory_slots.get(name)) |addr| {
                const slot: *i64 = @ptrFromInt(addr);
                return .{ .int = slot.* };
            }
        }
        return self.variables.get(name);
    }

    pub fn definedName(self: *Interpreter, name: []const u8) bool {
        return self.variables.contains(name) or self.locals.contains(name) or self.functions.contains(name);
    }

    pub fn runtimeError(self: *Interpreter, code: i64, message: []const u8) void {
        self.err = code;
        self.variables.put("err", .{ .int = code }) catch {};
        if (!self.in_try_block) {
            if (self.in_func.items[self.in_func.items.len - 1]) {
                if (self.function_tracker.items[self.function_tracker.items.len - 1]) |name| {
                    self.printFmt("Error while calling function '{s}'\n", .{name});
                }
            }
            self.out(message);
            self.out("\n");
            if (self.fail) std.process.exit(1);
        }
    }

    pub fn splitOnComment(self: *Interpreter, line: []const u8) []const u8 {
        _ = self;
        var in_string: u8 = 0;
        var esc = false;
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            const c = line[i];
            if (esc) {
                esc = false;
                continue;
            }
            if (c == '\\') {
                esc = true;
                continue;
            }
            if (c == '\'' or c == '"') {
                if (in_string == 0) in_string = c else if (in_string == c) in_string = 0;
            }
            if (in_string == 0 and i + 1 < line.len and line[i] == '/' and line[i + 1] == '/') {
                return line[0..i];
            }
        }
        return line;
    }

    pub fn preprocess(self: *Interpreter, program: []const u8) ![]const []const u8 {
        var joined: std.ArrayList(u8) = .empty;
        var it = std.mem.splitScalar(u8, program, '\n');
        var in_str = false;
        var line_no: usize = 0;
        while (it.next()) |raw| : (line_no += 1) {
            const line = self.splitOnComment(raw);
            if (std.mem.startsWith(u8, line, "#np") or
                (std.mem.startsWith(u8, line, "#preproc") and std.mem.indexOf(u8, line, "np") != null))
            {
                self.no_preproc = true;
            }
            if (!self.lines_map_done) {
                const text = try self.dup(std.mem.trim(u8, line, " \t\r"));
                try self.lines_map.append(self.allocator, .{ .text = text, .num = line_no });
            }
            for (line) |c| {
                if (c == '"') in_str = !in_str;
            }
            try joined.appendSlice(self.allocator, line);
            if (!in_str) try joined.append(self.allocator, ';');
        }
        self.lines_map_done = true;

        if (!self.no_preproc) {
            var in_s = false;
            var depth: i64 = 0;
            for (joined.items) |*c| {
                if (c.* == '"') {
                    in_s = !in_s;
                } else if (!in_s) {
                    if (c.* == '{') depth += 1 else if (c.* == '}') depth -= 1 else if (depth != 0 and c.* == ';') c.* = '|';
                }
            }
        }

        var result: std.ArrayList([]const u8) = .empty;
        var start: usize = 0;
        in_str = false;
        var i: usize = 0;
        while (i < joined.items.len) : (i += 1) {
            const c = joined.items[i];
            if (c == '"') in_str = !in_str;
            if (c == ';' and !in_str) {
                const piece = std.mem.trim(u8, joined.items[start..i], " \t\r\n");
                if (piece.len != 0) try result.append(self.allocator, piece);
                start = i + 1;
            }
        }
        if (start < joined.items.len) {
            const piece = std.mem.trim(u8, joined.items[start..], " \t\r\n");
            if (piece.len != 0) try result.append(self.allocator, piece);
        }
        return result.toOwnedSlice(self.allocator);
    }

    pub fn preInterpret(self: *Interpreter, program: []const u8) !void {
        var lines = try self.preprocess(program);
        if (self.preprocess_only) {
            for (lines) |line| {
                self.out(line);
                self.out("\n");
            }
            std.process.exit(0);
        }
        if (self.forward_declare) {
            self.forward_declare = false;
            for (lines, 0..) |line, i| {
                self.current_line = i;
                if (std.mem.startsWith(u8, line, "/")) {
                    try self.interpret(line);
                }
            }
            self.current_line = 0;
        }
        var i: usize = 0;
        while (i < lines.len) : (i += 1) {
            if (std.mem.startsWith(u8, lines[i], "#replace")) {
                const rest = std.mem.trim(u8, lines[i][8..], " \t");
                if (std.mem.indexOf(u8, rest, "->")) |pos| {
                    const a = std.mem.trim(u8, rest[0..pos], " \t");
                    const b = std.mem.trim(u8, rest[pos + 2 ..], " \t");
                    const av = try self.evalExpr(a);
                    const bv = try self.evalExpr(b);
                    const astr = try value.printString(self.allocator, av);
                    const bstr = try value.printString(self.allocator, bv);
                    var replaced_lines: std.ArrayList([]const u8) = .empty;
                    for (lines) |line| {
                        if (self.python) |python| {
                            const pattern = try python.newString(astr);
                            const replacement = try python.newString(bstr);
                            const source = try python.newString(line);
                            const result = try python.callHelper("re_sub", &.{ pattern, replacement, source });
                            const converted = try python.fromPy(result);
                            if (converted == .string) {
                                try replaced_lines.append(self.allocator, converted.string);
                            } else {
                                try replaced_lines.append(self.allocator, line);
                            }
                            py_mod.Py_DecRef(pattern);
                            py_mod.Py_DecRef(replacement);
                            py_mod.Py_DecRef(source);
                            py_mod.Py_DecRef(result);
                        } else {
                            try replaced_lines.append(self.allocator, try std.mem.replaceOwned(u8, self.allocator, line, astr, bstr));
                        }
                    }
                    lines = try replaced_lines.toOwnedSlice(self.allocator);
                }
            } else {
                try self.interpret(lines[i]);
            }
        }
    }

    pub fn interpretFile(self: *Interpreter, path: []const u8, args: []const []const u8) !void {
        self.file_path = std.mem.trim(u8, path, "\"");
        var argv_list = try self.allocator.create(List);
        argv_list.* = List.init(self.allocator);
        for (args) |arg| try argv_list.append(.{ .string = try self.dup(arg) });
        try self.setVar("argv", .{ .tuple = argv_list });
        const cwd = try std.process.currentPathAlloc(self.io, self.allocator);
        defer self.allocator.free(cwd);
        const absolute_file = try std.fs.path.resolveAlloc(self.allocator, &.{ cwd, self.file_path });
        try self.setVar("__file__", .{ .string = try self.dup(absolute_file) });

        const data = std.Io.Dir.cwd().readFileAlloc(self.io, self.file_path, self.allocator, .limited(64 * 1024 * 1024)) catch {
            self.printFmt("File '{s}' not found.\n", .{self.file_path});
            return;
        };
        const has_packed_prefix = data.len >= 3 and std.mem.eql(u8, data[0..3], "prz");
        if (self.unpack_ or has_packed_prefix) {
            if (self.python) |python| {
                const compressed = if (has_packed_prefix) data[3..] else data;
                const packed_bytes = try python.newBytes(compressed);
                const unpacked_obj = try python.callHelper("lzma_decompress", &.{packed_bytes});
                defer py_mod.Py_DecRef(unpacked_obj);
                py_mod.Py_DecRef(packed_bytes);
                const unpacked = try python.fromPy(unpacked_obj);
                if (unpacked == .string) try self.preInterpret(unpacked.string);
            } else {
                self.runtimeError(12, "Packed files require CPython support");
            }
            return;
        }
        try self.preInterpret(data);
    }

    pub fn interpret(self: *Interpreter, line_in: []const u8) anyerror!void {
        const statements = try splitOutsideStrings(self, line_in, ';');
        for (statements) |piece| {
            var line = piece;
            if (self.main_file < 1) self.no_preproc = false;
            self.main_file -= 1;
            const previous_line = self.current_line;
            if (!self.in_func.items[self.in_func.items.len - 1]) self.current_line = 0;

            var has_line_match = false;
            for (self.lines_map.items, 0..) |entry, idx| {
                if (entry.text.len != 0 and std.mem.startsWith(u8, line, entry.text)) {
                    if (!self.in_loop) _ = self.lines_map.orderedRemove(idx);
                    self.current_line = entry.num + 1;
                    has_line_match = true;
                    break;
                }
            }
            if (self.debug and !has_line_match) self.current_line = previous_line;
            line = std.mem.trim(u8, line, " \t\r\n");
            if (line.len == 0 or std.mem.startsWith(u8, line, "//")) continue;
            if (self.debug) try self.debugPrompt(line);

            var deleted = false;
            for (self.deleted_keywords.items) |kw| {
                if (std.mem.indexOf(u8, line, kw) != null and
                    !std.mem.startsWith(u8, line, "disablekeyword(") and
                    !std.mem.startsWith(u8, line, "enablekeyword("))
                {
                    deleted = true;
                    self.runtimeError(1, try std.fmt.allocPrint(self.allocator, "Error at line {d}: keyword deleted '{s}'", .{ self.current_line, kw }));
                    break;
                }
            }
            if (deleted) continue;

            self.interpretStatement(line) catch |e| {
                self.runtimeError(12, try std.fmt.allocPrint(self.allocator, "Error at line {d}: {s}", .{ self.current_line, @errorName(e) }));
            };
        }
    }

    fn interpretStatement(self: *Interpreter, line: []const u8) anyerror!void {
        if (std.mem.startsWith(u8, line, "print")) {
            try self.printValue(line[5..]);
        } else if (std.mem.startsWith(u8, line, "input")) {
            try self.inputStatement(line[5..]);
        } else if (std.mem.startsWith(u8, line, "assert")) {
            try self.assertStatement(line[6..]);
        } else if (std.mem.startsWith(u8, line, "struct ")) {
            try self.defineStruct(line);
        } else if (std.mem.startsWith(u8, line, "{") and std.mem.indexOfScalar(u8, line, '=') != null) {
            const eq = std.mem.indexOfScalar(u8, line, '=').?;
            const name_text = std.mem.trim(u8, line[1..eq], " \t}");
            const names = try self.splitArgs(name_text);
            const instance = try self.evalExpr(line[eq + 1 ..]);
            if (instance == .dict) {
                for (names, 0..) |raw_name, i| {
                    if (i >= instance.dict.keys.items.len) break;
                    const name = std.mem.trim(u8, raw_name, " \t");
                    try self.setVar(name, instance.dict.values.items[i]);
                }
            }
        } else if (std.mem.startsWith(u8, line, "int")) {
            var rest = std.mem.trim(u8, line[3..], " \t");
            if (std.mem.indexOf(u8, rest, "=")) |eq| {
                const name = std.mem.trim(u8, rest[0..eq], " \t");
                const ex = std.mem.trim(u8, rest[eq + 1 ..], " \t");
                const v = try self.evalExpr(ex);
                try self.setVar(name, .{ .int = value.asInt(v) orelse 0 });
            } else {
                try self.setVar(std.mem.trim(u8, rest, " \t"), .{ .int = 0 });
            }
        } else if (std.mem.startsWith(u8, line, "str")) {
            var rest = std.mem.trim(u8, line[3..], " \t");
            if (std.mem.indexOf(u8, rest, "=")) |eq| {
                const name = std.mem.trim(u8, rest[0..eq], " \t");
                const ex = std.mem.trim(u8, rest[eq + 1 ..], " \t");
                const v = try self.evalExpr(ex);
                const s = try value.printString(self.allocator, v);
                try self.setVar(name, .{ .string = s });
            } else {
                try self.setVar(std.mem.trim(u8, rest, " \t"), .{ .string = "" });
            }
        } else if (std.mem.startsWith(u8, line, "#")) {
            try self.processPragma(line);
        } else if (std.mem.startsWith(u8, line, "loc ")) {
            const rest = line[4..];
            if (std.mem.indexOf(u8, rest, "=")) |eq| {
                const name = std.mem.trim(u8, rest[0..eq], " \t");
                const v = try self.evalExpr(std.mem.trim(u8, rest[eq + 1 ..], " \t"));
                try self.pushLocal(name, v);
            }
        } else if (std.mem.startsWith(u8, line, "if")) {
            try self.interpretIf(line);
        } else if (std.mem.startsWith(u8, line, "while")) {
            try self.interpretWhile(line);
        } else if (std.mem.startsWith(u8, line, "for") and !std.mem.startsWith(u8, line, "foreach")) {
            try self.interpretFor(line);
        } else if (std.mem.startsWith(u8, line, "foreach")) {
            try self.interpretForeach(line);
        } else if (std.mem.startsWith(u8, line, "using ")) {
            try self.usingValue(line);
        } else if (std.mem.startsWith(u8, line, "match(")) {
            try self.interpretMatch(line);
        } else if (std.mem.startsWith(u8, line, "try{")) {
            try self.interpretTry(line);
        } else if (std.mem.startsWith(u8, line, "asm{") and line[line.len - 1] == '}') {
            try self.executeAsm(line);
        } else if (std.mem.startsWith(u8, line, "pyextern ")) {
            try self.bindPyExtern(line);
        } else if (std.mem.startsWith(u8, line, "extern ")) {
            try self.bindExtern(line);
        } else if (std.mem.startsWith(u8, line, "use ")) {
            try self.importWithDirectives(std.mem.trim(u8, line[4..], " \t"), false);
        } else if (std.mem.startsWith(u8, line, "from ")) {
            try self.importWithDirectives(std.mem.trim(u8, line[5..], " \t"), true);
        } else if (std.mem.startsWith(u8, line, "load(") and line[line.len - 1] == ')') {
            try self.loadPythonModule(line[5 .. line.len - 1]);
        } else if (std.mem.startsWith(u8, line, "call(") and line[line.len - 1] == ')') {
            _ = try self.evalExpr(line);
        } else if (std.mem.startsWith(u8, line, "ccall(") and line[line.len - 1] == ')') {
            _ = try self.evalExpr(line);
        } else if (std.mem.startsWith(u8, line, "append ")) {
            const args = try self.splitArgs(line[7..]);
            if (args.len == 2) {
                const name = std.mem.trim(u8, args[0], " \t");
                if (self.lookupVar(name)) |v| {
                    if (v == .list) try v.list.append(try self.evalExpr(args[1]));
                }
            }
        } else if (std.mem.startsWith(u8, line, "copy ")) {
            const args = try self.splitArgs(line[5..]);
            if (args.len == 2) {
                const src = self.lookupVar(std.mem.trim(u8, args[0], " \t")) orelse .none;
                const dst = self.lookupVar(std.mem.trim(u8, args[1], " \t")) orelse .none;
                if (src == .list and dst == .list) try dst.list.appendSlice(src.list.items.items);
            }
        } else if (std.mem.startsWith(u8, line, "remove ") and !std.mem.startsWith(u8, line, "remove_path(")) {
            const args = try self.splitArgs(line[7..]);
            if (args.len == 2) {
                const list_name = std.mem.trim(u8, args[0], " \t");
                if (self.lookupVar(list_name)) |list| {
                    if (list == .list) _ = list.list.removeValue(try self.evalExpr(args[1]));
                }
            }
        } else if (std.mem.startsWith(u8, line, "pyexec(") and line[line.len - 1] == ')') {
            _ = try self.evalExpr(line);
        } else if (std.mem.startsWith(u8, line, "pyeval(") and line[line.len - 1] == ')') {
            _ = try self.evalExpr(line);
        } else if ((std.mem.startsWith(u8, line, "py{") or std.mem.startsWith(u8, line, "py {")) and line[line.len - 1] == '}') {
            try self.execPythonBlock(line);
        } else if (std.mem.startsWith(u8, line, "exec(") and line[line.len - 1] == ')') {
            const args = try self.splitArgs(line[5 .. line.len - 1]);
            for (args) |arg| {
                const code = try self.evalExpr(arg);
                if (code == .string) try self.preInterpret(code.string);
            }
        } else if (std.mem.startsWith(u8, line, "eval(") and line[line.len - 1] == ')') {
            const args = try self.splitArgs(line[5 .. line.len - 1]);
            for (args) |arg| _ = try self.evalExpr(arg);
        } else if (std.mem.startsWith(u8, line, "isolate(") and line[line.len - 1] == ')') {
            _ = try self.evalExpr(line);
        } else if (std.mem.startsWith(u8, line, "json_dump(") and line[line.len - 1] == ')') {
            _ = try self.evalExpr(line);
        } else if (std.mem.startsWith(u8, line, "push(") and line[line.len - 1] == ')') {
            const args = try self.splitArgs(line[5 .. line.len - 1]);
            if (args.len == 3) {
                const dict_name = std.mem.trim(u8, args[0], " \t");
                const key = try self.evalExpr(args[1]);
                const val = try self.evalExpr(args[2]);
                if (self.lookupVar(dict_name)) |target| {
                    if (target == .dict) try target.dict.put(key, val);
                }
            }
        } else if (std.mem.startsWith(u8, line, "dpop(") and line[line.len - 1] == ')') {
            const args = try self.splitArgs(line[5 .. line.len - 1]);
            if (args.len == 2) {
                const dict_name = std.mem.trim(u8, args[0], " \t");
                const key = try self.evalExpr(args[1]);
                if (self.lookupVar(dict_name)) |target| {
                    if (target == .dict) _ = target.dict.remove(key);
                }
            }
        } else if (std.mem.startsWith(u8, line, "delvar(") and line[line.len - 1] == ')') {
            const target = try self.evalExpr(line[7 .. line.len - 1]);
            if (target == .string) _ = self.variables.remove(target.string);
        } else if (std.mem.startsWith(u8, line, "delfunc(") and line[line.len - 1] == ')') {
            const target = try self.evalExpr(line[8 .. line.len - 1]);
            if (target == .string) _ = self.functions.remove(target.string);
        } else if (std.mem.startsWith(u8, line, "disablekeyword(") and line[line.len - 1] == ')') {
            const args = try self.splitArgs(line[15 .. line.len - 1]);
            for (args) |arg| {
                const keyword = try self.evalExpr(arg);
                if (keyword == .string) try self.deleted_keywords.append(self.allocator, try self.dup(keyword.string));
            }
        } else if (std.mem.startsWith(u8, line, "enablekeyword(") and line[line.len - 1] == ')') {
            const args = try self.splitArgs(line[14 .. line.len - 1]);
            for (args) |arg| {
                const keyword = try self.evalExpr(arg);
                if (keyword != .string) continue;
                for (self.deleted_keywords.items, 0..) |disabled, index| {
                    if (std.mem.eql(u8, disabled, keyword.string)) {
                        _ = self.deleted_keywords.orderedRemove(index);
                        break;
                    }
                }
            }
        } else if (std.mem.startsWith(u8, line, "mkdir(") and line[line.len - 1] == ')') {
            const path = try self.evalExpr(line[6 .. line.len - 1]);
            if (path == .string) {
                std.Io.Dir.cwd().createDir(self.io, path.string, .default_dir) catch |err| {
                    self.runtimeError(12, try std.fmt.allocPrint(self.allocator, "Error at line {d}: {s}", .{ self.current_line, @errorName(err) }));
                };
            }
        } else if (std.mem.startsWith(u8, line, "makedirs(") and line[line.len - 1] == ')') {
            const path = try self.evalExpr(line[9 .. line.len - 1]);
            if (path == .string) {
                std.Io.Dir.cwd().createDirPath(self.io, path.string) catch |err| {
                    self.runtimeError(12, try std.fmt.allocPrint(self.allocator, "Error at line {d}: {s}", .{ self.current_line, @errorName(err) }));
                };
            }
        } else if (std.mem.startsWith(u8, line, "rmdir(") and line[line.len - 1] == ')') {
            const path = try self.evalExpr(line[6 .. line.len - 1]);
            if (path == .string) {
                std.Io.Dir.cwd().deleteDir(self.io, path.string) catch |err| {
                    self.runtimeError(12, try std.fmt.allocPrint(self.allocator, "Error at line {d}: {s}", .{ self.current_line, @errorName(err) }));
                };
            }
        } else if (std.mem.startsWith(u8, line, "removedirs(") and line[line.len - 1] == ')') {
            const path = try self.evalExpr(line[11 .. line.len - 1]);
            if (path == .string) try self.removeDirs(path.string);
        } else if (std.mem.startsWith(u8, line, "copy(") and line[line.len - 1] == ')') {
            const args = try self.splitArgs(line[5 .. line.len - 1]);
            if (args.len == 2) {
                const source = try self.evalExpr(args[0]);
                const destination = try self.evalExpr(args[1]);
                if (source == .string and destination == .string) {
                    std.Io.Dir.cwd().copyFile(source.string, .cwd(), destination.string, self.io, .{}) catch |err| {
                        self.runtimeError(12, try std.fmt.allocPrint(self.allocator, "Error at line {d}: {s}", .{ self.current_line, @errorName(err) }));
                    };
                }
            }
        } else if (std.mem.startsWith(u8, line, "copyfile(") and line[line.len - 1] == ')') {
            const args = try self.splitArgs(line[9 .. line.len - 1]);
            if (args.len == 2) {
                const source = try self.evalExpr(args[0]);
                const destination = try self.evalExpr(args[1]);
                if (source == .string and destination == .string) {
                    std.Io.Dir.cwd().copyFile(source.string, .cwd(), destination.string, self.io, .{}) catch |err| {
                        self.runtimeError(12, try std.fmt.allocPrint(self.allocator, "Error at line {d}: {s}", .{ self.current_line, @errorName(err) }));
                    };
                }
            }
        } else if (std.mem.startsWith(u8, line, "rename(") and line[line.len - 1] == ')') {
            const args = try self.splitArgs(line[7 .. line.len - 1]);
            if (args.len == 2) {
                const source = try self.evalExpr(args[0]);
                const destination = try self.evalExpr(args[1]);
                if (source == .string and destination == .string) {
                    std.Io.Dir.cwd().rename(source.string, .cwd(), destination.string, self.io) catch |err| {
                        self.runtimeError(12, try std.fmt.allocPrint(self.allocator, "Error at line {d}: {s}", .{ self.current_line, @errorName(err) }));
                    };
                }
            }
        } else if (std.mem.startsWith(u8, line, "symlink(") and line[line.len - 1] == ')') {
            const args = try self.splitArgs(line[8 .. line.len - 1]);
            if (args.len == 2) {
                const target = try self.evalExpr(args[0]);
                const link_path = try self.evalExpr(args[1]);
                if (target == .string and link_path == .string) {
                    std.Io.Dir.cwd().symLink(self.io, target.string, link_path.string, .{}) catch |err| {
                        self.runtimeError(12, try std.fmt.allocPrint(self.allocator, "Error at line {d}: {s}", .{ self.current_line, @errorName(err) }));
                    };
                }
            }
        } else if (std.mem.startsWith(u8, line, "unlink(") and line[line.len - 1] == ')') {
            const path = try self.evalExpr(line[7 .. line.len - 1]);
            if (path == .string) {
                std.Io.Dir.cwd().deleteFile(self.io, path.string) catch |err| {
                    if (err == error.FileNotFound) {
                        self.runtimeError(12, try std.fmt.allocPrint(self.allocator, "Error at line {d}: [Errno 2] No such file or directory: '{s}'", .{ self.current_line, path.string }));
                    } else {
                        self.runtimeError(12, try std.fmt.allocPrint(self.allocator, "Error at line {d}: {s}", .{ self.current_line, @errorName(err) }));
                    }
                };
            }
        } else if (std.mem.startsWith(u8, line, "remove_path(") and line[line.len - 1] == ')') {
            const path = try self.evalExpr(line[12 .. line.len - 1]);
            if (path == .string) std.Io.Dir.cwd().deleteFile(self.io, path.string) catch {};
        } else if (std.mem.startsWith(u8, line, "file_write(") and line[line.len - 1] == ')') {
            try self.fileWrite(line[11 .. line.len - 1]);
        } else if (std.mem.startsWith(u8, line, "sys(") and line[line.len - 1] == ')') {
            const command = try self.evalExpr(line[4 .. line.len - 1]);
            if (command == .string) {
                if (self.python) |python| {
                    const py_command = try python.newString(command.string);
                    defer py_mod.Py_DecRef(py_command);
                    const result = try python.callHelper("sys_call", &.{py_command});
                    py_mod.Py_DecRef(result);
                }
            }
        } else if (std.mem.startsWith(u8, line, "wait(") and line[line.len - 1] == ')') {
            const duration = try self.evalExpr(line[5 .. line.len - 1]);
            if (self.python) |python| {
                const py_duration = try python.toPy(duration, false);
                defer py_mod.Py_DecRef(py_duration);
                const result = try python.callHelper("wait", &.{py_duration});
                py_mod.Py_DecRef(result);
            }
        } else if (std.mem.startsWith(u8, line, "move(") and line[line.len - 1] == ')') {
            const args = try self.splitArgs(line[5 .. line.len - 1]);
            if (args.len != 3) {
                self.runtimeError(7, try std.fmt.allocPrint(self.allocator, "Error at line {d}: Invalid move instruction syntax. Expected format: move(old index, new index, list name)", .{self.current_line}));
                return;
            }
            const old_index = std.fmt.parseInt(i64, std.mem.trim(u8, args[0], " \t"), 10) catch {
                self.runtimeError(8, try std.fmt.allocPrint(self.allocator, "Error at line {d}: Invalid index", .{self.current_line}));
                return;
            };
            const new_index = std.fmt.parseInt(i64, std.mem.trim(u8, args[1], " \t"), 10) catch {
                self.runtimeError(8, try std.fmt.allocPrint(self.allocator, "Error at line {d}: Invalid index", .{self.current_line}));
                return;
            };
            const list_name = std.mem.trim(u8, args[2], " \t");
            if (self.lookupVar(list_name)) |target| {
                if (target == .list) {
                    if (target.list.popAt(old_index)) |item| {
                        const len: i64 = @intCast(target.list.len());
                        const normalized = if (new_index < 0) @max(0, len + new_index) else @min(len, new_index);
                        try target.list.insertAt(@intCast(normalized), item);
                    }
                }
            }
        } else if (std.mem.startsWith(u8, line, "write(") and line[line.len - 1] == ')') {
            const a = try self.splitArgs(line[6 .. line.len - 1]);
            if (a.len == 2) {
                const addr = value.asInt(try self.evalExpr(a[0])) orelse 0;
                const data = value.asInt(try self.evalExpr(a[1])) orelse 0;
                if (addr >= 0 and addr < self.mem.len) self.mem[@intCast(addr)] = @truncate(@as(u64, @bitCast(data)));
            }
        } else if (std.mem.startsWith(u8, line, "patch(") and line[line.len - 1] == ')') {
            const args = try self.splitArgs(line[6 .. line.len - 1]);
            if (args.len == 2) {
                const target = try self.evalExpr(args[0]);
                const replacement = try self.evalExpr(args[1]);
                if (target == .string and replacement == .string) {
                    if (self.functions.get(replacement.string)) |function| {
                        if (self.functions.contains(target.string)) {
                            try self.functions.put(try self.dup(target.string), function);
                        } else {
                            self.runtimeError(40, "Name of a non existing function pased as an argument to patch()");
                        }
                    } else {
                        self.runtimeError(40, "Name of a non existing function pased as an argument to patch()");
                    }
                }
            }
        } else if (std.mem.startsWith(u8, line, "pop ")) {
            const args = try self.splitArgs(line[4..]);
            if (args.len == 2) {
                const name = std.mem.trim(u8, args[0], " \t");
                const index = value.asInt(try self.evalExpr(args[1])) orelse 0;
                if (self.lookupVar(name)) |v| {
                    if (v == .list) _ = v.list.popAt(index);
                }
            }
        } else if (std.mem.startsWith(u8, line, "swap(") and line[line.len - 1] == ')') {
            const args = try self.splitArgs(line[5 .. line.len - 1]);
            if (args.len == 3) {
                const i = value.asInt(try self.evalExpr(args[0])) orelse 0;
                const j = value.asInt(try self.evalExpr(args[1])) orelse 0;
                const target = std.mem.trim(u8, args[2], " \t");
                if (self.lookupVar(target)) |v| if (v == .list) {
                    if (v.list.get(i)) |left| if (v.list.get(j)) |right| {
                        _ = v.list.set(i, right);
                        _ = v.list.set(j, left);
                    };
                };
            }
        } else if (std.mem.startsWith(u8, line, "defer{") and line[line.len - 1] == '}') {
            const body = try self.dup(line[6 .. line.len - 1]);
            const key = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{
                self.function_tracker.items[self.function_tracker.items.len - 1] orelse "",
                self.function_ids.items[self.function_ids.items.len - 1],
            });
            const gop = try self.defer_stack.getOrPut(key);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.allocator, body);
        } else if (std.mem.startsWith(u8, line, "/")) {
            try self.defineFunction(line);
        } else if (std.mem.startsWith(u8, line, "@")) {
            try self.callStatement(line[1..]);
        } else if (std.mem.indexOf(u8, line, ".@")) |method_pos| {
            const object = std.mem.trim(u8, line[0..method_pos], " \t");
            const rest = line[method_pos + 2 ..];
            const open = std.mem.indexOfScalar(u8, rest, '(') orelse return;
            const name = std.mem.trim(u8, rest[0..open], " \t");
            const args = if (rest[rest.len - 1] == ')') rest[open + 1 .. rest.len - 1] else "";
            const rewritten = try std.fmt.allocPrint(self.allocator, "@{s}({s}{s}{s})", .{
                name,
                object,
                if (args.len == 0) "" else ",",
                args,
            });
            try self.interpret(rewritten);
        } else if (std.mem.startsWith(u8, line, "return")) {
            self.ret_val = try self.evalExpr(std.mem.trim(u8, line[6..], " \t"));
        } else if (std.mem.eql(u8, line, "break")) {
            if (self.break_stack.items.len > 0) self.break_stack.items[self.break_stack.items.len - 1] = true;
        } else if (std.mem.startsWith(u8, line, "stop")) {
            std.process.exit(0);
        } else if (std.mem.indexOf(u8, line, "++") != null) {
            const name = std.mem.trim(u8, std.mem.replaceOwned(u8, self.allocator, line, "++", "") catch line, " \t");
            try self.incrementVar(name, "1");
        } else if (std.mem.indexOf(u8, line, "--") != null) {
            const name = std.mem.trim(u8, std.mem.replaceOwned(u8, self.allocator, line, "--", "") catch line, " \t");
            try self.decrementVar(name, "1");
        } else if (std.mem.indexOf(u8, line, "+=") != null) {
            const pos = std.mem.indexOf(u8, line, "+=").?;
            try self.incrementVar(std.mem.trim(u8, line[0..pos], " \t"), std.mem.trim(u8, line[pos + 2 ..], " \t"));
        } else if (std.mem.indexOf(u8, line, "-=") != null) {
            const pos = std.mem.indexOf(u8, line, "-=").?;
            try self.decrementVar(std.mem.trim(u8, line[0..pos], " \t"), std.mem.trim(u8, line[pos + 2 ..], " \t"));
        } else if (std.mem.indexOf(u8, line, "=") != null and
            !std.mem.startsWith(u8, line, "if") and !std.mem.startsWith(u8, line, "while") and
            std.mem.indexOf(u8, line, "==") == null and std.mem.indexOf(u8, line, "!=") == null and
            std.mem.indexOf(u8, line, "<=") == null and std.mem.indexOf(u8, line, ">=") == null)
        {
            const pos = std.mem.indexOfScalar(u8, line, '=').?;
            try self.assignValue(std.mem.trim(u8, line[0..pos], " \t"), std.mem.trim(u8, line[pos + 1 ..], " \t"));
        } else {
            self.runtimeError(11, try std.fmt.allocPrint(self.allocator, "Invalid statement at line {d}: {s}", .{ self.current_line, line }));
        }
    }

    fn defineFunction(self: *Interpreter, line: []const u8) !void {
        const open = std.mem.indexOfScalar(u8, line, '{') orelse {
            self.runtimeError(2, try std.fmt.allocPrint(self.allocator, "Invalid function definition at line {d}", .{self.current_line}));
            return;
        };
        if (line.len == 0 or line[line.len - 1] != '}') {
            self.runtimeError(2, try std.fmt.allocPrint(self.allocator, "Invalid function definition at line {d}", .{self.current_line}));
            return;
        }
        const name = std.mem.trim(u8, line[1..open], " \t");
        const body_text = line[open + 1 .. line.len - 1];
        const parts = try self.splitPipes(body_text);
        const fn_def = try self.allocator.create(Function);
        fn_def.* = .{};
        for (parts) |p| {
            const trimmed = std.mem.trim(u8, p, " \t\r\n");
            if (trimmed.len != 0) try fn_def.body.append(self.allocator, try self.dup(trimmed));
        }
        try self.functions.put(try self.dup(name), fn_def);
    }

    fn executeAsm(self: *Interpreter, line: []const u8) !void {
        self.asm_slots.clearRetainingCapacity();
        self.asm_slot_names.clearRetainingCapacity();
        const body = line[4 .. line.len - 1];
        const raw_lines = try self.splitPipes(body);
        var code: std.ArrayList(u8) = .empty;
        for (raw_lines) |raw| {
            const instruction_value = try self.evalExpr(std.mem.trim(u8, raw, " \t\r\n"));
            if (instruction_value != .string) continue;
            const instruction = std.mem.trim(u8, instruction_value.string, " \t\r\n");
            const space = std.mem.indexOfAny(u8, instruction, " \t") orelse continue;
            const op = instruction[0..space];
            const operands = try self.splitArgs(std.mem.trim(u8, instruction[space..], " \t"));
            if (operands.len != 2) continue;
            const dst = std.mem.trim(u8, operands[0], " \t");
            const src = std.mem.trim(u8, operands[1], " \t");
            if (std.mem.eql(u8, op, "mov")) {
                if (isAsmRegister(dst)) {
                    if (isAsmRegister(src)) {
                        if (std.mem.eql(u8, dst, src)) continue;
                        try code.appendSlice(self.allocator, &.{ 0x48, 0x89, asmRegModRm(dst, src) });
                    } else if (isIntegerLiteral(src)) {
                        const imm = std.fmt.parseInt(i64, src, 0) catch 0;
                        try appendMovImm64(self.allocator, &code, dst, imm);
                    } else {
                        const slot = try self.asmSlot(src);
                        try appendRipMem(self.allocator, &code, &.{ 0x48, 0x8b, asmRegRip(dst) }, slot, code.items.len);
                    }
                } else if (isAsmRegister(src)) {
                    const slot = try self.asmSlot(dst);
                    try appendRipMem(self.allocator, &code, &.{ 0x48, 0x89, asmRegStoreRip(src) }, slot, code.items.len);
                }
            } else if (isAsmRegister(dst) and (std.mem.eql(u8, op, "add") or std.mem.eql(u8, op, "sub"))) {
                if (isIntegerLiteral(src)) {
                    const imm = std.fmt.parseInt(i32, src, 0) catch 0;
                    try code.appendSlice(self.allocator, if (std.mem.eql(u8, op, "add")) &.{ 0x48, 0x05 } else &.{ 0x48, 0x2d });
                    try appendI32(self.allocator, &code, imm);
                } else if (isAsmRegister(src)) {
                    try code.appendSlice(self.allocator, &.{ 0x48, if (std.mem.eql(u8, op, "add")) 0x01 else 0x29, asmRegModRm(src, dst) });
                } else {
                    const slot = try self.asmSlot(src);
                    const opcode: u8 = if (std.mem.eql(u8, op, "add")) 0x03 else 0x2b;
                    try appendRipMem(self.allocator, &code, &.{ 0x48, opcode, asmRegRip(dst) }, slot, code.items.len);
                }
            }
        }
        try code.append(self.allocator, 0xc3); // ret
        if (code.items.len >= 2048) return error.AsmProgramTooLarge;
        const mem = mmap(null, 4096, 7, 0x22, -1, 0) orelse return error.AsmMapFailed;
        defer _ = munmap(mem, 4096);
        const bytes: [*]u8 = @ptrCast(mem);
        @memcpy(bytes[0..code.items.len], code.items);
        for (self.asm_slot_names.items, 0..) |name, i| {
            const offset = 2048 + i * 8;
            const slot: *i64 = @ptrCast(@alignCast(bytes + offset));
            const current = self.lookupVar(name) orelse .none;
            slot.* = value.asInt(current) orelse 0;
        }
        const function: *const fn () callconv(.c) void = @ptrCast(@alignCast(mem));
        function();
        for (self.asm_slot_names.items, 0..) |name, i| {
            const offset = 2048 + i * 8;
            const slot: *i64 = @ptrCast(@alignCast(bytes + offset));
            try self.setVar(name, .{ .int = slot.* });
        }
    }

    fn asmSlot(self: *Interpreter, name: []const u8) !usize {
        if (self.asm_slots.get(name)) |offset| return offset;
        const index = self.asm_slot_names.items.len;
        const offset = 2048 + index * 8;
        try self.asm_slots.put(try self.dup(name), offset);
        try self.asm_slot_names.append(self.allocator, try self.dup(name));
        return offset;
    }

    fn processPragma(self: *Interpreter, line: []const u8) !void {
        const pragma = std.mem.trim(u8, line[1..], " \t");
        if (std.mem.startsWith(u8, pragma, "insert")) {
            const path = try self.evalExpr(std.mem.trim(u8, pragma[6..], " \t"));
            if (path == .string) {
                const data = std.Io.Dir.cwd().readFileAlloc(self.io, path.string, self.allocator, .limited(64 * 1024 * 1024)) catch {
                    self.runtimeError(12, try std.fmt.allocPrint(self.allocator, "File '{s}' not found.", .{path.string}));
                    return;
                };
                try self.preInterpret(data);
            }
            return;
        }
        if (std.mem.startsWith(u8, pragma, "replace")) {
            return;
        }
        if (std.mem.startsWith(u8, pragma, "preproc")) {
            if (std.mem.indexOfScalar(u8, pragma, '=')) |eq| {
                const args = try self.splitArgs(pragma[eq + 1 ..]);
                for (args) |raw| self.applyDirective(std.mem.trim(u8, raw, " \t"));
            }
            return;
        }
        const args = try self.splitArgs(pragma);
        for (args) |raw| self.applyDirective(std.mem.trim(u8, raw, " \t"));
    }

    fn applyDirective(self: *Interpreter, directive: []const u8) void {
        if (std.mem.eql(u8, directive, "np")) self.no_preproc = true;
        if (std.mem.eql(u8, directive, "fd")) self.forward_declare = true;
        if (std.mem.eql(u8, directive, "nan")) self.nan = true;
        if (std.mem.eql(u8, directive, "an")) self.nan = false;
        if (std.mem.eql(u8, directive, "fail")) self.fail = true;
        if (std.mem.eql(u8, directive, "df")) self.fail = false;
        if (std.mem.eql(u8, directive, "rs")) self.return_stops = true;
        if (std.mem.eql(u8, directive, "rds")) self.return_stops = false;
        if (std.mem.eql(u8, directive, "esc")) self.escape = true;
        if (std.mem.eql(u8, directive, "desc")) self.escape = false;
        if (std.mem.eql(u8, directive, "gc")) self.gc = true;
        if (std.mem.eql(u8, directive, "ngc")) self.gc = false;
        if (std.mem.eql(u8, directive, "asm_native") or std.mem.eql(u8, directive, "anat")) self.asm_backend = "native";
        if (std.mem.eql(u8, directive, "asm_emu") or std.mem.eql(u8, directive, "aemu")) self.asm_backend = "emu";
        if (std.mem.eql(u8, directive, "mm") or std.mem.eql(u8, directive, "mmraw")) self.manual_memory_enabled = true;
        if (std.mem.eql(u8, directive, "amm")) {
            var it = self.memory_slots.iterator();
            while (it.next()) |entry| {
                if (self.variables.get(entry.key_ptr.*)) |v| {
                    const slot: *i64 = @ptrFromInt(entry.value_ptr.*);
                    _ = self.variables.put(entry.key_ptr.*, .{ .int = slot.* }) catch {};
                    _ = v;
                }
                free(@ptrFromInt(entry.value_ptr.*));
            }
            self.memory_slots.clearRetainingCapacity();
            self.manual_memory_enabled = false;
        }
    }

    fn defineStruct(self: *Interpreter, line: []const u8) !void {
        const open = std.mem.indexOfScalar(u8, line, '{') orelse return;
        const close = std.mem.lastIndexOfScalar(u8, line, '}') orelse return;
        const name = std.mem.trim(u8, line[7..open], " \t");
        const fields = try splitCommaOrPipe(self, line[open + 1 .. close]);
        const d = try Dict.create(self.allocator);
        for (fields) |field_raw| {
            const field = std.mem.trim(u8, field_raw, " \t\r\n");
            if (field.len == 0) continue;
            if (findTopLevel(field, "=")) |eq| {
                const key = std.mem.trim(u8, field[0..eq], " \t");
                const exp = std.mem.trim(u8, field[eq + 1 ..], " \t");
                try d.putStr(try self.dup(key), try self.evalExpr(exp));
            } else {
                try d.putStr(try self.dup(field), .none);
            }
        }
        try self.structs.put(try self.dup(name), d);
    }

    fn inputStatement(self: *Interpreter, line_in: []const u8) !void {
        const line = std.mem.trim(u8, line_in, " \t");
        const sep = std.mem.indexOf(u8, line, "::");
        const name = std.mem.trim(u8, if (sep) |p| line[0..p] else line, " \t");
        var prompt: []const u8 = "";
        if (sep) |p| {
            const prompt_val = try self.evalExpr(std.mem.trim(u8, line[p + 2 ..], " \t"));
            if (prompt_val == .string) prompt = prompt_val.string;
        }
        try self.setVar(name, .{ .string = try self.inputLine(prompt) });
    }

    fn assertStatement(self: *Interpreter, text: []const u8) !void {
        const args = try self.splitArgs(std.mem.trim(u8, text, " \t"));
        if (args.len < 2) {
            self.runtimeError(12, try std.fmt.allocPrint(self.allocator, "Error at line {d}: list index out of range", .{self.current_line}));
            return;
        }
        const condition = try self.evalExpr(args[0]);
        if (!value.truthy(condition)) {
            const message = try self.evalExpr(args[1]);
            const rendered = try value.printString(self.allocator, message);
            self.runtimeError(12, try std.fmt.allocPrint(self.allocator, "Error at line {d}: AssertionError: {s}", .{ self.current_line, rendered }));
        }
    }

    fn execPythonBlock(self: *Interpreter, line: []const u8) !void {
        const start: usize = if (std.mem.startsWith(u8, line, "py{")) 3 else 4;
        const python = self.python orelse return;
        const parts = try self.splitPipes(line[start .. line.len - 1]);
        var code: std.Io.Writer.Allocating = .init(self.allocator);
        for (parts, 0..) |part, i| {
            const statement = std.mem.trim(u8, part, " \t\r\n");
            if (statement.len == 0) continue;
            const evaluated = try self.evalExpr(statement);
            const source = try value.printString(self.allocator, evaluated);
            if (i != 0) try code.writer.writeByte(';');
            try code.writer.writeAll(source);
        }
        const globals = try self.pythonGlobals();
        python.execString(try code.toOwnedSlice(), globals, globals) catch py_mod.PyErr_Clear();
        try self.copyGlobalsFromPython(globals);
        py_mod.Py_DecRef(globals);
    }

    fn usingValue(self: *Interpreter, line: []const u8) !void {
        var rest = std.mem.trim(u8, line[6..], " \t");
        const is_global = std.mem.startsWith(u8, rest, "global ");
        if (is_global) rest = std.mem.trim(u8, rest[7..], " \t");
        var v = try self.evalExpr(rest);
        if (v == .reference) v = self.lookupVar(v.reference.var_name) orelse .none;
        if (v != .dict) {
            self.runtimeError(42, "'using' statement can only be used with structs.");
            return;
        }
        for (v.dict.keys.items, v.dict.values.items) |key, val| {
            if (key != .string) continue;
            if (is_global or !self.in_func.items[self.in_func.items.len - 1]) {
                try self.setVar(key.string, val);
            } else {
                try self.pushLocal(key.string, val);
            }
        }
    }

    fn interpretTry(self: *Interpreter, line: []const u8) !void {
        const catch_pos = std.mem.indexOf(u8, line, "}catch(");
        const body_end = if (catch_pos) |p| p else line.len - 1;
        const body = line[4..body_end];
        const saved_try = self.in_try_block;
        self.in_try_block = true;
        try self.runBody(body);
        self.in_try_block = saved_try;
        if (catch_pos) |p| {
            const code_start = p + 7;
            const code_end = std.mem.indexOfScalarPos(u8, line, code_start, ')') orelse return;
            const wanted = std.fmt.parseInt(i64, line[code_start..code_end], 10) catch return;
            if (self.err == wanted) {
                const open = std.mem.indexOfScalarPos(u8, line, code_end, '{') orelse return;
                const close = std.mem.lastIndexOfScalar(u8, line, '}') orelse return;
                self.err = 0;
                try self.runBody(line[open + 1 .. close]);
            }
        }
    }

    fn interpretMatch(self: *Interpreter, line: []const u8) !void {
        const open_paren = std.mem.indexOfScalar(u8, line, '(') orelse return;
        const close_paren = findMatching(line, open_paren, '(', ')') orelse return;
        const match_value = try self.evalExpr(line[open_paren + 1 .. close_paren]);
        const open_brace = std.mem.indexOfScalarPos(u8, line, close_paren, '{') orelse return;
        const close_brace = std.mem.lastIndexOfScalar(u8, line, '}') orelse return;
        const body = line[open_brace + 1 .. close_brace];
        const cases = try self.splitPipes(body);
        var default_body: ?[]const u8 = null;
        for (cases) |raw| {
            const c = std.mem.trim(u8, raw, " \t\r\n");
            if (!std.mem.startsWith(u8, c, "case(")) continue;
            const cp = std.mem.indexOfScalar(u8, c, '(') orelse continue;
            const ce = findMatching(c, cp, '(', ')') orelse continue;
            const cb = std.mem.indexOfScalarPos(u8, c, ce, '{') orelse continue;
            const cend = std.mem.lastIndexOfScalar(u8, c, '}') orelse continue;
            const test_expr = std.mem.trim(u8, c[cp + 1 .. ce], " \t");
            if (std.mem.eql(u8, test_expr, "_")) {
                default_body = c[cb + 1 .. cend];
                continue;
            }
            const candidate = try self.evalExpr(test_expr);
            if (value.eql(candidate, match_value)) {
                try self.runBody(c[cb + 1 .. cend]);
                return;
            }
        }
        if (default_body) |b| try self.runBody(b);
    }

    fn callStatement(self: *Interpreter, text: []const u8) !void {
        const trimmed = std.mem.trim(u8, text, " \t");
        var name = trimmed;
        var arg_values: std.ArrayList(Value) = .empty;
        if (std.mem.indexOfScalar(u8, trimmed, '(')) |op| {
            if (trimmed.len == 0 or trimmed[trimmed.len - 1] != ')') {
                self.runtimeError(11, "Invalid function call");
                return;
            }
            name = std.mem.trim(u8, trimmed[0..op], " \t");
            const arg_text = trimmed[op + 1 .. trimmed.len - 1];
            const args = try self.splitArgs(arg_text);
            for (args) |a| {
                const t = std.mem.trim(u8, a, " \t");
                if (t.len != 0) try arg_values.append(self.allocator, try self.evalExpr(t));
            }
        }
        self.ret_val = try self.callFunction(name, arg_values.items);
    }

    fn bindPyExtern(self: *Interpreter, line: []const u8) !void {
        const rest = std.mem.trim(u8, line[9..], " \t");
        const parsed = parseQuotedOrWord(rest) orelse return;
        const module_ref = parsed.value;
        const specs_text = std.mem.trim(u8, rest[parsed.end..], " \t");
        const python = self.python orelse return;
        const base = try python.newString(self.file_path);
        const module_ref_py = try python.newString(module_ref);
        const module = try python.callHelper("load_pyextern", &.{ module_ref_py, base });
        defer py_mod.Py_DecRef(module);
        py_mod.Py_DecRef(base);
        py_mod.Py_DecRef(module_ref_py);
        if (py_mod.PyObject_IsTrue(module) == 0) return;
        var names = std.ArrayList([]const u8).empty;
        if (specs_text.len >= 2 and specs_text[0] == '{' and specs_text[specs_text.len - 1] == '}') {
            names = .empty;
            const split = try splitCommaOrPipe(self, specs_text[1 .. specs_text.len - 1]);
            try names.appendSlice(self.allocator, split);
        } else {
            try names.append(self.allocator, specs_text);
        }
        for (names.items) |raw| {
            const spec = std.mem.trim(u8, raw, " \t\r\n");
            if (spec.len == 0) continue;
            if (std.mem.eql(u8, spec, "*")) {
                const public = try python.callHelper("public_callables", &.{module});
                var pos: isize = 0;
                var key: ?*py_mod.PyObject = null;
                var callable: ?*py_mod.PyObject = null;
                while (py_mod.PyDict_Next(public, &pos, &key, &callable) != 0) {
                    const name_value = try python.fromPy(key.?);
                    if (name_value != .string) continue;
                    py_mod.Py_IncRef(callable.?);
                    const ext = try self.allocator.create(value.ExternFn);
                    ext.* = .{ .callable = callable.?, .name = name_value.string, .is_c = false };
                    try self.setVar(name_value.string, .{ .extern_fn = ext });
                }
                py_mod.Py_DecRef(public);
                continue;
            }
            const alias_pos = std.mem.indexOf(u8, spec, " as ");
            const path = std.mem.trim(u8, if (alias_pos) |i| spec[0..i] else spec, " \t");
            const alias = std.mem.trim(u8, if (alias_pos) |i| spec[i + 4 ..] else lastPathPart(path), " \t");
            const py_path = try python.newString(path);
            const callable = try python.callHelper("resolve_attr", &.{ module, py_path });
            py_mod.Py_DecRef(py_path);
            if (py_mod.PyObject_IsTrue(callable) == 0) {
                py_mod.Py_DecRef(callable);
                continue;
            }
            const ext = try self.allocator.create(value.ExternFn);
            ext.* = .{ .callable = callable, .name = try self.dup(alias), .is_c = false };
            try self.setVar(alias, .{ .extern_fn = ext });
        }
    }

    fn bindExtern(self: *Interpreter, line: []const u8) !void {
        const rest = std.mem.trim(u8, line[7..], " \t");
        const parsed = parseQuotedOrWord(rest) orelse return;
        const specs_text = std.mem.trim(u8, rest[parsed.end..], " \t");
        const python = self.python orelse return;
        const path = try python.newString(parsed.value);
        const lib = try python.callHelper("load_c", &.{path});
        py_mod.Py_DecRef(path);
        defer py_mod.Py_DecRef(lib);
        var names = std.ArrayList([]const u8).empty;
        if (specs_text.len >= 2 and specs_text[0] == '{' and specs_text[specs_text.len - 1] == '}') {
            names = .empty;
            const split = try splitCommaOrPipe(self, specs_text[1 .. specs_text.len - 1]);
            try names.appendSlice(self.allocator, split);
        } else {
            try names.append(self.allocator, specs_text);
        }
        for (names.items) |raw| {
            const name = std.mem.trim(u8, raw, " \t\r\n");
            if (name.len == 0) continue;
            if (std.mem.eql(u8, name, "*")) {
                continue;
            }
            const py_name = try python.newString(name);
            const callable = python.callHelper("c_get", &.{ lib, py_name }) catch {
                py_mod.Py_DecRef(py_name);
                continue;
            };
            py_mod.Py_DecRef(py_name);
            const ext = try self.allocator.create(value.ExternFn);
            ext.* = .{ .callable = callable, .name = try self.dup(name), .is_c = true };
            try self.setVar(name, .{ .extern_fn = ext });
        }
    }

    fn importFunctions(self: *Interpreter, spec_in: []const u8) !void {
        var spec = std.mem.trim(u8, spec_in, " \t");
        var alias: ?[]const u8 = null;
        if (std.mem.indexOf(u8, spec, " as ")) |pos| {
            alias = std.mem.trim(u8, spec[pos + 4 ..], " \t");
            spec = std.mem.trim(u8, spec[0..pos], " \t");
        }
        const path_spec = parseQuotedOrWord(spec) orelse return;
        const module_path = path_spec.value;
        if (std.mem.startsWith(u8, module_path, "http://") or std.mem.startsWith(u8, module_path, "https://")) {
            const python = self.python orelse return;
            const url = try python.newString(module_path);
            const response = try python.callHelper("http_get", &.{url});
            defer py_mod.Py_DecRef(response);
            py_mod.Py_DecRef(url);
            const source = try python.fromPy(response);
            if (source == .string) try self.loadPryzmaFunctions(source.string, alias orelse std.fs.path.stem(module_path));
            return;
        }
        var file_path = module_path;
        if (!std.mem.containsAtLeast(u8, file_path, 1, "/") and !std.mem.containsAtLeast(u8, file_path, 1, "\\")) {
            const root = std.fs.path.dirname(self.file_path) orelse ".";
            if (std.mem.indexOf(u8, file_path, "::")) |separator| {
                const folder = std.mem.replaceOwned(u8, self.allocator, file_path[0..separator], "::", "/") catch return error.OutOfMemory;
                const package_file = try std.fmt.allocPrint(self.allocator, "{s}.pryzma", .{file_path[separator + 2 ..]});
                file_path = try std.fs.path.join(self.allocator, &.{ root, "packages", folder, package_file });
            } else {
                const package_file = try std.fmt.allocPrint(self.allocator, "{s}.pryzma", .{file_path});
                file_path = try std.fs.path.join(self.allocator, &.{ root, "packages", file_path, package_file });
            }
        }
        const data = std.Io.Dir.cwd().readFileAlloc(self.io, file_path, self.allocator, .limited(64 * 1024 * 1024)) catch {
            self.runtimeError(30, try std.fmt.allocPrint(self.allocator, "Error at line {d}: File '{s}' not found.", .{ self.current_line, file_path }));
            return;
        };
        const source = try self.unpackIfNeeded(data);
        const name = alias orelse std.fs.path.stem(file_path);
        try self.loadPryzmaFunctions(source, name);
    }

    fn importWithDirectives(self: *Interpreter, spec_in: []const u8, selected: bool) !void {
        const directive_pos = std.mem.indexOf(u8, spec_in, " with ") orelse {
            if (selected) {
                try self.importSelectedFunctions(spec_in);
            } else {
                try self.importFunctions(spec_in);
            }
            return;
        };

        const import_spec = std.mem.trim(u8, spec_in[0..directive_pos], " \t");
        var directive_text = std.mem.trim(u8, spec_in[directive_pos + 6 ..], " \t");
        if (std.mem.startsWith(u8, directive_text, "{") and std.mem.endsWith(u8, directive_text, "}")) {
            directive_text = directive_text[1 .. directive_text.len - 1];
        }

        const old_nan = self.nan;
        const old_forward_declare = self.forward_declare;
        const old_no_preproc = self.no_preproc;
        defer {
            self.nan = old_nan;
            self.forward_declare = old_forward_declare;
            self.no_preproc = old_no_preproc;
        }

        const directives = try self.splitArgs(directive_text);
        for (directives) |raw| self.applyDirective(std.mem.trim(u8, raw, " \t"));

        if (selected) {
            try self.importSelectedFunctions(import_spec);
        } else {
            try self.importFunctions(import_spec);
        }
    }

    fn importSelectedFunctions(self: *Interpreter, spec: []const u8) !void {
        const use_pos = std.mem.indexOf(u8, spec, " use ") orelse return;
        var module = std.mem.trim(u8, spec[0..use_pos], " \t");
        const path: QuotedWord = parseQuotedOrWord(module) orelse .{ .value = module, .end = module.len };
        module = path.value;
        if (!std.mem.containsAtLeast(u8, module, 1, "/") and !std.mem.containsAtLeast(u8, module, 1, "\\")) {
            const root = std.fs.path.dirname(self.file_path) orelse ".";
            if (std.mem.indexOf(u8, module, "::")) |separator| {
                const folder = try std.mem.replaceOwned(u8, self.allocator, module[0..separator], "::", "/");
                const package_file = try std.fmt.allocPrint(self.allocator, "{s}.pryzma", .{module[separator + 2 ..]});
                module = try std.fs.path.join(self.allocator, &.{ root, "packages", folder, package_file });
            } else {
                const package_file = try std.fmt.allocPrint(self.allocator, "{s}.pryzma", .{module});
                module = try std.fs.path.join(self.allocator, &.{ root, "packages", module, package_file });
            }
        }
        var functions_text = std.mem.trim(u8, spec[use_pos + 5 ..], " \t");
        if (std.mem.startsWith(u8, functions_text, "{") and std.mem.endsWith(u8, functions_text, "}")) {
            functions_text = functions_text[1 .. functions_text.len - 1];
        }
        const wanted = try splitCommaOrPipe(self, functions_text);
        const data = std.Io.Dir.cwd().readFileAlloc(self.io, module, self.allocator, .limited(64 * 1024 * 1024)) catch return;
        const source = try self.unpackIfNeeded(data);
        const lines = try self.preprocess(source);
        for (lines) |line| {
            if (!std.mem.startsWith(u8, line, "/")) continue;
            const open = std.mem.indexOfScalar(u8, line, '{') orelse continue;
            var name = std.mem.trim(u8, line[1..open], " \t");
            if (std.mem.indexOfScalar(u8, name, '.')) |dot| name = name[dot + 1 ..];
            for (wanted) |raw| {
                const selected = std.mem.trim(u8, raw, " \t");
                const alias_pos = std.mem.indexOf(u8, selected, " as ");
                const request_name = std.mem.trim(u8, if (alias_pos) |p| selected[0..p] else selected, " \t");
                if (!std.mem.eql(u8, name, request_name)) continue;
                var definition = line;
                if (alias_pos) |p| {
                    const replacement = std.mem.trim(u8, selected[p + 4 ..], " \t");
                    definition = try std.fmt.allocPrint(self.allocator, "/{s}{s}", .{ replacement, line[open..] });
                }
                try self.interpret(definition);
            }
        }
    }

    fn loadPryzmaFunctions(self: *Interpreter, source: []const u8, prefix: []const u8) !void {
        const lines = try self.preprocess(source);
        for (lines) |line| {
            if (!std.mem.startsWith(u8, line, "/")) continue;
            const open = std.mem.indexOfScalar(u8, line, '{') orelse continue;
            const original = std.mem.trim(u8, line[1..open], " \t");
            var definition = line;
            if (!self.nan and !std.mem.startsWith(u8, original, try std.fmt.allocPrint(self.allocator, "{s}.", .{prefix}))) {
                definition = try std.fmt.allocPrint(self.allocator, "/{s}.{s}", .{ prefix, line[1..] });
            }
            try self.interpret(definition);
            const name = std.mem.trim(u8, definition[1..std.mem.indexOfScalar(u8, definition, '{').?], " \t");
            const import_handler = try std.fmt.allocPrint(self.allocator, "{s}.on_import", .{prefix});
            if (std.mem.eql(u8, name, import_handler)) {
                _ = try self.callFunction(name, &.{});
            }
        }
    }

    fn unpackIfNeeded(self: *Interpreter, data: []const u8) ![]const u8 {
        if (!std.mem.startsWith(u8, data, "prz")) return data;
        const python = self.python orelse return error.PythonUnavailable;
        const bytes = try python.newBytes(data[3..]);
        defer py_mod.Py_DecRef(bytes);
        const result = try python.callHelper("lzma_decompress", &.{bytes});
        defer py_mod.Py_DecRef(result);
        const unpacked = try python.fromPy(result);
        return if (unpacked == .string) unpacked.string else "";
    }

    fn loadPythonModule(self: *Interpreter, expression: []const u8) !void {
        const module_ref = try self.evalExpr(expression);
        if (module_ref != .string) return;
        const python = self.python orelse return;
        const path = try python.newString(module_ref.string);
        const base = try python.newString(self.file_path);
        const module = try python.callHelper("load_pyextern", &.{ path, base });
        defer py_mod.Py_DecRef(module);
        py_mod.Py_DecRef(path);
        py_mod.Py_DecRef(base);
        const attr = try python.newString("start");
        const start = py_mod.PyObject_GetAttrString(module, "start") orelse {
            py_mod.Py_DecRef(attr);
            return;
        };
        py_mod.Py_DecRef(attr);
        const ext = try self.allocator.create(value.ExternFn);
        ext.* = .{ .callable = start, .name = "start", .is_c = false };
        try self.setVar("__module_start", .{ .extern_fn = ext });
    }

    fn fileWrite(self: *Interpreter, args_text: []const u8) !void {
        const args = try self.splitArgs(args_text);
        if (args.len != 3) {
            self.runtimeError(6, try std.fmt.allocPrint(self.allocator, "Error at line {d}: Invalid number of arguments for write()", .{self.current_line}));
            return;
        }
        const path = try self.evalExpr(args[0]);
        const mode = try self.evalExpr(args[1]);
        const content = try self.evalExpr(args[2]);
        const python = self.python orelse return error.PythonUnavailable;
        const py_path = try python.toPy(path, false);
        defer py_mod.Py_DecRef(py_path);
        const py_mode = try python.toPy(mode, false);
        defer py_mod.Py_DecRef(py_mode);
        const py_content = try python.toPy(content, false);
        defer py_mod.Py_DecRef(py_content);
        const result = try python.callHelper("write_file", &.{ py_path, py_mode, py_content });
        defer py_mod.Py_DecRef(result);
        const error_text = try python.fromPy(result);
        if (error_text == .string) {
            const rendered_path = try value.printString(self.allocator, path);
            self.runtimeError(15, try std.fmt.allocPrint(self.allocator, "Error at line {d} while writing to file '{s}': {s}", .{ self.current_line, rendered_path, error_text.string }));
        }
    }

    fn removeDirs(self: *Interpreter, path: []const u8) !void {
        var current = path;
        var first = true;
        while (current.len != 0) {
            std.Io.Dir.cwd().deleteDir(self.io, current) catch |err| {
                if (first) self.runtimeError(12, try std.fmt.allocPrint(self.allocator, "Error at line {d}: {s}", .{ self.current_line, @errorName(err) }));
                break;
            };
            first = false;
            current = std.fs.path.dirname(current) orelse break;
        }
    }

    fn runIsolated(self: *Interpreter, args_text: []const u8) !Value {
        const args = try self.splitArgs(args_text);
        var isolated: ?*Interpreter = null;
        var code_args: std.ArrayList([]const u8) = .empty;
        for (args) |arg_in| {
            const arg = std.mem.trim(u8, arg_in, " \t");
            if (std.mem.startsWith(u8, arg, "isolate")) {
                if (std.mem.indexOfScalar(u8, arg, '=')) |equals| {
                    const name = std.mem.trim(u8, arg[equals + 1 ..], " \t");
                    if (self.lookupVar(name)) |candidate| {
                        if (candidate == .isolate) isolated = @ptrCast(@alignCast(candidate.isolate));
                    }
                    continue;
                }
            }
            try code_args.append(self.allocator, arg);
        }
        if (isolated == null) isolated = try Interpreter.init(self.allocator, self.io, self.python);
        for (code_args.items) |code_arg| {
            const code = try self.evalExpr(code_arg);
            if (code != .string) continue;
            isolated.?.ret_val = .none;
            try isolated.?.preInterpret(code.string);
            if (isolated.?.ret_val != .none) return isolated.?.ret_val;
        }
        return .none;
    }

    fn callFromFile(self: *Interpreter, args_text: []const u8, is_c: bool) !Value {
        const args = try self.splitArgs(args_text);
        if (args.len < 2) return .none;
        const file = try self.evalExpr(args[0]);
        const function_name = try self.evalExpr(args[1]);
        if (file != .string or function_name != .string) return .none;
        const python = self.python orelse return .none;
        const path = try python.newString(file.string);
        const name = try python.newString(function_name.string);
        const values = try List.create(self.allocator);
        for (args[2..]) |arg| try values.append(try self.evalExpr(arg));
        const py_values = try python.toPy(.{ .list = values }, is_c);
        defer py_mod.Py_DecRef(path);
        defer py_mod.Py_DecRef(name);
        defer py_mod.Py_DecRef(py_values);
        const result = if (is_c)
            try python.callHelper("ccall", &.{ path, name, py_values })
        else
            try python.callHelper("call_file", &.{ path, name, py_values });
        defer py_mod.Py_DecRef(result);
        return try python.fromPy(result);
    }

    pub fn callFunction(self: *Interpreter, name_in: []const u8, args: []Value) anyerror!Value {
        var name = name_in;
        if (self.lookupVar(name)) |v| {
            switch (v) {
                .func_ref => |n| name = n,
                .extern_fn => |ext| return try self.callExtern(ext, args),
                .string => |s| if (self.functions.contains(s)) {
                    name = s;
                },
                else => {},
            }
        }
        const fn_def = self.functions.get(name) orelse {
            self.runtimeError(38, try std.fmt.allocPrint(self.allocator, "Error at line {d}: Referenced function '{s}' no longer exists", .{ self.current_line, name }));
            return .none;
        };

        const args_list = try self.allocator.create(List);
        args_list.* = List.init(self.allocator);
        for (args) |a| try args_list.append(a);
        try self.setVar("args", .{ .list = args_list });

        try self.in_func.append(self.allocator, true);
        try self.function_tracker.append(self.allocator, try self.dup(name));
        const func_id = self.next_func_id;
        self.next_func_id += 1;
        try self.function_ids.append(self.allocator, func_id);
        self.ret_val = .none;

        for (fn_def.body.items) |inst| {
            try self.interpret(inst);
            if (self.return_stops and std.mem.startsWith(u8, inst, "return")) break;
        }

        const defer_key = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ name, func_id });
        if (self.defer_stack.getPtr(defer_key)) |deferred| {
            while (deferred.items.len > 0) {
                const body = deferred.pop().?;
                try self.runBody(body);
            }
        }
        const result = self.ret_val;
        if (!self.escape and self.gc) {
            var locals_it = self.locals.iterator();
            while (locals_it.next()) |entry| {
                var entries = entry.value_ptr;
                var i = entries.items.len;
                while (i > 0) {
                    i -= 1;
                    if (entries.items[i].func_id == func_id) _ = entries.orderedRemove(i);
                }
            }
        }
        _ = self.in_func.pop();
        _ = self.function_tracker.pop();
        _ = self.function_ids.pop();
        return result;
    }

    fn callExtern(self: *Interpreter, ext: *value.ExternFn, args: []Value) !Value {
        const python = self.python orelse return .none;
        const py_args = try List.create(self.allocator);
        for (args) |arg| try py_args.append(arg);
        const callable: *py_mod.PyObject = ext.callable;
        const py_list = try python.toPy(.{ .list = py_args }, ext.is_c);
        const py_is_c = try python.newBool(ext.is_c);
        defer py_mod.Py_DecRef(py_list);
        defer py_mod.Py_DecRef(py_is_c);
        const result = try python.callHelper("call_extern", &.{ callable, py_list, py_is_c });
        defer py_mod.Py_DecRef(result);
        return try python.fromPy(result);
    }

    fn interpretIf(self: *Interpreter, line: []const u8) !void {
        var rest = line[2..];
        // Split elif/else at depth zero.
        var branches: std.ArrayList([]const u8) = .empty;
        var else_body: ?[]const u8 = null;
        var depth: i64 = 0;
        var in_str = false;
        var start: usize = 0;
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            const c = rest[i];
            if (c == '"') in_str = !in_str else if (!in_str) {
                if (c == '{') depth += 1 else if (c == '}') depth -= 1 else if (depth == 0 and std.mem.startsWith(u8, rest[i..], "elif")) {
                    try branches.append(self.allocator, rest[start..i]);
                    start = i;
                } else if (depth == 0 and std.mem.startsWith(u8, rest[i..], "else")) {
                    try branches.append(self.allocator, rest[start..i]);
                    else_body = rest[i..];
                    start = rest.len;
                    break;
                }
            }
        }
        if (start < rest.len) try branches.append(self.allocator, rest[start..]);

        var handled = false;
        for (branches.items) |br| {
            const b = std.mem.trim(u8, br, " \t");
            if (b.len == 0) continue;
            var cond_and_body = b;
            if (std.mem.startsWith(u8, b, "if")) cond_and_body = b[2..] else if (std.mem.startsWith(u8, b, "elif")) cond_and_body = b[4..];
            const open = std.mem.indexOfScalar(u8, cond_and_body, '{') orelse continue;
            const close = std.mem.lastIndexOfScalar(u8, cond_and_body, '}') orelse continue;
            const cond = std.mem.trim(u8, cond_and_body[0..open], " \t");
            if (std.mem.startsWith(u8, cond, "(") and cond.len >= 2 and cond[cond.len - 1] == ')') {
                const cv = try self.evalExpr(cond[1 .. cond.len - 1]);
                if (!value.truthy(cv)) continue;
            } else {
                const cv = try self.evalExpr(cond);
                if (!value.truthy(cv)) continue;
            }
            handled = true;
            try self.runBody(cond_and_body[open + 1 .. close]);
            break;
        }
        if (!handled) {
            if (else_body) |eb| {
                const open = std.mem.indexOfScalar(u8, eb, '{') orelse return;
                const close = std.mem.lastIndexOfScalar(u8, eb, '}') orelse return;
                try self.runBody(eb[open + 1 .. close]);
            }
        }
    }

    fn interpretWhile(self: *Interpreter, line: []const u8) !void {
        const rest = std.mem.trim(u8, line[5..], " \t");
        if (rest.len == 0 or rest[0] != '(') return;
        const close_paren = findMatching(rest, 0, '(', ')') orelse return;
        const cond = rest[1..close_paren];
        const open = std.mem.indexOfScalar(u8, rest[close_paren..], '{') orelse return;
        const close = std.mem.lastIndexOfScalar(u8, rest, '}') orelse return;
        const body = rest[close_paren + open + 1 .. close];
        try self.break_stack.append(self.allocator, false);
        defer _ = self.break_stack.pop();
        if (self.debug_continue) self.debug_continue = false;
        while (true) {
            const cv = try self.evalExpr(cond);
            if (!value.truthy(cv)) break;
            try self.runBody(body);
            if (self.debug_continue) self.debug_continue = false;
            if (self.break_stack.items[self.break_stack.items.len - 1]) break;
        }
    }

    fn interpretFor(self: *Interpreter, line: []const u8) !void {
        const rest = std.mem.trim(u8, line[3..], " \t");
        if (rest.len == 0 or rest[0] != '(') return;
        const close_paren = findMatching(rest, 0, '(', ')') orelse return;
        const header = rest[1..close_paren];
        const open = std.mem.indexOfScalar(u8, rest[close_paren..], '{') orelse return;
        const close = std.mem.lastIndexOfScalar(u8, rest, '}') orelse return;
        const body = rest[close_paren + open + 1 .. close];
        const comma = std.mem.indexOfScalar(u8, header, ',') orelse return;
        const var_name = std.mem.trim(u8, header[0..comma], " \t");
        const range = std.mem.trim(u8, header[comma + 1 ..], " \t");
        const colon = std.mem.indexOfScalar(u8, range, ':') orelse return;
        const start_v = value.asInt(try self.evalExpr(range[0..colon])) orelse 0;
        const end_v = value.asInt(try self.evalExpr(range[colon + 1 ..])) orelse 0;
        try self.break_stack.append(self.allocator, false);
        defer _ = self.break_stack.pop();
        const was_in_loop = self.in_loop;
        self.in_loop = true;
        defer self.in_loop = was_in_loop;
        if (self.debug_continue) self.debug_continue = false;
        var i = start_v;
        while (i < end_v) : (i += 1) {
            try self.setVar(var_name, .{ .int = i });
            try self.runBody(body);
            if (self.debug_continue) self.debug_continue = false;
            if (self.break_stack.items[self.break_stack.items.len - 1]) break;
        }
    }

    fn interpretForeach(self: *Interpreter, line: []const u8) !void {
        const rest = std.mem.trim(u8, line[7..], " \t");
        if (rest.len == 0 or rest[0] != '(') return;
        const close_paren = findMatching(rest, 0, '(', ')') orelse return;
        const header = rest[1..close_paren];
        const open = std.mem.indexOfScalar(u8, rest[close_paren..], '{') orelse return;
        const close = std.mem.lastIndexOfScalar(u8, rest, '}') orelse return;
        const body = rest[close_paren + open + 1 .. close];
        const comma = std.mem.indexOfScalar(u8, header, ',') orelse return;
        const var_name = std.mem.trim(u8, header[0..comma], " \t");
        const list_name = std.mem.trim(u8, header[comma + 1 ..], " \t");
        const lv = self.lookupVar(list_name) orelse {
            self.runtimeError(41, try std.fmt.allocPrint(self.allocator, "Error at line {d}: List not found for the foreach function.", .{self.current_line}));
            return;
        };
        const list = switch (lv) {
            .list => |l| l,
            .tuple => |t| t,
            else => {
                self.runtimeError(41, try std.fmt.allocPrint(self.allocator, "Error at line {d}: List not found for the foreach function.", .{self.current_line}));
                return;
            },
        };
        try self.break_stack.append(self.allocator, false);
        defer _ = self.break_stack.pop();
        const was_in_loop = self.in_loop;
        self.in_loop = true;
        defer self.in_loop = was_in_loop;
        if (self.debug_continue) self.debug_continue = false;
        for (list.items.items) |item| {
            try self.variables.put(try self.dup(var_name), item);
            try self.runBody(body);
            if (self.debug_continue) self.debug_continue = false;
            if (self.break_stack.items[self.break_stack.items.len - 1]) break;
        }
    }

    fn runBody(self: *Interpreter, body: []const u8) !void {
        const parts = try self.splitPipes(body);
        for (parts) |p| {
            const t = std.mem.trim(u8, p, " \t\r\n");
            if (t.len != 0) try self.interpret(t);
        }
    }

    pub fn splitPipes(self: *Interpreter, text: []const u8) ![]const []const u8 {
        var result: std.ArrayList([]const u8) = .empty;
        var depth: i64 = 0;
        var in_str = false;
        var esc = false;
        var start: usize = 0;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            if (esc) {
                esc = false;
                continue;
            }
            if (c == '\\') {
                esc = true;
                continue;
            }
            if (c == '"') {
                in_str = !in_str;
            } else if (!in_str) {
                if (c == '{' or c == '[' or c == '(') depth += 1 else if (c == '}' or c == ']' or c == ')') depth -= 1 else if (c == '|' and depth == 0) {
                    try result.append(self.allocator, text[start..i]);
                    start = i + 1;
                }
            }
        }
        if (start < text.len) try result.append(self.allocator, text[start..]);
        return result.toOwnedSlice(self.allocator);
    }

    pub fn splitArgs(self: *Interpreter, text: []const u8) ![]const []const u8 {
        var result: std.ArrayList([]const u8) = .empty;
        var depth: i64 = 0;
        var in_str = false;
        var esc = false;
        var start: usize = 0;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            if (esc) {
                esc = false;
                continue;
            }
            if (c == '\\') {
                esc = true;
                continue;
            }
            if (c == '"') {
                in_str = !in_str;
            } else if (!in_str) {
                if (c == '{' or c == '[' or c == '(') depth += 1 else if (c == '}' or c == ']' or c == ')') depth -= 1 else if (c == ',' and depth == 0) {
                    try result.append(self.allocator, text[start..i]);
                    start = i + 1;
                }
            }
        }
        if (start < text.len) try result.append(self.allocator, text[start..]);
        return result.toOwnedSlice(self.allocator);
    }

    fn assignValue(self: *Interpreter, target: []const u8, expr: []const u8) !void {
        const v = try self.evalExpr(expr);
        const assigned: Value = if (v == .dict) .{ .dict = try v.dict.copy() } else v;
        var name = target;
        if (std.mem.startsWith(u8, name, "*")) {
            name = std.mem.trim(u8, name[1..], " \t");
            const rv = self.lookupVar(name) orelse .none;
            if (rv == .reference) {
                const ref = rv.reference;
                if (ref.addr != null and self.manual_memory_enabled) {
                    const ptr: *i64 = @ptrFromInt(ref.addr.?);
                    ptr.* = value.asInt(assigned) orelse 0;
                    return;
                }
                name = ref.var_name;
            }
        }
        if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
            const base_name = std.mem.trim(u8, name[0..dot], " \t");
            var obj = self.lookupVar(base_name) orelse {
                self.runtimeError(36, try std.fmt.allocPrint(self.allocator, "Error at line {d}: Variable '{s}' not found in current scope.", .{ self.current_line, base_name }));
                return;
            };
            if (obj == .reference) obj = self.lookupVar(obj.reference.var_name) orelse .none;
            var rest = name[dot + 1 ..];
            while (std.mem.indexOfScalar(u8, rest, '.')) |next_dot| {
                const field = std.mem.trim(u8, rest[0..next_dot], " \t");
                obj = try self.getField(obj, field);
                rest = rest[next_dot + 1 ..];
            }
            try self.setField(obj, std.mem.trim(u8, rest, " \t"), assigned);
            return;
        }
        if (std.mem.indexOfScalar(u8, name, '[')) |bracket| {
            const base_name = std.mem.trim(u8, name[0..bracket], " \t");
            var obj = self.lookupVar(base_name) orelse return;
            if (obj == .reference) obj = self.lookupVar(obj.reference.var_name) orelse return;
            var pos = bracket;
            while (pos < name.len and name[pos] == '[') {
                const close = findMatching(name, pos, '[', ']') orelse return;
                const idx_v = try self.evalExpr(name[pos + 1 .. close]);
                if (close + 1 < name.len and name[close + 1] == '[') {
                    obj = try self.indexValue(obj, idx_v);
                } else {
                    try self.setIndex(obj, idx_v, assigned);
                    return;
                }
                pos = close + 1;
            }
            return;
        }
        if (self.locals.contains(name)) {
            try self.setLocalByName(name, assigned);
        } else {
            try self.setVar(name, assigned);
        }
    }

    fn setLocalByName(self: *Interpreter, name: []const u8, v: Value) !void {
        const entries = self.locals.getPtr(name) orelse return;
        var frame = self.function_tracker.items.len;
        while (frame > 0) {
            frame -= 1;
            var i = entries.items.len;
            while (i > 0) {
                i -= 1;
                const e = &entries.items[i];
                if (optionalNameEql(e.func_name, self.function_tracker.items[frame]) and
                    e.func_id == self.function_ids.items[frame])
                {
                    e.val = v;
                    return;
                }
            }
        }
        if (entries.items.len > 0 and self.escape) {
            entries.items[entries.items.len - 1].val = v;
            return;
        }
        try entries.append(self.allocator, .{ .val = v, .func_name = self.function_tracker.items[self.function_tracker.items.len - 1], .func_id = self.function_ids.items[self.function_ids.items.len - 1] });
    }

    fn incrementVar(self: *Interpreter, target: []const u8, expr: []const u8) !void {
        if (std.mem.indexOfScalar(u8, target, '[')) |bracket| {
            const close = std.mem.lastIndexOfScalar(u8, target, ']') orelse return;
            const base_name = std.mem.trim(u8, target[0..bracket], " \t");
            const obj = self.lookupVar(base_name) orelse return;
            const idx = try self.evalExpr(target[bracket + 1 .. close]);
            const old = try self.indexValue(obj, idx);
            try self.setIndex(obj, idx, value.add(old, try self.evalExpr(expr)));
            return;
        }
        const cur = self.lookupVar(target) orelse .none;
        const add = try self.evalExpr(expr);
        const nv = value.add(cur, add);
        try self.setVar(target, nv);
    }

    fn decrementVar(self: *Interpreter, target: []const u8, expr: []const u8) !void {
        if (std.mem.indexOfScalar(u8, target, '[')) |bracket| {
            const close = std.mem.lastIndexOfScalar(u8, target, ']') orelse return;
            const base_name = std.mem.trim(u8, target[0..bracket], " \t");
            const obj = self.lookupVar(base_name) orelse return;
            const idx = try self.evalExpr(target[bracket + 1 .. close]);
            const old = try self.indexValue(obj, idx);
            try self.setIndex(obj, idx, value.sub(old, try self.evalExpr(expr)));
            return;
        }
        const cur = self.lookupVar(target) orelse .none;
        const sub = try self.evalExpr(expr);
        const nv = value.sub(cur, sub);
        try self.setVar(target, nv);
    }

    fn printValue(self: *Interpreter, text_in: []const u8) !void {
        const text = std.mem.trim(u8, text_in, " \t");
        const parts = try self.splitArgs(text);
        for (parts) |part| {
            const p = std.mem.trim(u8, part, " \t");
            if (p.len == 0) continue;
            self.eval_error = false;
            const v = try self.evalExpr(p);
            if (self.eval_error or (self.in_try_block and v == .none)) continue;
            const s = try value.printString(self.allocator, v);
            const replaced = try std.mem.replaceOwned(u8, self.allocator, s, "\\n", "\n");
            self.out(replaced);
        }
    }

    pub fn evalExpr(self: *Interpreter, expr_in: []const u8) anyerror!Value {
        var expr = std.mem.trim(u8, expr_in, " \t\r\n");
        if (expr.len == 0) return .none;
        if (std.mem.startsWith(u8, expr, "read(") and expr[expr.len - 1] == ')') {
            const addr = value.asInt(try self.evalExpr(expr[5 .. expr.len - 1])) orelse 0;
            if (addr >= 0 and addr < self.mem.len) return .{ .int = self.mem[@intCast(addr)] };
            return .none;
        }
        if (std.mem.startsWith(u8, expr, "addr(") and expr[expr.len - 1] == ')') {
            const target = try self.evalExpr(expr[5 .. expr.len - 1]);
            if (target == .reference and target.reference.addr != null) return .{ .int = @intCast(target.reference.addr.?) };
            return .none;
        }
        if (std.mem.startsWith(u8, expr, "~")) {
            const lazy = try self.allocator.create(value.Lazy);
            lazy.* = .{ .interp = self, .expr = try self.dup(expr[1..]) };
            return .{ .lazy = lazy };
        }

        if (std.mem.indexOfAny(u8, expr, ".eE") != null) {
            if (std.fmt.parseFloat(f64, expr)) |number| return .{ .float = number } else |_| {}
        }
        if (isIntegerLiteral(expr)) {
            return .{ .int = std.fmt.parseInt(i64, expr, 0) catch 0 };
        }
        if (expr.len > 1 and expr[0] == '-' and isIntegerLiteral(expr[1..])) {
            return .{ .int = -(std.fmt.parseInt(i64, expr[1..], 0) catch 0) };
        }
        if (expr.len > 1 and expr[0] == '-') return value.sub(.{ .int = 0 }, try self.evalExpr(expr[1..]));
        if (expr.len >= 2 and ((expr[0] == '"' and expr[expr.len - 1] == '"') or (expr[0] == '\'' and expr[expr.len - 1] == '\''))) {
            return .{ .string = try self.dup(expr[1 .. expr.len - 1]) };
        }
        if (std.mem.eql(u8, expr, "True")) return .{ .boolean = true };
        if (std.mem.eql(u8, expr, "False")) return .{ .boolean = false };
        if (std.mem.eql(u8, expr, "None")) return .none;
        if (std.mem.eql(u8, expr, "timenow")) {
            const python = self.python orelse return .none;
            const result = try python.callHelper("now_datetime", &.{});
            defer py_mod.Py_DecRef(result);
            return try python.fromPy(result);
        }
        if (std.mem.startsWith(u8, expr, "not ")) return .{ .boolean = !value.truthy(try self.evalExpr(expr[4..])) };

        if (std.mem.startsWith(u8, expr, "replace(") and expr[expr.len - 1] == ')') {
            const a = try self.splitArgs(expr[8 .. expr.len - 1]);
            if (a.len == 3) {
                const src_v = try self.evalExpr(a[0]);
                const old_v = try self.evalExpr(a[1]);
                const new_v = try self.evalExpr(a[2]);
                if (src_v == .string and old_v == .string and new_v == .string) {
                    const old = if (std.mem.eql(u8, old_v.string, "\\n")) "\n" else old_v.string;
                    const new = if (std.mem.eql(u8, new_v.string, "\\n")) "\n" else new_v.string;
                    return .{ .string = try std.mem.replaceOwned(u8, self.allocator, src_v.string, old, new) };
                }
            }
            return .none;
        }
        if (std.mem.startsWith(u8, expr, "resplit(") and expr[expr.len - 1] == ')') {
            const a = try self.splitArgs(expr[8 .. expr.len - 1]);
            if (a.len == 2) {
                const pat = try self.evalExpr(a[0]);
                const src = try self.evalExpr(a[1]);
                if (pat == .string and src == .string) {
                    const python = self.python orelse return .none;
                    const pp = try python.newString(pat.string);
                    const ps = try python.newString(src.string);
                    const result = try python.callHelper("re_split", &.{ pp, ps });
                    defer py_mod.Py_DecRef(result);
                    py_mod.Py_DecRef(pp);
                    py_mod.Py_DecRef(ps);
                    return try python.fromPy(result);
                }
            }
            return .none;
        }
        if (std.mem.startsWith(u8, expr, "json_dump(") and expr[expr.len - 1] == ')') {
            const a = try self.splitArgs(expr[10 .. expr.len - 1]);
            if (a.len >= 1) {
                const val = try self.evalExpr(a[0]);
                const python = self.python orelse return .none;
                const pv = try python.toPy(val, false);
                if (a.len > 1) {
                    const path = try self.evalExpr(a[1]);
                    if (path == .string) {
                        const pp = try python.newString(path.string);
                        const r = try python.callHelper("json_dump_file", &.{ pv, pp });
                        py_mod.Py_DecRef(r);
                        py_mod.Py_DecRef(pp);
                    }
                    py_mod.Py_DecRef(pv);
                    return .none;
                }
                const result = try python.callHelper("json_dumps", &.{pv});
                defer py_mod.Py_DecRef(result);
                py_mod.Py_DecRef(pv);
                return try python.fromPy(result);
            }
        }
        if (std.mem.startsWith(u8, expr, "json_load(") and expr[expr.len - 1] == ')') {
            const input = try self.evalExpr(expr[10 .. expr.len - 1]);
            if (input == .string) {
                const python = self.python orelse return .none;
                var result: *py_mod.PyObject = undefined;
                const file = std.Io.Dir.cwd().readFileAlloc(self.io, input.string, self.allocator, .limited(64 * 1024 * 1024)) catch null;
                if (file) |content| {
                    const pp = try python.newString(input.string);
                    result = python.callHelper("json_load_file", &.{pp}) catch {
                        py_mod.Py_DecRef(pp);
                        return .none;
                    };
                    py_mod.Py_DecRef(pp);
                    _ = content;
                } else {
                    const pp = try python.newString(input.string);
                    result = try python.callHelper("json_loads", &.{pp});
                    py_mod.Py_DecRef(pp);
                }
                defer py_mod.Py_DecRef(result);
                return try python.fromPy(result);
            }
        }
        if (std.mem.startsWith(u8, expr, "pyeval(") and expr[expr.len - 1] == ')') {
            const a = try self.splitArgs(expr[7 .. expr.len - 1]);
            if (a.len > 0) {
                const src = try self.evalExpr(a[0]);
                if (src == .string) {
                    const python = self.python orelse return .none;
                    const namespace = if (a.len > 1) try self.evalExpr(a[1]) else .none;
                    const globals = if (namespace == .dict) try self.pythonNamespace(namespace) else try self.pythonGlobals();
                    const result = python.evalString(src.string, globals, globals) catch {
                        py_mod.PyErr_Clear();
                        py_mod.Py_DecRef(globals);
                        return .none;
                    };
                    defer py_mod.Py_DecRef(result);
                    py_mod.Py_DecRef(globals);
                    return try python.fromPy(result);
                }
            }
        }
        if (std.mem.startsWith(u8, expr, "new_isolate(") and isWholeCall(expr, "new_isolate")) {
            const isolated = try Interpreter.init(self.allocator, self.io, self.python);
            return .{ .isolate = @ptrCast(isolated) };
        }
        if (std.mem.startsWith(u8, expr, "isolate(") and isWholeCall(expr, "isolate")) {
            return try self.runIsolated(expr[8 .. expr.len - 1]);
        }
        if (std.mem.startsWith(u8, expr, "call(") and isWholeCall(expr, "call")) {
            return try self.callFromFile(expr[5 .. expr.len - 1], false);
        }
        if (std.mem.startsWith(u8, expr, "ccall(") and isWholeCall(expr, "ccall")) {
            return try self.callFromFile(expr[6 .. expr.len - 1], true);
        }
        if (std.mem.startsWith(u8, expr, "pyexec(") and expr[expr.len - 1] == ')') {
            const a = try self.splitArgs(expr[7 .. expr.len - 1]);
            if (a.len > 0) {
                const src = try self.evalExpr(a[0]);
                if (src == .string) {
                    const python = self.python orelse return .none;
                    const namespace = if (a.len > 1) try self.evalExpr(a[1]) else .none;
                    const globals = if (namespace == .dict) try self.pythonNamespace(namespace) else try self.pythonGlobals();
                    python.execString(src.string, globals, globals) catch py_mod.PyErr_Clear();
                    if (namespace == .dict) {
                        try self.copyPythonDictToValue(globals, namespace.dict);
                    } else {
                        try self.copyGlobalsFromPython(globals);
                    }
                    py_mod.Py_DecRef(globals);
                }
            }
            return .none;
        }
        if (std.mem.startsWith(u8, expr, "in(") and expr[expr.len - 1] == ')') {
            const a = try self.splitArgs(expr[3 .. expr.len - 1]);
            if (a.len == 2) {
                const haystack = try self.evalExpr(a[0]);
                const needle = try self.evalExpr(a[1]);
                return .{ .boolean = switch (haystack) {
                    .list => |l| l.indexOf(needle) != null,
                    .tuple => |l| l.indexOf(needle) != null,
                    .string => |s| needle == .string and std.mem.indexOf(u8, s, needle.string) != null,
                    .dict => |d| d.indexOf(needle) != null,
                    else => false,
                } };
            }
        }
        if (std.mem.startsWith(u8, expr, "splitby(") and expr[expr.len - 1] == ')') {
            const a = try self.splitArgs(expr[8 .. expr.len - 1]);
            if (a.len >= 2) {
                const sep = try self.evalExpr(a[0]);
                const src = try self.evalExpr(a[1]);
                if (sep == .string and src == .string) {
                    if (sep.string.len == 0) {
                        self.runtimeError(12, try std.fmt.allocPrint(self.allocator, "Error at line {d}: empty separator", .{self.current_line}));
                        self.eval_error = true;
                        return .none;
                    }
                    const result = try List.create(self.allocator);
                    const maxsplit = if (a.len >= 3) value.asInt(try self.evalExpr(a[2])) orelse -1 else -1;
                    var start: usize = 0;
                    var splits: i64 = 0;
                    while (std.mem.indexOf(u8, src.string[start..], sep.string)) |relative| {
                        if (maxsplit >= 0 and splits >= maxsplit) break;
                        const pos = start + relative;
                        try result.append(.{ .string = src.string[start..pos] });
                        start = pos + sep.string.len;
                        splits += 1;
                        if (sep.string.len == 0) break;
                    }
                    try result.append(.{ .string = src.string[start..] });
                    return .{ .list = result };
                }
            }
        }
        if (std.mem.startsWith(u8, expr, "all(") and expr[expr.len - 1] == ')') {
            const v = try self.evalExpr(expr[4 .. expr.len - 1]);
            if (v == .list) {
                var aw: std.Io.Writer.Allocating = .init(self.allocator);
                for (v.list.items.items) |item| {
                    const s = try value.printString(self.allocator, item);
                    try aw.writer.writeAll(s);
                }
                return .{ .string = try aw.toOwnedSlice() };
            }
        }
        if (std.mem.startsWith(u8, expr, "defined(") and expr[expr.len - 1] == ')') {
            const name = std.mem.trim(u8, expr[8 .. expr.len - 1], " \t\"'");
            return .{ .boolean = self.definedName(name) };
        }
        if (std.mem.startsWith(u8, expr, "fields(") and expr[expr.len - 1] == ')') {
            const v = try self.evalExpr(expr[7 .. expr.len - 1]);
            if (v == .dict) {
                const l = try List.create(self.allocator);
                for (v.dict.keys.items) |key| try l.append(key);
                return .{ .list = l };
            }
        }
        if (std.mem.startsWith(u8, expr, "strip(") and expr[expr.len - 1] == ')') {
            const v = try self.evalExpr(expr[6 .. expr.len - 1]);
            if (self.python) |python| {
                const py_value = try python.toPy(v, false);
                defer py_mod.Py_DecRef(py_value);
                const result = try python.callHelper("strip_or_error", &.{py_value});
                defer py_mod.Py_DecRef(result);
                const stripped = try python.fromPy(result);
                if (stripped == .string and std.mem.startsWith(u8, stripped.string, "__PRYZMA_STRIP_ERROR__:")) {
                    self.runtimeError(12, try std.fmt.allocPrint(self.allocator, "Error at line {d}: {s}", .{ self.current_line, stripped.string["__PRYZMA_STRIP_ERROR__:".len..] }));
                    self.eval_error = true;
                    return .none;
                }
                return stripped;
            }
            if (v == .string) return .{ .string = std.mem.trim(u8, v.string, " \t\r\n") };
        }
        if (std.mem.startsWith(u8, expr, "list(") and expr[expr.len - 1] == ')') {
            const v = try self.evalExpr(expr[5 .. expr.len - 1]);
            if (v == .list) return v;
            if (v == .string) {
                const l = try List.create(self.allocator);
                var i: usize = 0;
                while (i < v.string.len) {
                    const seq_len = std.unicode.utf8ByteSequenceLength(v.string[i]) catch 1;
                    const end = @min(i + seq_len, v.string.len);
                    try l.append(.{ .string = v.string[i..end] });
                    i = end;
                }
                return .{ .list = l };
            }
        }
        if (std.mem.startsWith(u8, expr, "file_read(") and expr[expr.len - 1] == ')') {
            const path = try self.evalExpr(expr[10 .. expr.len - 1]);
            if (path == .string) {
                const data = std.Io.Dir.cwd().readFileAlloc(self.io, path.string, self.allocator, .limited(64 * 1024 * 1024)) catch return .{ .string = "" };
                return .{ .string = data };
            }
        }
        if (std.mem.startsWith(u8, expr, "is_file(") and isWholeCall(expr, "is_file")) {
            const path = try self.evalExpr(expr[8 .. expr.len - 1]);
            if (path == .string) {
                const stat = std.Io.Dir.cwd().statFile(self.io, path.string, .{}) catch return .{ .boolean = false };
                return .{ .boolean = stat.kind == .file };
            }
        }
        if (std.mem.startsWith(u8, expr, "is_dir(") and isWholeCall(expr, "is_dir")) {
            const path = try self.evalExpr(expr[7 .. expr.len - 1]);
            if (path == .string) {
                const stat = std.Io.Dir.cwd().statFile(self.io, path.string, .{}) catch return .{ .boolean = false };
                return .{ .boolean = stat.kind == .directory };
            }
        }
        if (std.mem.startsWith(u8, expr, "exists(") and isWholeCall(expr, "exists")) {
            const path = try self.evalExpr(expr[7 .. expr.len - 1]);
            if (path == .string) {
                _ = std.Io.Dir.cwd().statFile(self.io, path.string, .{}) catch return .{ .boolean = false };
                return .{ .boolean = true };
            }
        }
        if (std.mem.startsWith(u8, expr, "file_size(") and isWholeCall(expr, "file_size")) {
            const path = try self.evalExpr(expr[10 .. expr.len - 1]);
            if (path == .string) {
                const stat = std.Io.Dir.cwd().statFile(self.io, path.string, .{}) catch return .none;
                return .{ .int = @intCast(stat.size) };
            }
        }
        if (std.mem.startsWith(u8, expr, "splitlines(") and isWholeCall(expr, "splitlines")) {
            const text = try self.evalExpr(expr[11 .. expr.len - 1]);
            if (text == .string) {
                const python = self.python orelse return .none;
                const py_text = try python.newString(text.string);
                defer py_mod.Py_DecRef(py_text);
                const result = try python.callHelper("split_lines", &.{py_text});
                defer py_mod.Py_DecRef(result);
                return try python.fromPy(result);
            }
        }
        if (std.mem.startsWith(u8, expr, "dirname(") and isWholeCall(expr, "dirname")) {
            const path = try self.evalExpr(expr[8 .. expr.len - 1]);
            if (path == .string) {
                if (std.mem.endsWith(u8, path.string, "/")) {
                    const trimmed = std.mem.trimEnd(u8, path.string, "/");
                    if (trimmed.len == 0) return .{ .string = path.string };
                    return .{ .string = trimmed };
                }
                return .{ .string = std.fs.path.dirname(path.string) orelse "" };
            }
        }
        if (std.mem.startsWith(u8, expr, "basename(") and isWholeCall(expr, "basename")) {
            const path = try self.evalExpr(expr[9 .. expr.len - 1]);
            if (path == .string) {
                if (path.string.len != 0 and std.fs.path.isSep(path.string[path.string.len - 1])) {
                    return .{ .string = "" };
                }
                return .{ .string = std.fs.path.basename(path.string) };
            }
        }
        if (std.mem.startsWith(u8, expr, "abs_path(") and isWholeCall(expr, "abs_path")) {
            const path = try self.evalExpr(expr[9 .. expr.len - 1]);
            if (path == .string) {
                const cwd = try std.process.currentPathAlloc(self.io, self.allocator);
                defer self.allocator.free(cwd);
                return .{ .string = try std.fs.path.resolveAlloc(self.allocator, &.{ cwd, path.string }) };
            }
        }
        if (std.mem.startsWith(u8, expr, "split_ext(") and isWholeCall(expr, "split_ext")) {
            const path = try self.evalExpr(expr[10 .. expr.len - 1]);
            if (path == .string) {
                const base = std.fs.path.basename(path.string);
                var extension_start: ?usize = null;
                if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
                    if (dot > 0 and std.mem.trim(u8, base[0..dot], ".").len > 0) {
                        extension_start = path.string.len - base.len + dot;
                    }
                }
                const split = extension_start orelse path.string.len;
                const parts = try value.List.create(self.allocator);
                try parts.append(.{ .string = path.string[0..split] });
                try parts.append(.{ .string = path.string[split..] });
                return .{ .tuple = parts };
            }
        }
        if (std.mem.startsWith(u8, expr, "join_path(") and isWholeCall(expr, "join_path")) {
            const args = try self.splitArgs(expr[10 .. expr.len - 1]);
            var paths: std.ArrayList([]const u8) = .empty;
            for (args) |arg| {
                const part = try self.evalExpr(arg);
                if (part != .string) return .none;
                try paths.append(self.allocator, part.string);
            }
            if (paths.items.len == 0) return .{ .string = "" };
            return .{ .string = try std.fs.path.join(self.allocator, paths.items) };
        }
        if (std.mem.startsWith(u8, expr, "list_dir(") and isWholeCall(expr, "list_dir")) {
            const path = try self.evalExpr(expr[9 .. expr.len - 1]);
            if (path == .string) {
                const dir = std.Io.Dir.cwd().openDir(self.io, path.string, .{ .iterate = true }) catch return .none;
                defer dir.close(self.io);
                var entries = dir.iterate();
                const result = try value.List.create(self.allocator);
                while (try entries.next(self.io)) |entry| {
                    try result.append(.{ .string = try self.dup(entry.name) });
                }
                return .{ .list = result };
            }
        }
        if (std.mem.startsWith(u8, expr, "walk(") and isWholeCall(expr, "walk")) {
            const path = try self.evalExpr(expr[5 .. expr.len - 1]);
            if (path == .string) {
                const result = try value.List.create(self.allocator);
                try self.walkDirectory(path.string, result);
                return .{ .list = result };
            }
        }
        if (std.mem.startsWith(u8, expr, "is_link(") and isWholeCall(expr, "is_link")) {
            const path = try self.evalExpr(expr[8 .. expr.len - 1]);
            if (path == .string) {
                const stat = std.Io.Dir.cwd().statFile(self.io, path.string, .{ .follow_symlinks = false }) catch return .{ .boolean = false };
                return .{ .boolean = stat.kind == .sym_link };
            }
        }
        if (std.mem.startsWith(u8, expr, "read_link(") and isWholeCall(expr, "read_link")) {
            const path = try self.evalExpr(expr[10 .. expr.len - 1]);
            if (path == .string) {
                var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const len = std.Io.Dir.cwd().readLink(self.io, path.string, &buffer) catch |err| {
                    const os_error: ?[]const u8 = if (err == error.FileNotFound)
                        "[Errno 2] No such file or directory"
                    else if (err == error.NotLink)
                        "[Errno 22] Invalid argument"
                    else
                        null;
                    if (os_error) |message| {
                        self.runtimeError(12, try std.fmt.allocPrint(self.allocator, "Error at line {d}: {s}: '{s}'", .{ self.current_line, message, path.string }));
                        self.eval_error = true;
                        return .none;
                    }
                    return err;
                };
                return .{ .string = try self.dup(buffer[0..len]) };
            }
        }
        if (std.mem.startsWith(u8, expr, "index(") and isWholeCall(expr, "index")) {
            const args = try self.splitArgs(expr[6 .. expr.len - 1]);
            if (args.len != 2) {
                self.runtimeError(24, try std.fmt.allocPrint(self.allocator, "Error at line {d}: Invalid number of arguments for index function.", .{self.current_line}));
                return .none;
            }
            const list_name = std.mem.trim(u8, args[0], " \t");
            const wanted = try self.evalExpr(args[1]);
            if (self.lookupVar(list_name)) |target| {
                if (target == .list) {
                    if (target.list.indexOf(wanted)) |position| return .{ .int = @intCast(position) };
                    const rendered = try value.printString(self.allocator, wanted);
                    self.runtimeError(25, try std.fmt.allocPrint(self.allocator, "Error at line {d}: Value '{s}' not found in list '{s}'.", .{ self.current_line, rendered, list_name }));
                    return .none;
                }
            }
            self.runtimeError(26, try std.fmt.allocPrint(self.allocator, "Error at line {d}: Variable '{s}' is not a list.", .{ self.current_line, list_name }));
            return .none;
        }
        if (std.mem.startsWith(u8, expr, "get(") and isWholeCall(expr, "get")) {
            const args = try self.splitArgs(expr[4 .. expr.len - 1]);
            if (args.len == 2) {
                const dict_name = std.mem.trim(u8, args[0], " \t");
                const key = try self.evalExpr(args[1]);
                if (self.lookupVar(dict_name)) |target| {
                    if (target == .dict) return target.dict.get(key) orelse .none;
                }
            }
            return .none;
        }
        if (std.mem.startsWith(u8, expr, "is_func(") and isWholeCall(expr, "is_func")) {
            const candidate = try self.evalExpr(expr[8 .. expr.len - 1]);
            return .{ .boolean = switch (candidate) {
                .func_ref => true,
                .string => |name| self.functions.contains(name),
                else => false,
            } };
        }
        if (std.mem.startsWith(u8, expr, "join(") and isWholeCall(expr, "join")) {
            const args = try self.splitArgs(expr[5 .. expr.len - 1]);
            if (args.len != 2) return .none;
            const separator = try self.evalExpr(args[0]);
            const sequence = try self.evalExpr(args[1]);
            if (separator != .string) return .none;

            var output: std.Io.Writer.Allocating = .init(self.allocator);
            var first = true;
            const appendItem = struct {
                fn run(writer: *std.Io.Writer, sep: []const u8, is_first: *bool, item: []const u8) !void {
                    if (!is_first.*) try writer.writeAll(sep);
                    try writer.writeAll(item);
                    is_first.* = false;
                }
            }.run;
            switch (sequence) {
                .string => |text| {
                    var offset: usize = 0;
                    while (offset < text.len) {
                        const width = std.unicode.utf8ByteSequenceLength(text[offset]) catch 1;
                        const end = @min(offset + width, text.len);
                        try appendItem(&output.writer, separator.string, &first, text[offset..end]);
                        offset = end;
                    }
                },
                .list, .tuple => |items| {
                    for (items.items.items) |item| {
                        if (item != .string) return .none;
                        try appendItem(&output.writer, separator.string, &first, item.string);
                    }
                },
                else => return .none,
            }
            return .{ .string = try output.toOwnedSlice() };
        }
        if (std.mem.startsWith(u8, expr, "startswith(") and expr[expr.len - 1] == ')') {
            const a = try self.splitArgs(expr[11 .. expr.len - 1]);
            if (a.len == 2) {
                const prefix = try self.evalExpr(a[0]);
                const text = try self.evalExpr(a[1]);
                return .{ .boolean = prefix == .string and text == .string and std.mem.startsWith(u8, text.string, prefix.string) };
            }
        }
        if (std.mem.startsWith(u8, expr, "endswith(") and isWholeCall(expr, "endswith")) {
            const a = try self.splitArgs(expr[9 .. expr.len - 1]);
            if (a.len == 2) {
                const suffix = try self.evalExpr(a[0]);
                const text = try self.evalExpr(a[1]);
                return .{ .boolean = suffix == .string and text == .string and std.mem.endsWith(u8, text.string, suffix.string) };
            }
        }
        if (std.mem.startsWith(u8, expr, "isanumber(") and isWholeCall(expr, "isanumber")) {
            const v = try self.evalExpr(expr[10 .. expr.len - 1]);
            if (self.python) |python| {
                const py_value = try python.toPy(v, false);
                defer py_mod.Py_DecRef(py_value);
                const result = try python.callHelper("is_numeric", &.{py_value});
                defer py_mod.Py_DecRef(result);
                return try python.fromPy(result);
            }
            if (v == .int) return .{ .boolean = v.int >= 0 };
            if (v == .string) {
                if (v.string.len == 0) return .{ .boolean = false };
                for (v.string) |c| if (!std.ascii.isDigit(c)) return .{ .boolean = false };
                return .{ .boolean = true };
            }
            return .{ .boolean = false };
        }
        if (std.mem.startsWith(u8, expr, "randint(") and expr[expr.len - 1] == ')') {
            const a = try self.splitArgs(expr[8 .. expr.len - 1]);
            if (a.len == 2) {
                const lo = value.asInt(try self.evalExpr(a[0])) orelse 0;
                const hi = value.asInt(try self.evalExpr(a[1])) orelse lo;
                return .{ .int = lo + @mod(@as(i64, rand()), @max(hi - lo + 1, 1)) };
            }
        }
        if (findTopLevel(expr, "{")) |brace| {
            const struct_name = std.mem.trim(u8, expr[0..brace], " \t");
            if (self.structs.get(struct_name)) |definition| {
                const close = std.mem.lastIndexOfScalar(u8, expr, '}') orelse return .none;
                const raw_args = try splitCommaOrPipe(self, expr[brace + 1 .. close]);
                const named = try Dict.create(self.allocator);
                const positional = try List.create(self.allocator);
                for (raw_args) |raw| {
                    const arg = std.mem.trim(u8, raw, " \t\r\n");
                    if (arg.len == 0) continue;
                    if (findTopLevel(arg, "=")) |eq| {
                        const key = std.mem.trim(u8, arg[0..eq], " \t");
                        try named.putStr(try self.dup(key), try self.evalExpr(arg[eq + 1 ..]));
                    } else {
                        try positional.append(try self.evalExpr(arg));
                    }
                }
                const instance = try Dict.create(self.allocator);
                instance.type_name = struct_name;
                for (definition.keys.items, definition.values.items, 0..) |key, default, i| {
                    if (key != .string) continue;
                    var field = named.get(key) orelse positional.get(@intCast(i)) orelse default;
                    if (field == .string and std.mem.startsWith(u8, field.string, "@")) {
                        field = try self.evalExpr(field.string);
                    }
                    try instance.put(key, field);
                }
                for (named.keys.items, named.values.items) |key, val| {
                    if (key == .string and instance.get(key) == null) try instance.put(key, val);
                }
                return .{ .dict = instance };
            }
        }
        if (std.mem.startsWith(u8, expr, "len(") and expr[expr.len - 1] == ')') {
            const v = try self.evalExpr(expr[4 .. expr.len - 1]);
            if (self.python) |python| {
                const py_value = try python.toPy(v, false);
                defer py_mod.Py_DecRef(py_value);
                const result = try python.callHelper("length_or_error", &.{py_value});
                defer py_mod.Py_DecRef(result);
                const length = try python.fromPy(result);
                if (length == .string and std.mem.startsWith(u8, length.string, "__PRYZMA_LEN_ERROR__:")) {
                    self.runtimeError(12, try std.fmt.allocPrint(self.allocator, "Error at line {d}: {s}", .{ self.current_line, length.string["__PRYZMA_LEN_ERROR__:".len..] }));
                    self.eval_error = true;
                    return .none;
                }
                return length;
            }
            return .{ .int = @intCast(try self.lengthOf(v)) };
        }
        if (std.mem.startsWith(u8, expr, "type(") and expr[expr.len - 1] == ')') {
            const v = try self.evalExpr(expr[5 .. expr.len - 1]);
            if (v == .py_object) {
                const python = self.python orelse return .{ .string = "python object" };
                const result = try python.callHelper("type_name", &.{@ptrCast(v.py_object)});
                defer py_mod.Py_DecRef(result);
                return try python.fromPy(result);
            }
            return .{ .string = value.typeName(v) };
        }
        if (std.mem.startsWith(u8, expr, "char(") and isWholeCall(expr, "char")) {
            const v = try self.evalExpr(expr[5 .. expr.len - 1]);
            const codepoint: i64 = switch (v) {
                .int => |n| n,
                .boolean => |b| if (b) 1 else 0,
                else => {
                    const type_name: []const u8 = switch (v) {
                        .string => "str",
                        .float => "float",
                        .none => "NoneType",
                        .list => "list",
                        .tuple => "tuple",
                        .dict => "dict",
                        .func_ref => "FuncReference",
                        .extern_fn => "ExternFunction",
                        .py_object => "object",
                        .reference => "Reference",
                        .lazy => "object",
                        .isolate => "object",
                        .int, .boolean => unreachable,
                    };
                    self.runtimeError(12, try std.fmt.allocPrint(self.allocator, "Error at line {d}: '{s}' object cannot be interpreted as an integer", .{ self.current_line, type_name }));
                    self.eval_error = true;
                    return .none;
                },
            };
            if (codepoint < 0 or codepoint > 0x10ffff) {
                self.runtimeError(12, try std.fmt.allocPrint(self.allocator, "Error at line {d}: chr() arg not in range(0x110000)", .{self.current_line}));
                self.eval_error = true;
                return .none;
            }
            if (codepoint >= 0xd800 and codepoint <= 0xdfff) {
                self.runtimeError(12, try std.fmt.allocPrint(self.allocator, "Error at line {d}: 'utf-8' codec can't encode character '\\u{x}' in position 0: surrogates not allowed", .{ self.current_line, codepoint }));
                self.eval_error = true;
                return .none;
            }
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(@intCast(codepoint), &buf) catch return .none;
            return .{ .string = try self.dup(buf[0..n]) };
        }
        if (std.mem.startsWith(u8, expr, "ascii(") and expr[expr.len - 1] == ')') {
            const v = try self.evalExpr(expr[6 .. expr.len - 1]);
            if (v == .string) {
                const count = try self.lengthOf(v);
                if (count != 1) {
                    self.runtimeError(12, try std.fmt.allocPrint(self.allocator, "Error at line {d}: ord() expected a character, but string of length {d} found", .{ self.current_line, count }));
                    self.eval_error = true;
                    return .none;
                }
                const cp = std.unicode.utf8Decode(v.string) catch 0;
                return .{ .int = @intCast(cp) };
            }
            self.runtimeError(12, try std.fmt.allocPrint(self.allocator, "Error at line {d}: ord() expected string of length 1, but {s} found", .{ self.current_line, value.typeName(v) }));
            self.eval_error = true;
            return .none;
        }
        if (std.mem.startsWith(u8, expr, "int(") and expr[expr.len - 1] == ')') {
            const v = try self.evalExpr(expr[4 .. expr.len - 1]);
            if (self.python) |python| {
                const py_value = try python.toPy(v, false);
                defer py_mod.Py_DecRef(py_value);
                const result = try python.callHelper("int_or_error", &.{py_value});
                defer py_mod.Py_DecRef(result);
                const converted = try python.fromPy(result);
                if (converted == .string and std.mem.startsWith(u8, converted.string, "__PRYZMA_INT_ERROR__:")) {
                    const message = converted.string["__PRYZMA_INT_ERROR__:".len..];
                    self.runtimeError(12, try std.fmt.allocPrint(self.allocator, "Error at line {d}: {s}", .{ self.current_line, message }));
                    self.eval_error = true;
                    return .none;
                }
                return converted;
            }
            return .{ .int = value.asInt(v) orelse 0 };
        }
        if (std.mem.startsWith(u8, expr, "str(") and expr[expr.len - 1] == ')') {
            const v = try self.evalExpr(expr[4 .. expr.len - 1]);
            return .{ .string = try value.printString(self.allocator, v) };
        }
        if (std.mem.startsWith(u8, expr, "@")) {
            self.ret_val = .none;
            try self.callStatement(expr[1..]);
            return self.ret_val;
        }
        if (std.mem.startsWith(u8, expr, "&")) {
            const target = std.mem.trim(u8, expr[1..], " \t");
            if (self.variables.contains(target) or self.locals.contains(target)) {
                return .{ .reference = .{ .var_name = try self.dup(target), .addr = self.memory_slots.get(target) } };
            }
            if (self.functions.contains(target)) return .{ .func_ref = try self.dup(target) };
            return .none;
        }
        if (std.mem.startsWith(u8, expr, "*")) {
            const rv = try self.evalExpr(expr[1..]);
            if (rv == .reference) {
                if (rv.reference.addr != null and self.manual_memory_enabled) {
                    const ptr: *const i64 = @ptrFromInt(rv.reference.addr.?);
                    return .{ .int = ptr.* };
                }
                if (self.lookupVar(rv.reference.var_name)) |v| return v;
                if (self.locals.get(rv.reference.var_name)) |entries| {
                    if (entries.items.len > 0) return entries.items[entries.items.len - 1].val;
                }
                self.runtimeError(37, try std.fmt.allocPrint(self.allocator, "Error at line {d}: Referenced variable '{s}' no longer exists", .{ self.current_line, rv.reference.var_name }));
                return .none;
            }
            return rv;
        }
        if (std.mem.startsWith(u8, expr, "[") and expr[expr.len - 1] == ']') {
            const list = try self.allocator.create(List);
            list.* = List.init(self.allocator);
            const items = try self.splitArgs(expr[1 .. expr.len - 1]);
            for (items) |it| {
                const t = std.mem.trim(u8, it, " \t");
                if (t.len != 0) try list.append(try self.evalExpr(t));
            }
            return .{ .list = list };
        }
        if (expr[0] == '{' and expr[expr.len - 1] == '}') {
            const d = try self.allocator.create(Dict);
            d.* = Dict.init(self.allocator);
            const items = try self.splitArgs(expr[1 .. expr.len - 1]);
            for (items) |it| {
                const t = std.mem.trim(u8, it, " \t");
                if (t.len == 0) continue;
                if (std.mem.indexOfScalar(u8, t, ':')) |colon| {
                    const k = try self.evalExpr(std.mem.trim(u8, t[0..colon], " \t"));
                    const v = try self.evalExpr(std.mem.trim(u8, t[colon + 1 ..], " \t"));
                    try d.put(k, v);
                }
            }
            return .{ .dict = d };
        }
        if (findTopLevel(expr, "==")) |p| {
            return .{ .boolean = value.eql(try self.evalExpr(expr[0..p]), try self.evalExpr(expr[p + 2 ..])) };
        }
        if (findTopLevel(expr, " or ")) |p| {
            const left = try self.evalExpr(expr[0..p]);
            if (value.truthy(left)) return left;
            return try self.evalExpr(expr[p + 4 ..]);
        }
        if (findTopLevel(expr, " and ")) |p| {
            const left = try self.evalExpr(expr[0..p]);
            if (!value.truthy(left)) return left;
            return try self.evalExpr(expr[p + 5 ..]);
        }
        if (findTopLevel(expr, "!=")) |p| {
            return .{ .boolean = !value.eql(try self.evalExpr(expr[0..p]), try self.evalExpr(expr[p + 2 ..])) };
        }
        if (findTopLevel(expr, "<=")) |p| {
            const a = try self.evalExpr(expr[0..p]);
            const b = try self.evalExpr(expr[p + 2 ..]);
            return .{ .boolean = if (value.cmp(a, b)) |o| o != .gt else false };
        }
        if (findTopLevel(expr, ">=")) |p| {
            const a = try self.evalExpr(expr[0..p]);
            const b = try self.evalExpr(expr[p + 2 ..]);
            return .{ .boolean = if (value.cmp(a, b)) |o| o != .lt else false };
        }
        if (findTopLevel(expr, "<")) |p| {
            const a = try self.evalExpr(expr[0..p]);
            const b = try self.evalExpr(expr[p + 1 ..]);
            return .{ .boolean = if (value.cmp(a, b)) |o| o == .lt else false };
        }
        if (findTopLevel(expr, ">")) |p| {
            const a = try self.evalExpr(expr[0..p]);
            const b = try self.evalExpr(expr[p + 1 ..]);
            return .{ .boolean = if (value.cmp(a, b)) |o| o == .gt else false };
        }
        if (std.mem.indexOf(u8, expr, "<") != null) {
            const p = std.mem.indexOf(u8, expr, "<").?;
            const a = try self.evalExpr(expr[0..p]);
            const b = try self.evalExpr(expr[p + 1 ..]);
            return .{ .boolean = if (value.cmp(a, b)) |o| o == .lt else false };
        }
        if (std.mem.indexOf(u8, expr, ">") != null) {
            const p = std.mem.indexOf(u8, expr, ">").?;
            const a = try self.evalExpr(expr[0..p]);
            const b = try self.evalExpr(expr[p + 1 ..]);
            return .{ .boolean = if (value.cmp(a, b)) |o| o == .gt else false };
        }
        if (findTopLevel(expr, "+")) |p| {
            const a = try self.evalExpr(expr[0..p]);
            const b = try self.evalExpr(expr[p + 1 ..]);
            return value.add(a, b);
        }
        if (findTopLevel(expr, "-")) |p| {
            if (p > 0 and !std.mem.endsWith(u8, std.mem.trim(u8, expr[0..p], " \t"), "+")) {
                const a = try self.evalExpr(expr[0..p]);
                const b = try self.evalExpr(expr[p + 1 ..]);
                return value.sub(a, b);
            }
        }
        if (findTopLevel(expr, "*")) |p| {
            const a = try self.evalExpr(expr[0..p]);
            const b = try self.evalExpr(expr[p + 1 ..]);
            return value.mul(a, b);
        }
        if (findTopLevel(expr, "/")) |p| {
            const a = try self.evalExpr(expr[0..p]);
            const b = try self.evalExpr(expr[p + 1 ..]);
            return value.div(a, b);
        }
        if (findTopLevel(expr, "%")) |p| {
            const a = try self.evalExpr(expr[0..p]);
            const b = try self.evalExpr(expr[p + 1 ..]);
            return value.mod(a, b);
        }

        if (std.mem.indexOfScalar(u8, expr, '.')) |dot| {
            const base = std.mem.trim(u8, expr[0..dot], " \t");
            const field = std.mem.trim(u8, expr[dot + 1 ..], " \t");
            const obj = if (std.mem.indexOfScalar(u8, base, '[') != null)
                try self.evalExpr(base)
            else
                self.lookupVar(base) orelse {
                    self.runtimeError(28, try std.fmt.allocPrint(self.allocator, "Error at line {d}: Unknown variable or expression: {s}", .{ self.current_line, expr }));
                    return .none;
                };
            return try self.getField(obj, field);
        }
        if (findTopLevel(expr, "[")) |bracket| {
            const base_text = std.mem.trim(u8, expr[0..bracket], " \t");
            var obj = try self.evalExpr(base_text);
            var pos = bracket;
            while (pos < expr.len and expr[pos] == '[') {
                const close = findMatching(expr, pos, '[', ']') orelse break;
                const inner = expr[pos + 1 .. close];
                if (std.mem.indexOfScalar(u8, inner, ':') != null) {
                    obj = try self.sliceValue(obj, inner);
                } else {
                    const idx = try self.evalExpr(inner);
                    obj = try self.indexValue(obj, idx);
                }
                pos = close + 1;
            }
            if (pos < expr.len and expr[pos] == '.') {
                return try self.getField(obj, expr[pos + 1 ..]);
            }
            return obj;
        }

        if (self.lookupVar(expr)) |v| {
            if (v == .lazy) {
                return try self.evalExpr(v.lazy.expr);
            }
            return v;
        }
        self.runtimeError(28, try std.fmt.allocPrint(self.allocator, "Error at line {d}: Unknown variable or expression: {s}", .{ self.current_line, expr }));
        return .none;
    }

    fn lengthOf(self: *Interpreter, v: Value) !usize {
        return switch (v) {
            .string => |s| blk: {
                if (self.python) |python| {
                    const py_text = try python.newString(s);
                    defer py_mod.Py_DecRef(py_text);
                    const result = try python.callHelper("text_length", &.{py_text});
                    defer py_mod.Py_DecRef(result);
                    const length = try python.fromPy(result);
                    break :blk @intCast(value.asInt(length) orelse 0);
                }
                break :blk s.len;
            },
            .list => |l| l.items.items.len,
            .tuple => |t| t.items.items.len,
            .dict => |d| d.keys.items.len,
            else => 0,
        };
    }

    fn sliceValue(self: *Interpreter, obj: Value, slice: []const u8) !Value {
        const colon = std.mem.indexOfScalar(u8, slice, ':') orelse return .none;
        const second = std.mem.indexOfScalarPos(u8, slice, colon + 1, ':');
        const start_text = std.mem.trim(u8, slice[0..colon], " \t");
        const stop_text = std.mem.trim(u8, slice[colon + 1 .. second orelse slice.len], " \t");
        const step_text = if (second) |p| std.mem.trim(u8, slice[p + 1 ..], " \t") else "";
        const step = if (step_text.len == 0) 1 else value.asInt(try self.evalExpr(step_text)) orelse 1;
        if (step == 0) return .none;
        if (obj != .string and obj != .list and obj != .tuple) return .none;
        const length: i64 = @intCast(try self.lengthOf(obj));
        var start: i64 = if (start_text.len == 0) (if (step > 0) 0 else length - 1) else value.asInt(try self.evalExpr(start_text)) orelse 0;
        var stop: i64 = if (stop_text.len == 0) (if (step > 0) length else -1) else value.asInt(try self.evalExpr(stop_text)) orelse length;
        if (start < 0) start += length;
        if (stop < 0 and stop_text.len != 0) stop += length;
        if (step > 0) {
            start = @max(0, @min(start, length));
            stop = @max(0, @min(stop, length));
        } else {
            start = @max(-1, @min(start, length - 1));
            stop = @max(-1, @min(stop, length - 1));
        }
        if (obj == .string) {
            var output: std.Io.Writer.Allocating = .init(self.allocator);
            var i = start;
            while (if (step > 0) i < stop else i > stop) : (i += step) {
                if (i >= 0 and i < length) {
                    const byte_start = stringByteOffset(obj.string, @intCast(i));
                    const byte_end = stringByteOffset(obj.string, @intCast(i + 1));
                    try output.writer.writeAll(obj.string[byte_start..byte_end]);
                }
            }
            return .{ .string = try output.toOwnedSlice() };
        }
        const source = if (obj == .list) obj.list else obj.tuple;
        const result = try List.create(self.allocator);
        var i = start;
        while (if (step > 0) i < stop else i > stop) : (i += step) {
            if (source.get(i)) |item| try result.append(item);
        }
        return if (obj == .list) .{ .list = result } else .{ .tuple = result };
    }

    fn stringByteOffset(text: []const u8, codepoint_index: usize) usize {
        var byte_offset: usize = 0;
        var count: usize = 0;
        while (byte_offset < text.len and count < codepoint_index) : (count += 1) {
            const width = std.unicode.utf8ByteSequenceLength(text[byte_offset]) catch 1;
            byte_offset = @min(byte_offset + width, text.len);
        }
        return byte_offset;
    }

    fn walkDirectory(self: *Interpreter, path: []const u8, result: *value.List) !void {
        const dir = std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        const dirnames = try value.List.create(self.allocator);
        const filenames = try value.List.create(self.allocator);
        var child_names: std.ArrayList([]const u8) = .empty;
        var iterator = dir.iterate();
        while (try iterator.next(self.io)) |entry| {
            const name = try self.dup(entry.name);
            if (entry.kind == .directory) {
                try dirnames.append(.{ .string = name });
                try child_names.append(self.allocator, name);
            } else if (entry.kind == .sym_link) {
                const entry_path = try std.fs.path.join(self.allocator, &.{ path, name });
                const stat: ?std.Io.Dir.Stat = std.Io.Dir.cwd().statFile(self.io, entry_path, .{}) catch null;
                if (stat) |metadata| {
                    if (metadata.kind == .directory) {
                        try dirnames.append(.{ .string = name });
                        continue;
                    }
                }
                try filenames.append(.{ .string = name });
            } else {
                try filenames.append(.{ .string = name });
            }
        }

        const row = try value.List.create(self.allocator);
        try row.append(.{ .string = try self.dup(path) });
        try row.append(.{ .list = dirnames });
        try row.append(.{ .list = filenames });
        try result.append(.{ .tuple = row });

        for (child_names.items) |child_name| {
            const child_path = try std.fs.path.join(self.allocator, &.{ path, child_name });
            try self.walkDirectory(child_path, result);
        }
    }

    fn pythonGlobals(self: *Interpreter) !*py_mod.PyObject {
        const python = self.python orelse return error.PythonUnavailable;
        const dict = py_mod.PyDict_New() orelse return error.PythonError;
        var it = self.variables.iterator();
        while (it.next()) |entry| {
            const key = try python.newString(entry.key_ptr.*);
            const val = try python.toPy(entry.value_ptr.*, false);
            const zkey = try self.allocator.allocSentinel(u8, entry.key_ptr.len, 0);
            @memcpy(zkey, entry.key_ptr.*);
            _ = py_mod.PyDict_SetItemString(dict, zkey, val);
            py_mod.Py_DecRef(key);
            py_mod.Py_DecRef(val);
        }
        return dict;
    }

    fn pythonNamespace(self: *Interpreter, namespace: Value) !*py_mod.PyObject {
        const python = self.python orelse return error.PythonUnavailable;
        if (namespace != .dict) return error.PythonError;
        const dict = py_mod.PyDict_New() orelse return error.PythonError;
        for (namespace.dict.keys.items, namespace.dict.values.items) |key_value, item_value| {
            if (key_value != .string) continue;
            const key = try self.allocator.allocSentinel(u8, key_value.string.len, 0);
            @memcpy(key, key_value.string);
            const item = try python.toPy(item_value, false);
            defer py_mod.Py_DecRef(item);
            _ = py_mod.PyDict_SetItemString(dict, key, item);
        }
        return dict;
    }

    fn copyPythonDictToValue(self: *Interpreter, source: *py_mod.PyObject, destination: *value.Dict) !void {
        const python = self.python orelse return;
        destination.keys.clearRetainingCapacity();
        destination.values.clearRetainingCapacity();
        var pos: isize = 0;
        var key: ?*py_mod.PyObject = null;
        var item: ?*py_mod.PyObject = null;
        while (py_mod.PyDict_Next(source, &pos, &key, &item) != 0) {
            const converted_key = try python.fromPy(key.?);
            const converted_value = try python.fromPy(item.?);
            try destination.put(converted_key, converted_value);
        }
    }

    fn copyGlobalsFromPython(self: *Interpreter, dict: *py_mod.PyObject) !void {
        const python = self.python orelse return;
        var pos: isize = 0;
        var key: ?*py_mod.PyObject = null;
        var val: ?*py_mod.PyObject = null;
        while (py_mod.PyDict_Next(dict, &pos, &key, &val) != 0) {
            const k = try python.fromPy(key.?);
            if (k != .string or std.mem.startsWith(u8, k.string, "__")) continue;
            try self.setVar(k.string, try python.fromPy(val.?));
        }
    }

    fn indexValue(self: *Interpreter, obj: Value, idx: Value) !Value {
        switch (obj) {
            .list => |l| {
                if (value.asInt(idx)) |i| {
                    if (l.get(i)) |v| return v;
                }
                self.runtimeError(43, try std.fmt.allocPrint(self.allocator, "Error at line {d}: Indexing error", .{self.current_line}));
                return .none;
            },
            .tuple => |t| {
                if (value.asInt(idx)) |i| {
                    if (t.get(i)) |v| return v;
                }
                return .none;
            },
            .string => |s| {
                if (value.asInt(idx)) |i| {
                    const n: i64 = @intCast(try self.lengthOf(.{ .string = s }));
                    const j = if (i < 0) i + n else i;
                    if (j >= 0 and j < n) {
                        const start = stringByteOffset(s, @intCast(j));
                        const end = stringByteOffset(s, @intCast(j + 1));
                        return .{ .string = try self.dup(s[start..end]) };
                    }
                }
                return .none;
            },
            .dict => |d| {
                if (d.get(idx)) |v| return v;
                self.runtimeError(43, try std.fmt.allocPrint(self.allocator, "Error at line {d}: Indexing error", .{self.current_line}));
                return .none;
            },
            else => return .none,
        }
    }

    fn setIndex(self: *Interpreter, obj: Value, idx: Value, v: Value) !void {
        _ = self;
        switch (obj) {
            .list => |l| {
                if (value.asInt(idx)) |i| _ = l.set(i, v);
            },
            .dict => |d| try d.put(idx, v),
            else => {},
        }
    }

    fn getField(self: *Interpreter, obj: Value, field_in: []const u8) !Value {
        var field = std.mem.trim(u8, field_in, " \t");
        if (findTopLevel(field, ".")) |dot| {
            const left = try self.getField(obj, field[0..dot]);
            return try self.getField(left, field[dot + 1 ..]);
        }
        if (std.mem.indexOfScalar(u8, field, '[')) |bracket| {
            if (field.len > 0 and field[field.len - 1] == ']') {
                const base = try self.getField(obj, field[0..bracket]);
                const idx = try self.evalExpr(field[bracket + 1 .. field.len - 1]);
                return try self.indexValue(base, idx);
            }
        }
        if (obj == .reference) {
            if (self.lookupVar(obj.reference.var_name)) |v| return try self.getField(v, field);
        }
        if (obj == .dict) {
            if (obj.dict.getStr(field)) |v| return v;
        }
        self.runtimeError(44, try std.fmt.allocPrint(self.allocator, "Error at line {d}: Field '{s}' not found on object", .{ self.current_line, field }));
        return .none;
    }

    fn setField(self: *Interpreter, obj: Value, field: []const u8, v: Value) !void {
        if (obj == .reference) {
            if (self.lookupVar(obj.reference.var_name)) |base| return self.setField(base, field, v);
        }
        if (obj == .dict) {
            try obj.dict.put(.{ .string = try self.dup(field) }, v);
            return;
        }
        self.runtimeError(44, try std.fmt.allocPrint(self.allocator, "Error at line {d}: Field '{s}' not found on object", .{ self.current_line, field }));
    }

    pub fn inputLine(self: *Interpreter, prompt: []const u8) ![]const u8 {
        if (prompt.len != 0) self.out(prompt);
        if (self.stdin_reader == null) self.stdin_reader = std.Io.File.stdin().reader(self.io, &self.stdin_buf);
        const line = self.stdin_reader.?.interface.takeDelimiter('\n') catch return "";
        if (line) |l| return try self.dup(l);
        return "";
    }

    fn debugPrompt(self: *Interpreter, line: []const u8) !void {
        var at_breakpoint = false;
        for (self.breakpoints.items) |bp| if (bp == self.current_line) {
            at_breakpoint = true;
            break;
        };
        if (self.debug_continue) {
            if (!at_breakpoint) return;
            self.debug_continue = false;
        } else if (self.debug_step_once) {
            self.debug_step_once = false;
        } else if (self.breakpoints.items.len != 0 and !at_breakpoint) {
            return;
        }
        if (!self.debug_session_started) {
            self.debug_session_started = true;
            try self.logDebug("Debugger started.");
        }
        try self.logDebug(try std.fmt.allocPrint(self.allocator, "Executing line {d}: {s}", .{ self.current_line, line }));
        self.printFmt("Debug: Executing line {d}: {s}\n", .{ self.current_line, line });
        while (self.debug) {
            self.out("debug> ");
            const raw = try self.inputLine("");
            const cmd = std.mem.trim(u8, raw, " \t\r\n");
            if (std.mem.eql(u8, cmd, "s") or std.mem.eql(u8, cmd, "")) {
                self.debug_step_once = true;
                try self.logDebug("User chose to step.");
                return;
            }
            if (std.mem.eql(u8, cmd, "c")) {
                self.debug_continue = true;
                try self.logDebug("User chose to continue to the next breakpoint.");
                return;
            }
            if (std.mem.eql(u8, cmd, "exit")) {
                self.debug = false;
                return;
            }
            if (std.mem.eql(u8, cmd, "help")) {
                self.out(
                    \\Available commands:
                    \\s: Step to the next line
                    \\c: Continue to the next breakpoint
                    \\b <line>: Add a breakpoint at the specified line number
                    \\r <line>: Remove a breakpoint at the specified line number
                    \\l: List all current breakpoints
                    \\v: View all variables
                    \\f: View all functions
                    \\st: View all structs
                    \\! <pryzma code>: Run Pryzma code
                    \\!! <python code>: Run Python code
                    \\log: Set the log file name (default is log.txt)
                    \\clear: Clear the screen
                    \\exit: Exit the debugger
                    \\help: Show this help message
                    \\
                );
                continue;
            }
            if (std.mem.eql(u8, cmd, "clear")) {
                self.out("\x1b[2J\x1b[H");
                continue;
            }
            if (std.mem.eql(u8, cmd, "l")) {
                const sorted = try self.allocator.dupe(usize, self.breakpoints.items);
                for (sorted, 0..) |_, i| {
                    for (i + 1..sorted.len) |j| {
                        if (sorted[i] > sorted[j]) std.mem.swap(usize, &sorted[i], &sorted[j]);
                    }
                }
                self.out("Breakpoints: [");
                for (sorted, 0..) |bp, i| {
                    if (i != 0) self.out(", ");
                    self.printFmt("{d}", .{bp});
                }
                self.out("]\n");
                continue;
            }
            if (std.mem.eql(u8, cmd, "v")) {
                var vars = self.variables.iterator();
                while (vars.next()) |entry| {
                    const rendered = try value.repr(self.allocator, entry.value_ptr.*);
                    self.printFmt("{s} = {s}\n", .{ entry.key_ptr.*, rendered });
                }
                continue;
            }
            if (std.mem.eql(u8, cmd, "f")) {
                var funcs = self.functions.iterator();
                while (funcs.next()) |entry| self.printFmt("{s}\n", .{entry.key_ptr.*});
                continue;
            }
            if (std.mem.eql(u8, cmd, "st")) {
                self.out("Structs: ");
                var structs = self.structs.iterator();
                var first = true;
                while (structs.next()) |entry| {
                    if (!first) self.out(", ");
                    first = false;
                    const rendered = try value.repr(self.allocator, .{ .dict = entry.value_ptr.* });
                    self.printFmt("{s}: {s}", .{ entry.key_ptr.*, rendered });
                }
                self.out("\n");
                continue;
            }
            if (std.mem.startsWith(u8, cmd, "!!")) {
                const python = self.python orelse continue;
                const globals = try self.pythonGlobals();
                const code = std.mem.trim(u8, cmd[2..], " \t");
                python.execString(code, globals, globals) catch {
                    py_mod.PyErr_Print();
                    py_mod.PyErr_Clear();
                    py_mod.Py_DecRef(globals);
                    continue;
                };
                try self.copyGlobalsFromPython(globals);
                py_mod.Py_DecRef(globals);
                try self.logDebug(try std.fmt.allocPrint(self.allocator, "Run code: {s}", .{code}));
                continue;
            }
            if (std.mem.startsWith(u8, cmd, "!") and !std.mem.startsWith(u8, cmd, "!!")) {
                const was_debugging = self.debug;
                self.debug = false;
                const code = std.mem.trim(u8, cmd[1..], " \t");
                try self.interpret(code);
                self.debug = was_debugging;
                try self.logDebug(try std.fmt.allocPrint(self.allocator, "Run code: {s}", .{code}));
                self.out("\n\n");
                continue;
            }
            if (std.mem.startsWith(u8, cmd, "b ")) {
                const n = std.fmt.parseInt(usize, std.mem.trim(u8, cmd[2..], " \t"), 10) catch continue;
                if (n != 0) {
                    try self.breakpoints.append(self.allocator, n - 1);
                    try self.logDebug(try std.fmt.allocPrint(self.allocator, "Breakpoint added at line {d}.", .{n}));
                }
                continue;
            }
            if (std.mem.startsWith(u8, cmd, "r ")) {
                const n = std.fmt.parseInt(usize, std.mem.trim(u8, cmd[2..], " \t"), 10) catch continue;
                for (self.breakpoints.items, 0..) |bp, i| if (bp == n) {
                    _ = self.breakpoints.orderedRemove(i);
                    try self.logDebug(try std.fmt.allocPrint(self.allocator, "Breakpoint removed at line {d}.", .{n}));
                    break;
                };
            }
            if (std.mem.eql(u8, cmd, "log")) {
                self.out("Enter log file name (press Enter for 'log.txt'): ");
                const requested = std.mem.trim(u8, try self.inputLine(""), " \t\r\n");
                self.debug_log_file = try self.dup(if (requested.len == 0) "log.txt" else requested);
                self.printFmt("Logging to {s}\n", .{self.debug_log_file.?});
                try self.logDebug(try std.fmt.allocPrint(self.allocator, "Log file set to: {s}", .{self.debug_log_file.?}));
                continue;
            }
        }
    }

    fn logDebug(self: *Interpreter, message: []const u8) !void {
        const path = self.debug_log_file orelse return;
        const python = self.python orelse return;
        const path_obj = try python.newString(path);
        defer py_mod.Py_DecRef(path_obj);
        const text_obj = try python.newString(try std.fmt.allocPrint(self.allocator, "{s}\n", .{message}));
        defer py_mod.Py_DecRef(text_obj);
        const result = try python.callHelper("append_text", &.{ path_obj, text_obj });
        py_mod.Py_DecRef(result);
    }

    pub fn ppmCommand(self: *Interpreter, command_line: []const u8) !void {
        const python = self.python orelse return;
        const executable: Value = self.variables.get("interpreter_path") orelse .{ .string = "pryzma" };
        const exe_path = if (executable == .string) executable.string else "pryzma";
        const root = std.fs.path.dirname(exe_path) orelse ".";
        const args = try List.create(self.allocator);
        var tokens = std.mem.tokenizeAny(u8, command_line, " \t\r\n");
        while (tokens.next()) |token| try args.append(.{ .string = try self.dup(token) });
        const py_root = try python.newString(root);
        const py_args = try python.toPy(.{ .list = args }, false);
        const result = try python.callHelper("ppm_command", &.{ py_root, py_args });
        py_mod.Py_DecRef(result);
        py_mod.Py_DecRef(py_root);
        py_mod.Py_DecRef(py_args);
    }
};

fn isIntegerLiteral(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        for (s[2..]) |c| {
            if (!std.ascii.isHex(c)) return false;
        }
        return true;
    }
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn optionalNameEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn findTopLevel(text: []const u8, needle: []const u8) ?usize {
    var depth: i64 = 0;
    var quote: u8 = 0;
    var escaped = false;
    var i: usize = 0;
    while (i + needle.len <= text.len) : (i += 1) {
        const c = text[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            continue;
        }
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            continue;
        }
        if (depth == 0 and std.mem.startsWith(u8, text[i..], needle)) return i;
        if (c == '(' or c == '[' or c == '{') {
            depth += 1;
            continue;
        }
        if (c == ')' or c == ']' or c == '}') {
            depth -= 1;
            continue;
        }
    }
    return null;
}

fn splitCommaOrPipe(interp: *Interpreter, text: []const u8) ![]const []const u8 {
    var normalized: std.ArrayList(u8) = .empty;
    var depth: i64 = 0;
    var quote: u8 = 0;
    var escaped = false;
    for (text) |c| {
        if (escaped) {
            try normalized.append(interp.allocator, c);
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            try normalized.append(interp.allocator, c);
            continue;
        }
        if (quote != 0) {
            if (c == quote) quote = 0;
            try normalized.append(interp.allocator, c);
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
        } else if (c == '(' or c == '[' or c == '{') {
            depth += 1;
        } else if (c == ')' or c == ']' or c == '}') {
            depth -= 1;
        }
        try normalized.append(interp.allocator, if (depth == 0 and c == '|') ',' else c);
    }
    return interp.splitArgs(normalized.items);
}

fn splitOutsideStrings(interp: *Interpreter, text: []const u8, delimiter: u8) ![]const []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var quote: u8 = 0;
    var escaped = false;
    var start: usize = 0;
    for (text, 0..) |c, i| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            continue;
        }
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
        } else if (c == delimiter) {
            try parts.append(interp.allocator, text[start..i]);
            start = i + 1;
        }
    }
    try parts.append(interp.allocator, text[start..]);
    return parts.toOwnedSlice(interp.allocator);
}

const QuotedWord = struct {
    value: []const u8,
    end: usize,
};

fn parseQuotedOrWord(text: []const u8) ?QuotedWord {
    if (text.len == 0) return null;
    if (text[0] == '"' or text[0] == '\'') {
        const quote = text[0];
        var i: usize = 1;
        while (i < text.len) : (i += 1) {
            if (text[i] == quote and (i == 0 or text[i - 1] != '\\')) {
                return .{ .value = text[1..i], .end = i + 1 };
            }
        }
        return null;
    }
    const end = std.mem.indexOfAny(u8, text, " \t") orelse text.len;
    return .{ .value = text[0..end], .end = end };
}

fn isWholeCall(expr: []const u8, name: []const u8) bool {
    if (!std.mem.startsWith(u8, expr, name) or expr.len <= name.len or expr[name.len] != '(') return false;
    return findMatching(expr, name.len, '(', ')') == expr.len - 1;
}

fn lastPathPart(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '.')) |p| path[p + 1 ..] else path;
}

fn asmRegCode(reg: []const u8) ?u8 {
    const names = [_][]const u8{ "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15" };
    for (names, 0..) |name, i| if (std.mem.eql(u8, reg, name)) return @intCast(i);
    return null;
}

fn isAsmRegister(reg: []const u8) bool {
    return asmRegCode(reg) != null;
}

fn asmRegModRm(dst: []const u8, src: []const u8) u8 {
    return 0xc0 | ((asmRegCode(src) orelse 0) & 7) << 3 | ((asmRegCode(dst) orelse 0) & 7);
}

fn asmRegRip(dst: []const u8) u8 {
    return 0x05 | ((asmRegCode(dst) orelse 0) & 7) << 3;
}

fn asmRegStoreRip(src: []const u8) u8 {
    return 0x05 | ((asmRegCode(src) orelse 0) & 7) << 3;
}

fn appendMovImm64(allocator: Allocator, code: *std.ArrayList(u8), reg: []const u8, imm: i64) !void {
    const n = asmRegCode(reg) orelse return;
    try code.append(allocator, if (n >= 8) 0x49 else 0x48);
    try code.append(allocator, 0xb8 + (n & 7));
    try code.appendSlice(allocator, &@as([8]u8, @bitCast(imm)));
}

fn appendI32(allocator: Allocator, code: *std.ArrayList(u8), imm: i32) !void {
    try code.appendSlice(allocator, &@as([4]u8, @bitCast(imm)));
}

fn appendRipMem(allocator: Allocator, code: *std.ArrayList(u8), prefix: []const u8, slot: usize, start: usize) !void {
    try code.appendSlice(allocator, prefix);
    const next_instruction = start + prefix.len + 4;
    const displacement: i32 = @intCast(@as(isize, @intCast(slot)) - @as(isize, @intCast(next_instruction)));
    try appendI32(allocator, code, displacement);
}

fn findMatching(s: []const u8, start: usize, open: u8, close: u8) ?usize {
    var depth: i64 = 0;
    var in_str = false;
    var i = start;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '"') in_str = !in_str;
        if (in_str) continue;
        if (c == open) depth += 1 else if (c == close) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}
