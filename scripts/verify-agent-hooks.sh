#!/bin/bash
#
# 隔离环境验证矩阵：`AgentIsland/Resources/agent-island-state.py` 的多来源归一与决定回写。
#
# 覆盖 11 个来源，每个来源喂一条**该来源真实形状**的代表性载荷，断言三件事：
#   ① 信封关键字段：`agent` / `event` / `status` / `session_id`（外加各来源特有的
#      cwd / tool / tool_input / session_file）
#   ② 阻塞事件（PermissionRequest）的 stdout 形状按来源翻译
#      （claude 家族/Codex/TraeCli → hookSpecificOutput 信封；gemini → {"decision":"allow"}；
#       cline → 永远立刻 {"cancel":false}）
#   ③ 非阻塞事件**不等应答**：替身保持沉默时脚本也必须秒退且不写 stdout
# 另加一条**超时负控**：替身不答时阻塞事件必须在预算内退出、且不写 stdout（回落原生审批）。
#
# 替身（`<ROOT>/notch_double.py`）的读语义与真实应用一致：poll + 读到首个字节后静默 50ms
# 即算一条消息读完，不要求换行或半关闭（同 HookSocketServer）。`silence` 档**保持连接
# 打开、不发应答**，让客户端自己的超时成为裁决者；若替身直接关连接，语义就变成「应用被杀」。
#
# 用法：
#   scripts/verify-agent-hooks.sh                       # 跑全部 case
#   scripts/verify-agent-hooks.sh claude-permission-allow gemini-before-tool
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# 物理路径：macOS 的 `/tmp` 是 `/private/tmp` 的软链，而脚本取 cwd 用的是
# `os.getcwd()`（返回物理路径的形式），断言必须拿同一形式比。
PWD_PHYSICAL="$(pwd -P)"
SCRIPT="$REPO_ROOT/AgentIsland/Resources/agent-island-state.py"
ROOT="${ROOT:-/tmp/agent-island-hook-verify}"
SOCK="$ROOT/agent-island.sock"
LOG="$ROOT/requests.jsonl"
MODE_FILE="$ROOT/mode.txt"
ANSWERS_FILE="$ROOT/answers.json"
HOME_SANDBOX="$ROOT/home"
GROK_HOME="$ROOT/grok"
# Grok 的 workspace 环境兜底（`cwd` → `workspaceRoot` → `GROK_WORKSPACE_ROOT` → 进程 cwd）
GROK_WORKSPACE="$ROOT/grok-workspace"
# 普通审批的等待预算：默认 300s 太长，验证时压到 20s（实现读的是同一个环境变量）。
APPROVAL_BUDGET="${APPROVAL_BUDGET:-20}"
ASK_BUDGET="${ASK_BUDGET:-20}"
# 「非阻塞 / 秒退」判据的上限（秒）。替身沉默时若脚本等了应答，elapsed 会接近预算。
FAST_LIMIT=5
FAILED=0
SKIPPED=0
SERVER_PID=""

log()  { printf '%s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILED=$((FAILED + 1)); }
# 跳过：只在「这条判据在当前环境无法成立」时用（例如导出的树里没有 git 历史）。
# 跳过不算通过、也不算失败，但必须打印原因，且最终摘要里可见。
skip() { printf 'SKIP  %s\n' "$*"; SKIPPED=$((SKIPPED + 1)); }

# ---------------------------------------------------------------------------
# 替身：按 mode 文件逐请求应答，并把收到的信封按行追加到日志
# ---------------------------------------------------------------------------

write_double() {
  cat > "$1" <<'PY'
"""AgentIsland hook socket 的替身：按 mode 文件逐请求应答。

读语义复刻真实应用（HookSocketServer）：poll + 读到首个字节后静默 50ms 即算一条消息读完，
不要求换行也不要求半关闭。日志按追加写，每行一个 {"t", "mode", "request"}；request 用
**嵌套对象**记录，内层引号因此不被转义，断言可以直接 grep 字段。
"""
import json
import select
import socket
import sys
import threading
import time

SOCK = sys.argv[1]
LOG = sys.argv[2]
MODE_FILE = sys.argv[3]
ANSWERS_FILE = sys.argv[4] if len(sys.argv) > 4 else None


def current_mode():
    """本次请求用哪个档；读不到按 allow。"""
    try:
        with open(MODE_FILE, encoding="utf-8") as fh:
            return fh.read().strip() or "allow"
    except OSError:
        return "allow"


def current_answers():
    """answer 档的作答：{"<问题 id>": ["<label>"]}。"""
    if ANSWERS_FILE is None:
        return {}
    try:
        with open(ANSWERS_FILE, encoding="utf-8") as fh:
            loaded = json.load(fh)
        return loaded if isinstance(loaded, dict) else {}
    except (OSError, ValueError):
        return {}


def handle(conn):
    buf = b""
    try:
        while True:
            ready, _, _ = select.select([conn], [], [], 0.05)
            if not ready:
                if buf:
                    break  # 50ms 静默且有数据 → 读完
                continue
            chunk = conn.recv(65536)
            if not chunk:
                break  # EOF
            buf += chunk
            if b"\n" in buf:
                break
    except OSError:
        return

    mode = current_mode()
    raw = buf.decode("utf-8", "replace").strip()
    try:
        request = json.loads(raw)
    except ValueError:
        request = raw
    with open(LOG, "a", encoding="utf-8") as fh:
        fh.write(json.dumps({"t": time.time(), "mode": mode, "request": request},
                            ensure_ascii=False) + "\n")

    try:
        if mode == "allow":
            conn.sendall(b'{"decision":"allow"}')
        elif mode == "deny":
            conn.sendall(b'{"decision":"deny","reason":"denied by verify-agent-hooks"}')
        elif mode == "answer":
            payload = json.dumps({"decision": "answer", "answers": current_answers()})
            conn.sendall(payload.encode("utf-8"))
        elif mode == "passthrough":
            # 应用在门口丢弃这条信封时的显式应答（`shouldIgnore`）：hook 脚本必须**不输出**，
            # 让工具回落自己的原生审批 —— 与扩展侧的 passthrough 语义一致。
            conn.sendall(b'{"decision":"passthrough"}')
        else:
            # silence：不发应答、保持连接打开（最多 120s），等客户端自己超时。
            for _ in range(1200):
                time.sleep(0.1)
    except OSError:
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


def main():
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK)
    srv.listen(16)
    print("listening on %s" % SOCK, flush=True)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


main()
PY
}

# ---------------------------------------------------------------------------
# stdout 形状判据（用真 JSON 解析，而不是子串匹配）
# ---------------------------------------------------------------------------

