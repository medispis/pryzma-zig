#!/usr/bin/env bash
set -eu

bin="$(realpath "$1")"
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
port_file="$tmp/port"
source_file="$tmp/http_import.pryzma"
server_pid=""
cleanup() {
    if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; fi
    rm -rf "$tmp"
}
trap cleanup EXIT

python3 -c 'import http.server, os, sys; os.chdir(sys.argv[2]); server = http.server.HTTPServer(("127.0.0.1", 0), http.server.SimpleHTTPRequestHandler); open(sys.argv[1], "w").write(str(server.server_port)); server.serve_forever()' "$port_file" "$root/tests" >/dev/null 2>&1 &
server_pid=$!
for _ in {1..50}; do
    [[ -s "$port_file" ]] && break
    kill -0 "$server_pid" 2>/dev/null || { echo "HTTP test server failed to start"; exit 1; }
    sleep 0.1
done
[[ -s "$port_file" ]] || { echo "HTTP test server did not publish a port"; exit 1; }
port="$(cat "$port_file")"
cat >"$source_file" <<EOF
use "http://127.0.0.1:${port}/http_import_module.pryzma"
@http_import_module.greet("HTTP import works")
EOF

actual="$("$bin" "$source_file" 2>&1)"
if [[ "$actual" == "HTTP import works" ]]; then
    echo "[OK] HTTP module import"
else
    echo "[FAIL] HTTP module import"
    printf '%s\n' "$actual"
    exit 1
fi
