#!/usr/bin/env bash
# Behavioural test of the "Install gitleaks" step in .github/workflows/audit.yml.
#
# The step's own script runs unchanged, against a local server standing in for
# the GitHub release download: curl is wrapped only to rewrite that one URL.
# A transient 504 must be retried a bounded number of times (lovspor#794), and
# a download that then arrives with the wrong bytes must still fail the
# pinned SHA-256 check: a retry may never hide a genuine integrity failure.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
server_pid=
cleanup() {
  [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

# The step's run: block, as written in the workflow.
python3 - "$root/.github/workflows/audit.yml" > "$work/step.sh" <<'PY'
import sys, textwrap
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
start = lines.index("      - name: Install gitleaks")
run = next(i for i in range(start, len(lines)) if lines[i].strip() == "run: |")
body = []
for line in lines[run + 1:]:
    if line.strip() and not line.startswith(" " * 10):
        break
    body.append(line)
print(textwrap.dedent("\n".join(body)))
PY

# Answers the first $1 requests with 504, then 200 with bytes that are not the
# pinned archive. Every request is counted in $work/requests.
cat > "$work/server.py" <<'PY'
import http.server, sys
failures, count_file, port_file = int(sys.argv[1]), sys.argv[2], sys.argv[3]
seen = 0
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        global seen
        seen += 1
        open(count_file, "w").write(str(seen))
        if seen <= failures:
            self.send_response(504)
            self.end_headers()
            return
        body = b"not the gitleaks archive"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
open(port_file, "w").write(str(server.server_address[1]))
server.serve_forever()
PY

real_curl=$(command -v curl)
mkdir -p "$work/bin"

run_step() { # $1: failures before the 200; prints the step's exit code
  rm -f "$work/requests" "$work/port"
  python3 "$work/server.py" "$1" "$work/requests" "$work/port" &
  server_pid=$!
  for _ in $(seq 50); do [ -s "$work/port" ] && break; sleep 0.1; done
  cat > "$work/bin/curl" <<SH
#!/usr/bin/env bash
args=()
for arg in "\$@"; do
  args+=("\${arg/https:\/\/github.com\/gitleaks\/gitleaks\/releases\/download/http://127.0.0.1:$(cat "$work/port")}")
done
exec "$real_curl" "\${args[@]}"
SH
  chmod +x "$work/bin/curl"
  mkdir -p "$work/runner"
  set +e
  PATH="$work/bin:$PATH" RUNNER_OS=Linux RUNNER_ARCH=X64 RUNNER_TEMP="$work/runner" \
    GITLEAKS_VERSION=8.30.1 bash "$work/step.sh" > "$work/out" 2>&1
  code=$?
  set -e
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  server_pid=
  echo "$code"
}

fail() { echo "FAIL: $*"; cat "$work/out"; exit 1; }

# Two transient 504s are retried; the bytes that then arrive are checked and refused.
code=$(run_step 2)
[ "$(cat "$work/requests")" = 3 ] || fail "expected 3 requests after two 504s, got $(cat "$work/requests")"
[ "$code" != 0 ] || fail "wrong bytes passed the pinned checksum"
grep -q "FAILED" "$work/out" || fail "the failure is not the checksum check"
echo "ok: two 504s retried, wrong bytes refused by the pinned SHA-256"

# A download that never recovers fails after a bounded number of attempts.
code=$(run_step 1000)
[ "$code" = 22 ] || fail "expected curl exit 22 on a persistent 504, got $code"
[ "$(cat "$work/requests")" = 6 ] || fail "expected 6 attempts, got $(cat "$work/requests")"
echo "ok: a persistent 504 fails after 6 attempts"