write_stdout_checker() {
  cat > "$1" <<'PY'
"""按 kind 断言 hook 脚本的 stdout 形状：解析真 JSON 并逐字段核对。

用法：check_stdout.py <stdout 文件> <kind> [问题正文]
退出码 0 = 通过；非 0 = 失败，原因打印到 stdout（供 shell 原样贴出）。
"""
import json
import sys


def load(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    if text.strip() == "":
        return None
    return json.loads(text)


def behavior(payload, expected):
    decision = payload["hookSpecificOutput"]["decision"]
    assert payload["hookSpecificOutput"]["hookEventName"] == "PermissionRequest", \
        "hookEventName 不是 PermissionRequest"
    assert decision["behavior"] == expected, "behavior=%r（期望 %r）" % (decision["behavior"], expected)
    return decision


def main():
    path, kind = sys.argv[1], sys.argv[2]
    payload = load(path)
    assert payload is not None, "stdout 为空"

    if kind == "claude-allow":
        behavior(payload, "allow")
    elif kind == "claude-deny":
        decision = behavior(payload, "deny")
        assert decision.get("message"), "deny 缺 message"
    elif kind == "gemini-allow":
        assert payload == {"decision": "allow"}, "gemini 形状不对：%r" % (payload,)
    elif kind == "cline-cancel":
        assert payload == {"cancel": False}, "cline 形状不对：%r" % (payload,)
    elif kind == "ask-answer":
        decision = behavior(payload, "allow")
        updated = decision.get("updatedInput")
        assert isinstance(updated, dict), "缺 updatedInput"
        assert isinstance(updated.get("questions"), list) and updated["questions"], \
            "updatedInput 丢了 questions（Claude 侧会崩）"
        answers = updated.get("answers")
        question = sys.argv[3]
        assert isinstance(answers, dict), "updatedInput.answers 不是对象"
        assert answers.get(question) == "C1", "answers[%r]=%r（期望 \"C1\"）" % (
            question, answers.get(question))
    else:
        raise AssertionError("未知 kind：%s" % kind)
    print("OK")


main()
PY
}

# ---------------------------------------------------------------------------
# 老版本逐字比对（Claude 路径必须与改造前一致）
# ---------------------------------------------------------------------------

write_pid_checker() {
  cat > "$1" <<'PY'
"""断言信封里的 pid 落在「活的、确实是该来源 CLI」的祖先进程上。

用法：check_pid.py <被验证脚本> <信封 jsonl> <来源> <mode>
mode：
  absent        这条事件不该带 pid（cline，或链上没有该 CLI）
  ancestor      pid 若存在，必须是**活的**且二进制名命中该来源；不存在也通过
  equals:<pid>  pid 必须等于该 pid，且同样要活着、命中

判据直接复用被验证脚本自己的 `process_table` / `matches_source_binary`，避免两份规则漂移。
打印 `OK <证据>` 或 `FAIL <原因>`（退出码 0/1）。
"""
import importlib.util
import json
import sys


def load_module(path):
    spec = importlib.util.spec_from_file_location("agent_island_state_under_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def last_request(path):
    with open(path, encoding="utf-8") as fh:
        lines = [line for line in fh.read().splitlines() if line.strip()]
    if not lines:
        raise AssertionError("没有收到任何信封")
    return json.loads(lines[-1]).get("request", {})


def main():
    script_path, envelope_path, source, mode = sys.argv[1:5]
    module = load_module(script_path)
    request = last_request(envelope_path)
    pid = request.get("pid")
    table = module.process_table()

    def report(message):
        print(message)

    if mode == "absent":
        if pid is None:
            report("OK absent（链上没有 %s 的匹配祖先）" % source)
            return
        entry = table.get(pid)
        detail = entry[1] if entry else "进程已不在表里"
        report("FAIL 不该带 pid，却有 pid=%s（%s）" % (pid, detail))
        return

    if pid is None:
        if mode == "ancestor":
            report("OK absent（链上没有 %s 的匹配祖先）" % source)
        else:
            report("FAIL 期望 pid=%s，信封里没有 pid 字段" % mode.split(":", 1)[1])
        return

    entry = table.get(pid)
    if entry is None:
        report("FAIL pid=%s 已不在进程表里（上报了会秒退的进程）" % pid)
        return
    if not module.matches_source_binary(entry, source):
        report("FAIL pid=%s 的进程不是 %s 的 CLI（comm=%s argv=%s）" % (pid, source, entry[1], entry[2]))
        return
    if mode.startswith("equals:"):
        want = int(mode.split(":", 1)[1])
        if pid != want:
            report("FAIL pid=%s != 期望的 %s" % (pid, want))
            return
        report("OK pid=%s 就是链上那个 %s 进程（comm=%r）" % (pid, source, entry[1]))
        return
    report("OK pid=%s 活着且命中 %s（comm=%r）" % (pid, source, entry[1]))


main()
PY
}

write_envelope_comparator() {
  cat > "$1" <<'PY'
"""比对两条信封是否等价（忽略新脚本新增的键）。

忽略集：
* `agent` / `session_file`：新增的归属与记录路径（契约要求，应用侧只做等价消费）
* `pid` / `tty`：两次运行的进程与终端由验证脚本继承，同一 shell 下必然相同，不构成行为判据
* `expects_response`：契约要求阻塞审批显式带上；对 Claude 是**行为中性**的——应用的
  `HookEvent.expectsResponse` 对 `PermissionRequest` + `waiting_for_approval` 本来就判真，
  不看这个字段（见 HookSocketServer.swift）。

用法：compare_envelope.py <老信封文件> <新信封文件> [额外忽略的键（逗号分隔）]；退出码 0 = 等价。
"""
import json
import sys

IGNORED = ("agent", "session_file", "pid", "tty", "expects_response")
EXTRA_IGNORED = tuple(k for k in (sys.argv[3].split(",") if len(sys.argv) > 3 else []) if k)


def requests(path):
    out = []
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return out
    for line in lines:
        if not line.strip():
            continue
        entry = json.loads(line)
        request = entry.get("request")
        if isinstance(request, dict):
            ignored = IGNORED + EXTRA_IGNORED
            out.append({k: v for k, v in request.items() if k not in ignored})
    return out


old, new = requests(sys.argv[1]), requests(sys.argv[2])
if len(old) != len(new):
    print("信封条数不同：老 %d 条 / 新 %d 条" % (len(old), len(new)))
    sys.exit(1)
for index, (left, right) in enumerate(zip(old, new)):
    if left == right:
        continue
    diff = sorted(set(left) ^ set(right)) or sorted(
        key for key in set(left) & set(right) if left[key] != right[key])
    print("第 %d 条信封不同，差异键：%s\n  老：%s\n  新：%s" % (
        index + 1, diff, json.dumps(left, ensure_ascii=False), json.dumps(right, ensure_ascii=False)))
    sys.exit(1)
print("OK")
PY
}

# ---------------------------------------------------------------------------
# 沙箱
# ---------------------------------------------------------------------------

prepare_sandbox() {
  rm -rf "$ROOT"
  mkdir -p "$ROOT" "$HOME_SANDBOX" "$GROK_HOME" "$ROOT/cases"
  : > "$LOG"
  write_double "$ROOT/notch_double.py"
  write_stdout_checker "$ROOT/check_stdout.py"
  write_envelope_comparator "$ROOT/compare_envelope.py"
  write_pid_checker "$ROOT/check_pid.py"
  printf '%s\n' 'silence' > "$MODE_FILE"
  printf '{}' > "$ANSWERS_FILE"
}

start_server() {
  python3 "$ROOT/notch_double.py" "$SOCK" "$LOG" "$MODE_FILE" "$ANSWERS_FILE" \
    > "$ROOT/double.log" 2>&1 &
  SERVER_PID=$!
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -S "$SOCK" ] && return 0
    sleep 0.3
  done
  fail "替身没起来（$SOCK 不存在）"
  return 1
}

stop_server() {
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null; fi
  SERVER_PID=""
  rm -f "$SOCK"
}

# ---------------------------------------------------------------------------
# 断言
# ---------------------------------------------------------------------------

count_log() {
  if [ ! -f "$LOG" ]; then printf 0; return; fi
  printf '%s' "$(grep -c . "$LOG" 2>/dev/null || true)"
}

assert_contains() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then
    pass "$3：含「${2}」"
  else
    fail "$3：缺「${2}」（$(head -c 400 "$1" 2>/dev/null)）"
  fi
}

assert_absent() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then
    fail "$3：不该含「${2}」"
  else
    pass "$3：不含「${2}」"
  fi
}

assert_empty() {
  if [ -s "$1" ]; then
    fail "$2：stdout 应为空，实际「$(head -c 200 "$1")」"
  else
    pass "$2：stdout 为空"
  fi
}

assert_exit_zero() {
  if [ "$1" = "0" ]; then pass "$2：退出码 0"; else fail "$2：退出码 ${1}"; fi
}

# elapsed 判据：由 python 比较浮点秒，避免 bash 只能算整秒。
assert_faster_than() {
  local verdict
  verdict="$(python3 - "$1" "$2" <<'PY'
import sys

elapsed, limit = float(sys.argv[1]), float(sys.argv[2])
print("OK %.2fs < %.2fs" % (elapsed, limit) if elapsed < limit
      else "SLOW %.2fs >= %.2fs" % (elapsed, limit))
PY
)"
  case "$verdict" in
    OK*) pass "$3：$verdict" ;;
    *)   fail "$3：$verdict" ;;
  esac
}

# pid 判据：复用 check_pid.py（absent / ancestor / equals:<pid>）。
assert_pid() {
  local file="$1" source="$2" mode="$3" label="$4"
  local output
  output="$(python3 "$ROOT/check_pid.py" "$SCRIPT" "$file" "$source" "$mode" 2>&1)"
  case "$output" in
    OK*) pass "${label}（${source}/${mode}）：${output#OK }" ;;
    *)   fail "${label}（${source}/${mode}）：${output}" ;;
  esac
}

