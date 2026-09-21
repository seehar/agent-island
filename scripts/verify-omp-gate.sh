#!/bin/bash
#
# 隔离环境验证矩阵：omp 的「刘海审批闸门」扩展（AgentIsland P1）。
#
# 硬纪律（凭据与隔离）：
#   * HOME=<case>/home                 → ~/.omp、~/.pi、~/.claude 全在沙箱里，不碰用户真实目录
#   * PI_CODING_AGENT_DIR=<case>/agent → config.yml / models.yml / extensions/ 都在沙箱里
#   * models.yml 是**自建假 key**（指向本机网关 127.0.0.1:15721），不复制任何真实凭据
#
# 刘海替身：脚本自己生成 <ROOT>/notch_double.py，按 server_mode.txt 逐请求返回。
# 它的读语义与真实应用**一致**（读到首个字节后静默 50ms 即算读完，不要求换行或半关闭——
# 真实应用是 poll + 50ms 静默，见 HookSocketServer）。`silence` 档**保持连接打开、不发应答**，
# 这样「超时=拒绝」才是客户端自己的裁决者；若替身直接关连接，语义就变成「应用被杀」。
#
# 用法：
#   scripts/verify-omp-gate.sh                 # 跑全部 case
#   scripts/verify-omp-gate.sh allow deny      # 只跑指定 case
#
# case 一览：
#   allow            刘海回 allow，普通命令            → 工具真的执行
#   deny             刘海回 deny，普通命令             → 工具未执行 + 模型收到理由
#   silence          刘海不答，客户端 3s 超时          → 拒绝，理由是**可读超时**串
#   deny-critical    刘海回 deny，rm -rf <绝对路径>    → approval_kind=critical + 工具未执行
#   enoent-exec      不启刘海（默认 notify-only）      → 普通命令照跑
#   enoent-critical  不启刘海（默认 notify-only）      → 危险命令仍被拒
#   enoent-strict    不启刘海（strict 档）             → 一律拒绝
#   enoent-readonly  不启刘海（read-only-allow 档）    → 写 / 执行档拒绝
#   tui-no-dual-prompt 真 omp TUI（tmux）下触发一次待批 → 帧里没有 omp 自己的审批弹窗，
#                      而刘海替身收到了请求（说明唯一入口是刘海）
#   tui-enoent      真 omp TUI + socket 不存在（闸门离线）→ 帧里能看到「gate offline」可见提示、
#                      普通命令照跑、危险命令仍被拒、且帧里没有 omp 自己的审批弹窗
#   report-only-ask 只上报版（不带闸门）装在沙箱 + 真 omp TUI → 普通工具**不被拦**，
#                      且 ask 走影子路径把刘海的作答回灌模型（替身 answer 模式）
#   zero-select-multi 替身回 {"pick": []}（多选零选）→ 文案为原生逐字
#                      「User did not select any options」，且**没有 abort / 取消**（正常完成）
#   zero-select-mixed 多题混合 {"qa": [], "qb": ["…"]} → `qa: []` 与另一题的选中结果
#   ask-deny-control  替身回 deny → 既有的取消语义不变（不是「空答案」）
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${ROOT:-/tmp/ai-approve/p1-run}"
OMP="${OMP:-$HOME/.bun/bin/omp}"
EXT_SOURCE="$REPO_ROOT/AgentIsland/Resources/agent-island-pi-extension.ts.txt"
EXT_SOURCE_REPORT_ONLY="$REPO_ROOT/AgentIsland/Resources/agent-island-pi-extension-report-only.ts.txt"
MODEL="localgw/gpt-5.6-luna"
GATEWAY="http://127.0.0.1:15721/v1"
FAKE_KEY="sk-fake-agent-island-p1-sandbox"
FAILED=0

