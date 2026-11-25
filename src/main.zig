const std = @import("std");
const py = @import("py.zig");
const interp_mod = @import("interp.zig");
const value = @import("value.zig");
extern "c" fn isatty(c_int) c_int;

pub fn main(init: std.process.Init.Minimal) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const allocator = std.heap.c_allocator;
    const p = try py.Py.init(allocator);
    const interpreter = try interp_mod.Interpreter.init(allocator, io, p);
    _ = try interpreter.setVar("__python__", .{ .py_object = @ptrCast(p.helper) });

    const args = init.args.vector;
    if (args.len > 0) {
        _ = try interpreter.setVar("interpreter_path", .{ .string = std.mem.span(args[0]) });
    }
    if (args.len <= 1) {
        if (isatty(0) != 0) {
            try runRepl(interpreter, allocator);
        } else {
            try runStdin(interpreter, allocator);
        }
        return;
    }

    const file = std.mem.span(args[1]);
    var script_args: std.ArrayList([]const u8) = .empty;
    for (args[1..]) |arg| {
        const text = std.mem.span(arg);
        if (!std.mem.eql(u8, text, "-upi")) try script_args.append(allocator, text);
    }
    var line_mode = false;
    var help = false;
    var packed_mode: ?[]const u8 = null;
    for (args[2..]) |arg_ptr| {
        const arg = std.mem.span(arg_ptr);
        if (std.mem.eql(u8, arg, "-h")) help = true;
        if (std.mem.eql(u8, arg, "-d")) interpreter.debug = true;
        if (std.mem.eql(u8, arg, "-p")) interpreter.preprocess_only = true;
        if (std.mem.eql(u8, arg, "-np")) interpreter.no_preproc = true;
        if (std.mem.eql(u8, arg, "-fd")) interpreter.forward_declare = true;
        if (std.mem.eql(u8, arg, "-l")) line_mode = true;
        if (std.mem.eql(u8, arg, "-pk") or std.mem.eql(u8, arg, "-upk")) packed_mode = arg;
    }
    if (help) {
        try std.Io.File.stdout().writeStreamingAll(io,
            \\flags:
            \\    -d  debug mode
            \\    -p  preprocess only
            \\    -np no preprocessing
            \\    -l  execute a single line
            \\    -fd forward declare functions
            \\    -pk pack a file
            \\    -upk unpack a file
            \\    -upi unpack and interpret a file
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
        const data = try std.Io.Dir.cwd().readFileAlloc(io, file, allocator, .limited(64 * 1024 * 1024));
        if (std.mem.eql(u8, mode, "-pk")) {
            const source = try interpreter.preprocess(data);
            var body: std.Io.Writer.Allocating = .init(allocator);
            try body.writer.writeAll("#np;");
            for (source, 0..) |statement, i| {
                if (i != 0) try body.writer.writeByte(';');
                try body.writer.writeAll(statement);
            }
            const text = try body.toOwnedSlice();
            const py_text = try p.newString(text);
            const compressed = try p.callHelper("lzma_compress", &.{py_text});
            defer py.Py_DecRef(compressed);
            const bytes = try p.fromPy(compressed);
            if (bytes == .string) {
                try std.Io.File.stdout().writeStreamingAll(io, "prz");
                try std.Io.File.stdout().writeStreamingAll(io, bytes.string);
            }
            py.Py_DecRef(py_text);
        } else {
            if (!std.mem.startsWith(u8, data, "prz")) {
                try std.Io.File.stderr().writeStreamingAll(io, "Can't decompress data\n");
                return;
            }
            const py_bytes = try p.newBytes(data[3..]);
            const text = try p.callHelper("lzma_decompress", &.{py_bytes});
            defer py.Py_DecRef(text);
            const unpacked = try p.fromPy(text);
            if (unpacked == .string) {
                try std.Io.File.stdout().writeStreamingAll(io, unpacked.string);
                try std.Io.File.stdout().writeStreamingAll(io, "\n");
            }
            py.Py_DecRef(py_bytes);
        }
        return;
    }
    // Packed files are detected and unpacked by interpretFile. This flag is
    // retained for compatibility with the reference CLI.
    try interpreter.interpretFile(file, script_args.items);
}

fn runStdin(interpreter: *interp_mod.Interpreter, allocator: std.mem.Allocator) !void {
    var buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(interpreter.io, &buf);
    const contents = try reader.interface.allocRemaining(allocator, .unlimited);
    if (contents.len != 0) try interpreter.preInterpret(contents);
}