assert_stdout_shape() {
  local file="$1" kind="$2" label="$3" extra="${4:-}"
  local output
  output="$(python3 "$ROOT/check_stdout.py" "$file" "$kind" "$extra" 2>&1)"
  if [ "$output" = "OK" ]; then
    pass "${label}：stdout 形状 ${kind}"
  else
    fail "${label}：stdout 形状 ${kind} 不符 → ${output}"
  fi
}

# ---------------------------------------------------------------------------
# 单 case
# ---------------------------------------------------------------------------

# run_case 标签 来源|"-" 事件|"-" 替身档 期望stdout 载荷 信封判据…
#
# 期望 stdout 取值：empty（必须不写 stdout 且秒退）/ claude-allow / claude-deny /
# gemini-allow / cline-cancel。
# cline 的转发在后台完成，因此它的信封是**异步**到达的（下面按期望形状等待）。
run_case() {
  local label="$1" source="$2" eventarg="$3" mode="$4" expect_stdout="$5" payload="$6"
  shift 6
  local needles=("$@")
  local dir="$ROOT/cases/$label"
  rm -rf "$dir"
  mkdir -p "$dir"

  printf '%s\n' "$mode" > "$MODE_FILE"
  local before
  before="$(count_log)"
  local start end
  start="$(python3 -c 'import time; print(time.time())')"

  if [ "$source" = "-" ]; then
    printf '%s' "$payload" | hook_env python3 "$SCRIPT" \
      > "$dir/stdout.txt" 2> "$dir/stderr.txt"
  elif [ "$eventarg" = "-" ]; then
    printf '%s' "$payload" | hook_env python3 "$SCRIPT" --source "$source" \
      > "$dir/stdout.txt" 2> "$dir/stderr.txt"
  else
    printf '%s' "$payload" | hook_env python3 "$SCRIPT" --source "$source" --event "$eventarg" \
      > "$dir/stdout.txt" 2> "$dir/stderr.txt"
  fi
  local code=$?
  end="$(python3 -c 'import time; print(time.time())')"

  log "=== case=${label}（来源 ${source}，事件参数 ${eventarg}，替身 ${mode}）"

  if [ "$expect_stdout" = "cline-cancel" ]; then
    # 后台转发：等信封出现（最多 3s），否则后面所有信封断言都会失败。
    local waited=0
    while [ "$(count_log)" -le "$before" ] && [ "$waited" -lt 30 ]; do
      sleep 0.1
      waited=$((waited + 1))
    done
  fi
  sed -n "$((before + 1)),\$p" "$LOG" > "$dir/envelopes.jsonl" 2>/dev/null || true

  log "    ---- stdout ----"
  sed 's/^/    /' "$dir/stdout.txt" 2>/dev/null
  log "    ---- 信封（${label}）----"
  sed 's/^/    /' "$dir/envelopes.jsonl" 2>/dev/null
  log "    ---- 断言 ----"

  assert_exit_zero "$code" "$label"
  local needle
  for needle in "${needles[@]}"; do
    assert_contains "$dir/envelopes.jsonl" "$needle" "$label 信封"
  done

  case "$expect_stdout" in
    empty)
      assert_empty "$dir/stdout.txt" "$label"
      assert_faster_than "$(python3 -c "print($end - $start)")" "$FAST_LIMIT" "$label 不等应答"
      ;;
    claude-allow)  assert_stdout_shape "$dir/stdout.txt" claude-allow "$label" ;;
    claude-deny)   assert_stdout_shape "$dir/stdout.txt" claude-deny "$label" ;;
    gemini-allow)  assert_stdout_shape "$dir/stdout.txt" gemini-allow "$label" ;;
    cline-cancel)  assert_stdout_shape "$dir/stdout.txt" cline-cancel "$label" ;;
    ask-answer)    assert_stdout_shape "$dir/stdout.txt" ask-answer "$label" "$ASK_QUESTION" ;;
    *)             fail "${label}：未知的期望 stdout 类型 ${expect_stdout}" ;;
  esac
  if [ -s "$dir/stderr.txt" ]; then
    fail "${label}：stderr 有输出「$(head -c 200 "$dir/stderr.txt")」"
  else
    pass "${label}：stderr 为空"
  fi
  log ""
}

# 超时负控：替身不答 → 阻塞事件必须在预算内退出、且不写 stdout（回落原生审批）。
run_timeout_case() {
  local label="timeout-negative"
  local dir="$ROOT/cases/$label"
  rm -rf "$dir"
  mkdir -p "$dir"
  printf '%s\n' 'silence' > "$MODE_FILE"
  log "=== case=${label}（替身沉默，审批预算 ${TIMEOUT_BUDGET}s）"

  local before start end
  before="$(count_log)"
  start="$(python3 -c 'import time; print(time.time())')"
  printf '%s' '{"session_id":"claude-timeout-1","cwd":"/tmp/timeout","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}' \
    | AGENT_ISLAND_SOCKET="$SOCK" AGENT_ISLAND_APPROVAL_TIMEOUT_SECONDS="$TIMEOUT_BUDGET" \
      python3 "$SCRIPT" --source claude > "$dir/stdout.txt" 2> "$dir/stderr.txt"
  local code=$?
  end="$(python3 -c 'import time; print(time.time())')"
  sed -n "$((before + 1)),\$p" "$LOG" > "$dir/envelopes.jsonl" 2>/dev/null || true

  log "    ---- stdout（应为空）----"
  sed 's/^/    /' "$dir/stdout.txt" 2>/dev/null
  log "    ---- 断言 ----"
  assert_exit_zero "$code" "$label"
  assert_empty "$dir/stdout.txt" "$label 拿不到决定时不输出"
  assert_contains "$dir/envelopes.jsonl" '"expects_response": true' "$label 负控前置（确实问过）"
  local elapsed
  elapsed="$(python3 -c "print($end - $start)")"
  local verdict
  verdict="$(python3 - "$elapsed" "$TIMEOUT_BUDGET" <<'PY'
import sys

elapsed, budget = float(sys.argv[1]), float(sys.argv[2])
# 下界：必须真的等过预算（否则说明它根本没阻塞）；上界：留 5s 余量。
print("OK %.2fs ∈ [%.1f, %.1f]" % (elapsed, budget * 0.8, budget + 5)
      if budget * 0.8 <= elapsed <= budget + 5 else
      "OUT %.2fs ∉ [%.1f, %.1f]" % (elapsed, budget * 0.8, budget + 5))
PY
)"
  case "$verdict" in
    OK*) pass "${label}：${verdict}" ;;
    *)   fail "${label}：${verdict}" ;;
  esac
  if [ -s "$dir/stderr.txt" ]; then
    fail "${label}：stderr 有输出「$(head -c 200 "$dir/stderr.txt")」"
  else
    pass "${label}：stderr 为空"
  fi
  log ""
}

hook_env() {
  env HOME="$HOME_SANDBOX" GROK_HOME="$GROK_HOME" GROK_WORKSPACE_ROOT="$GROK_WORKSPACE" \
      AGENT_ISLAND_SOCKET="$SOCK" \
      AGENT_ISLAND_APPROVAL_TIMEOUT_SECONDS="$APPROVAL_BUDGET" \
      AGENT_ISLAND_ASK_TIMEOUT_SECONDS="$ASK_BUDGET" \
      "$@"
}

# ---------------------------------------------------------------------------
# 逐字比对：新脚本 vs HEAD 版（Claude 老路径）
# ---------------------------------------------------------------------------

