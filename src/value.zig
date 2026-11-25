const std = @import("std");
const Allocator = std.mem.Allocator;

pub const PyObject = anyopaque;

pub const Reference = struct {
    var_name: []const u8,
    addr: ?usize = null,
};

pub const ExternFn = struct {
    callable: *PyObject,
    name: []const u8 = "",
    is_c: bool = false,
};

pub const Lazy = struct {
    interp: *anyopaque,
    expr: []const u8,
};

pub const List = struct {
    allocator: Allocator,
    items: std.ArrayList(Value) = .empty,

    pub fn init(allocator: Allocator) List {
        return .{ .allocator = allocator };
    }

    pub fn create(allocator: Allocator) !*List {
        const l = try allocator.create(List);
        l.* = init(allocator);
        return l;
    }

    pub fn append(self: *List, v: Value) !void {
        try self.items.append(self.allocator, v);
    }

    pub fn appendSlice(self: *List, vs: []const Value) !void {
        try self.items.appendSlice(self.allocator, vs);
    }

    pub fn len(self: *const List) usize {
        return self.items.items.len;
    }

    pub fn get(self: *const List, index: i64) ?Value {
        const n: i64 = @intCast(self.items.items.len);
        const i = if (index < 0) index + n else index;
        if (i < 0 or i >= n) return null;
        return self.items.items[@intCast(i)];
    }

    pub fn set(self: *List, index: i64, v: Value) bool {
        const n: i64 = @intCast(self.items.items.len);
        const i = if (index < 0) index + n else index;
        if (i < 0 or i >= n) return false;
        self.items.items[@intCast(i)] = v;
        return true;
    }

    pub fn popAt(self: *List, index: i64) ?Value {
        const n: i64 = @intCast(self.items.items.len);
        const i = if (index < 0) index + n else index;
        if (i < 0 or i >= n) return null;
        return self.items.orderedRemove(@intCast(i));
    }

    pub fn pop(self: *List) ?Value {
        return self.items.pop();
    }

    pub fn removeValue(self: *List, v: Value) bool {
        for (self.items.items, 0..) |item, i| {
            if (eql(item, v)) {
                _ = self.items.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn indexOf(self: *const List, v: Value) ?usize {
        for (self.items.items, 0..) |item, i| {
            if (eql(item, v)) return i;
        }
        return null;
    }

    pub fn insertAt(self: *List, index: usize, v: Value) !void {
        try self.items.insert(self.allocator, index, v);
    }
};

pub const Dict = struct {
    allocator: Allocator,
    keys: std.ArrayList(Value) = .empty,
    values: std.ArrayList(Value) = .empty,
    type_name: ?[]const u8 = null,

    pub fn init(allocator: Allocator) Dict {
        return .{ .allocator = allocator };
    }

    pub fn create(allocator: Allocator) !*Dict {
        const d = try allocator.create(Dict);
        d.* = init(allocator);
        return d;
    }

    pub fn len(self: *const Dict) usize {
        return self.keys.items.len;
    }

    pub fn indexOf(self: *const Dict, key: Value) ?usize {
        for (self.keys.items, 0..) |k, i| {
            if (eql(k, key)) return i;
        }
        return null;
    }

    pub fn get(self: *const Dict, key: Value) ?Value {
        if (self.indexOf(key)) |i| return self.values.items[i];
        return null;
    }

    pub fn getStr(self: *const Dict, key: []const u8) ?Value {
        return self.get(.{ .string = key });
    }

    pub fn put(self: *Dict, key: Value, v: Value) !void {
        if (self.indexOf(key)) |i| {
            self.values.items[i] = v;
            return;
        }
        try self.keys.append(self.allocator, key);
        try self.values.append(self.allocator, v);
    }

    pub fn putStr(self: *Dict, key: []const u8, v: Value) !void {
        try self.put(.{ .string = key }, v);
    }

    pub fn remove(self: *Dict, key: Value) ?Value {
        if (self.indexOf(key)) |i| {
            _ = self.keys.orderedRemove(i);
            return self.values.orderedRemove(i);
        }
        return null;
    }

    pub fn copy(self: *const Dict) !*Dict {
        const d = try create(self.allocator);
        d.type_name = self.type_name;
        try d.keys.appendSlice(self.allocator, self.keys.items);
        try d.values.appendSlice(self.allocator, self.values.items);
        return d;
    }
};

pub const Value = union(enum) {
    none,
    boolean: bool,
    int: i64,
    float: f64,
    string: []const u8,
    list: *List,
    dict: *Dict,
    tuple: *List,
    reference: Reference,
    func_ref: []const u8,
    extern_fn: *ExternFn,
    py_object: *PyObject,
    lazy: *Lazy,
    isolate: *anyopaque,
};

pub fn truthy(v: Value) bool {
    return switch (v) {
        .none => false,
        .boolean => |b| b,
        .int => |i| i != 0,
        .float => |f| f != 0,
        .string => |s| s.len != 0,
        .list => |l| l.items.items.len != 0,
        .dict => |d| d.keys.items.len != 0,
        .tuple => |t| t.items.items.len != 0,
        else => true,
    };
}

pub fn typeName(v: Value) []const u8 {
    return switch (v) {
        .none => "NoneType",
        .boolean => "bool",
        .int => "int",
        .float => "float",
        .string => "str",
        .list => "list",
        .dict => |d| d.type_name orelse "dict",
        .tuple => "tuple",
        .reference => "Reference",
        .func_ref => "FuncReference",
        .extern_fn => "function",
        .py_object => "object",
        .lazy => "function",
        .isolate => "PryzmaInterpreter",
    };
}

pub fn isNumber(v: Value) bool {
    return switch (v) {
        .int, .float, .boolean => true,
        else => false,
    };
}

pub fn asFloat(v: Value) ?f64 {
    return switch (v) {
        .int => |i| @floatFromInt(i),
        .float => |f| f,
        .boolean => |b| if (b) 1.0 else 0.0,
        else => null,
    };
}

pub fn asInt(v: Value) ?i64 {
    return switch (v) {
        .int => |i| i,
        .boolean => |b| if (b) 1 else 0,
        .float => |f| @intFromFloat(f),
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

pub fn eql(a: Value, b: Value) bool {
    const ta = std.meta.activeTag(a);
    const tb = std.meta.activeTag(b);
    if (ta != tb) {
        if (ta == .int and tb == .float) return @as(f64, @floatFromInt(a.int)) == b.float;
        if (ta == .float and tb == .int) return a.float == @as(f64, @floatFromInt(b.int));
        if (ta == .boolean and tb == .int) return @as(i64, if (a.boolean) 1 else 0) == b.int;
        if (ta == .int and tb == .boolean) return a.int == @as(i64, if (b.boolean) 1 else 0);
        return false;
    }
    return switch (a) {
        .none => true,
        .boolean => a.boolean == b.boolean,
        .int => a.int == b.int,
        .float => a.float == b.float,
        .string => std.mem.eql(u8, a.string, b.string),
        .list => listEql(a.list, b.list),
        .tuple => listEql(a.tuple, b.tuple),
        .dict => dictEql(a.dict, b.dict),
        .reference => std.mem.eql(u8, a.reference.var_name, b.reference.var_name) and a.reference.addr == b.reference.addr,
        .func_ref => std.mem.eql(u8, a.func_ref, b.func_ref),
        .extern_fn => a.extern_fn == b.extern_fn,
        .py_object => a.py_object == b.py_object,
        .lazy => a.lazy == b.lazy,
        .isolate => a.isolate == b.isolate,
    };
}

fn listEql(a: *List, b: *List) bool {
    if (a.items.items.len != b.items.items.len) return false;
    for (a.items.items, b.items.items) |x, y| {
        if (!eql(x, y)) return false;
    }
    return true;
}

fn dictEql(a: *Dict, b: *Dict) bool {
    if (a.keys.items.len != b.keys.items.len) return false;
    for (a.keys.items, a.values.items) |k, v| {
        const other = b.get(k) orelse return false;
        if (!eql(v, other)) return false;
    }
    return true;
}

pub fn appendFloat(w: *std.Io.Writer, f: f64) !void {
    if (std.math.isNan(f)) return w.writeAll("nan");
    if (std.math.isInf(f)) return w.writeAll(if (f < 0) "-inf" else "inf");
    if (f == @trunc(f) and @abs(f) < 1e16) {
        try w.print("{d}.0", .{@as(i64, @intFromFloat(f))});
        return;
    }
    try w.print("{d}", .{f});
}

pub fn appendQuoted(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('\'');
    for (s) |c| {
        switch (c) {
            '\\' => try w.writeAll("\\\\"),
            '\'' => try w.writeAll("\\'"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 32 or c == 127) {
                    try w.print("\\x{x:0>2}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('\'');
}

pub fn appendRepr(w: *std.Io.Writer, v: Value) anyerror!void {
    switch (v) {
        .none => try w.writeAll("None"),
        .boolean => |b| try w.writeAll(if (b) "True" else "False"),
        .int => |i| try w.print("{d}", .{i}),
        .float => |f| try appendFloat(w, f),
        .string => |s| try appendQuoted(w, s),
        .list => |l| {
            try w.writeByte('[');
            for (l.items.items, 0..) |item, i| {
                if (i != 0) try w.writeAll(", ");
                try appendRepr(w, item);
            }
            try w.writeByte(']');
        },
        .tuple => |t| {
            try w.writeByte('(');
            for (t.items.items, 0..) |item, i| {
                if (i != 0) try w.writeAll(", ");
                try appendRepr(w, item);
            }
            if (t.items.items.len == 1) try w.writeByte(',');
            try w.writeByte(')');
        },
        .dict => |d| {
            try w.writeByte('{');
            for (d.keys.items, d.values.items, 0..) |k, val, i| {
                if (i != 0) try w.writeAll(", ");
                try appendRepr(w, k);
                try w.writeAll(": ");
                try appendRepr(w, val);
            }
            try w.writeByte('}');
        },
        .reference => |r| try w.print("<Reference {s}>", .{r.var_name}),
        .func_ref => |n| try w.print("<FuncReference {s}>", .{n}),
        .extern_fn => |e| try w.print("<function {s}>", .{e.name}),
        .py_object => try w.writeAll("<python object>"),
        .lazy => try w.writeAll("<function>"),
        .isolate => try w.writeAll("<PryzmaInterpreter>"),
    }
}

pub fn repr(allocator: Allocator, v: Value) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    try appendRepr(&aw.writer, v);
    return aw.toOwnedSlice();
}

pub fn printString(allocator: Allocator, v: Value) ![]u8 {
    return switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        else => try repr(allocator, v),
    };
}

pub fn concat(allocator: Allocator, a: []const u8, b: []const u8) ![]const u8 {
    const out = try allocator.alloc(u8, a.len + b.len);
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return out;
}

pub fn add(a: Value, b: Value) Value {
    if (a == .string or b == .string) {
        const aa = printString(std.heap.page_allocator, a) catch return .none;
        const bb = printString(std.heap.page_allocator, b) catch return .none;
        return .{ .string = concat(std.heap.page_allocator, aa, bb) catch return .none };
    }
    if (a == .list and b == .list) {
        const l = List.create(std.heap.page_allocator) catch return .none;
        l.appendSlice(a.list.items.items) catch return .none;
        l.appendSlice(b.list.items.items) catch return .none;
        return .{ .list = l };
    }
    if (a == .int and b == .int) return .{ .int = a.int +% b.int };
    if (isNumber(a) and isNumber(b)) return .{ .float = asFloat(a).? + asFloat(b).? };
    return .none;
}

pub fn sub(a: Value, b: Value) Value {
    if (a == .int and b == .int) return .{ .int = a.int -% b.int };
    if (isNumber(a) and isNumber(b)) return .{ .float = asFloat(a).? - asFloat(b).? };
    return .none;
}

pub fn mul(a: Value, b: Value) Value {
    if (a == .int and b == .int) return .{ .int = a.int *% b.int };
    if (isNumber(a) and isNumber(b)) return .{ .float = asFloat(a).? * asFloat(b).? };
    if (a == .string and b == .int and b.int >= 0) {
        const n: usize = @intCast(b.int);
        const out = std.heap.page_allocator.alloc(u8, a.string.len * n) catch return .none;
        for (0..n) |i| @memcpy(out[i * a.string.len ..][0..a.string.len], a.string);
        return .{ .string = out };
    }
    if (a == .list and b == .int and b.int >= 0) {
        const l = List.create(std.heap.page_allocator) catch return .none;
        for (0..@intCast(b.int)) |_| l.appendSlice(a.list.items.items) catch return .none;
        return .{ .list = l };
    }
    return .none;
}

pub fn div(a: Value, b: Value) Value {
    const divisor = asFloat(b) orelse return .none;
    if (divisor == 0) return .none;
    return .{ .float = asFloat(a).? / divisor };
}

pub fn mod(a: Value, b: Value) Value {
    if (a == .int and b == .int and b.int != 0) return .{ .int = @mod(a.int, b.int) };
    const divisor = asFloat(b) orelse return .none;
    if (divisor == 0) return .none;
    return .{ .float = @mod(asFloat(a).?, divisor) };
}

pub fn cmp(a: Value, b: Value) ?std.math.Order {
    if (isNumber(a) and isNumber(b)) return std.math.order(asFloat(a).?, asFloat(b).?);
    if (a == .string and b == .string) return std.mem.order(u8, a.string, b.string);
    return null;
}
