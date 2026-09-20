#!/bin/bash
# 编译门禁：本仓库「改动能不能交付」的唯一判定入口。
#
# 只做检查：跑本地化守卫 + 编译一次 + 按日志判定诊断数 + 可选跑测试。
# 它不安装应用、不改动 build/ 与 releases/ 下的任何产物、不碰 /Applications。
# 派生数据与日志固定在 "${TMPDIR:-/tmp}/agent-island-gate"（可用 TMPDIR 覆盖），
# 既不污染用户 ~/Library/Developer/Xcode/DerivedData，也不和其它任务的构建互相覆盖。
#
# 判据（任何一步不达标就地 exit 非 0，不要只看日志）：
#   步骤 1  check-localization.py --strict：0 错误、0 警告
#   步骤 2  编译出现 ** BUILD SUCCEEDED **，且 ": error:" / ": warning:" 诊断数为 0
#   步骤 3  --with-tests 时追加 xcodebuild test（Debug，只跑 AgentIslandTests）：** TEST SUCCEEDED **
#
# 用法：
#   ./scripts/gate.sh                # Release 编译 + 本地化守卫（默认）
#   ./scripts/gate.sh --debug        # Debug 编译
#   ./scripts/gate.sh --with-tests   # 追加跑测试；scheme 里没有测试目标时打印提示并跳过
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT="$PROJECT_DIR/AgentIsland.xcodeproj"
SCHEME_FILE="$PROJECT/xcshareddata/xcschemes/AgentIsland.xcscheme"

CONFIGURATION="Release"
WITH_TESTS=false

while [ $# -gt 0 ]; do
    case "$1" in
        --release) CONFIGURATION="Release" ;;
        --debug) CONFIGURATION="Debug" ;;
        --with-tests) WITH_TESTS=true ;;
        # 打印开头的注释块作为帮助，遇到第一个非注释行就停
        -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "未知参数: $1（--help 查看用法）"; exit 2 ;;
    esac
    shift
done

# 派生数据与日志都落在临时目录：门禁不占用也不影响用户的 DerivedData
GATE_DIR="${TMPDIR:-/tmp}"
GATE_DIR="${GATE_DIR%/}/agent-island-gate"
GUARD_LOG="$GATE_DIR/localization.log"
BUILD_LOG="$GATE_DIR/build.log"
TEST_LOG="$GATE_DIR/test.log"

mkdir -p "$GATE_DIR"

echo "=== AgentIsland 编译门禁（${CONFIGURATION}） ==="
echo "派生数据: $GATE_DIR"
echo ""

# ============================================
# 步骤 1: 本地化守卫
# ============================================
echo "=== 步骤 1: 本地化守卫（--strict） ==="
set +e
python3 "$SCRIPT_DIR/check-localization.py" --strict 2>&1 | tee "$GUARD_LOG"
GUARD_EXIT=${PIPESTATUS[0]}
set -e

# check-localization.py 的严格模式只把「未引用键」记成 WARN、退出码仍是 0，
# 所以这里自己数一遍警告，保证「0 错误 0 警告」这条判据真的成立
GUARD_WARNINGS=$(grep -c '^WARN' "$GUARD_LOG" || true)
if [ "$GUARD_EXIT" -ne 0 ] || [ "$GUARD_WARNINGS" -ne 0 ]; then
    echo ""
    echo "ERROR: 门禁未通过 —— 本地化守卫（退出码 ${GUARD_EXIT}，警告 $GUARD_WARNINGS 条）"
    exit 1
fi
echo ""

# ============================================
# 步骤 2: 编译并判定诊断
# ============================================
echo "=== 步骤 2: 编译 $CONFIGURATION ==="
set +e
xcodebuild -project "$PROJECT" \
    -scheme AgentIsland \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$GATE_DIR" \
    CODE_SIGNING_ALLOWED=NO \
    build > "$BUILD_LOG" 2>&1
BUILD_EXIT=$?
set -e

echo "xcodebuild 退出码: ${BUILD_EXIT}（完整日志：${BUILD_LOG}）"

BUILD_SUCCEEDED=false
if grep -qF '** BUILD SUCCEEDED **' "$BUILD_LOG"; then
    BUILD_SUCCEEDED=true
fi
# grep -c 无匹配时退出码为 1，这里按 0 条处理
DIAGNOSTICS=$(grep -cE ': (error|warning):' "$BUILD_LOG" || true)
DIAGNOSTICS=${DIAGNOSTICS:-0}

echo "BUILD SUCCEEDED: ${BUILD_SUCCEEDED}；编译诊断: $DIAGNOSTICS 条"

if [ "$BUILD_EXIT" -ne 0 ] || [ "$BUILD_SUCCEEDED" != true ] || [ "$DIAGNOSTICS" -ne 0 ]; then
    echo ""
    echo "ERROR: 门禁未通过 —— 判据是 BUILD SUCCEEDED 且编译诊断 0 条"
    if [ "$DIAGNOSTICS" -ne 0 ]; then
        echo "--- 诊断前 20 条 ---"
        grep -m20 -E ': (error|warning):' "$BUILD_LOG" || true
    fi
    echo "--- 完整日志：$BUILD_LOG ---"
    exit 1
fi
echo ""

# ============================================
# 步骤 3: 测试（可选）
# ============================================
if [ "$WITH_TESTS" = true ]; then
    echo "=== 步骤 3: 测试（Debug） ==="
    # TestAction 下没有 TestableReference 说明 scheme 还没接测试目标，
    # 这种情况下 xcodebuild test 会直接报「not currently configured for the test action」，
    # 所以提前跳过并提示，不算门禁失败
    if [ ! -f "$SCHEME_FILE" ] || ! grep -q '<TestableReference' "$SCHEME_FILE"; then
        echo "提示: scheme 里没有 test action（还没挂测试目标 AgentIslandTests），跳过 xcodebuild test。"
        echo "      等测试目标接进 scheme 后重跑 --with-tests 即可，本脚本不用改。"
    else
        set +e
        xcodebuild -project "$PROJECT" \
            -scheme AgentIsland \
            -configuration Debug \
            -derivedDataPath "$GATE_DIR" \
            CODE_SIGNING_ALLOWED=NO \
            test -only-testing:AgentIslandTests > "$TEST_LOG" 2>&1
        TEST_EXIT=$?
        set -e

        if [ "$TEST_EXIT" -ne 0 ] || ! grep -qF '** TEST SUCCEEDED **' "$TEST_LOG"; then
            echo "ERROR: 门禁未通过 —— 测试未成功（退出码 ${TEST_EXIT}）"
            tail -40 "$TEST_LOG"
            echo "--- 完整日志：$TEST_LOG ---"
            exit 1
        fi
        echo "测试通过（完整日志：${TEST_LOG}）"
    fi
    echo ""
fi

echo "=== 门禁通过（${CONFIGURATION}） ==="