# 老配置（`python3 <path>`，不带参数）必须与改造前**行为一致**：同一条 claude 载荷下，
# stdout 字节相等、信封除新增键（agent / session_file）与 pid/tty 外逐字段相等。
LEGACY_CASES=(
  "pre-tool-use|silence|{\"session_id\":\"legacy-pre\",\"cwd\":\"/tmp/legacy\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"},\"tool_use_id\":\"tu-1\",\"transcript_path\":\"/tmp/legacy/t.jsonl\"}"
  "post-tool-use|silence|{\"session_id\":\"legacy-post\",\"cwd\":\"/tmp/legacy\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"},\"tool_use_id\":\"tu-2\"}"
  "post-tool-use-failure|silence|{\"session_id\":\"legacy-postfail\",\"cwd\":\"/tmp/legacy\",\"hook_event_name\":\"PostToolUseFailure\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"},\"tool_use_id\":\"tu-3\",\"error\":\"boom\"}"
  "user-prompt-submit|silence|{\"session_id\":\"legacy-prompt\",\"cwd\":\"/tmp/legacy\",\"hook_event_name\":\"UserPromptSubmit\"}"
  "stop|silence|{\"session_id\":\"legacy-stop\",\"cwd\":\"/tmp/legacy\",\"hook_event_name\":\"Stop\"}"
  "stop-failure|silence|{\"session_id\":\"legacy-stopfail\",\"cwd\":\"/tmp/legacy\",\"hook_event_name\":\"StopFailure\",\"error\":\"rate limited\"}"
  "session-start|silence|{\"session_id\":\"legacy-start\",\"cwd\":\"/tmp/legacy\",\"hook_event_name\":\"SessionStart\"}"
  "session-end|silence|{\"session_id\":\"legacy-end\",\"cwd\":\"/tmp/legacy\",\"hook_event_name\":\"SessionEnd\"}"
  "notification-idle|silence|{\"session_id\":\"legacy-idle\",\"cwd\":\"/tmp/legacy\",\"hook_event_name\":\"Notification\",\"notification_type\":\"idle_prompt\",\"message\":\"waiting\"}"
  "notification-permission-prompt|silence|{\"session_id\":\"legacy-permprompt\",\"cwd\":\"/tmp/legacy\",\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\"}"
  "pre-compact|silence|{\"session_id\":\"legacy-compact\",\"cwd\":\"/tmp/legacy\",\"hook_event_name\":\"PreCompact\"}"
  "post-compact|silence|{\"session_id\":\"legacy-postcompact\",\"cwd\":\"/tmp/legacy\",\"hook_event_name\":\"PostCompact\"}"
  "subagent-start|silence|{\"session_id\":\"legacy-sub\",\"cwd\":\"/tmp/legacy\",\"hook_event_name\":\"SubagentStart\"}"
  "unknown-event|silence|{\"session_id\":\"legacy-unknown\",\"cwd\":\"/tmp/legacy\",\"hook_event_name\":\"SomethingBrandNew\"}"
  "permission-allow|allow|{\"session_id\":\"legacy-perm-allow\",\"cwd\":\"/tmp/legacy\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}"
  "permission-deny|deny|{\"session_id\":\"legacy-perm-deny\",\"cwd\":\"/tmp/legacy\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}"
  "ask-answer|answer|{\"session_id\":\"legacy-ask\",\"cwd\":\"/tmp/legacy\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"AskUserQuestion\",\"tool_input\":{\"questions\":[{\"question\":\"C_LEGACY?\",\"options\":[{\"label\":\"C1\"},{\"label\":\"C2\"}]}]}}"
)

# 取「改造前那一版」脚本：从历史里找**最新的、还不含 --source 的**那一次修订。
# 不直接用 HEAD：新脚本一旦被提交，HEAD 就变成了新版，比对会静默失去意义（实测踩到）。
find_legacy_blob() {
  local destination="$1" revision
  while read -r revision; do
    [ -n "$revision" ] || continue
    if git -C "$REPO_ROOT" show "$revision:AgentIsland/Resources/agent-island-state.py" \
        > "$destination" 2>/dev/null && [ -s "$destination" ] \
        && ! grep -qF -- '--source' "$destination"; then
      printf '%s' "$revision"
      return 0
    fi
  done < <(git -C "$REPO_ROOT" log -n 100 --format=%H -- AgentIsland/Resources/agent-island-state.py)
  return 1
}

run_legacy_case() {
  local dir="$ROOT/cases/legacy-equivalence"
  rm -rf "$dir"
  mkdir -p "$dir"
  local legacy="$dir/legacy-state.py"
  local legacy_rev
  legacy_rev="$(find_legacy_blob "$legacy")"
  if [ -z "$legacy_rev" ]; then
    # 两种情况都不是「本脚本坏了」：① 在 `git archive` 导出的树里跑（没有 .git）；
    # ② 历史被压缩/重写过，改造前那次修订已经不在了。跳过并说明，别报成失败——
    # 门禁的判据是「当前脚本的行为」，历史比对只是加分证据。
    if git -C "$REPO_ROOT" rev-parse --git-dir > /dev/null 2>&1; then
      skip "legacy-equivalence：历史里找不到改造前的版本（最近 100 次修订都带 --source，历史可能被重写）"
    else
      skip "legacy-equivalence：$REPO_ROOT 不是 git 工作树（导出的树没有历史可比）"
    fi
    return
  fi

  log "=== case=legacy-equivalence（新脚本 vs 改造前版本 ${legacy_rev:0:8}：${#LEGACY_CASES[@]} 条 claude 载荷）"
  printf '%s' '{"C_LEGACY?": ["C1"]}' > "$ANSWERS_FILE"
  local row label mode payload
  for row in "${LEGACY_CASES[@]}"; do
    label="${row%%|*}"
    row="${row#*|}"
    mode="${row%%|*}"
    payload="${row#*|}"
    printf '%s\n' "$mode" > "$MODE_FILE"

    local before
    before="$(count_log)"
    printf '%s' "$payload" | hook_env python3 "$legacy" > "$dir/$label.old.out" 2> "$dir/$label.old.err"
    local old_code=$?
    local mid
    mid="$(count_log)"
    sed -n "$((before + 1)),$((mid))p" "$LOG" > "$dir/$label.old.jsonl" 2>/dev/null || true

    before="$mid"
    printf '%s' "$payload" | hook_env python3 "$SCRIPT" > "$dir/$label.new.out" 2> "$dir/$label.new.err"
    local new_code=$?
    sed -n "$((before + 1)),\$p" "$LOG" > "$dir/$label.new.jsonl" 2>/dev/null || true

    assert_exit_zero "$old_code" "legacy(${label}) 老脚本"
    assert_exit_zero "$new_code" "legacy(${label}) 新脚本"
    # 老脚本会把 ppid 当 pid 报（这次要修的缺陷），比对时 pid/tty 一律忽略（见比对器注释）。

    if cmp -s "$dir/$label.old.out" "$dir/$label.new.out"; then
      pass "legacy(${label})：stdout 字节相等（$(wc -c < "$dir/$label.new.out" | tr -d ' ') 字节）"
    else
      fail "legacy(${label})：stdout 不同 → 老「$(head -c 200 "$dir/$label.old.out")」新「$(head -c 200 "$dir/$label.new.out")」"
    fi

    # `StopFailure` 是唯一一处**契约要求的**差异：归一表把它折到 `Stop`（与 `stop_failure`
    # 同义），应用侧两者都落 `.waitingForInput`，差别只有 `Stop` 会额外触发一次记录同步与
    # 子 Agent 收尾——对「一轮以 API 错误结束」正是应有的收尾。因此这一行改为断言
    # 「除 event 外逐字段相等 + stop_error 保留 + 归一后的 event 就是 Stop」。
    local extra_ignore=""
    if [ "$label" = "stop-failure" ]; then
      extra_ignore="event"
      assert_contains "$dir/$label.new.jsonl" '"event": "Stop"' "legacy(${label}) 归一后的事件名"
      assert_contains "$dir/$label.new.jsonl" '"stop_error": "rate limited"' "legacy(${label}) 错误文案保留"
    fi

    local verdict
    verdict="$(python3 "$ROOT/compare_envelope.py" "$dir/$label.old.jsonl" "$dir/$label.new.jsonl" \
      "$extra_ignore" 2>&1)"
    if [ "$verdict" = "OK" ]; then
      pass "legacy(${label})：信封等价（老 $(grep -c . "$dir/$label.old.jsonl" || true) 条 / 新 $(grep -c . "$dir/$label.new.jsonl" || true) 条${extra_ignore:+，额外忽略 ${extra_ignore}）}"
    else
      fail "legacy(${label})：信封不等价 → ${verdict}"
    fi
  done
  printf '{}' > "$ANSWERS_FILE"
  log ""
}

# ---------------------------------------------------------------------------
# 畸形 stdin：绝不因异常以非 0 退出（工具侧会把非 0 记成 hook 失败）
# ---------------------------------------------------------------------------

