#!/bin/bash
# 基于当前代码构建 Release 并安装到本机 /Applications。
#
# 与 build.sh 的区别：build.sh 走 developer-id 导出（需要 Apple 签名证书），
# 本脚本面向没有 Developer ID 的机器 —— 关闭签名构建，安装前做 ad-hoc 重签
# （arm64 上完全无签名的 app 无法运行），不做公证，产物未经 Apple 认证。
#
# 用法：
#   ./scripts/build-and-install.sh              构建 + 安装 + 启动
#   ./scripts/build-and-install.sh --no-launch  安装后不启动
#   ./scripts/build-and-install.sh --build-only 只构建，产出 .app 与 DMG 到 releases/
#   ./scripts/build-and-install.sh --no-dmg     不生成 DMG（安装不需要它）
#   ./scripts/build-and-install.sh --install-dir DIR  安装到 DIR（默认 /Applications）
#
# 注意：安装到 /Applications 之外的目录时脚本不会去动正在运行的实例。
# 步骤 1 先跑 scripts/gate.sh --release（本地化守卫 + Release 编译 0 诊断），未过即中止，
# 不会进入归档与安装。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

APP_NAME="AgentIsland"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/AgentIsland.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
STAGED_APP="$EXPORT_DIR/$APP_NAME.app"
RELEASE_DIR="$PROJECT_DIR/releases"

INSTALL_DIR="/Applications"
BUILD_ONLY=false
MAKE_DMG=true
# 默认装完就启动（先退掉旧实例）；--no-launch 保留「只装不启动」
LAUNCH_AFTER=true

while [ $# -gt 0 ]; do
    case "$1" in
        --build-only) BUILD_ONLY=true; LAUNCH_AFTER=false ;;
        --no-dmg) MAKE_DMG=false ;;
        --no-launch) LAUNCH_AFTER=false ;;
        --launch) LAUNCH_AFTER=true ;;
        --install-dir) INSTALL_DIR="${2:?--install-dir 需要一个路径}"; shift ;;
        # 打印开头的注释块作为帮助，遇到第一个非注释行就停
        -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "未知参数: $1（--help 查看用法）"; exit 2 ;;
    esac
    shift
done

DEST_APP="$INSTALL_DIR/$APP_NAME.app"

if [ "$BUILD_ONLY" = false ]; then
    # 目标目录可能还不存在（--install-dir 指向新路径），先建再判断可写，避免白构建一轮
    mkdir -p "$INSTALL_DIR" 2>/dev/null || true
    if [ ! -w "$INSTALL_DIR" ]; then
        echo "ERROR: $INSTALL_DIR 不可写。用 --install-dir 指定其他目录，或加 --build-only。"
        exit 1
    fi
fi

echo "=== 构建并安装 AgentIsland ==="
echo "项目目录: $PROJECT_DIR"
echo "源码状态: $(cd "$PROJECT_DIR" && git rev-parse --short HEAD 2>/dev/null || echo '非 git 仓库')$( [ -n "$(cd "$PROJECT_DIR" && git status --porcelain 2>/dev/null)" ] && echo ' (含未提交改动)')"
echo ""

# ============================================
# 步骤 1: 编译门禁（本地化守卫 + Release 编译 0 诊断）
# ============================================
echo "=== 步骤 1: 编译门禁 ==="
if ! "$SCRIPT_DIR/gate.sh" --release; then
    echo "ERROR: 编译门禁未通过，中止构建。"
    exit 1
fi
echo "" 

# ============================================
# 步骤 2: 归档（关闭签名）
# ============================================
echo "=== 步骤 2: 归档 Release ==="
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

LOG="$BUILD_DIR/archive.log"
set +e
xcodebuild archive \
    -scheme AgentIsland \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_STYLE=Manual \
    ENABLE_HARDENED_RUNTIME=YES > "$LOG" 2>&1
ARCHIVE_EXIT=$?
set -e

if [ "$ARCHIVE_EXIT" -ne 0 ]; then
    echo "ERROR: 归档失败，完整日志：$LOG"
    tail -40 "$LOG"
    exit 1
fi

# 诊断判据由步骤 1 的门禁负责（0 条才算过），这里只确认归档产物存在
echo "归档成功"

if [ ! -d "$ARCHIVED_APP" ]; then
    echo "ERROR: 归档里找不到 $APP_NAME.app"
    exit 1
fi

# ============================================
# 步骤 3: 取出并 ad-hoc 重签
# ============================================
echo ""
echo "=== 步骤 3: 重签为 ad-hoc ==="

