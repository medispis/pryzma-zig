const std = @import("std");
const py = @import("py.zig");
const interp_mod = @import("interp.zig");
const value = @import("value.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const allocator = std.heap.c_allocator;
    const p = try py.Py.init(allocator);
    const interpreter = try interp_mod.Interpreter.init(allocator, io, p);
    _ = try interpreter.setVar("__python__", .{ .py_object = @ptrCast(p.helper) });

    const args = init.args.vector;
    if (args.len <= 1) {
        try runStdin(interpreter, allocator);
        return;
    }

    const file = std.mem.span(args[1]);
    var script_args: std.ArrayList([]const u8) = .empty;
    for (args[1..]) |arg| try script_args.append(allocator, std.mem.span(arg));
    var line_mode = false;
    var help = false;
    var packed_mode: ?[]const u8 = null;
    for (args[2..]) |arg_ptr| {
        const arg = std.mem.span(arg_ptr);
        if (std.mem.eql(u8, arg, "-h")) help = true;
        if (std.mem.eql(u8, arg, "-p")) interpreter.preprocess_only = true;
        if (std.mem.eql(u8, arg, "-np")) interpreter.no_preproc = true;
        if (std.mem.eql(u8, arg, "-fd")) interpreter.forward_declare = true;
        if (std.mem.eql(u8, arg, "-l")) line_mode = true;
        if (std.mem.eql(u8, arg, "-pk") or std.mem.eql(u8, arg, "-upk")) packed_mode = arg;
    }
    if (help) {
        try std.Io.File.stdout().writeStreamingAll(io,
            \\flags:
            \\    -d  debug mode (not yet implemented)
            \\    -p  preprocess only
            \\    -np no preprocessing
            \\    -l  execute a single line
            \\    -fd forward declare functions
            \\    -pk pack a file (not yet implemented)
            \\    -upk unpack a file (not yet implemented)
            \\
        );
        return;
    }
    if (line_mode) {
        const code_idx = blk: {
            for (args[2..], 2..) |arg_ptr, i| {
                if (std.mem.eql(u8, std.mem.span(arg_ptr), "-l")) break :blk i + 1;
            }
            break :blk args.len;
        };
        if (code_idx < args.len) {
            try interpreter.preInterpret(std.mem.span(args[code_idx]));
        }
        return;
    }
    if (packed_mode) |mode| {
        _ = mode;
        try std.Io.File.stderr().writeStreamingAll(io, "Packing flags are not implemented yet.\n");
        return;
    }
    try interpreter.interpretFile(file, script_args.items);
    _ = value.Value.none;
}

fn runStdin(interpreter: *interp_mod.Interpreter, allocator: std.mem.Allocator) !void {
    var buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(interpreter.io, &buf);
    const contents = try reader.interface.allocRemaining(allocator, .unlimited);
    if (contents.len != 0) try interpreter.preInterpret(contents);
}