# 三种畸形输入（非法 JSON / 空 stdin / 顶层不是对象）都必须：退出码 0、不写 stdout/stderr，
# 且按契约用 `<source>-ppid-<ppid>` 兜底会话 id（第 4 条顺带验证 `--flag=值` 写法）。
run_malformed_case() {
  local dir="$ROOT/cases/malformed-stdin"
  rm -rf "$dir"
  mkdir -p "$dir"
  printf '%s\n' 'silence' > "$MODE_FILE"
  log "=== case=malformed-stdin（非法 JSON / 空 stdin / 非对象 JSON / --flag=值）"
  local row label payload args
  for row in "invalid-json|{not json|--source|claude" \
             "empty-stdin||--source|claude" \
             "non-object|[1,2]|--source|claude" \
             "flag-equals-form|{}|--source=codex --event=preToolUse|"; do
    label="${row%%|*}"
    row="${row#*|}"
    payload="${row%%|*}"
    row="${row#*|}"
    args="${row%%|*}"

    local before after
    before="$(count_log)"
    if [ -n "$args" ]; then
      # shellcheck disable=SC2086 # args 是刻意做词拆分（含 `--flag=值` 的整串）
      printf '%s' "$payload" | hook_env python3 "$SCRIPT" $args \
        > "$dir/$label.out" 2> "$dir/$label.err"
    else
      printf '%s' "$payload" | hook_env python3 "$SCRIPT" \
        > "$dir/$label.out" 2> "$dir/$label.err"
    fi
    local code=$?
    after="$(count_log)"
    sed -n "$((before + 1)),$((after))p" "$LOG" > "$dir/$label.jsonl" 2>/dev/null || true

    assert_exit_zero "$code" "malformed(${label})"
    assert_empty "$dir/$label.out" "malformed(${label}) 不写 stdout"
    if [ -s "$dir/$label.err" ]; then
      fail "malformed(${label})：stderr 有输出「$(head -c 200 "$dir/$label.err")」"
    else
      pass "malformed(${label})：stderr 为空"
    fi
    if [ "$label" = "flag-equals-form" ]; then
      assert_contains "$dir/$label.jsonl" '"agent": "codex"' "malformed(${label}) --source=值"
      assert_contains "$dir/$label.jsonl" '"event": "PreToolUse"' "malformed(${label}) --event=值"
    else
      assert_contains "$dir/$label.jsonl" '"agent": "claude"' "malformed(${label}) 缺来源时按 claude"
      assert_contains "$dir/$label.jsonl" '"session_id": "claude-ppid-' "malformed(${label}) 会话 id 兜底"
    fi
  done
  log ""
}

# ---------------------------------------------------------------------------
# 祖先解析：pid 与兜底 session_id 都必须落在「活得久的 CLI 进程」上
# ---------------------------------------------------------------------------

# 假 CLI 祖先：把 /bin/sh **符号链接**成目标名字（拷贝会被代码签名杀掉，实测 exit 137）。
# 进程镜像是解释器，名字只在 argv 里——这正是脚本型 / node 型 CLI 的真实形态，
# 因此判据必须同时看 comm 与 argv。
#
# 链路：假 CLI（argv[0] 的名字）→ 瞬时 sh → hook。`repeats` 次事件各起一个瞬时 sh，
# 用来证明「同一会话的多个事件拿到同一个兜底 session_id」。
FAKE_DIR="$ROOT/cases/fake-ancestor"
FAKE_SPAWN="$FAKE_DIR/spawn.sh"
FAKE_PID=""

spawn_fake_chain() {
  local fake="$1" source="$2" payload="$3" repeats="$4" out="$5" err="$6"
  mkdir -p "$FAKE_DIR/bin"
  ln -sf /bin/sh "$FAKE_DIR/bin/$fake"
  {
    printf '#!/bin/sh\n'
    local index
    for index in $(seq 1 "$repeats"); do
      printf "sh -c 'python3 \"%s\" --source \"%s\" < \"%s\"; :'\n" "$SCRIPT" "$source" "$payload"
      printf 'sleep 0.3\n'
    done
    printf 'sleep 5\n:\n'
  } > "$FAKE_SPAWN"
  # 环境必须显式给：链路里的 hook 要拿到 AGENT_ISLAND_SOCKET 等沙箱环境。
  # 这里**不能**套 hook_env（shell 函数）：`函数 &` 会多一层 fork，`$!` 拿到的是那层
  # 包装进程而不是假 CLI，后面 `equals:$FAKE_PID` 的断言就会假失败。`env … 命令 &`
  # 是简单命令的后台 fork+exec，`$!` 就是 env→假 CLI 这个进程本身。
  env HOME="$HOME_SANDBOX" GROK_HOME="$GROK_HOME" AGENT_ISLAND_SOCKET="$SOCK" \
    AGENT_ISLAND_APPROVAL_TIMEOUT_SECONDS="$APPROVAL_BUDGET" \
    AGENT_ISLAND_ASK_TIMEOUT_SECONDS="$ASK_BUDGET" \
    "$FAKE_DIR/bin/$fake" "$FAKE_SPAWN" > "$out" 2> "$err" &
  FAKE_PID=$!
  # 自检：后台 pid 必须真的是那个假 CLI（argv 里带假 CLI 路径），否则断言的前提不成立。
  if ! ps -o command= -p "$FAKE_PID" 2>/dev/null | grep -qF "$FAKE_DIR/bin/$fake"; then
    fail "假祖先没起来（pid=${FAKE_PID} 的 argv 里没有 $FAKE_DIR/bin/$fake）"
  fi
}

stop_fake_chain() {
  if [ -n "$FAKE_PID" ]; then kill "$FAKE_PID" 2>/dev/null; fi
  FAKE_PID=""
}