mkdir -p "$EXPORT_DIR"
rm -rf "$STAGED_APP"
# 用 ditto 保留扩展属性；cp -R 可能破坏包结构
ditto "$ARCHIVED_APP" "$STAGED_APP"

# arm64 上无签名无法运行，因此必须补一个 ad-hoc 签名；--deep 覆盖 Sparkle.framework
codesign --force --deep --sign - "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
echo "ad-hoc 签名完成，签名校验通过"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$STAGED_APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$STAGED_APP/Contents/Info.plist")
echo "版本: $VERSION (build $BUILD)"

# ============================================
# 步骤 4: 打包 DMG（仅保留产物，安装不走它）
# ============================================
if [ "$MAKE_DMG" = true ]; then
    echo ""
    echo "=== 步骤 4: 生成 DMG ==="
    mkdir -p "$RELEASE_DIR"
    DMG_PATH="$RELEASE_DIR/AgentIsland-$VERSION.dmg"
    rm -f "$DMG_PATH"

    # create-dmg 能做出带背景和拖拽布局的 DMG，没有就退回 hdiutil
    if command -v create-dmg > /dev/null; then
        create-dmg \
            --volname "$APP_NAME" \
            --window-size 600 400 \
            --icon-size 100 \
            --icon "$APP_NAME.app" 150 200 \
            --app-drop-link 450 200 \
            --hide-extension "$APP_NAME.app" \
            "$DMG_PATH" \
            "$STAGED_APP" || true
    fi

    if [ ! -f "$DMG_PATH" ]; then
        hdiutil create -volname "$APP_NAME" \
            -srcfolder "$STAGED_APP" \
            -ov -format UDZO "$DMG_PATH" > /dev/null
    fi

    # 这里不生成 .sha256：本地重打包出的字节与已发布资产不是同一份，那个文件会被误当发布校验值；
    # 校验值由 create-release.sh 在附件上传成功后、对「本次上传的那份 DMG」生成
    echo "DMG: $DMG_PATH"
fi

if [ "$BUILD_ONLY" = true ]; then
    echo ""
    echo "=== 仅构建完成 ==="
    echo "App: $STAGED_APP"
    exit 0
fi

# ============================================
# 步骤 5: 安装
# ============================================
echo ""
echo "=== 步骤 5: 安装到 $INSTALL_DIR ==="

RUNNING_PIDS=$(pgrep -f "$DEST_APP/Contents/MacOS/" || true)
if [ -n "$RUNNING_PIDS" ]; then
    echo "正在退出现有实例: $RUNNING_PIDS"
    # 只退目标路径下的实例，不碰其他位置的构建
    for pid in $RUNNING_PIDS; do kill -TERM "$pid" 2>/dev/null || true; done
    for _ in $(seq 1 20); do
        pgrep -f "$DEST_APP/Contents/MacOS/" > /dev/null || break
        sleep 0.5
    done
    if pgrep -f "$DEST_APP/Contents/MacOS/" > /dev/null; then
        echo "WARNING: 实例未退出，安装可能产生新旧混杂"
    fi
fi

rm -rf "$DEST_APP"
ditto "$STAGED_APP" "$DEST_APP"

# ============================================
# 步骤 6: 校验
# ============================================
echo ""
echo "=== 步骤 6: 校验 ==="

INSTALLED_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$DEST_APP/Contents/Info.plist")
codesign --verify --deep --strict "$DEST_APP"
echo "安装位置: $DEST_APP"
echo "安装版本: $INSTALLED_VERSION (build $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$DEST_APP/Contents/Info.plist"))"
echo "签名: $(codesign -dv "$DEST_APP" 2>&1 | grep '^Signature=' | cut -d= -f2)"
echo "隔离属性: $(xattr "$DEST_APP" 2>/dev/null | grep -c quarantine) 个"

if [ "$LAUNCH_AFTER" = true ]; then
    echo ""
    echo "=== 启动 ==="
    open "$DEST_APP"
    sleep 6
    if pgrep -f "$DEST_APP/Contents/MacOS/" > /dev/null; then
        echo "已启动: $(pgrep -f "$DEST_APP/Contents/MacOS/" | tr '\n' ' ')"
    else
        echo "ERROR: 启动后未发现进程"
        exit 1
    fi
fi

echo ""
echo "=== 完成 ==="
echo ""
echo "提示：本脚本不再生成 releases/*.dmg.sha256 —— 校验值只对「实际上传的那份文件」有意义，"
echo "      发布态的哈希由 scripts/create-release.sh 在 gh 上传成功后生成。"
echo "提示：产物为 ad-hoc 签名、未经 Apple 公证，spctl 会拒绝它；"
echo "      本机安装不受影响，分发给他人需要 Developer ID 证书与公证。"