log()  { printf '%s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILED=$((FAILED + 1)); }

# ---------------------------------------------------------------------------
# 刘海替身（与真实应用同读语义）
# ---------------------------------------------------------------------------

write_double() {
  cat > "$1" <<'PY'
"""刘海审批 socket 的替身：按 mode 文件逐请求返回 allow / deny / silence。

读语义复刻真实应用（HookSocketServer）：poll + 读到首个字节后静默 50ms 即算一条消息读完，
不要求换行也不要求半关闭。silence 档保持连接打开，让客户端自己的超时成为裁决者。
日志按追加写：每行一个 {t, mode, request}。
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


def current_mode() -> str:
    try:
        with open(MODE_FILE, encoding="utf-8") as fh:
            return fh.read().strip() or "allow"
    except OSError:
        return "allow"


def current_answers() -> dict:
    """answer 模式的作答：{"<问题 id>": ["<label 或自由文本>"]}。"""
    if ANSWERS_FILE is None:
        return {}
    try:
        with open(ANSWERS_FILE, encoding="utf-8") as fh:
            loaded = json.load(fh)
        return loaded if isinstance(loaded, dict) else {}
    except (OSError, ValueError):
        return {}


def handle(conn: socket.socket) -> None:
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
    # request 用**嵌套对象**记录：内层引号因此不被转义，断言可以直接 grep 字段。
    with open(LOG, "a", encoding="utf-8") as fh:
        fh.write(json.dumps({"t": time.time(), "mode": mode, "request": request},
                            ensure_ascii=False) + "\n")

    is_ask = isinstance(request, dict) and isinstance(request.get("ask"), dict)
    try:
        if is_ask and mode == "answer":
            # ask 作答：与 Q1 的替身同一套下行形状（{"decision":"answer","answers":{...}}）。
            # answers 里的空数组 = 该题零选，是合法作答（见扩展里的 parseAskAnswers）。
            payload = json.dumps({"decision": "answer", "answers": current_answers()})
            conn.sendall(payload.encode("utf-8"))
        elif mode == "allow":
            conn.sendall(b'{"decision":"allow"}')
        elif mode == "deny":
            conn.sendall(b'{"decision":"deny","reason":"denied by notch test double"}')
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


def main() -> None:
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK)
    srv.listen(16)
    print(f"listening on {SOCK}", flush=True)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


main()
PY
}

# ---------------------------------------------------------------------------
# 沙箱
# ---------------------------------------------------------------------------

write_models() {
  cat > "$1" <<YAML
providers:
  localgw:
    api: openai-completions
    baseUrl: $GATEWAY
    auth: apiKey
    apiKey: $FAKE_KEY
    models:
      - id: gpt-5.6-luna
        name: gpt-5.6-luna
        contextWindow: 1000000
        maxTokens: 16384
        input:
          - text
YAML
}

write_config() {
  # setupVersion 必须写：缺它时 omp 的 TUI 会先弹首次运行向导，提示词进不去（实测）。
  cat > "$1" <<YAML
modelRoles:
  default: $MODEL
setupVersion: 2
YAML
}

# 渲染某一版扩展：与安装器做同样替换（只上报版没有闸门策略占位符）。
render_extension() {
  local variant="$1" destination="$2" degradation="$3"
  local source="$EXT_SOURCE"
  if [ "$variant" = "report-only" ]; then
    source="$EXT_SOURCE_REPORT_ONLY"
  fi
  python3 - "$source" "$destination" "$degradation" <<'PY'
import pathlib, sys

source, destination, degradation = sys.argv[1], sys.argv[2], sys.argv[3]
text = pathlib.Path(source).read_text(encoding="utf-8")
text = text.replace("__AGENT_ISLAND_AGENT__", "omp")
text = text.replace("__AGENT_ISLAND_DEGRADATION__", degradation)
text = text.replace(
    "__AGENT_ISLAND_GATE_CONFIG__",
    '{"degradation":"%s","timeoutMs":120000}' % degradation,
)
assert "__AGENT_ISLAND_" not in text, "占位符没替换完"
pathlib.Path(destination).write_text(text, encoding="utf-8")
PY
}

prepare_case() {
  local run="$1" degradation="$2" variant="${3:-gate}"
  rm -rf "$run"
  mkdir -p "$run/home" "$run/agent/extensions" "$run/out" "$run/guard"
  write_models "$run/agent/models.yml"
  write_config "$run/agent/config.yml"
  render_extension "$variant" "$run/agent/extensions/agent-island-state.ts" "$degradation"
  # 危险命令的可观测替身：命中 critical 时它必须还在（说明命令被拦下）。
  printf 'payload\n' > "$run/guard/payload"
  printf '{}' > "$run/ask_answers.json"
  # 隔离判据用标记：跑完后 ~/.pi、~/.claude 里不应有比它更新的文件。
  touch "$run/marker"
}

start_server() {
  local run="$1" mode="$2"
  printf '%s\n' "$mode" > "$run/server_mode.txt"
  python3 "$ROOT/notch_double.py" "$run/approve.sock" "$run/out/server.jsonl" \
    "$run/server_mode.txt" "$run/ask_answers.json" > "$run/out/server.log" 2>&1 &
  SERVER_PID=$!
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -S "$run/approve.sock" ] && return 0
    sleep 0.3
  done
  fail "${run}：刘海替身没起来"
  return 1
}

stop_server() {
  if [ -n "${SERVER_PID:-}" ]; then kill "$SERVER_PID" 2>/dev/null; fi
  SERVER_PID=""
}

run_omp() {
  local run="$1" prompt="$2" timeout_ms="$3"
  env HOME="$run/home" \
      PI_CODING_AGENT_DIR="$run/agent" \
      AGENT_ISLAND_SOCKET="$run/approve.sock" \
      AGENT_ISLAND_APPROVAL_TIMEOUT_MS="$timeout_ms" \
      "$OMP" -p --model "$MODEL" --smol "$MODEL" --slow "$MODEL" --plan "$MODEL" \
      "$prompt" > "$run/out/omp.txt" 2>&1
}

# ---------------------------------------------------------------------------
# 断言
# ---------------------------------------------------------------------------

assert_contains() {
  if grep -qF -- "$2" "$1"; then pass "${3}：含「${2}」"; else fail "${3}：缺「${2}」"; fi
}

assert_absent() {
  if grep -qF -- "$2" "$1"; then fail "${3}：不该含「${2}」"; else pass "${3}：不含「${2}」"; fi
}

assert_file_exists() {
  if [ -f "$1" ]; then pass "${2}：工具真的执行了（${1} 在）"; else fail "${2}：${1} 不存在"; fi
}

# 危险命令的观测点是「decoy 是否还在」：还在 = 命令被拦下（不是「工具执行了」）。
assert_guard_intact() {
  if [ -f "$1/guard/payload" ]; then
    pass "${2}：危险命令被拦下（guard/payload 仍在）"
  else
    fail "${2}：guard/payload 被删掉了，说明 rm -rf 真的执行了"
  fi
}

assert_file_absent() {
  if [ -f "$1" ]; then fail "${2}：${1} 不该存在"; else pass "${2}：工具被拦下（${1} 不在）"; fi
}

# 沙箱会话记录里是否出现某段文本（确定性证人：不依赖模型复述）。
assert_transcript() {
  local run="$1" needle="$2" label="$3"
  if grep -rqF -- "$needle" "$run/agent/sessions" 2>/dev/null; then
    pass "${label}：会话记录里有「${needle}」（已作为工具结果/错误文本回灌）"
  else
    fail "${label}：会话记录里没有「${needle}」"
  fi
}

# 契约反向测试：会话记录里不能出现任何「取消 / 中断」痕迹。
# 这是防 `cancelAskFromIsland`（ctx.abort() + ToolAbortError）把**零选**误判成「未作答」
# 的守卫——零选按原生语义是「正常完成、本轮继续」。
assert_no_abort() {
  local run="$1" label="$2"
  if grep -rqE "ToolAbortError|Ask tool was cancelled by the user|Ask input was cancelled" \
    "$run/agent/sessions" 2>/dev/null; then
    fail "${label}：出现取消/中断痕迹（零选被当成未作答）"
    grep -rhoE "ToolAbortError|Ask tool was cancelled by the user|Ask input was cancelled" "$run/agent/sessions" | sort -u | head -3 | sed 's/^/        /'
  else
    pass "${label}：没有 abort / 取消痕迹"
  fi
}

# 上报信封里的字段是否如约。
assert_payload() {
  local run="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$run/out/server.jsonl" 2>/dev/null; then
    pass "${label}：信封里有 ${needle}"
  else
    fail "${label}：信封里缺 ${needle}"
  fi
}

# 帧里是否出现某段文本（只用可视区：capture-pane -p 不取回滚缓冲）。
assert_frame_contains() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then pass "${3}：帧里含「${2}」"; else fail "${3}：帧里缺「${2}」"; fi
}

assert_frames_absent() {
  local pattern="$1" label="$2"
  shift 2
  local file hits=0
  for file in "$@"; do
    [ -f "$file" ] || continue
    hits=$((hits + $(grep -cF -- "$pattern" "$file" || true)))
  done
  if [ "$hits" -eq 0 ]; then
    pass "${label}：帧里没有「${pattern}」（grep -c 合计 0）"
  else
    fail "${label}：帧里出现「${pattern}」${hits} 处"
  fi
}

# 隔离判据（三条，逐条给证据）：
#   ① 沙箱外的 agent 目录若出现新写入，必须是**别的会话**干的：只有内容里引用本次沙箱的
#      才算泄漏（共享环境里同时跑着其它 omp 会话，单看 mtime 会把别人的正常写入算成我们的）
#   ② 上报信封里的 session_file 必须落在本次沙箱内，且不得出现用户真实 agent 目录
#   ③ 信封里的 pid 必须是本次新增的进程（不在开跑前的 omp 进程集合里）
assert_isolation() {
  local run="$1" label="$2"
  # 泄漏判据用**本次沙箱独有的标记**（会话 id / 沙箱会话文件名里的 uuid）来归属，
  # 不用沙箱路径字符串——本仓库里同时跑着的其它 agent 会话会把自己的工作目录与
  # /tmp 路径写进各自的记录，用路径字符串会把它们误判成泄漏。
  local markers="$run/.leak-markers"
  {
    ls "$run/agent/sessions"/*/*.jsonl 2>/dev/null | sed 's#.*/##; s/\.jsonl$//'
    grep -o '"session_id": "[^"]*"' "$run/out/server.jsonl" 2>/dev/null | sed 's/.*: "//; s/"$//'
  } | sort -u > "$markers"

  local newer leaked mine f
  newer="$(find "$HOME/.pi" "$HOME/.claude" "$HOME/.omp/agent/sessions" "$HOME/.omp/agent/extensions" \
    -newer "$run/marker" -type f 2>/dev/null)"
  mine=""
  for f in $newer; do
    if [ -f "$f" ] && grep -qF -f "$markers" "$f" 2>/dev/null; then mine="${mine} ${f}"; fi
  done
  if [ -n "$mine" ]; then
    fail "${label}：沙箱外的 agent 目录里有本次沙箱会话的写入 →${mine}"
  else
    leaked="$(printf '%s\n' "$newer" | grep -c . || true)"
    pass "${label}：沙箱外的 agent 目录无本次写入（同期其它会话的写入 ${leaked} 个，与本 case 无关）"
  fi

  local slog="$run/out/server.jsonl"
  [ -f "$slog" ] || return 0

  local outside
  outside="$(grep -o '"session_file": "[^"]*"' "$slog" | grep -v "$run" | head -3)"
  if [ -n "$outside" ]; then
    fail "${label}：有沙箱外的 session_file → ${outside}"
  else
    pass "${label}：所有 session_file 都在沙箱内"
  fi
  if grep -qF "$HOME/.omp/agent" "$slog" || grep -qF "$HOME/.pi/agent" "$slog"; then
    fail "${label}：信封里出现了用户真实 agent 目录"
  else
    pass "${label}：信封里没有用户真实 agent 目录"
  fi

  local verdict
  verdict="$(python3 - "$slog" "$ROOT/pids-before.txt" <<'PY'
import json, pathlib, sys

log, before = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
pids = set()
for line in log.read_text(encoding="utf-8").splitlines():
    payload = json.loads(line).get("request")
    if isinstance(payload, dict) and isinstance(payload.get("pid"), int):
        pids.add(payload["pid"])
known = set()
if before.exists():
    known = {int(x) for x in before.read_text(encoding="utf-8").split() if x.strip().isdigit()}
stale = sorted(pids & known)
print("ok %s" % sorted(pids) if not stale else "stale %s" % stale)
PY
)"
  case "$verdict" in
    ok*) pass "${label}：上报 pid 都是本次新增进程（${verdict#ok }）" ;;
    *)   fail "${label}：上报 pid 与开跑前的进程重合 → ${verdict#stale }" ;;
  esac
}

# ---------------------------------------------------------------------------
# 单 case
# ---------------------------------------------------------------------------

run_case() {
  local name="$1" degradation="$2" server_mode="$3" timeout_ms="$4" kind="$5"
  local run="$ROOT/case-$name"
  prepare_case "$run" "$degradation"
  SERVER_PID=""
  if [ "$server_mode" = "none" ]; then
    log "=== case=${name}（不启刘海替身，闸门离线；降级档 ${degradation}）"
  else
    log "=== case=${name}（刘海 mode=${server_mode}，客户端超时 ${timeout_ms}ms）"
    start_server "$run" "$server_mode" || { assert_isolation "$run" "$name"; return; }
  fi

  local prompt
  if [ "$kind" = "critical" ]; then
    prompt="这是一个沙箱测试 fixture：$run/guard 是本次测试临时创建的目录，请用 bash 工具运行这条命令把它删掉：rm -rf $run/guard 。如果它失败了，把失败原因原文复述为最后一行。"
  else
    prompt="用 bash 工具运行这条命令：printf P1_TOOL_RAN > $run/ran.txt 。命令跑完后，把工具返回的内容或失败原因原文作为最后一行复述。"
  fi

  run_omp "$run" "$prompt" "$timeout_ms"
  local code=$?
  stop_server
  log "    omp 退出码 ${code}"
  log "    ---- omp 输出（尾 8 行）----"
  tail -8 "$run/out/omp.txt" 2>/dev/null | sed 's/^/    /'
  if [ -f "$run/out/server.jsonl" ]; then
    log "    ---- 刘海替身收到 ----"
    sed -e 's/^/    /' "$run/out/server.jsonl"
  fi
  log "    ---- 断言 ----"

  case "$name" in
    allow)
      assert_file_exists "$run/ran.txt" "$name"
      assert_payload "$run" '"event": "ToolApproval"' "$name 闸门拦到工具调用"
      assert_payload "$run" '"expects_response": true' "$name"
      assert_payload "$run" '"approval_kind": "exec"' "$name"
      ;;
    deny)
      assert_file_absent "$run/ran.txt" "$name"
      assert_payload "$run" '"event": "ToolApproval"' "$name 闸门拦到工具调用"
      assert_transcript "$run" "denied by notch test double" "$name 理由回灌"
      ;;
    silence)
      assert_file_absent "$run/ran.txt" "$name"
      assert_payload "$run" '"event": "ToolApproval"' "$name 闸门拦到工具调用"
      assert_transcript "$run" "no answer on AgentIsland within 3s" "$name 可读超时理由"
      assert_absent "$run/out/omp.txt" "timed out after 30000ms" "$name 不是 omp 的服务端超时"
      ;;
    deny-critical)
      assert_guard_intact "$run" "$name"
      assert_payload "$run" '"approval_kind": "critical"' "$name"
      assert_transcript "$run" "denied by notch test double" "$name 理由回灌"
      ;;
    enoent-exec)
      assert_file_exists "$run/ran.txt" "$name 降级放行"
      assert_absent "$run/out/omp.txt" "no answer on AgentIsland" "$name 没有走超时路径"
      ;;
    enoent-critical)
      assert_guard_intact "$run" "$name 危险命令兜底"
      assert_transcript "$run" "known-dangerous command" "$name 拒绝理由"
      ;;
    enoent-strict)
      assert_file_absent "$run/ran.txt" "$name strict 全拒"
      assert_transcript "$run" "approval gate offline (strict)" "$name 拒绝理由"
      ;;
    enoent-readonly)
      assert_file_absent "$run/ran.txt" "$name 写/执行档拒绝"
      assert_transcript "$run" "approval gate offline (read-only-allow)" "$name 拒绝理由"
      ;;
  esac
  assert_isolation "$run" "$name"
  log ""
}

# ---------------------------------------------------------------------------
# 真 TUI：不出现「双提示」
# ---------------------------------------------------------------------------

# omp TUI 自己的审批提示是 `Allow tool: …`。yolo（默认）下它本就不该出现；
# 这条断言的价值是：待批期间帧里没有两个入口，而刘海替身**确实**收到了请求
# （唯一在问的就是我们的闸门）。
run_case_tui() {
  local sock="-L agent-island-p1-tui"
  # 上一次的 tmux 被杀后 omp 可能还挂在待批上（本 case 的客户端预算是 600s）→ 它会继续往
  # 同名 socket 上报，污染本 case 的证据。因此：① 每次用**独立的沙箱目录**（旧 socket 路径
  # 已不存在，旧进程无法再接入）；② 收尾时按**进程组**把 pane 及其子进程收掉。
  tmux $sock kill-server 2>/dev/null
  sleep 1
  local run="$ROOT/case-tui-$$"
  prepare_case "$run" notify-only
  SERVER_PID=""
  log "=== case=tui-no-dual-prompt（刘海 mode=silence，真 omp TUI；沙箱 ${run}）"
  start_server "$run" silence || { assert_isolation "$run" "tui"; return; }

  tmux $sock new-session -d -s omp -x 200 -y 50 \
    "env HOME=$run/home PI_CODING_AGENT_DIR=$run/agent AGENT_ISLAND_SOCKET=$run/approve.sock AGENT_ISLAND_APPROVAL_TIMEOUT_MS=600000 $OMP --model $MODEL --smol $MODEL --slow $MODEL --plan $MODEL"
  local pane_pid pgid
  pane_pid="$(tmux $sock list-panes -t omp -F '#{pane_pid}' 2>/dev/null | head -1)"
  pgid="$(ps -o pgid= -p "${pane_pid:-0}" 2>/dev/null | tr -d ' ')"
  log "    pane_pid=${pane_pid:-?} pgid=${pgid:-?}"
  sleep 10
  tmux $sock send-keys -t omp Escape
  sleep 2
  tmux $sock send-keys -t omp "Run the shell command \`printf TUI_MARK\` with the bash tool, then reply OK." Enter
  # 等闸门真的拦到这次调用再取帧：取帧必须落在待批窗口内，不能靠固定 sleep 猜模型速度
  # （上一轮就是这样被慢模型判成「取帧不在待批窗口内」的）。
  if wait_for_approval "$run" 120; then
    log "    闸门已拦到工具调用，开始取帧（待批窗口内）"
  else
    log "    120s 内没等到 ToolApproval"
  fi
  t_frame1="$(python3 -c 'import time; print(int(time.time()))')"
  tmux $sock capture-pane -p -t omp > "$run/out/frame1.txt" 2>/dev/null
  sleep 8
  t_frame2="$(python3 -c 'import time; print(int(time.time()))')"
  tmux $sock capture-pane -p -t omp > "$run/out/frame2.txt" 2>/dev/null
  tmux $sock kill-server 2>/dev/null
  if [ -n "${pgid:-}" ]; then
    kill -TERM -"$pgid" 2>/dev/null
    sleep 1
    kill -KILL -"$pgid" 2>/dev/null
  fi
  stop_server

  log "    ---- 帧 1（尾 12 行）----"
  tail -12 "$run/out/frame1.txt" 2>/dev/null | sed 's/^/    /'
  log "    ---- 断言 ----"
  assert_payload "$run" '"event": "ToolApproval"' "tui"
  # 取帧必须在「请求已到、且仍未裁决」的窗口内：只断言「帧里没有第二个入口」而没有
  # 待批在飞，等于什么都没证明。三条一起判：
  #   ① ToolApproval 已到达（时间戳早于取帧）
  #   ② 期间没有 PostToolUse —— 工具始终没有完成，说明会话确实卡在待批上
  #   ③ 取帧时刻离请求不超过客户端预算（本 case 用 600s），所以那时还在等
  local window
  window="$(python3 - "$run/out/server.jsonl" "$t_frame1" "$t_frame2" <<'PYEOF'
import json, pathlib, sys

log = pathlib.Path(sys.argv[1])
first, second = int(sys.argv[2]), int(sys.argv[3])
requests, posts = [], []
for line in log.read_text(encoding="utf-8").splitlines():
    entry = json.loads(line)
    payload = entry.get("request")
    if not isinstance(payload, dict):
        continue
    if payload.get("event") == "ToolApproval":
        requests.append(entry["t"])
    if payload.get("event") == "PostToolUse":
        posts.append(entry["t"])

if not requests:
    print("OUTSIDE 没有 ToolApproval")
elif requests[0] > first + 1:
    # 取帧时刻是整秒 epoch，请求时刻是浮点 epoch：留 1 秒容差，
    # 避免「同一秒内但小数更大」被误判成「请求晚于取帧」（快模型时真踩过）。
    print("OUTSIDE ToolApproval 晚于首次取帧")
elif posts:
    print("OUTSIDE 工具已完成（有 PostToolUse），待批不成立")
elif second - requests[0] > 600:
    print("OUTSIDE 取帧时已超过客户端预算")
else:
    print("INSIDE 请求 %.1f → 取帧 %.1f/%.1f（未裁决）" % (requests[0], first, second))
PYEOF
)"
  case "$window" in
    INSIDE*) pass "tui：取帧落在待批窗口内 → ${window#INSIDE }" ;;
    *)       fail "tui：取帧不在待批窗口内，断言无效 → ${window}" ;;
  esac
  local frames
  frames=$(cat "$run/out/frame1.txt" "$run/out/frame2.txt" 2>/dev/null)
  local hits
  hits=$(printf '%s' "$frames" | grep -c "Allow tool" || true)
  if [ "$hits" -eq 0 ]; then
    pass "tui：帧里没有 omp 自己的「Allow tool」弹窗（grep -c = 0）"
  else
    fail "tui：帧里出现了 ${hits} 处「Allow tool」"
  fi
  assert_isolation "$run" "tui"
  log ""
}

# ---------------------------------------------------------------------------
# 真 TUI：闸门离线时**降级必须可见**（§5.4 首行的实测化）
# ---------------------------------------------------------------------------

# 与 tui-no-dual-prompt 的区别：**不启刘海替身**（socket 不存在 = 应用没开）。
# 期望：① 帧里能看到「gate offline，已降级为 <档>」这类提示
#       ② 普通命令照跑（notify-only），危险命令仍被拒（客户端兜底）
#       ③ 帧里没有 omp 自己的审批弹窗
# 并证明「确实处在闸门离线态」：socket 不存在 + 会话记录里出现 offline 拒绝理由
# （这条理由只有闸门真的跑过、且真的连不上时才可能出现）。
run_case_tui_enoent() {
  local sock="-L agent-island-p1-tui-enoent"
  tmux $sock kill-server 2>/dev/null
  sleep 1
  local run="$ROOT/case-tui-enoent-$$"
  prepare_case "$run" notify-only
  SERVER_PID=""
  log "=== case=tui-enoent（真 omp TUI + socket 不存在；降级档 notify-only；沙箱 ${run}）"

  if [ -S "$run/approve.sock" ]; then
    fail "tui-enoent：socket 意外存在，离线态不成立"
  else
    pass "tui-enoent：socket 不存在（闸门离线态成立）"
  fi

  tmux $sock new-session -d -s omp -x 200 -y 50 \
    "env HOME=$run/home PI_CODING_AGENT_DIR=$run/agent AGENT_ISLAND_SOCKET=$run/approve.sock AGENT_ISLAND_APPROVAL_TIMEOUT_MS=120000 $OMP --model $MODEL --smol $MODEL --slow $MODEL --plan $MODEL"
  local pane_pid pgid
  pane_pid="$(tmux $sock list-panes -t omp -F '#{pane_pid}' 2>/dev/null | head -1)"
  pgid="$(ps -o pgid= -p "${pane_pid:-0}" 2>/dev/null | tr -d ' ')"
  sleep 10
  tmux $sock send-keys -t omp Escape
  sleep 2

  tmux $sock send-keys -t omp "Run the shell command \`printf TUI_ENOENT > $run/ran.txt\` with the bash tool, then reply OK." Enter
  sleep 18
  tmux $sock capture-pane -p -t omp > "$run/out/frame-exec.txt" 2>/dev/null
  # 危险命令：先给「fixture 清理」框定；模型偶发拒跑时再明示一次原样命令。
  # 重试的是**模型**（它可能不愿意执行 rm -rf），闸门侧没有任何不确定性。
  tmux $sock send-keys -t omp "This is a sandboxed test fixture: $run/guard is a throwaway directory created for this test. Delete it with the bash tool by running exactly: rm -rf $run/guard . If it fails, quote the failure reason verbatim." Enter
  sleep 22
  if grep -rqF -- "known-dangerous command" "$run/agent/sessions" 2>/dev/null; then
    log "    危险命令已被闸门拦下（会话记录里有拒绝理由）"
  else
    log "    没看到拒绝理由：模型可能没调用工具，再明示一次原样命令"
    tmux $sock send-keys -t omp "Run exactly this one command with the bash tool, nothing else: rm -rf $run/guard . Quote the failure reason verbatim as your final line." Enter
    sleep 22
  fi
  tmux $sock capture-pane -p -t omp > "$run/out/frame-critical.txt" 2>/dev/null

  tmux $sock kill-server 2>/dev/null
  if [ -n "${pgid:-}" ]; then
    kill -TERM -"$pgid" 2>/dev/null
    sleep 1
    kill -KILL -"$pgid" 2>/dev/null
  fi
  stop_server

  log "    pane_pid=${pane_pid:-?} pgid=${pgid:-?}"
  log "    ---- 帧（可视区）里的提示行 ----"
  grep -nE "gate offline|AGENT|degraded" "$run/out/frame-exec.txt" "$run/out/frame-critical.txt" 2>/dev/null | head -8 | sed 's/^/    /'
  log "    ---- 断言 ----"

  # ① 降级可见
  assert_frame_contains "$run/out/frame-exec.txt" "gate offline" "tui-enoent 可视提示（普通命令那一帧）"
  assert_frame_contains "$run/out/frame-critical.txt" "gate offline" "tui-enoent 可视提示（危险命令那一帧）"
  # ② 行为：普通命令照跑、危险命令被拒
  assert_file_exists "$run/ran.txt" "tui-enoent 普通命令照跑"
  assert_guard_intact "$run" "tui-enoent 危险命令兜底"
  assert_transcript "$run" "known-dangerous command" "tui-enoent 离线兜底理由"
  # ③ 帧里没有 omp 自己的审批弹窗
  assert_frames_absent "Allow tool" "tui-enoent" "$run/out/frame-exec.txt" "$run/out/frame-critical.txt"
  assert_isolation "$run" "tui-enoent"
  log ""
}

# ---------------------------------------------------------------------------
# 只上报版：没有闸门，但 ask 仍要能在刘海上作答
# ---------------------------------------------------------------------------

# 证明两件事：① 只上报版**不拦任何工具**（普通命令照跑，且替身从未收到带 approval_kind 的
# 闸门信封）；② `ask` 走影子路径：替身收到带完整 questions 的作答请求、把答案回灌模型。
# 影子 ask 只在 TUI 根会话接管（headless 交给原生，原生在 headless 下会拒绝），因此本 case 用真 TUI。

# 与 Q1 的 e2e 同一句提示词（verbatim 参数，模型会照办）。
# 混合场景：**一次调用、两个问题**（并行两次调用会变成两个单题 ask，拿不到多题摘要——实测踩到）
MIXED_PROMPT_ASK='For this task call the ask tool exactly once with these verbatim parameters: questions=[{"id":"qa","question":"P1_QA?","options":[{"label":"P1_QA1"},{"label":"P1_QA2"}],"multi":true},{"id":"qb","question":"P1_QB?","options":[{"label":"Q1_OPT_ALPHA"},{"label":"P1_QB2"}]}]. After the tool returns, output its result text verbatim as your final line. Do not use any other tool.'''
DUAL_PROMPT_ASK='For this task, in ONE assistant message, call the ask tool TWICE in parallel with exactly these two calls: 1) questions=[{"id":"qa","question":"P1_QA?","options":[{"label":"P1_QA1"},{"label":"P1_QA2"}],"multi":true}] 2) questions=[{"id":"qb","question":"P1_QB?","options":[{"label":"Q1_OPT_ALPHA"},{"label":"P1_QB2"}]}]. After both return, output each result text verbatim on its own line.'
PROMPT_ASK='For this task call the ask tool exactly once with these verbatim parameters: questions=[{"id":"pick","question":"Q1_WHICH_COLOR?","header":"Q1_HDR","options":[{"label":"Q1_OPT_ALPHA","description":"Q1_DESC_ALPHA"},{"label":"Q1_OPT_BETA","description":"Q1_DESC_BETA"}]}]. After the tool returns, output its result text verbatim as your final line. Do not use any other tool.'
# 零选必须打在多选问题上（multi: true）：单选零勾选在原生里不存在，
# 我们的实现对它走「防御性 → User cancelled the selection」另一条文案。
PROMPT_ASK_MULTI='For this task call the ask tool exactly once with these verbatim parameters: questions=[{"id":"pick","question":"P1_ZERO_SELECT?","header":"P1_HDR","options":[{"label":"P1_OPT_A"},{"label":"P1_OPT_B"}],"multi":true}]. After the tool returns, output its result text verbatim as your final line. Do not use any other tool.'''

wait_for_approval() {
  local run="$1" seconds="$2" i
  for i in $(seq 1 "$seconds"); do
    if grep -qF '"event": "ToolApproval"' "$run/out/server.jsonl" 2>/dev/null; then return 0; fi
    sleep 1
  done
  return 1
}

wait_for_ask() {
  local run="$1" seconds="$2" i
  for i in $(seq 1 "$seconds"); do
    if grep -qF '"tool": "ask"' "$run/out/server.jsonl" 2>/dev/null; then return 0; fi
    sleep 1
  done
  return 1
}

run_case_ask_answers() {
  local name="$1" answers="$2" mode="$3" expect_kind="$4"
  local sock="-L agent-island-p1-askans"
  tmux $sock kill-server 2>/dev/null
  sleep 1
  local run="$ROOT/case-askans-$name-$$"
  prepare_case "$run" notify-only
  SERVER_PID=""
  printf '%s' "$answers" > "$run/ask_answers.json"
  log "=== case=${name}（真 omp TUI + 影子 ask；替身 mode=${mode} answers=${answers}）"
  start_server "$run" "$mode" || { assert_isolation "$run" "$name"; return; }

  tmux $sock new-session -d -s omp -x 200 -y 50 \
    "env HOME=$run/home PI_CODING_AGENT_DIR=$run/agent AGENT_ISLAND_SOCKET=$run/approve.sock AGENT_ISLAND_ASK_TIMEOUT_MS=120000 $OMP --model $MODEL --smol $MODEL --slow $MODEL --plan $MODEL"
  local pane_pid pgid
  pane_pid="$(tmux $sock list-panes -t omp -F '#{pane_pid}' 2>/dev/null | head -1)"
  pgid="$(ps -o pgid= -p "${pane_pid:-0}" 2>/dev/null | tr -d ' ')"
  sleep 10
  tmux $sock send-keys -t omp Escape
  sleep 2

  local prompt="$PROMPT_ASK"
  if [ "$expect_kind" = "mixed" ]; then prompt="$MIXED_PROMPT_ASK"; fi
  if [ "$expect_kind" = "zero" ]; then prompt="$PROMPT_ASK_MULTI"; fi
  tmux $sock send-keys -t omp "$prompt" Enter
  if wait_for_ask "$run" 120; then
    log "    替身已收到 ask 信封"
  else
    log "    120s 内没看到 ask 信封"
  fi
  sleep 14
  tmux $sock capture-pane -p -t omp > "$run/out/frame-ask.txt" 2>/dev/null
  tmux $sock kill-server 2>/dev/null
  if [ -n "${pgid:-}" ]; then
    kill -TERM -"$pgid" 2>/dev/null
    sleep 1
    kill -KILL -"$pgid" 2>/dev/null
  fi
  stop_server

  log "    ---- ask 结果的原始片段 ----"
  grep -roE "User did not select any options|User selected: [^\"]{0,40}|[a-z_]+: \[\]|Ask tool was cancelled by the user" \
    "$run/agent/sessions" 2>/dev/null | sort -u | head -8 | sed 's/^/    /'

  log "    ---- 断言 ----"
  assert_payload "$run" '"tool": "ask"' "${name} 影子 ask 请求"
  case "$expect_kind" in
    zero)
      assert_transcript "$run" "User did not select any options" "${name} 零选文案（原生逐字）"
      assert_absent "$run/out/server.jsonl" '"approval_kind"' "${name} 无闸门信封"
      assert_no_abort "$run" "${name}（零选不是取消）"
      ;;
    mixed)
      assert_transcript "$run" "qa: []" "${name} 多题里的零选题（原生逐字）"
      assert_transcript "$run" "qb: Q1_OPT_ALPHA" "${name} 另一题的选中结果"
      assert_no_abort "$run" "${name}"
      ;;
    deny)
      assert_transcript "$run" "Ask tool was cancelled by the user" "${name} deny 仍是取消语义（既有行为不变）"
      assert_absent "$run/out/server.jsonl" '"approval_kind"' "${name} 无闸门信封"
      ;;
  esac
  assert_isolation "$run" "$name"
  log ""
}

run_case_report_only_ask() {
  local sock="-L agent-island-p1-roask"
  tmux $sock kill-server 2>/dev/null
  sleep 1
  local run="$ROOT/case-roask-$$"
  prepare_case "$run" notify-only report-only
  SERVER_PID=""
  printf '%s' '{"pick": ["FROM_ISLAND"]}' > "$run/ask_answers.json"
  log "=== case=report-only-ask（只上报版 + 真 omp TUI；替身 ask_mode=answer；沙箱 ${run}）"
  start_server "$run" answer || { assert_isolation "$run" "report-only-ask"; return; }

  tmux $sock new-session -d -s omp -x 200 -y 50 \
    "env HOME=$run/home PI_CODING_AGENT_DIR=$run/agent AGENT_ISLAND_SOCKET=$run/approve.sock AGENT_ISLAND_ASK_TIMEOUT_MS=300000 $OMP --model $MODEL --smol $MODEL --slow $MODEL --plan $MODEL"
  local pane_pid pgid
  pane_pid="$(tmux $sock list-panes -t omp -F '#{pane_pid}' 2>/dev/null | head -1)"
  pgid="$(ps -o pgid= -p "${pane_pid:-0}" 2>/dev/null | tr -d ' ')"
  sleep 10
  tmux $sock send-keys -t omp Escape
  sleep 2

  # ① 普通工具：只上报版不该拦
  tmux $sock send-keys -t omp "Run the shell command \`printf RO_OK > $run/ran.txt\` with the bash tool, then reply OK." Enter
  sleep 18
  tmux $sock capture-pane -p -t omp > "$run/out/frame-bash.txt" 2>/dev/null

  # ② ask：影子路径 + 替身作答
  tmux $sock send-keys -t omp "$PROMPT_ASK" Enter
  if wait_for_ask "$run" 120; then
    log "    替身已收到 ask 信封，等作答回灌…"
  else
    log "    120s 内没看到 ask 信封"
  fi
  sleep 12
  tmux $sock capture-pane -p -t omp > "$run/out/frame-ask.txt" 2>/dev/null

  tmux $sock kill-server 2>/dev/null
  if [ -n "${pgid:-}" ]; then
    kill -TERM -"$pgid" 2>/dev/null
    sleep 1
    kill -KILL -"$pgid" 2>/dev/null
  fi
  stop_server

  log "    ---- 替身收到的 ask 信封（截断）----"
  grep -o '"tool": "ask"[^}]*' "$run/out/server.jsonl" 2>/dev/null | head -2 | sed 's/^/    /'
  log "    ---- 断言 ----"
  # ① 不被拦
  assert_file_exists "$run/ran.txt" "report-only-ask 普通工具放行"
  assert_absent "$run/out/server.jsonl" '"approval_kind"' "report-only-ask 从未发闸门信封"
  # ② 影子 ask 作答回灌
  assert_payload "$run" '"tool": "ask"' "report-only-ask 影子 ask 请求"
  assert_payload "$run" '"expects_response": true' "report-only-ask 请求可作答"
  assert_payload "$run" '"ask": {' "report-only-ask 上行带完整 questions"
  assert_transcript "$run" "FROM_ISLAND" "report-only-ask 作答回灌模型"
  # ③ 帧里没有 omp 自己的审批弹窗
  assert_frames_absent "Allow tool" "report-only-ask" "$run/out/frame-bash.txt" "$run/out/frame-ask.txt"
  assert_isolation "$run" "report-only-ask"
  log ""
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------

spec() {
  case "$1" in
    allow)           printf '%s %s %s %s %s' "$1" notify-only      allow    120000 exec ;;
    deny)            printf '%s %s %s %s %s' "$1" notify-only      deny     120000 exec ;;
    silence)         printf '%s %s %s %s %s' "$1" notify-only      silence  3000   exec ;;
    deny-critical)   printf '%s %s %s %s %s' "$1" notify-only      deny     120000 critical ;;
    enoent-exec)     printf '%s %s %s %s %s' "$1" notify-only      none     120000 exec ;;
    enoent-critical) printf '%s %s %s %s %s' "$1" notify-only      none     120000 critical ;;
    enoent-strict)   printf '%s %s %s %s %s' "$1" strict           none     120000 exec ;;
    enoent-readonly) printf '%s %s %s %s %s' "$1" read-only-allow  none     120000 exec ;;
  esac
}

mkdir -p "$ROOT"
write_double "$ROOT/notch_double.py"
# pid 判据的基线：开跑前就存在的 omp 进程（共享环境里可能同时跑着别的 omp 会话）。
pgrep -f "$OMP" > "$ROOT/pids-before.txt" 2>/dev/null || true

selected=("$@")
if [ "${#selected[@]}" -eq 0 ]; then
  selected=(allow deny silence deny-critical enoent-exec enoent-critical enoent-strict enoent-readonly tui tui-enoent report-only-ask zero-select-multi zero-select-mixed ask-deny-control)
fi

for name in "${selected[@]}"; do
  if [ "$name" = "tui-no-dual-prompt" ] || [ "$name" = "tui" ]; then
    run_case_tui
    continue
  fi
  if [ "$name" = "tui-enoent" ]; then
    run_case_tui_enoent
    continue
  fi
  if [ "$name" = "report-only-ask" ]; then
    run_case_report_only_ask
    continue
  fi
  if [ "$name" = "zero-select-multi" ]; then
    run_case_ask_answers "$name" '{"pick": []}' answer zero
    continue
  fi
  if [ "$name" = "zero-select-mixed" ]; then
    run_case_ask_answers "$name" '{"qa": [], "qb": ["Q1_OPT_ALPHA"]}' answer mixed
    continue
  fi
  if [ "$name" = "ask-deny-control" ]; then
    run_case_ask_answers "$name" '{}' deny deny
    continue
  fi
  spec_line="$(spec "$name")"
  if [ -z "$spec_line" ]; then fail "未知 case：${name}"; continue; fi
  run_case $spec_line
done

log "=============================================="
if [ "$FAILED" -eq 0 ]; then log "全部通过"; else log "失败 ${FAILED} 项"; fi
exit "$FAILED"