wait_for_envelopes() {
  local before="$1" want="$2" waited=0
  while [ "$(( $(count_log) - before ))" -lt "$want" ] && [ "$waited" -lt 60 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
}

# 断言文件里出现某串恰好 N 次。
assert_count() {
  local file="$1" needle="$2" want="$3" label="$4" got
  got="$(grep -cF -- "$needle" "$file" 2>/dev/null || true)"
  if [ "${got:-0}" = "$want" ]; then
    pass "${label}：出现 ${want} 次「${needle}」"
  else
    fail "${label}：期望 ${want} 次「${needle}」，实际 ${got:-0} 次"
  fi
}

run_fake_ancestor_case() {
  mkdir -p "$ROOT/cases"
  printf '%s\n' 'silence' > "$MODE_FILE"
  log "=== case=fake-ancestor（假 CLI 祖先 → 瞬时 sh → hook；两条链路各一次）"

  # ① 假 codex 祖先 + 两次事件（载荷**不带 session_id**）：pid 与兜底 session_id 都必须
  #    落在假祖先上，且两次的 session_id 完全一致（这就是「sh -c 起 hook 会让兜底 id 漂移」的回归判据）。
  local dir="$FAKE_DIR/codex-twice"
  rm -rf "$dir"
  mkdir -p "$dir"
  printf '%s' '{"cwd":"/tmp/fake","hook_event_name":"PreToolUse","tool_name":"shell","tool_input":{"command":"ls"}}' \
    > "$dir/payload.json"
  local before
  before="$(count_log)"
  spawn_fake_chain codex codex "$dir/payload.json" 2 "$dir/out.txt" "$dir/err.txt"
  local fake_codex_pid="$FAKE_PID"
  wait_for_envelopes "$before" 2
  sed -n "$((before + 1)),\$p" "$LOG" > "$dir/envelopes.jsonl" 2>/dev/null || true

  log "    ---- 信封（假 codex 祖先 pid=${fake_codex_pid}）----"
  sed 's/^/    /' "$dir/envelopes.jsonl"
  assert_count "$dir/envelopes.jsonl" '"agent": "codex"' 2 "fake-ancestor(codex-twice) 两条事件都上报"
  assert_pid "$dir/envelopes.jsonl" codex "equals:${fake_codex_pid}" "fake-ancestor(codex-twice)"
  assert_count "$dir/envelopes.jsonl" "\"pid\": ${fake_codex_pid}" 2 "fake-ancestor(codex-twice) pid 都是假祖先"
  assert_count "$dir/envelopes.jsonl" "\"session_id\": \"codex-ppid-${fake_codex_pid}\"" 2 \
    "fake-ancestor(codex-twice) 两次事件同一个兜底 session_id"
  # pid 的「活着」判据要在窗口内跑，所以 stop 放在断言之后
  stop_fake_chain
  if [ -s "$dir/err.txt" ]; then
    fail "fake-ancestor(codex-twice)：stderr 有输出「$(head -c 200 "$dir/err.txt")」"
  else
    pass "fake-ancestor(codex-twice)：stderr 为空"
  fi

  # ② 假 cline 祖先 + cline：即使链上有一个叫 cline 的祖先，也必须**不发 pid**（cline 没有
  #    CLI 二进制，是 VSCode 扩展派生的脚本）。stdout 仍必须是 {"cancel":false}。
  dir="$FAKE_DIR/cline"
  rm -rf "$dir"
  mkdir -p "$dir"
  printf '%s' '{"taskId":"cline-fake-1","hookName":"PreToolUse","preToolUse":{"toolName":"execute_command","parameters":{"command":"ls"}}}' \
    > "$dir/payload.json"
  before="$(count_log)"
  spawn_fake_chain cline cline "$dir/payload.json" 1 "$dir/out.txt" "$dir/err.txt"
  local fake_cline_pid="$FAKE_PID"
  wait_for_envelopes "$before" 1
  sed -n "$((before + 1)),\$p" "$LOG" > "$dir/envelopes.jsonl" 2>/dev/null || true

  log "    ---- stdout / 信封（假 cline 祖先 pid=${fake_cline_pid}）----"
  sed 's/^/    /' "$dir/out.txt"
  sed 's/^/    /' "$dir/envelopes.jsonl"
  assert_stdout_shape "$dir/out.txt" cline-cancel "fake-ancestor(cline)"
  assert_contains "$dir/envelopes.jsonl" '"session_id": "cline-fake-1"' "fake-ancestor(cline) 会话 id 来自 taskId"
  assert_pid "$dir/envelopes.jsonl" cline absent "fake-ancestor(cline)"
  stop_fake_chain
  log ""
}

# 链上没有该 CLI（= 本 harness 直接调起 hook）：pid 不发，兜底 session_id 仍要**非空且稳定**。
run_no_ancestor_case() {
  mkdir -p "$ROOT/cases"
  printf '%s\n' 'silence' > "$MODE_FILE"
  local dir="$ROOT/cases/no-ancestor"
  rm -rf "$dir"
  mkdir -p "$dir"
  log "=== case=no-ancestor（链上没有 codex：不发 pid，兜底 id 在同一棵树内稳定）"
  # 两次事件必须落在**同一棵进程树**里（同一个瞬时 sh 顺序起两次 hook）：链上没有匹配
  # 祖先时，兜底用的就是那个瞬时 shell 的 pid，换一棵树它本来就该不同——这正是需要
  # 祖先解析的理由。本 case 断言的是「同一棵树内稳定且非空」。
  printf '%s' '{"cwd":"/tmp/noanc","hook_event_name":"PreToolUse","tool_name":"shell","tool_input":{"command":"ls"}}' \
    > "$dir/payload.json"
  local before
  before="$(count_log)"
  hook_env /bin/sh -c "python3 \"$SCRIPT\" --source codex < \"$dir/payload.json\"; :; python3 \"$SCRIPT\" --source codex < \"$dir/payload.json\"; :" \
    > "$dir/sh.out" 2> "$dir/sh.err"
  sed -n "$((before + 1)),\$p" "$LOG" > "$dir/envelopes.jsonl" 2>/dev/null || true

  log "    ---- 信封 ----"
  sed 's/^/    /' "$dir/envelopes.jsonl"
  assert_count "$dir/envelopes.jsonl" '"agent": "codex"' 2 "no-ancestor 两条事件都上报"
  assert_pid "$dir/envelopes.jsonl" codex absent "no-ancestor"
  local verdict
  verdict="$(python3 - "$dir/envelopes.jsonl" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    lines = [line for line in fh.read().splitlines() if line.strip()]
ids = [json.loads(line)["request"]["session_id"] for line in lines]
if len(ids) < 2:
    print("MISSING 只收到 %d 条信封" % len(ids))
elif not ids[0]:
    print("EMPTY 兜底 session_id 是空串")
elif ids[0] != ids[1]:
    print("UNSTABLE 同一棵树内两次不同：%r vs %r" % (ids[0], ids[1]))
elif not re.fullmatch(r"codex-ppid-\d+", ids[0]):
    print("SHAPE 形状不对：%r" % ids[0])
else:
    print("OK %s" % ids[0])
PY
)"
  case "$verdict" in
    OK*) pass "no-ancestor：兜底 session_id 非空且同一棵树内一致 → ${verdict#OK }" ;;
    *)   fail "no-ancestor：${verdict}" ;;
  esac
  if [ -s "$dir/sh.err" ]; then
    fail "no-ancestor：stderr 有输出「$(head -c 200 "$dir/sh.err")」"
  else
    pass "no-ancestor：stderr 为空"
  fi
  log ""
}

# ---------------------------------------------------------------------------
# Grok 运行时的重复投递去重（Grok 会导入 claude / cursor 的 hooks）
# ---------------------------------------------------------------------------

# Grok CLI 会把 `~/.claude/settings.json` 与 `~/.cursor/hooks.json` 里的 hooks 一并导入执行，
# 于是同一动作会经三条通路各报一次；审批事件是阻塞的，重复投递会给刘海多出一张没人能撤的
# 待批卡。判据 = 上游 `GrokHookForwardingPolicy.shouldForward`：Grok 运行时里只放行 `--source grok`。
# 空白值按「没设」处理，因此再补一条 whitespace-only 的反向对照。
run_grok_dedup_case() {
  local dir="$ROOT/cases/grok-runtime-dedup"
  rm -rf "$dir"
  mkdir -p "$dir"
  printf '%s\n' 'silence' > "$MODE_FILE"
  log "=== case=grok-runtime-dedup（Grok 运行时里导入的 claude hook 必须被丢弃，grok 自己照发）"
  local payload='{"session_id":"grok-dup-1","cwd":"/tmp/dup","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}'
  local row label env_grok source expect_envelope
  for row in "session-id-set|GROK_SESSION_ID=grok-sid|claude|no" \
             "hook-event-set|GROK_HOOK_EVENT=PreToolUse|claude|no" \
             "whitespace-only|GROK_SESSION_ID= |claude|yes" \
             "grok-itself|GROK_SESSION_ID=grok-sid|grok|yes"; do
    label="${row%%|*}"
    row="${row#*|}"
    env_grok="${row%%|*}"
    row="${row#*|}"
    source="${row%%|*}"
    expect_envelope="${row#*|}"

    local before after code start end
    before="$(count_log)"
    start="$(python3 -c 'import time; print(time.time())')"
    # shellcheck disable=SC2086 # env_grok 是刻意做词拆分（形如 KEY=VALUE）
    printf '%s' "$payload" | env HOME="$HOME_SANDBOX" GROK_HOME="$GROK_HOME" \
      AGENT_ISLAND_SOCKET="$SOCK" AGENT_ISLAND_APPROVAL_TIMEOUT_SECONDS=3 $env_grok \
      python3 "$SCRIPT" --source "$source" > "$dir/$label.out" 2> "$dir/$label.err"
    code=$?
    end="$(python3 -c 'import time; print(time.time())')"
    after="$(count_log)"
    sed -n "$((before + 1)),$((after))p" "$LOG" > "$dir/$label.jsonl" 2>/dev/null || true

    log "    ---- ${label}（env ${env_grok}，--source ${source}）----"
    sed 's/^/    /' "$dir/$label.jsonl"
    assert_exit_zero "$code" "grok-dedup(${label})"
    assert_empty "$dir/$label.out" "grok-dedup(${label}) 不写 stdout"
    assert_faster_than "$(python3 -c "print($end - $start)")" "$FAST_LIMIT" "grok-dedup(${label}) 不卡住"
    if [ "$expect_envelope" = "no" ]; then
      assert_absent "$dir/$label.jsonl" '"agent"' "grok-dedup(${label}) 替身收不到任何信封"
    else
      assert_contains "$dir/$label.jsonl" "\"agent\": \"${source}\"" "grok-dedup(${label}) 照常上报"
    fi
    if [ -s "$dir/$label.err" ]; then
      fail "grok-dedup(${label})：stderr 有输出「$(head -c 200 "$dir/$label.err")」"
    else
      pass "grok-dedup(${label})：stderr 为空"
    fi
  done
  log ""
}

