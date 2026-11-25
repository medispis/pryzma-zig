const std = @import("std");
const Allocator = std.mem.Allocator;
const value = @import("value.zig");
const py_mod = @import("py.zig");
const Value = value.Value;
const List = value.List;
const Dict = value.Dict;
extern "c" fn rand() c_int;

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
    unpack_: bool = false,
    in_loop: bool = false,
    main_file: i64 = 1,
    asm_backend: []const u8 = "emu",
    manual_memory_enabled: bool = false,

    lines_map: std.ArrayList(LineMap) = .empty,
    lines_map_done: bool = false,

    mem: [4096]u8 = @splat(0),

    file_path: []const u8 = "",
    stdin_buf: [65536]u8 = undefined,
    stdin_reader: ?std.Io.Reader = null,

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
        return self.variables.get(name);
    }

    pub fn definedName(self: *Interpreter, name: []const u8) bool {
        return self.variables.contains(name) or self.locals.contains(name) or self.functions.contains(name);
    }

    pub fn runtimeError(self: *Interpreter, code: i64, message: []const u8) void {
        self.err = code;
        if (!self.in_try_block) {
            self.variables.put("err", .{ .int = code }) catch {};
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
                        try replaced_lines.append(self.allocator, try std.mem.replaceOwned(u8, self.allocator, line, astr, bstr));
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
        try self.setVar("argv", .{ .list = argv_list });
        try self.setVar("__file__", .{ .string = try self.dup(self.file_path) });

        const data = std.Io.Dir.cwd().readFileAlloc(self.io, self.file_path, self.allocator, .limited(64 * 1024 * 1024)) catch {
            self.printFmt("File '{s}' not found.\n", .{self.file_path});
            return;
        };
        if (data.len >= 3 and std.mem.eql(u8, data[0..3], "prz")) {
            self.runtimeError(12, "Packed files require CPython support");
            return;
        }
        try self.preInterpret(data);
    }

    pub fn interpret(self: *Interpreter, line_in: []const u8) anyerror!void {
        var it = std.mem.splitScalar(u8, line_in, ';');
        while (it.next()) |piece| {
            var line = piece;
            if (self.main_file < 1) self.no_preproc = false;
            self.main_file -= 1;
            if (!self.in_func.items[self.in_func.items.len - 1]) self.current_line = 0;

            for (self.lines_map.items, 0..) |entry, idx| {
                if (entry.text.len != 0 and std.mem.startsWith(u8, line, entry.text)) {
                    if (!self.in_loop) _ = self.lines_map.orderedRemove(idx);
                    self.current_line = entry.num + 1;
                    break;
                }
            }
            line = std.mem.trim(u8, line, " \t\r\n");
            if (line.len == 0 or std.mem.startsWith(u8, line, "//")) continue;

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
        } else if (std.mem.startsWith(u8, line, "struct ")) {
            try self.defineStruct(line);
        } else if (std.mem.startsWith(u8, line, "append ")) {
            const args = try self.splitArgs(line[7..]);
            if (args.len == 2) {
                const name = std.mem.trim(u8, args[0], " \t");
                if (self.lookupVar(name)) |v| {
                    if (v == .list) try v.list.append(try self.evalExpr(args[1]));
                }
            }
        } else if (std.mem.startsWith(u8, line, "json_dump(") and line[line.len - 1] == ')') {
            _ = try self.evalExpr(line);
        } else if (std.mem.startsWith(u8, line, "remove_path(") and line[line.len - 1] == ')') {
            const path = try self.evalExpr(line[12 .. line.len - 1]);
            if (path == .string) std.Io.Dir.cwd().deleteFile(self.io, path.string) catch {};
        } else if (std.mem.startsWith(u8, line, "write(") and line[line.len - 1] == ')') {
            const a = try self.splitArgs(line[6 .. line.len - 1]);
            if (a.len == 2) {
                const addr = value.asInt(try self.evalExpr(a[0])) orelse 0;
                const data = value.asInt(try self.evalExpr(a[1])) orelse 0;
                if (addr >= 0 and addr < self.mem.len) self.mem[@intCast(addr)] = @truncate(@as(u64, @bitCast(data)));
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

    fn processPragma(self: *Interpreter, line: []const u8) !void {
        const pragma = std.mem.trim(u8, line[1..], " \t");
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
        if (std.mem.eql(u8, directive, "amm")) self.manual_memory_enabled = false;
    }

    fn defineStruct(self: *Interpreter, line: []const u8) !void {
        const open = std.mem.indexOfScalar(u8, line, '{') orelse return;
        const close = std.mem.lastIndexOfScalar(u8, line, '}') orelse return;
        const name = std.mem.trim(u8, line[7..open], " \t");
        const fields = try self.splitArgs(line[open + 1 .. close]);
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
        _ = try self.callFunction(name, arg_values.items);
    }

    pub fn callFunction(self: *Interpreter, name_in: []const u8, args: []Value) anyerror!Value {
        var name = name_in;
        if (self.lookupVar(name)) |v| {
            switch (v) {
                .func_ref => |n| name = n,
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

        const result = self.ret_val;
        _ = self.in_func.pop();
        _ = self.function_tracker.pop();
        _ = self.function_ids.pop();
        return result;
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
        while (true) {
            const cv = try self.evalExpr(cond);
            if (!value.truthy(cv)) break;
            try self.runBody(body);
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
        self.in_loop = true;
        defer self.in_loop = false;
        var i = start_v;
        while (i < end_v) : (i += 1) {
            try self.setVar(var_name, .{ .int = i });
            try self.runBody(body);
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
        for (list.items.items) |item| {
            try self.setVar(var_name, item);
            try self.runBody(body);
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
        var name = target;
        if (std.mem.startsWith(u8, name, "*")) {
            name = std.mem.trim(u8, name[1..], " \t");
            const rv = self.lookupVar(name) orelse .none;
            if (rv == .reference) {
                const ref = rv.reference;
                if (ref.addr != null and self.manual_memory_enabled) {
                    const ptr: *i64 = @ptrFromInt(ref.addr.?);
                    ptr.* = value.asInt(v) orelse 0;
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
            try self.setField(obj, std.mem.trim(u8, rest, " \t"), v);
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
                    try self.setIndex(obj, idx_v, v);
                    return;
                }
                pos = close + 1;
            }
            return;
        }
        if (self.locals.contains(name)) {
            try self.setLocalByName(name, v);
        } else {
            try self.setVar(name, v);
        }
    }

    fn setLocalByName(self: *Interpreter, name: []const u8, v: Value) !void {
        const entries = self.locals.getPtr(name) orelse return;
        var i = entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = &entries.items[i];
            if (optionalNameEql(e.func_name, self.function_tracker.items[self.function_tracker.items.len - 1]) and
                e.func_id == self.function_ids.items[self.function_ids.items.len - 1])
            {
                e.val = v;
                return;
            }
        }
        try entries.append(self.allocator, .{ .val = v, .func_name = self.function_tracker.items[self.function_tracker.items.len - 1], .func_id = self.function_ids.items[self.function_ids.items.len - 1] });
    }

    fn incrementVar(self: *Interpreter, target: []const u8, expr: []const u8) !void {
        const cur = self.lookupVar(target) orelse .none;
        const add = try self.evalExpr(expr);
        const nv = value.add(cur, add);
        try self.setVar(target, nv);
    }

    fn decrementVar(self: *Interpreter, target: []const u8, expr: []const u8) !void {
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
            const v = try self.evalExpr(p);
            if (self.in_try_block and v == .none) continue;
            const s = try value.printString(self.allocator, v);
            const replaced = try std.mem.replaceOwned(u8, self.allocator, s, "\\n", "\n");
            self.out(replaced);
        }
    }

    pub fn evalExpr(self: *Interpreter, expr_in: []const u8) anyerror!Value {
        var expr = std.mem.trim(u8, expr_in, " \t\r\n");
        if (expr.len == 0) return .none;

        if (isIntegerLiteral(expr)) {
            return .{ .int = std.fmt.parseInt(i64, expr, 0) catch 0 };
        }
        if (expr.len >= 2 and ((expr[0] == '"' and expr[expr.len - 1] == '"') or (expr[0] == '\'' and expr[expr.len - 1] == '\''))) {
            return .{ .string = try self.dup(expr[1 .. expr.len - 1]) };
        }
        if (std.mem.eql(u8, expr, "True")) return .{ .boolean = true };
        if (std.mem.eql(u8, expr, "False")) return .{ .boolean = false };
        if (std.mem.eql(u8, expr, "None")) return .none;

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
                    const globals = try self.pythonGlobals();
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
        if (std.mem.startsWith(u8, expr, "pyexec(") and expr[expr.len - 1] == ')') {
            const a = try self.splitArgs(expr[7 .. expr.len - 1]);
            if (a.len > 0) {
                const src = try self.evalExpr(a[0]);
                if (src == .string) {
                    const python = self.python orelse return .none;
                    const globals = try self.pythonGlobals();
                    python.execString(src.string, globals, globals) catch py_mod.PyErr_Clear();
                    try self.copyGlobalsFromPython(globals);
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
                    const result = try List.create(self.allocator);
                    var parts = std.mem.splitSequence(u8, src.string, sep.string);
                    while (parts.next()) |part| try result.append(.{ .string = part });
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
            if (v == .string) return .{ .string = std.mem.trim(u8, v.string, " \t\r\n") };
        }
        if (std.mem.startsWith(u8, expr, "randint(") and expr[expr.len - 1] == ')') {
            const a = try self.splitArgs(expr[8 .. expr.len - 1]);
            if (a.len == 2) {
                const lo = value.asInt(try self.evalExpr(a[0])) orelse 0;
                const hi = value.asInt(try self.evalExpr(a[1])) orelse lo;
                return .{ .int = lo + @mod(@as(i64, rand()), @max(hi - lo + 1, 1)) };
            }
        }
        if (std.mem.startsWith(u8, expr, "len(") and expr[expr.len - 1] == ')') {
            const v = try self.evalExpr(expr[4 .. expr.len - 1]);
            return .{ .int = @intCast(try self.lengthOf(v)) };
        }
        if (std.mem.startsWith(u8, expr, "type(") and expr[expr.len - 1] == ')') {
            const v = try self.evalExpr(expr[5 .. expr.len - 1]);
            return .{ .string = value.typeName(v) };
        }
        if (std.mem.startsWith(u8, expr, "char(") and expr[expr.len - 1] == ')') {
            const v = try self.evalExpr(expr[5 .. expr.len - 1]);
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(@intCast(value.asInt(v) orelse 0), &buf) catch return .none;
            return .{ .string = try self.dup(buf[0..n]) };
        }
        if (std.mem.startsWith(u8, expr, "ascii(") and expr[expr.len - 1] == ')') {
            const v = try self.evalExpr(expr[6 .. expr.len - 1]);
            if (v == .string and v.string.len > 0) {
                const cp = std.unicode.utf8Decode(v.string) catch 0;
                return .{ .int = @intCast(cp) };
            }
            return .{ .int = 0 };
        }
        if (std.mem.startsWith(u8, expr, "int(") and expr[expr.len - 1] == ')') {
            const v = try self.evalExpr(expr[4 .. expr.len - 1]);
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
                return .{ .reference = .{ .var_name = try self.dup(target) } };
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
            const obj = self.lookupVar(base) orelse {
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
                const idx = try self.evalExpr(expr[pos + 1 .. close]);
                obj = try self.indexValue(obj, idx);
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
        _ = self;
        return switch (v) {
            .string => |s| s.len,
            .list => |l| l.items.items.len,
            .tuple => |t| t.items.items.len,
            .dict => |d| d.keys.items.len,
            else => 0,
        };
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
                    const n: i64 = @intCast(s.len);
                    const j = if (i < 0) i + n else i;
                    if (j >= 0 and j < n) return .{ .string = try self.dup(s[@intCast(j)..@intCast(j + 1)]) };
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
        const line = self.stdin_reader.?.takeDelimiter('\n') catch return "";
        if (line) |l| return try self.dup(l);
        return "";
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
