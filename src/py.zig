const std = @import("std");
const Allocator = std.mem.Allocator;
const value = @import("value.zig");
const Value = value.Value;
const List = value.List;
const Dict = value.Dict;

pub const PyObject = anyopaque;

extern "c" fn Py_InitializeEx(initsigs: c_int) void;
extern "c" fn Py_FinalizeEx() c_int;
extern "c" fn PyRun_StringFlags(code: [*:0]const u8, start: c_int, globals: *PyObject, locals: *PyObject, flags: ?*anyopaque) ?*PyObject;
extern "c" fn PyImport_ImportModule(name: [*:0]const u8) ?*PyObject;
pub extern "c" fn PyObject_GetAttrString(obj: *PyObject, name: [*:0]const u8) ?*PyObject;
extern "c" fn PyObject_SetAttrString(obj: *PyObject, name: [*:0]const u8, v: *PyObject) c_int;
extern "c" fn PyObject_Call(callable: *PyObject, args: *PyObject, kwargs: ?*PyObject) ?*PyObject;
extern "c" fn PyObject_CallObject(callable: *PyObject, args: ?*PyObject) ?*PyObject;
extern "c" fn PyObject_Str(obj: *PyObject) ?*PyObject;
extern "c" fn PyObject_Repr(obj: *PyObject) ?*PyObject;
extern "c" fn PyUnicode_AsUTF8AndSize(obj: *PyObject, size: *isize) ?[*:0]const u8;
extern "c" fn PyUnicode_FromStringAndSize(s: [*]const u8, size: isize) ?*PyObject;
extern "c" fn PyLong_FromLongLong(v: c_longlong) ?*PyObject;
extern "c" fn PyLong_AsLongLong(obj: *PyObject) c_longlong;
extern "c" fn PyFloat_AsDouble(obj: *PyObject) f64;
extern "c" fn PyFloat_FromDouble(v: f64) ?*PyObject;
extern "c" fn PyBool_FromLong(v: c_long) ?*PyObject;
pub extern "c" fn PyObject_IsTrue(obj: *PyObject) c_int;
extern "c" fn PyList_New(size: isize) ?*PyObject;
extern "c" fn PyList_SetItem(list: *PyObject, index: isize, item: *PyObject) c_int;
extern "c" fn PyList_Append(list: *PyObject, item: *PyObject) c_int;
extern "c" fn PyList_Size(list: *PyObject) isize;
extern "c" fn PyTuple_New(size: isize) ?*PyObject;
extern "c" fn PyTuple_SetItem(tuple: *PyObject, index: isize, item: *PyObject) c_int;
pub extern "c" fn PyDict_New() ?*PyObject;
pub extern "c" fn PyDict_SetItemString(dict: *PyObject, key: [*:0]const u8, v: *PyObject) c_int;
extern "c" fn PyDict_SetItem(dict: *PyObject, key: *PyObject, v: *PyObject) c_int;
extern "c" fn PyDict_GetItemString(dict: *PyObject, key: [*:0]const u8) ?*PyObject;
pub extern "c" fn PyDict_Next(dict: *PyObject, pos: *isize, key: *?*PyObject, val: *?*PyObject) c_int;
extern "c" fn PyDict_Size(dict: *PyObject) isize;
pub extern "c" fn Py_DecRef(obj: *PyObject) void;
pub extern "c" fn Py_IncRef(obj: *PyObject) void;
pub extern "c" fn PyErr_Clear() void;
extern "c" fn PyErr_Occurred() ?*PyObject;
pub extern "c" fn PyErr_Print() void;
extern "c" fn PyObject_IsInstance(obj: *PyObject, cls: *PyObject) c_int;
extern "c" fn PyBytes_FromStringAndSize(s: [*]const u8, size: isize) ?*PyObject;
extern "c" fn PyBytes_AsStringAndSize(obj: *PyObject, s: *?[*]u8, size: *isize) c_int;