# ---------------------------------------------------------------------------
# Cline 的「永远立刻输出 cancel」不变量（哪怕这条事件不上报）
# ---------------------------------------------------------------------------

# `Notification(permission_prompt)` 是被显式挡掉、不上报的那类事件。cline 的 hook 契约要求
# 每个 hook 都立刻输出合法 JSON，因此必须**照样**输出 `{"cancel":false}`，且不产生信封。
run_cline_suppressed_case() {
  local dir="$ROOT/cases/cline-suppressed"
  rm -rf "$dir"
  mkdir -p "$dir"
  printf '%s\n' 'allow' > "$MODE_FILE"
  log "=== case=cline-suppressed（被挡掉的 Notification(permission_prompt)，Cline 仍要答 cancel）"
  local before after code
  before="$(count_log)"
  printf '%s' '{"taskId":"cline-notify-1","hookName":"Notification","notification_type":"permission_prompt"}' \
    | hook_env python3 "$SCRIPT" --source cline > "$dir/stdout.txt" 2> "$dir/stderr.txt"
  code=$?
  sleep 0.5
  after="$(count_log)"

  log "    ---- stdout ----"
  sed 's/^/    /' "$dir/stdout.txt"
  log "    ---- 断言 ----"
  assert_exit_zero "$code" "cline-suppressed"
  assert_stdout_shape "$dir/stdout.txt" cline-cancel "cline-suppressed"
  if [ "$after" = "$before" ]; then
    pass "cline-suppressed：被挡掉的事件不上报（信封 ${before} → ${after}）"
  else
    fail "cline-suppressed：不该上报，却多出 $((after - before)) 条信封"
  fi
  if [ -s "$dir/stderr.txt" ]; then
    fail "cline-suppressed：stderr 有输出「$(head -c 200 "$dir/stderr.txt")」"
  else
    pass "cline-suppressed：stderr 为空"
  fi
  log ""
}

# ---------------------------------------------------------------------------
# 连不上应用：任何事件都不得写 stdout、不得建 socket
# ---------------------------------------------------------------------------

run_socket_absent_case() {
  local dir="$ROOT/cases/socket-absent"
  local missing="$ROOT/absent.sock"
  rm -rf "$dir"
  mkdir -p "$dir"
  rm -f "$missing"
  log "=== case=socket-absent（socket 不存在：${missing}）"
  local row label payload
  for row in "permission|{\"session_id\":\"absent-perm\",\"cwd\":\"/tmp/absent\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{}}" \
             "pre-tool-use|{\"session_id\":\"absent-pre\",\"cwd\":\"/tmp/absent\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{}}"; do
    label="${row%%|*}"
    payload="${row#*|}"
    local start end
    start="$(python3 -c 'import time; print(time.time())')"
    printf '%s' "$payload" | env AGENT_ISLAND_SOCKET="$missing" python3 "$SCRIPT" --source claude \
      > "$dir/$label.out" 2> "$dir/$label.err"
    local code=$?
    end="$(python3 -c 'import time; print(time.time())')"
    assert_exit_zero "$code" "socket-absent(${label})"
    assert_empty "$dir/$label.out" "socket-absent(${label}) 不写 stdout"
    assert_faster_than "$(python3 -c "print($end - $start)")" "$FAST_LIMIT" "socket-absent(${label}) 不卡住"
    if [ -s "$dir/$label.err" ]; then
      fail "socket-absent(${label})：stderr 有输出「$(head -c 200 "$dir/$label.err")」"
    else
      pass "socket-absent(${label})：stderr 为空"
    fi
  done
  if [ -e "$missing" ]; then
    fail "socket-absent：脚本不该创建 socket 文件"
  else
    pass "socket-absent：脚本没有创建 socket 文件"
  fi
  log ""
}

# ---------------------------------------------------------------------------
# 矩阵（一条来源一条代表性载荷）
# ---------------------------------------------------------------------------

ASK_QUESTION="今晚吃哪种菜系？"