fn runRepl(interpreter: *interp_mod.Interpreter, allocator: std.mem.Allocator) !void {
    const io = interpreter.io;
    var history: std.ArrayList([]const u8) = .empty;
    try std.Io.File.stdout().writeStreamingAll(io,
        \\Pryzma 6.2
        \\To show the license type "license" or "help" to get help.
        \\
    );
    var buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &buf);
    while (true) {
        try std.Io.File.stdout().writeStreamingAll(io, "/// ");
        const line = (try reader.interface.takeDelimiter('\n')) orelse break;
        const code = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, code, "exit")) break;
        if (code.len != 0) try history.append(allocator, try allocator.dupe(u8, code));
        if (std.mem.startsWith(u8, code, "history")) {
            const rest = std.mem.trim(u8, code["history".len..], " \t");
            if (rest.len == 0) {
                var output: std.Io.Writer.Allocating = .init(allocator);
                for (history.items, 0..) |entry, index| try output.writer.print("{d}. {s}\n", .{ index + 1, entry });
                try std.Io.File.stdout().writeStreamingAll(io, output.written());
            } else if (std.mem.eql(u8, rest, "clear")) {
                history.clearRetainingCapacity();
            } else if (std.fmt.parseUnsigned(usize, rest, 10)) |number| {
                if (number == 0 or number > history.items.len) {
                    try std.Io.File.stdout().writeStreamingAll(io, "Invalid history index.\n");
                } else {
                    const selected = history.items[number - 1];
                    const statements = try interpreter.preprocess(selected);
                    for (statements) |statement| try interpreter.interpret(statement);
                }
            } else |_| {
                var output: std.Io.Writer.Allocating = .init(allocator);
                try output.writer.print("Searching for '{s}' in history:\n", .{rest});
                var found: usize = 0;
                for (history.items) |entry| {
                    if (std.mem.indexOf(u8, entry, rest)) |_| {
                        found += 1;
                        try output.writer.print("{d}. {s}\n", .{ found, entry });
                    }
                }
                if (found == 0) try output.writer.writeAll("No commands found matching the search term.\n");
                try std.Io.File.stdout().writeStreamingAll(io, output.written());
            }
            continue;
        }
        if (std.mem.startsWith(u8, code, "ppm")) {
            const command = std.mem.trim(u8, code[3..], " \t");
            if (command.len != 0) {
                try interpreter.ppmCommand(command);
            } else {
                try std.Io.File.stdout().writeStreamingAll(io, "ppm shell. Type 'exit' to quit.\n");
                while (true) {
                    try std.Io.File.stdout().writeStreamingAll(io, "> ");
                    const ppm_line = (try reader.interface.takeDelimiter('\n')) orelse break;
                    const ppm_command = std.mem.trim(u8, ppm_line, " \t\r");
                    if (std.mem.eql(u8, ppm_command, "exit")) break;
                    try interpreter.ppmCommand(ppm_command);
                }
            }
            continue;
        }
        if (std.mem.eql(u8, code, "file")) {
            try std.Io.File.stdout().writeStreamingAll(io, "Enter the file path of the program: ");
            const path_line = (try reader.interface.takeDelimiter('\n')) orelse break;
            const path = std.mem.trim(u8, path_line, " \t\r\"");
            try interpreter.interpretFile(path, &.{});
            try std.Io.File.stdout().writeStreamingAll(io, "Clear variables, functions and structs dictionaries? (y/n): ");
            const clear_line = (try reader.interface.takeDelimiter('\n')) orelse break;
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, clear_line, " \t\r"), "y")) {
                interpreter.variables.clearRetainingCapacity();
                interpreter.functions.clearRetainingCapacity();
                interpreter.structs.clearRetainingCapacity();
            }
            continue;
        }
        if (std.mem.eql(u8, code, "debug")) {
            try std.Io.File.stdout().writeStreamingAll(io, "Path to the file to debug ('exit' to quit debug mode): ");
            const path_line = (try reader.interface.takeDelimiter('\n')) orelse break;
            const path = std.mem.trim(u8, path_line, " \t\r\"");
            if (!std.mem.eql(u8, path, "exit")) {
                interpreter.debug = true;
                try interpreter.interpretFile(path, &.{});
                interpreter.debug = false;
            }
            continue;
        }
        if (std.mem.eql(u8, code, "help")) {
            try std.Io.File.stdout().writeStreamingAll(io,
                \\Commands: file, cls, clear, debug, history, info, ppm, errors, exit, reboot, v, f, s, l, help, license
                \\Enter Pryzma statements to execute them.
                \\
            );
            continue;
        }
        if (std.mem.eql(u8, code, "license")) {
            const license_text = std.Io.Dir.cwd().readFileAlloc(io, "license.txt", allocator, .limited(1024 * 1024)) catch "License file not found.";
            try std.Io.File.stdout().writeStreamingAll(io, license_text);
            try std.Io.File.stdout().writeStreamingAll(io, "\n");
            continue;
        }
        if (std.mem.eql(u8, code, "info")) {
            const result = try interpreter.python.?.callHelper("system_info", &.{});
            defer py.Py_DecRef(result);
            const info = try interpreter.python.?.fromPy(result);
            if (info == .string) try std.Io.File.stdout().writeStreamingAll(io, info.string);
            continue;
        }
        if (std.mem.eql(u8, code, "errors")) {
            try std.Io.File.stdout().writeStreamingAll(io,
                \\
                \\1 - Error keyword deleted
                \\2 - Invalid function definition
                \\3 - Function not defined
                \\4 - Too much arguments for +=
                \\5 - Too much arguments for -=
                \\6 - Invalid number of arguments for write()
                \\7 - Invalid move() instruction syntax
                \\8 - Invalid index for move() instruction
                \\9 - Invalid swap() instruction syntax
                \\10 - Invalid index for swap() instruction
                \\11 - Invalid statement
                \\12 - Unknown error
                \\13 - Module does not have a 'start' function.
                \\14 - Error loading module
                \\15 - Error writing to file
                \\16 - Invalid number of arguments for replace function
                \\17 - Invalid number of arguments for resplit function
                \\18 - The first argument of resplit() must be a string (regex pattern).
                \\19 - The second argument of resplit() must be a string.
                \\20 - Invalid regex pattern.
                \\21 - in() function error
                \\22 - Invalid number of arguments for splitby function
                \\23 - File not found
                \\24 - Invalid number of arguments for index function
                \\25 - Value not found in list for index function
                \\26 - Variable is not a list for index function
                \\27 - List not defined for all()
                \\28 - Unknown variable or expression
                \\29 - Invalid range expression for loop
                \\30 - File not found for use function
                \\31 - List does not exist for append function
                \\32 - Index out of range for pop function
                \\33 - List does not exist for pop function
                \\34 - Invalid number of arguments for call.
                \\35 - Invalid call statement format.
                \\36 - Variable not found in current scope.
                \\37 - Referenced variable no longer exists.
                \\38 - Referenced function no longer exists.
                \\39 - Overlaping names of struct instance and one of variables used for destructuring.
                \\40 - Name of a non existing function pased as an argument to patch()
                \\41 - List not found for the foreach function.
                \\42 - 'using' statement can only be used with struct instances.
                \\43 - Indexing Error.
                \\44 - Field not found on object.
                \\
            );
            continue;
        }
        if (std.mem.eql(u8, code, "clear")) {
            try std.Io.File.stdout().writeStreamingAll(io, "\x1b[2J\x1b[H");
            continue;
        }
        if (std.mem.eql(u8, code, "v")) {
            var output: std.Io.Writer.Allocating = .init(allocator);
            try output.writer.writeAll("variables: {");
            var vars = interpreter.variables.iterator();
            var first = true;
            while (vars.next()) |entry| {
                if (!first) try output.writer.writeAll(", ");
                first = false;
                const rendered = try value.repr(allocator, entry.value_ptr.*);
                try output.writer.print("'{s}': {s}", .{ entry.key_ptr.*, rendered });
            }
            try output.writer.writeAll("} \n\n");
            try std.Io.File.stdout().writeStreamingAll(io, output.written());
            continue;
        }
        if (std.mem.eql(u8, code, "f")) {
            var output: std.Io.Writer.Allocating = .init(allocator);
            try output.writer.writeAll("functions: {");
            var funcs = interpreter.functions.iterator();
            var first = true;
            while (funcs.next()) |entry| {
                if (!first) try output.writer.writeAll(", ");
                first = false;
                const body = try value.List.create(allocator);
                for (entry.value_ptr.*.body.items) |line_text| {
                    try body.append(.{ .string = line_text });
                }
                const rendered = try value.repr(allocator, .{ .list = body });
                try output.writer.print("'{s}': {s}", .{ entry.key_ptr.*, rendered });
            }
            try output.writer.writeAll("} \n\n");
            try std.Io.File.stdout().writeStreamingAll(io, output.written());
            continue;
        }
        if (std.mem.eql(u8, code, "cls")) {
            interpreter.variables.clearRetainingCapacity();
            interpreter.functions.clearRetainingCapacity();
            interpreter.structs.clearRetainingCapacity();
            continue;
        }
        if (code.len == 0) continue;
        const statements = try interpreter.preprocess(code);
        for (statements) |statement| try interpreter.interpret(statement);
    }
}
