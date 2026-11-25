const std = @import("std");
const Allocator = std.mem.Allocator;

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
    py_object: *anyopaque,
    lazy: *Lazy,
    isolate: *anyopaque,
    timestamp: i64,
    duration: i64,
};

pub const Reference = struct {
    var_name: []const u8,
    addr: ?usize = null,
};

pub const ExternFn = struct {
    py_callable: *anyopaque,
    name: []const u8 = "",
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

    pub fn append(self: *List, value: Value) !void {
        try self.items.append(self.allocator, value);
    }

    pub fn count(self: *const List) usize {
        return self.items.items.len;
    }

    pub fn at(self: *const List, index: i64) ?Value {
        const n: i64 = @intCast(self.items.items.len);
        const idx = if (index < 0) index + n else index;
        if (idx < 0 or idx >= n) return null;
        return self.items.items[@intCast(idx)];
    }

    pub fn set(self: *List, index: i64, value: Value) bool {
        const n: i64 = @intCast(self.items.items.len);
        const idx = if (index < 0) index + n else index;
        if (idx < 0 or idx >= n) return false;
        self.items.items[@intCast(idx)] = value;
        return true;
    }

    pub fn pop(self: *List, index: i64) ?Value {
        const n: i64 = @intCast(self.items.items.len);
        const idx = if (index < 0) index + n else index;
        if (idx < 0 or idx >= n) return null;
        return self.items.orderedRemove(@intCast(idx));
    }

    pub fn popLast(self: *List) ?Value {
        return self.items.pop();
    }

    pub fn removeValue(self: *List, value: Value) bool {
        for (self.items.items, 0..) |item, i| {
            if (eql(item, value)) {
                _ = self.items.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn insert(self: *List, index: usize, value: Value) !void {
        try self.items.insert(self.allocator, index, value);
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

    pub fn count(self: *const Dict) usize {
        return self.keys.items.len;
    }

    pub fn getIndex(self: *const Dict, key: Value) ?usize {
        for (self.keys.items, 0..) |k, i| {
            if (eql(k, key)) return i;
        }
        return null;
    }

    pub fn get(self: *const Dict, key: Value) ?Value {
        if (self.getIndex(key)) |i| return self.values.items[i];
        return null;
    }

    pub fn put(self: *Dict, key: Value, value: Value) !void {
        if (self.getIndex(key)) |i| {
            self.values.items[i] = value;
            return;
        }
        try self.keys.append(self.allocator, key);
        try self.values.append(self.allocator, value);
    }

    pub fn putStr(self: *Dict, key: []const u8, value: Value) !void {
        try self.put(.{ .string = key }, value);
    }

    pub fn getStr(self: *const Dict, key: []const u8) ?Value {
        return self.get(.{ .string = key });
    }

    pub fn remove(self: *Dict, key: Value) ?Value {
        if (self.getIndex(key)) |i| {
            _ = self.keys.orderedRemove(i);
            return self.values.orderedRemove(i);
        }
        return null;
    }

    pub fn copy(self: *const Dict) !*Dict {
        const d = try self.allocator.create(Dict);
        d.* = Dict.init(self.allocator);
        d.type_name = self.type_name;
        try d.keys.appendSlice(self.allocator, self.keys.items);
        try d.values.appendSlice(self.allocator, self.values.items);
        return d;
    }
};

pub fn truthy(value: Value) bool {
    return switch (value) {
        .none => false,
        .boolean => |b| b,
        .int => |i| i != 0,
        .float => |f| f != 0,
        .string => |s| s.len != 0,
        .list => |l| l.items.items.len != 0,
        .dict => |d| d.keys.items.len != 0,
        .tuple => |t| t.items.items.len != 0,
        .reference => true,
        .func_ref => true,
        .extern_fn => true,
        .py_object => true,
        .lazy => true,
        .isolate => true,
        .timestamp => true,
        .duration => |d| d != 0,
    };
}

pub fn typeName(value: Value) []const u8 {
    return switch (value) {
        .none => "NoneType",
        .boolean => "bool",
        .int => "int",
        .float => "float",
        .string => "str",
        .list => "list",
        .dict => |d| if (d.type_name) |n| n else "dict",
        .tuple => "tuple",
        .reference => "Reference",
        .func_ref => "function",
        .extern_fn => "function",
        .py_object => "object",
        .lazy => "function",
        .isolate => "isolate",
        .timestamp => "datetime",
        .duration => "timedelta",
    };
}

pub fn eql(a: Value, b: Value) bool {
    const tag_a = std.meta.activeTag(a);
    const tag_b = std.meta.activeTag(b);
    if (tag_a != tag_b) {
        if ((tag_a == .int and tag_b == .float)) return @as(f64, @floatFromInt(a.int)) == b.float;
        if ((tag_a == .float and tag_b == .int)) return a.float == @as(f64, @floatFromInt(b.int));
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
        .timestamp => a.timestamp == b.timestamp,
        .duration => a.duration == b.duration,
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

pub fn isNumber(value: Value) bool {
    return switch (value) {
        .int, .float, .boolean => true,
        else => false,
    };
}

pub fn asFloat(value: Value) ?f64 {
    return switch (value) {
        .int => |i| @floatFromInt(i),
        .float => |f| f,
        .boolean => |b| if (b) 1 else 0,
        else => null,
    };
}

pub fn asInt(value: Value) ?i64 {
    return switch (value) {
        .int => |i| i,
        .boolean => |b| if (b) 1 else 0,
        .float => |f| @intFromFloat(f),
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

pub fn appendQuoted(out: *std.ArrayList(u8), allocator: Allocator, s: []const u8) !void {
    try out.append(allocator, '\'');
    for (s) |c| {
        switch (c) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\'' => try out.appendSlice(allocator, "\\'"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (c < 32 or c == 127) {
                    try std.fmt.format(out.writer(allocator), "\\x{x:0>2}", .{c});
                } else {
                    try out.append(allocator, c);
                }
            },
        }
    }
    try out.append(allocator, '\'');
}

pub fn appendRepr(out: *std.ArrayList(u8), allocator: Allocator, value: Value) anyerror!void {
    switch (value) {
        .none => try out.appendSlice(allocator, "None"),
        .boolean => |b| try out.appendSlice(allocator, if (b) "True" else "False"),
        .int => |i| try std.fmt.format(out.writer(allocator), "{d}", .{i}),
        .float => |f| try appendFloat(out, allocator, f),
        .string => |s| try appendQuoted(out, allocator, s),
        .list => |l| {
            try out.append(allocator, '[');
            for (l.items.items, 0..) |item, i| {
                if (i != 0) try out.appendSlice(allocator, ", ");
                try appendRepr(out, allocator, item);
            }
            try out.append(allocator, ']');
        },
        .tuple => |t| {
            try out.append(allocator, '(');
            for (t.items.items, 0..) |item, i| {
                if (i != 0) try out.appendSlice(allocator, ", ");
                try appendRepr(out, allocator, item);
            }
            if (t.items.items.len == 1) try out.append(allocator, ',');
            try out.append(allocator, ')');
        },
        .dict => |d| {
            try out.append(allocator, '{');
            for (d.keys.items, d.values.items, 0..) |k, v, i| {
                if (i != 0) try out.appendSlice(allocator, ", ");
                try appendRepr(out, allocator, k);
                try out.appendSlice(allocator, ": ");
                try appendRepr(out, allocator, v);
            }
            try out.append(allocator, '}');
        },
        .reference => |r| try std.fmt.format(out.writer(allocator), "<Reference {s}>", .{r.var_name}),
        .func_ref => |n| try std.fmt.format(out.writer(allocator), "<function {s}>", .{n}),
        .extern_fn => |e| try std.fmt.format(out.writer(allocator), "<extern {s}>", .{e.name}),
        .py_object => try out.appendSlice(allocator, "<python object>"),
        .lazy => try out.appendSlice(allocator, "<lazy>"),
        .isolate => try out.appendSlice(allocator, "<isolate>"),
        .timestamp => |t| try std.fmt.format(out.writer(allocator), "{d}", .{t}),
        .duration => |d| try std.fmt.format(out.writer(allocator), "{d}", .{d}),
    }
}

pub fn appendFloat(out: *std.ArrayList(u8), allocator: Allocator, f: f64) !void {
    if (std.math.isNan(f)) {
        try out.appendSlice(allocator, "nan");
        return;
    }
    if (std.math.isInf(f)) {
        try out.appendSlice(allocator, if (f < 0) "-inf" else "inf");
        return;
    }
    if (f == @floor(f) and @abs(f) < 1e16) {
        try std.fmt.format(out.writer(allocator), "{d}.0", .{@as(i64, @intFromFloat(f))});
        return;
    }
    try std.fmt.format(out.writer(allocator), "{d}", .{f});
}

pub fn repr(allocator: Allocator, value: Value) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try appendRepr(&out, allocator, value);
    return out.toOwnedSlice(allocator);
}

pub fn printString(allocator: Allocator, value: Value) ![]u8 {
    return switch (value) {
        .string => |s| try allocator.dupe(u8, s),
        else => try repr(allocator, value),
    };
}

pub fn add(a: Value, b: Value) Value {
    if (a == .string or b == .string) {
        // Custom Pryzma behavior: convert both to strings and concatenate.
        const aa = printString(std.heap.page_allocator, a) catch return .none;
        defer std.heap.page_allocator.free(aa);
        const bb = printString(std.heap.page_allocator, b) catch return .none;
        defer std.heap.page_allocator.free(bb);
        const out = std.heap.page_allocator.alloc(u8, aa.len + bb.len) catch return .none;
        @memcpy(out[0..aa.len], aa);
        @memcpy(out[aa.len..], bb);
        return .{ .string = out };
    }
    if (a == .list and b == .list) {
        const l = std.heap.page_allocator.create(List) catch return .none;
        l.* = List.init(std.heap.page_allocator);
        l.items.appendSlice(std.heap.page_allocator, a.list.items.items) catch return .none;
        l.items.appendSlice(std.heap.page_allocator, b.list.items.items) catch return .none;
        return .{ .list = l };
    }
    if (a == .tuple and b == .tuple) {
        const l = std.heap.page_allocator.create(List) catch return .none;
        l.* = List.init(std.heap.page_allocator);
        l.items.appendSlice(std.heap.page_allocator, a.tuple.items.items) catch return .none;
        l.items.appendSlice(std.heap.page_allocator, b.tuple.items.items) catch return .none;
        return .{ .tuple = l };
    }
    if (a == .int and b == .int) return .{ .int = a.int +% b.int };
    if (isNumber(a) and isNumber(b)) return .{ .float = (asFloat(a) orelse 0) + (asFloat(b) orelse 0) };
    return .none;
}

pub fn sub(a: Value, b: Value) Value {
    if (a == .int and b == .int) return .{ .int = a.int -% b.int };
    if (isNumber(a) and isNumber(b)) return .{ .float = (asFloat(a) orelse 0) - (asFloat(b) orelse 0) };
    return .none;
}

pub fn mul(a: Value, b: Value) Value {
    if (a == .int and b == .int) return .{ .int = a.int *% b.int };
    if (isNumber(a) and isNumber(b)) return .{ .float = (asFloat(a) orelse 0) * (asFloat(b) orelse 0) };
    if (a == .string and b == .int) {
        const n: usize = if (b.int > 0) @intCast(b.int) else 0;
        const out = std.heap.page_allocator.alloc(u8, a.string.len * n) catch return .none;
        var i: usize = 0;
        while (i < n) : (i += 1) @memcpy(out[i * a.string.len ..][0..a.string.len], a.string);
        return .{ .string = out };
    }
    if (a == .int and b == .string) return mul(b, a);
    if (a == .list and b == .int) {
        const n: usize = if (b.int > 0) @intCast(b.int) else 0;
        const l = std.heap.page_allocator.create(List) catch return .none;
        l.* = List.init(std.heap.page_allocator);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            l.items.appendSlice(std.heap.page_allocator, a.list.items.items) catch return .none;
        }
        return .{ .list = l };
    }
    if (a == .int and b == .list) return mul(b, a);
    return .none;
}

pub fn div(a: Value, b: Value) Value {
    const bf = asFloat(b) orelse return .none;
    if (bf == 0) return .none;
    return .{ .float = (asFloat(a) orelse 0) / bf };
}

pub fn mod(a: Value, b: Value) Value {
    if (a == .int and b == .int and b.int != 0) return .{ .int = @mod(a.int, b.int) };
    const bf = asFloat(b) orelse return .none;
    if (bf == 0) return .none;
    return .{ .float = @mod(asFloat(a) orelse 0, bf) };
}

pub fn pow(a: Value, b: Value) Value {
    if (a == .int and b == .int and b.int >= 0) {
        var result: i64 = 1;
        var i: i64 = 0;
        while (i < b.int) : (i += 1) result *%= a.int;
        return .{ .int = result };
    }
    return .{ .float = std.math.pow(f64, asFloat(a) orelse 0, asFloat(b) orelse 0) };
}

pub fn cmp(a: Value, b: Value) ?std.math.Order {
    if (a == .int and b == .int) return std.math.order(a.int, b.int);
    if (isNumber(a) and isNumber(b)) return std.math.order(asFloat(a).?, asFloat(b).?);
    if (a == .string and b == .string) return std.mem.order(u8, a.string, b.string);
    return null;
}

pub fn intFromValue(value: Value) i64 {
    return asInt(value) orelse 0;
}

pub fn floatFromValue(value: Value) f64 {
    return asFloat(value) orelse 0;
}