run_cases_one() {
  case "$1" in
    # Claude：老配置（不带任何参数）必须与改造前一致
    claude-default)
      run_case claude-default - - silence empty \
        '{"session_id":"claude-legacy-1","cwd":"/tmp/legacy","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"tool_use_id":"tu-legacy"}' \
        '"agent": "claude"' '"event": "PreToolUse"' '"status": "running_tool"' \
        '"session_id": "claude-legacy-1"' '"tool": "Bash"' '"tool_use_id": "tu-legacy"'
      # pid 判据（不是恒真断言）：若带 pid，它必须是**活的、且确实是 claude 的**祖先进程。
      # 这个 harness 的链路（verify 脚本 → 瞬时环境 → hook）里通常没有 claude 二进制，
      # 因此预期 absent；改造前那种「pid = getppid()」的实现会在这里报到瞬时 shell 上而失败。
      assert_pid "$ROOT/cases/claude-default/envelopes.jsonl" claude ancestor claude-default
      ;;

    # Claude：阻塞审批（allow / deny）
    claude-permission-allow)
      run_case claude-permission-allow claude - allow claude-allow \
        '{"session_id":"claude-perm-1","cwd":"/tmp/perm","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/x"}}' \
        '"agent": "claude"' '"event": "PermissionRequest"' '"status": "waiting_for_approval"' \
        '"session_id": "claude-perm-1"' '"expects_response": true' '"tool": "Bash"'
      ;;

    claude-permission-deny)
      run_case claude-permission-deny claude - deny claude-deny \
        '{"session_id":"claude-perm-2","cwd":"/tmp/perm","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}' \
        '"event": "PermissionRequest"' '"status": "waiting_for_approval"'
      ;;

    # Claude 家族 fork（Qoder 走同一套 hook 格式 + 同一个 AskUserQuestion 契约）
    qoder-permission-allow)
      run_case qoder-permission-allow qoder - allow claude-allow \
        '{"session_id":"qoder-1","cwd":"/tmp/qoder","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}' \
        '"agent": "qoder"' '"event": "PermissionRequest"' '"status": "waiting_for_approval"' \
        '"session_id": "qoder-1"'
      ;;

    # Codex：PreToolUse 非阻塞；PermissionRequest 阻塞
    codex-pretool)
      run_case codex-pretool codex - silence empty \
        '{"session_id":"codex-1","cwd":"/tmp/codex","hook_event_name":"PreToolUse","tool_name":"shell","tool_input":{"command":["ls"]}}' \
        '"agent": "codex"' '"event": "PreToolUse"' '"status": "running_tool"' \
        '"session_id": "codex-1"' '"tool_input": {"command": ["ls"]}'
      ;;

    codex-permission-deny)
      run_case codex-permission-deny codex - deny claude-deny \
        '{"session_id":"codex-2","cwd":"/tmp/codex","hook_event_name":"PermissionRequest","tool_name":"shell","tool_input":{"command":["rm","-rf","/"]}}' \
        '"agent": "codex"' '"event": "PermissionRequest"' '"status": "waiting_for_approval"'
      ;;

    # Gemini：stdin 不带事件名、不带 cwd → 靠 --event BeforeTool + 进程 cwd 归一
    gemini-before-tool)
      run_case gemini-before-tool gemini BeforeTool allow gemini-allow \
        '{"session_id":"gemini-1","tool_name":"run_shell_command","tool_input":{"command":"ls"}}' \
        '"agent": "gemini"' '"event": "PermissionRequest"' '"status": "waiting_for_approval"' \
        '"session_id": "gemini-1"' "\"cwd\": \"${PWD_PHYSICAL:-$PWD}\"" '"expects_response": true'
      ;;

    # Cursor：camelCase，stdin 不带事件名
    cursor-shell)
      run_case cursor-shell cursor beforeShellExecution silence empty \
        '{"sessionId":"cursor-1","cwd":"/tmp/cursor","toolName":"shell","tool_input":{"command":"ls -la"}}' \
        '"agent": "cursor"' '"event": "PreToolUse"' '"status": "running_tool"' \
        '"session_id": "cursor-1"' '"cwd": "/tmp/cursor"'
      ;;

    # Copilot：camelCase + toolArgs 是 JSON 字符串
    copilot-pretool)
      run_case copilot-pretool copilot preToolUse silence empty \
        '{"sessionId":"copilot-1","cwd":"/tmp/copilot","toolName":"bash","toolArgs":"{\"command\":\"ls -la\"}"}' \
        '"agent": "copilot"' '"event": "PreToolUse"' '"status": "running_tool"' \
        '"session_id": "copilot-1"' '"tool": "bash"' '"tool_input": {"command": "ls -la"}'
      ;;

    # Kimi：Claude 风格事件名，无审批事件
    kimi-stop)
      run_case kimi-stop kimi - silence empty \
        '{"session_id":"kimi-1","cwd":"/tmp/kimi","hook_event_name":"Stop"}' \
        '"agent": "kimi"' '"event": "Stop"' '"status": "waiting_for_input"' '"session_id": "kimi-1"'
      ;;

    # Cline：立刻 {"cancel":false} + 后台转发；信封异步到达，且不带 pid / expects_response
    cline-pretool)
      run_case cline-pretool cline PreToolUse allow cline-cancel \
        '{"taskId":"cline-task-1","hookName":"PreToolUse","preToolUse":{"toolName":"execute_command","parameters":{"command":"ls -la"}}}' \
        '"agent": "cline"' '"event": "PreToolUse"' '"status": "running_tool"' \
        '"session_id": "cline-task-1"' '"tool": "execute_command"' \
        '"tool_input": {"command": "ls -la"}'
      assert_absent "$ROOT/cases/cline-pretool/envelopes.jsonl" '"expects_response"' 'cline 不等决定'
      assert_absent "$ROOT/cases/cline-pretool/envelopes.jsonl" '"pid"' 'cline 不带临时 shell 的 pid'
      ;;

    # Grok：camelCase + workspaceRoot + stop_failure（折到 Stop）+ 自行拼接的 session_file
    grok-stop-failure)
      run_case grok-stop-failure grok - silence empty \
        '{"hookEventName":"stop_failure","sessionId":"grok-1","workspaceRoot":"/tmp/grok ws","error":"rate limited"}' \
        '"agent": "grok"' '"event": "Stop"' '"status": "waiting_for_input"' \
        '"session_id": "grok-1"' '"cwd": "/tmp/grok ws"' \
        "\"session_file\": \"$GROK_HOME/sessions/%2Ftmp%2Fgrok%20ws/grok-1/chat_history.jsonl\"" \
        '"stop_error": "rate limited"'
      ;;

    # Grok：payload 不带 workspaceRoot 时用 GROK_WORKSPACE_ROOT 兜底（且优先于进程 cwd）
    grok-workspace-env)
      run_case grok-workspace-env grok - silence empty \
        '{"hookEventName":"PreToolUse","sessionId":"grok-2","tool_name":"shell","tool_input":{"command":"ls"}}' \
        '"agent": "grok"' '"event": "PreToolUse"' '"status": "running_tool"' \
        '"session_id": "grok-2"' "\"cwd\": \"$GROK_WORKSPACE\""
      ;;

    # Trae（IDE）：camelCase，stdin 不带事件名
    trae-shell)
      run_case trae-shell trae beforeShellExecution silence empty \
        '{"session_id":"trae-1","cwd":"/tmp/trae","toolName":"bash"}' \
        '"agent": "trae"' '"event": "PreToolUse"' '"status": "running_tool"' '"session_id": "trae-1"'
      ;;

    # TraeCli：snake_case + permission_request 阻塞。**安装器形态**：托管项是「单一命令 +
    # matchers 列全部事件」，不带 `--event`，事件名走 stdin（上游 ConfigInstaller.swift:1665-1680
    # 的 `renderManagedTraecliHooksText` 里没有 --event，其 remote hook 必须从 stdin 读到事件名）。
    traecli-permission)
      run_case traecli-permission traecli - allow claude-allow \
        '{"session_id":"traecli-1","cwd":"/tmp/traecli","hook_event_name":"permission_request","tool_name":"bash","tool_input":{"command":"ls"}}' \
        '"agent": "traecli"' '"event": "PermissionRequest"' '"status": "waiting_for_approval"' \
        '"session_id": "traecli-1"'
      ;;

    # 同一条事件的 **--event 兜底**路径（stdin 不带事件名时也能通）
    traecli-permission-event-flag)
      run_case traecli-permission-event-flag traecli permission_request allow claude-allow \
        '{"session_id":"traecli-2","cwd":"/tmp/traecli","tool_name":"bash","tool_input":{"command":"ls"}}' \
        '"agent": "traecli"' '"event": "PermissionRequest"' '"status": "waiting_for_approval"' \
        '"session_id": "traecli-2"'
      ;;

    # 应用回 passthrough（例如该 Agent 已被用户关闭）：脚本不输出任何东西，回落原生审批
    claude-passthrough)
      run_case claude-passthrough claude - passthrough empty \
        '{"session_id":"claude-pass-1","cwd":"/tmp/pass","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}' \
        '"agent": "claude"' '"event": "PermissionRequest"' '"status": "waiting_for_approval"' \
        '"expects_response": true'
      ;;

    # Claude 的 AskUserQuestion：上行带 ask 负载，作答映射回 updatedInput
    claude-ask-answer)
      printf '%s' '{"今晚吃哪种菜系？": ["C1"]}' > "$ANSWERS_FILE"
      run_case claude-ask-answer claude - answer ask-answer \
        "{\"session_id\":\"claude-ask-1\",\"cwd\":\"/tmp/ask\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"AskUserQuestion\",\"tool_input\":{\"questions\":[{\"question\":\"$ASK_QUESTION\",\"header\":\"菜系\",\"options\":[{\"label\":\"C1\",\"description\":\"麻辣\"},{\"label\":\"C2\"}],\"multiSelect\":false}]}}" \
        '"agent": "claude"' '"status": "waiting_for_approval"' '"ask": {"questions"' \
        '"expects_response": true'
      printf '{}' > "$ANSWERS_FILE"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------

# 负控用的审批预算（秒）：3s 足够区分「等过预算」与「根本没阻塞」。
TIMEOUT_BUDGET=3
ALL_CASES=(claude-default claude-permission-allow claude-permission-deny qoder-permission-allow
  codex-pretool codex-permission-deny gemini-before-tool cursor-shell copilot-pretool kimi-stop
  cline-pretool cline-suppressed fake-ancestor no-ancestor grok-runtime-dedup grok-stop-failure
  grok-workspace-env trae-shell
  traecli-permission traecli-permission-event-flag
  claude-ask-answer claude-passthrough
  legacy-equivalence socket-absent malformed-stdin timeout-negative)

selected=("$@")
if [ "${#selected[@]}" -eq 0 ]; then
  selected=("${ALL_CASES[@]}")
fi

if [ ! -f "$SCRIPT" ]; then
  printf 'FAIL  找不到被验证的脚本：%s\n' "$SCRIPT" >&2
  exit 1
fi

prepare_sandbox
start_server || { stop_server; exit 1; }
log "被验证脚本：$SCRIPT"
log "沙箱：${ROOT}（替身 ${SOCK}）"
log ""

ran=0
for name in "${selected[@]}"; do
  if ! printf '%s\n' "${ALL_CASES[@]}" | grep -qxF "$name"; then
    fail "未知 case：${name}"
    continue
  fi
  case "$name" in
    timeout-negative)   run_timeout_case ;;
    legacy-equivalence) run_legacy_case ;;
    socket-absent)      run_socket_absent_case ;;
    malformed-stdin)    run_malformed_case ;;
    cline-suppressed)   run_cline_suppressed_case ;;
    grok-runtime-dedup) run_grok_dedup_case ;;
    fake-ancestor)      run_fake_ancestor_case ;;
    no-ancestor)        run_no_ancestor_case ;;
    *)                  run_cases_one "$name" ;;
  esac
  ran=$((ran + 1))
done

stop_server

log "=============================================="
if [ "$ran" -eq 0 ]; then
  log "没有跑任何 case"
  exit 1
fi
if [ "$FAILED" -eq 0 ]; then
  if [ "$SKIPPED" -eq 0 ]; then
    log "全部通过（${ran} 个 case，$(count_log) 条信封）"
  else
    log "通过（${ran} 个 case，$(count_log) 条信封；跳过 ${SKIPPED} 项，原因见上面的 SKIP 行）"
  fi
else
  log "失败 ${FAILED} 项（跳过 ${SKIPPED} 项）"
fi
exit "$FAILED"