extern var _Py_NoneStruct: anyopaque;
extern var _Py_TrueStruct: anyopaque;
extern var _Py_FalseStruct: anyopaque;
extern var PyLong_Type: anyopaque;
extern var PyFloat_Type: anyopaque;
extern var PyUnicode_Type: anyopaque;
extern var PyList_Type: anyopaque;
extern var PyDict_Type: anyopaque;
extern var PyTuple_Type: anyopaque;
extern var PyBool_Type: anyopaque;
extern var PyBytes_Type: anyopaque;

pub const py_eval_input: c_int = 258;
pub const py_file_input: c_int = 257;

pub fn noneObj() *PyObject {
    return @ptrCast(&_Py_NoneStruct);
}

pub const Py = struct {
    allocator: Allocator,
    helper: *PyObject,
    ref_class: *PyObject,
    funcref_class: *PyObject,
    initialized: bool = false,

    const helper_source =
        \\import sys, os, importlib, importlib.util, ctypes, re, json, lzma, datetime, random, shutil, time, platform
        \\
        \\class Ref:
        \\    __slots__ = ('var_name', 'addr')
        \\    def __init__(self, var_name, addr=None):
        \\        self.var_name = var_name
        \\        self.addr = addr
        \\    def __repr__(self):
        \\        return f"<Reference {self.var_name}>"
        \\
        \\class FuncRef:
        \\    __slots__ = ('func_name',)
        \\    def __init__(self, func_name):
        \\        self.func_name = func_name
        \\    def __repr__(self):
        \\        return f"<FuncReference {self.func_name}>"
        \\
        \\class Self:
        \\    def __init__(self, d):
        \\        self.variables = d
        \\
        \\def make_ref(n, a):
        \\    return Ref(n, a)
        \\
        \\def make_funcref(n):
        \\    return FuncRef(n)
        \\
        \\def make_self(d):
        \\    return Self(d)
        \\
        \\def system_info():
        \\    now = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        \\    machine = platform.machine()
        \\    arch = '64-bit' if machine in ('x86_64', 'AMD64') else ('32-bit' if machine in ('i386', 'i686') else 'Unknown')
        \\    return f"Pryzma 6.2\nCurrent Date and Time: {now}\nOperating System: {platform.system()} {platform.release()} {arch} ({machine})\nProcessor: {platform.processor()}\n"
        \\
        \\def load_pyextern(module_ref, base_file):
        \\    try:
        \\        if module_ref.endswith('.py') or os.path.sep in module_ref:
        \\            base_dir = os.path.dirname(base_file) if base_file else os.getcwd()
        \\            candidates = []
        \\            if os.path.isabs(module_ref):
        \\                candidates.append(module_ref)
        \\            else:
        \\                candidates.append(os.path.abspath(module_ref))
        \\                candidates.append(os.path.abspath(os.path.join(base_dir, module_ref)))
        \\            module_path = next((p for p in candidates if os.path.isfile(p)), None)
        \\            if module_path is None:
        \\                print(f"File '{module_ref}' does not exist.")
        \\                return None
        \\            module_name = f"pryzma_pyextern_{abs(hash(module_path))}"
        \\            spec = importlib.util.spec_from_file_location(module_name, module_path)
        \\            if spec is None or spec.loader is None:
        \\                print(f"Could not load the module from '{module_path}'.")
        \\                return None
        \\            module = importlib.util.module_from_spec(spec)
        \\            spec.loader.exec_module(module)
        \\            return module
        \\        return importlib.import_module(module_ref)
        \\    except Exception as e:
        \\        print(f"Error loading python module '{module_ref}': {e}")
        \\        return None
        \\
        \\def resolve_attr(module, path):
        \\    target = module
        \\    for attr in path.split('.'):
        \\        if not hasattr(target, attr):
        \\            return None
        \\        target = getattr(target, attr)
        \\    return target
        \\
        \\def public_callables(module):
        \\    out = {}
        \\    for name in dir(module):
        \\        if name.startswith('_'):
        \\            continue
        \\        try:
        \\            attr = getattr(module, name)
        \\        except AttributeError:
        \\            continue
        \\        if callable(attr):
        \\            out[name] = attr
        \\    return out
        \\
        \\def load_c(path):
        \\    return ctypes.CDLL(path)
        \\
        \\def c_get(lib, name):
        \\    return c_attr(lib, name)
        \\
        \\def c_attr(lib, name):
        \\    f = getattr(lib, name)
        \\    lower = name.lower()
        \\    if lower == 'malloc':
        \\        f.argtypes = [ctypes.c_size_t]; f.restype = ctypes.c_void_p
        \\    elif lower == 'calloc':
        \\        f.argtypes = [ctypes.c_size_t, ctypes.c_size_t]; f.restype = ctypes.c_void_p
        \\    elif lower == 'realloc':
        \\        f.argtypes = [ctypes.c_void_p, ctypes.c_size_t]; f.restype = ctypes.c_void_p
        \\    elif lower == 'free':
        \\        f.argtypes = [ctypes.c_void_p]; f.restype = None
        \\    elif lower in ('memcpy', 'memmove'):
        \\        f.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]; f.restype = ctypes.c_void_p
        \\    elif lower == 'memset':
        \\        f.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_size_t]; f.restype = ctypes.c_void_p
        \\    return f
        \\
        \\def prepare_c_arg(arg):
        \\    if isinstance(arg, str):
        \\        return arg.encode('utf-8')
        \\    if isinstance(arg, bool):
        \\        return int(arg)
        \\    if isinstance(arg, (bytes, bytearray)):
        \\        return bytes(arg)
        \\    if isinstance(arg, (list, tuple)):
        \\        seq = list(arg)
        \\        if not seq:
        \\            return seq
        \\        if all(isinstance(i, bool) for i in seq):
        \\            return [int(i) for i in seq]
        \\        if all(isinstance(i, int) for i in seq):
        \\            return (ctypes.c_longlong * len(seq))(*seq)
        \\        if all(isinstance(i, float) for i in seq):
        \\            return (ctypes.c_double * len(seq))(*seq)
        \\        if all(isinstance(i, (bytes, bytearray, str)) for i in seq):
        \\            conv = [i.encode('utf-8') if isinstance(i, str) else bytes(i) for i in seq]
        \\            return (ctypes.c_char_p * len(conv))(*conv)
        \\        return [prepare_c_arg(i) for i in seq]
        \\    return arg
        \\
        \\def call_extern(func, args, is_c):
        \\    if is_c:
        \\        args = [prepare_c_arg(a) for a in args]
        \\    return func(*args)
        \\
        \\def ccall(path, name, args):
        \\    lib = ctypes.CDLL(path)
        \\    f = c_attr(lib, name)
        \\    return f(*args)
        \\
        \\def call_file(path, name, args):
        \\    spec = importlib.util.spec_from_file_location("module.name", path)
        \\    module = importlib.util.module_from_spec(spec)
        \\    spec.loader.exec_module(module)
        \\    return getattr(module, name)(*args)
        \\
        \\def re_split(p, s):
        \\    return re.split(p, s)
        \\
        \\def re_sub(p, r, s):
        \\    return re.sub(p, r, s)
        \\
        \\def json_dumps(v):
        \\    return json.dumps(v)
        \\
        \\def json_loads(s):
        \\    return json.loads(s)
        \\
        \\def json_dump_file(v, p):
        \\    with open(p, 'w') as f:
        \\        json.dump(v, f)
        \\    return None
        \\
        \\def json_load_file(p):
        \\    with open(p, 'r') as f:
        \\        return json.load(f)
        \\
        \\def lzma_compress(s):
        \\    return lzma.compress(s.encode('utf-8'), preset=9 | lzma.PRESET_EXTREME)
        \\
        \\def lzma_decompress(b):
        \\    return lzma.decompress(b).decode('utf-8')
        \\
        \\def timenow():
        \\    return datetime.datetime.now()
        \\
        \\def dirname(p):
        \\    return os.path.dirname(p)
        \\
        \\def join_path(args):
        \\    return os.path.join(*args)
        \\
        \\def abs_path(p):
        \\    return os.path.abspath(p)
        \\
        \\def basename(p):
        \\    return os.path.basename(p)
        \\
        \\def split_ext(p):
        \\    return os.path.splitext(p)
        \\
        \\def list_dir(p):
        \\    return os.listdir(p)
        \\
        \\def walk(p):
        \\    return list(os.walk(p))
        \\
        \\def is_link(p):
        \\    return os.path.islink(p)
        \\
        \\def read_link(p):
        \\    return os.readlink(p)
        \\
        \\def is_file(p):
        \\    return os.path.isfile(p)
        \\
        \\def is_dir(p):
        \\    return os.path.isdir(p)
        \\
        \\def exists(p):
        \\    return os.path.exists(p)
        \\
        \\def file_size(p):
        \\    return os.path.getsize(p)
        \\
        \\def file_read(p):
        \\    with open(p, 'r') as f:
        \\        return f.read()
        \\
        \\def file_write(p, mode, content):
        \\    with open(p, mode) as f:
        \\        if isinstance(content, list):
        \\            for line in content:
        \\                f.write(str(line))
        \\        else:
        \\            f.write(str(content))
        \\    return None
        \\
        \\def remove_path(p):
        \\    os.remove(p)
        \\
        \\def mkdir(p):
        \\    os.mkdir(p)
        \\
        \\def makedirs(p):
        \\    os.makedirs(p, exist_ok=True)
        \\
        \\def rmdir(p):
        \\    os.rmdir(p)
        \\
        \\def removedirs(p):
        \\    os.removedirs(p)
        \\
        \\def rename(a, b):
        \\    os.rename(a, b)
        \\
        \\def copyfile(a, b):
        \\    shutil.copyfile(a, b)
        \\
        \\def copy_file(a, b):
        \\    shutil.copy(a, b)
        \\
        \\def move_file(a, b):
        \\    shutil.move(a, b)
        \\
        \\def symlink(a, b):
        \\    os.symlink(a, b)
        \\
        \\def unlink(p):
        \\    os.unlink(p)
        \\
        \\def splitlines(s):
        \\    return s.splitlines()
        \\
        \\def sys_call(cmd):
        \\    return os.system(cmd)
        \\
        \\def wait(t):
        \\    time.sleep(t)
        \\
        \\def randint(a, b):
        \\    return random.randint(a, b)
        \\
        \\def http_get(url):
        \\    import requests
        \\    return requests.get(url).text
        \\
        \\def http_get_bytes(url):
        \\    import requests
        \\    return requests.get(url).content
        \\
        \\def read_stdin():
        \\    return sys.stdin.readline()
        \\
        \\def stdout_write(s):
        \\    sys.stdout.write(s)
        \\    sys.stdout.flush()
        \\
        \\def ppm_command(root, args):
        \\    packages = os.path.join(root, 'packages')
        \\    os.makedirs(packages, exist_ok=True)
        \\    api = 'http://pryzma.dzordz.pl/download'
        \\    def install(name, url=api):
        \\        target = os.path.join(packages, name)
        \\        try:
        \\            response = __import__('requests').get(url + '/' + name)
        \\            if response.status_code != 200:
        \\                print('Package', name, 'not found in the repository.')
        \\                return
        \\            os.makedirs(target, exist_ok=True)
        \\            archive = os.path.join(target, name + '.zip')
        \\            with open(archive, 'wb') as f: f.write(response.content)
        \\            import zipfile
        \\            with zipfile.ZipFile(archive) as z: z.extractall(target)
        \\            os.remove(archive)
        \\            print('Package', name, 'downloaded and installed successfully.')
        \\        except Exception as e:
        \\            print('Primary source failed:', url + '/' + name)
        \\            print('Trying fallback source (GitHub)...')
        \\            import subprocess
        \\            temp = os.path.join('/tmp', 'ppm_temp_' + name)
        \\            try:
        \\                subprocess.run(['git', 'clone', '--depth=1', 'https://github.com/IgorCielniak/Pryzma-packages', temp], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        \\                source = os.path.join(temp, name)
        \\                if not os.path.isdir(source): raise FileNotFoundError("Package '" + name + "' not found in GitHub repo.")
        \\                if os.path.exists(target): shutil.rmtree(target)
        \\                shutil.copytree(source, target)
        \\                print(name + ' installed successfully from GitHub.')
        \\            except Exception as err:
        \\                print('Fallback source failed:', err)
        \\                print('Package installation failed from both sources.')
        \\            finally:
        \\                if os.path.exists(temp): shutil.rmtree(temp)
        \\    if not args: return
        \\    cmd = args[0]
        \\    if cmd == 'help':
        \\        print('Commands: remove, list [avaliable], from URL PACKAGE..., install PACKAGE..., update [PACKAGE...], show [PACKAGE...], help, exit')
        \\    elif cmd == 'remove':
        \\        if len(args) < 2: print('Please provide a package name.')
        \\        else:
        \\            path = os.path.join(packages, args[1])
        \\            if os.path.exists(path): shutil.rmtree(path); print('Package', args[1], 'removed successfully.')
        \\            else: print('Package', args[1], 'not found.')
        \\    elif cmd == 'list':
        \\        if len(args) > 1 and args[1] == 'avaliable':
        \\            url = args[2] if len(args) > 2 else 'http://pryzma.dzordz.pl/api/fetch'
        \\            try:
        \\                response = __import__('requests').get(url)
        \\                names = response.json() if response.status_code == 200 else []
        \\                if names:
        \\                    print('Available packages:')
        \\                    for name in names: print('-', name)
        \\                else: print('No packages available on the server.')
        \\            except Exception as e: print('Error fetching packages:', e)
        \\        else:
        \\            names = os.listdir(packages)
        \\            if names:
        \\                print('Available packages:')
        \\                for name in names: print('-', name)
        \\            else: print('No packages installed.')
        \\    elif cmd in ('install', 'from'):
        \\        if cmd == 'from' and len(args) >= 3:
        \\            for name in args[2:]: install(name, args[1])
        \\        elif cmd == 'install' and len(args) >= 2:
        \\            for name in args[1:]: install(name)
        \\        else: print('Please provide a package name.')
        \\    elif cmd == 'update':
        \\        names = args[1:] or os.listdir(packages)
        \\        for name in names: install(name)
        \\    elif cmd == 'show':
        \\        names = args[1:] or os.listdir(packages)
        \\        if not names: print('No packages installed.')
        \\        for name in names:
        \\            path = os.path.join(packages, name, 'metadata.json')
        \\            if not os.path.isfile(path): print('Package metadata not found.'); continue
        \\            with open(path) as f: meta = json.load(f)
        \\            print(name, meta.get('version', 'Version not specified.'))
        \\            print('Author:', meta.get('author', 'Author not specified.'))
        \\            print('Description:', meta.get('description', 'Description not specified.'))
        \\            print('License:', meta.get('license', 'License not specified.'), '\\n')
        \\    else: print("Unknown command. Type 'help' for available commands.")
        \\
    ;

    pub fn init(allocator: Allocator) !*Py {
        Py_InitializeEx(0);
        const self = try allocator.create(Py);
        self.* = .{ .allocator = allocator, .helper = undefined, .ref_class = undefined, .funcref_class = undefined };
        const dict = PyDict_New() orelse return error.PythonError;
        const code = try allocator.allocSentinel(u8, helper_source.len, 0);
        @memcpy(code, helper_source);
        defer allocator.free(code);
        const res = PyRun_StringFlags(code.ptr, py_file_input, dict, dict, null);
        if (res == null) {
            PyErr_Print();
            return error.PythonError;
        }
        Py_DecRef(res.?);
        self.helper = dict;
        self.ref_class = PyDict_GetItemString(dict, "Ref") orelse return error.PythonError;
        self.funcref_class = PyDict_GetItemString(dict, "FuncRef") orelse return error.PythonError;
        self.initialized = true;
        return self;
    }

    pub fn helperFn(self: *Py, name: [:0]const u8) ?*PyObject {
        return PyDict_GetItemString(self.helper, name.ptr);
    }

    pub fn callHelper(self: *Py, name: [:0]const u8, args: []const *PyObject) !*PyObject {
        const f = self.helperFn(name) orelse return error.PythonError;
        const tuple = PyTuple_New(@intCast(args.len)) orelse return error.PythonError;
        for (args, 0..) |a, i| {
            Py_IncRef(a);
            _ = PyTuple_SetItem(tuple, @intCast(i), a);
        }
        defer Py_DecRef(tuple);
        const res = PyObject_CallObject(f, tuple) orelse {
            PyErr_Print();
            return error.PythonError;
        };
        return res;
    }

    pub fn newString(self: *Py, s: []const u8) !*PyObject {
        _ = self;
        return PyUnicode_FromStringAndSize(s.ptr, @intCast(s.len)) orelse error.PythonError;
    }

    pub fn newBytes(self: *Py, s: []const u8) !*PyObject {
        _ = self;
        return PyBytes_FromStringAndSize(s.ptr, @intCast(s.len)) orelse error.PythonError;
    }

    pub fn newInt(self: *Py, v: i64) !*PyObject {
        _ = self;
        return PyLong_FromLongLong(@intCast(v)) orelse error.PythonError;
    }

    pub fn newFloat(self: *Py, v: f64) !*PyObject {
        _ = self;
        return PyFloat_FromDouble(v) orelse error.PythonError;
    }

    pub fn newBool(self: *Py, v: bool) !*PyObject {
        _ = self;
        return PyBool_FromLong(if (v) 1 else 0) orelse error.PythonError;
    }

    pub fn strOf(self: *Py, obj: *PyObject) ![]const u8 {
        const s = PyObject_Str(obj) orelse return error.PythonError;
        defer Py_DecRef(s);
        var size: isize = 0;
        const ptr = PyUnicode_AsUTF8AndSize(s, &size) orelse return error.PythonError;
        return try self.allocator.dupe(u8, ptr[0..@intCast(size)]);
    }

    pub fn reprOf(self: *Py, obj: *PyObject) ![]const u8 {
        const s = PyObject_Repr(obj) orelse return error.PythonError;
        defer Py_DecRef(s);
        var size: isize = 0;
        const ptr = PyUnicode_AsUTF8AndSize(s, &size) orelse return error.PythonError;
        return try self.allocator.dupe(u8, ptr[0..@intCast(size)]);
    }

    pub fn toPy(self: *Py, v: Value, c_mode: bool) anyerror!*PyObject {
        switch (v) {
            .none => return noneObj(),
            .boolean => |b| return try self.newBool(b),
            .int => |i| return try self.newInt(i),
            .float => |f| return try self.newFloat(f),
            .string => |s| {
                if (c_mode) {
                    return PyBytes_FromStringAndSize(s.ptr, @intCast(s.len)) orelse error.PythonError;
                }
                return try self.newString(s);
            },
            .list => |l| {
                const py = PyList_New(@intCast(l.items.items.len)) orelse return error.PythonError;
                for (l.items.items, 0..) |item, i| {
                    const obj = try self.toPy(item, c_mode);
                    _ = PyList_SetItem(py, @intCast(i), obj);
                }
                return py;
            },
            .tuple => |t| {
                const py = PyTuple_New(@intCast(t.items.items.len)) orelse return error.PythonError;
                for (t.items.items, 0..) |item, i| {
                    const obj = try self.toPy(item, c_mode);
                    _ = PyTuple_SetItem(py, @intCast(i), obj);
                }
                return py;
            },
            .dict => |d| {
                const py = PyDict_New() orelse return error.PythonError;
                for (d.keys.items, d.values.items) |k, val| {
                    const pk = try self.toPy(k, c_mode);
                    const pv = try self.toPy(val, c_mode);
                    _ = PyDict_SetItem(py, pk, pv);
                    Py_DecRef(pk);
                    Py_DecRef(pv);
                }
                return py;
            },
            .reference => |r| {
                const name = try self.newString(r.var_name);
                const addr: *PyObject = if (r.addr) |a| try self.newInt(@intCast(a)) else noneObj();
                const res = try self.callHelper("make_ref", &.{ name, addr });
                Py_DecRef(name);
                return res;
            },
            .func_ref => |n| {
                const name = try self.newString(n);
                defer Py_DecRef(name);
                return try self.callHelper("make_funcref", &.{name});
            },
            .extern_fn => |e| return e.callable,
            .py_object => |p| return p,
            .lazy => return noneObj(),
            .isolate => return noneObj(),
        }
    }

    pub fn fromPy(self: *Py, obj: *PyObject) anyerror!Value {
        if (obj == noneObj()) return .none;
        if (obj == @as(*PyObject, @ptrCast(&_Py_TrueStruct))) return .{ .boolean = true };
        if (obj == @as(*PyObject, @ptrCast(&_Py_FalseStruct))) return .{ .boolean = false };
        if (PyObject_IsInstance(obj, @ptrCast(&PyBool_Type)) == 1) {
            return .{ .boolean = PyObject_IsTrue(obj) == 1 };
        }
        if (PyObject_IsInstance(obj, @ptrCast(&PyLong_Type)) == 1) {
            const n = PyLong_AsLongLong(obj);
            if (PyErr_Occurred() != null) {
                PyErr_Clear();
                const f = PyFloat_AsDouble(obj);
                return .{ .float = f };
            }
            return .{ .int = @intCast(n) };
        }
        if (PyObject_IsInstance(obj, @ptrCast(&PyFloat_Type)) == 1) {
            return .{ .float = PyFloat_AsDouble(obj) };
        }
        if (PyObject_IsInstance(obj, @ptrCast(&PyUnicode_Type)) == 1) {
            var size: isize = 0;
            const ptr = PyUnicode_AsUTF8AndSize(obj, &size) orelse return error.PythonError;
            return .{ .string = try self.allocator.dupe(u8, ptr[0..@intCast(size)]) };
        }
        if (PyObject_IsInstance(obj, @ptrCast(&PyBytes_Type)) == 1) {
            var s: ?[*]u8 = null;
            var size: isize = 0;
            if (PyBytes_AsStringAndSize(obj, &s, &size) == 0) {
                if (s) |p| return .{ .string = try self.allocator.dupe(u8, p[0..@intCast(size)]) };
            }
            return .{ .string = "" };
        }
        if (PyObject_IsInstance(obj, self.ref_class) == 1) {
            const name_obj = PyObject_GetAttrString(obj, "var_name") orelse return error.PythonError;
            defer Py_DecRef(name_obj);
            var size: isize = 0;
            const ptr = PyUnicode_AsUTF8AndSize(name_obj, &size) orelse return error.PythonError;
            const name = try self.allocator.dupe(u8, ptr[0..@intCast(size)]);
            const addr_obj = PyObject_GetAttrString(obj, "addr") orelse return error.PythonError;
            defer Py_DecRef(addr_obj);
            var addr: ?usize = null;
            if (addr_obj != noneObj()) {
                addr = @intCast(PyLong_AsLongLong(addr_obj));
            }
            return .{ .reference = .{ .var_name = name, .addr = addr } };
        }
        if (PyObject_IsInstance(obj, self.funcref_class) == 1) {
            const name_obj = PyObject_GetAttrString(obj, "func_name") orelse return error.PythonError;
            defer Py_DecRef(name_obj);
            var size: isize = 0;
            const ptr = PyUnicode_AsUTF8AndSize(name_obj, &size) orelse return error.PythonError;
            return .{ .func_ref = try self.allocator.dupe(u8, ptr[0..@intCast(size)]) };
        }
        if (PyObject_IsInstance(obj, @ptrCast(&PyList_Type)) == 1) {
            const n = PyList_Size(obj);
            const list = try List.create(self.allocator);
            var i: isize = 0;
            while (i < n) : (i += 1) {
                const item = PyList_GetItem(obj, i) orelse return error.PythonError;
                try list.append(try self.fromPy(item));
            }
            return .{ .list = list };
        }
        if (PyObject_IsInstance(obj, @ptrCast(&PyTuple_Type)) == 1) {
            const n = PyTuple_Size(obj);
            const list = try List.create(self.allocator);
            var i: isize = 0;
            while (i < n) : (i += 1) {
                const item = PyTuple_GetItem(obj, i) orelse return error.PythonError;
                try list.append(try self.fromPy(item));
            }
            return .{ .tuple = list };
        }
        if (PyObject_IsInstance(obj, @ptrCast(&PyDict_Type)) == 1) {
            const d = try Dict.create(self.allocator);
            var pos: isize = 0;
            var k: ?*PyObject = null;
            var v: ?*PyObject = null;
            while (PyDict_Next(obj, &pos, &k, &v) != 0) {
                try d.put(try self.fromPy(k.?), try self.fromPy(v.?));
            }
            if (d.getStr("__type__")) |t| {
                if (t == .string) {
                    d.type_name = t.string;
                    _ = d.remove(.{ .string = "__type__" });
                }
            }
            return .{ .dict = d };
        }
        Py_IncRef(obj);
        return .{ .py_object = obj };
    }

    pub fn evalString(self: *Py, code: []const u8, globals: ?*PyObject, locals: ?*PyObject) !*PyObject {
        const z = try self.allocator.allocSentinel(u8, code.len, 0);
        @memcpy(z, code);
        defer self.allocator.free(z);
        const g = globals orelse blk: {
            break :blk PyDict_New() orelse return error.PythonError;
        };
        const l = locals orelse g;
        const res = PyRun_StringFlags(z.ptr, py_eval_input, g, l, null) orelse return error.PythonError;
        return res;
    }

    pub fn execString(self: *Py, code: []const u8, globals: *PyObject, locals: *PyObject) !void {
        const z = try self.allocator.allocSentinel(u8, code.len, 0);
        @memcpy(z, code);
        defer self.allocator.free(z);
        const res = PyRun_StringFlags(z.ptr, py_file_input, globals, locals, null) orelse return error.PythonError;
        Py_DecRef(res);
    }

    pub fn dictToValue(self: *Py, dict: *PyObject) !*Dict {
        const d = try Dict.create(self.allocator);
        var pos: isize = 0;
        var k: ?*PyObject = null;
        var v: ?*PyObject = null;
        while (PyDict_Next(dict, &pos, &k, &v) != 0) {
            try d.put(try self.fromPy(k.?), try self.fromPy(v.?));
        }
        return d;
    }

    pub fn dictFromValue(self: *Py, d: *Dict) !*PyObject {
        const py = PyDict_New() orelse return error.PythonError;
        for (d.keys.items, d.values.items) |k, val| {
            const pk = try self.toPy(k, false);
            const pv = try self.toPy(val, false);
            _ = PyDict_SetItem(py, pk, pv);
            Py_DecRef(pk);
            Py_DecRef(pv);
        }
        return py;
    }
};

extern "c" fn PyList_GetItem(list: *PyObject, index: isize) ?*PyObject;
extern "c" fn PyTuple_GetItem(tuple: *PyObject, index: isize) ?*PyObject;
extern "c" fn PyTuple_Size(tuple: *PyObject) isize;
