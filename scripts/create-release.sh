#!/bin/bash
# Create a release: notarize, create DMG, sign for Sparkle, upload to GitHub, update website
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
EXPORT_PATH="$BUILD_DIR/export"
RELEASE_DIR="$PROJECT_DIR/releases"
KEYS_DIR="$PROJECT_DIR/.sparkle-keys"

# GitHub repository (owner/repo format)
GITHUB_REPO="seehar/agent-island"

# GitHub Pages 上的更新 feed（Pages 源选 gh-pages 分支根目录）
PAGES_FEED_URL="https://seehar.github.io/agent-island/appcast.xml"

# Website repo for auto-updating appcast
WEBSITE_DIR="${AGENT_ISLAND_WEBSITE:-$PROJECT_DIR/../AgentIsland-website}"
WEBSITE_PUBLIC="$WEBSITE_DIR/public"

APP_PATH="$EXPORT_PATH/AgentIsland.app"
APP_NAME="AgentIsland"
KEYCHAIN_PROFILE="AgentIsland"

echo "=== Creating Release ==="
echo ""

# Check if app exists
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: App not found at $APP_PATH"
    echo "Run ./scripts/build.sh first"
    exit 1
fi

# Get version from app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")

echo "Version: $VERSION (build $BUILD)"
echo ""

mkdir -p "$RELEASE_DIR"

# ============================================
# Step 1: Notarize the app
# ============================================
echo "=== Step 1: Notarizing ==="

# Check if keychain profile exists
if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" &>/dev/null; then
    echo ""
    echo "No keychain profile found. Set up credentials with:"
    echo ""
    echo "  xcrun notarytool store-credentials \"$KEYCHAIN_PROFILE\" \\"
    echo "      --apple-id \"your@email.com\" \\"
    echo "      --team-id \"2DKS5U9LV4\" \\"
    echo "      --password \"xxxx-xxxx-xxxx-xxxx\""
    echo ""
    echo "Create an app-specific password at: https://appleid.apple.com"
    echo ""
    read -p "Skip notarization for now? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
    SKIP_NOTARIZATION=true
    echo "WARNING: Skipping notarization. Users will see Gatekeeper warnings!"
else
    # Create zip for notarization
    ZIP_PATH="$BUILD_DIR/$APP_NAME-$VERSION.zip"
    echo "Creating zip for notarization..."
    ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

    echo "Submitting for notarization..."
    xcrun notarytool submit "$ZIP_PATH" \
        --keychain-profile "$KEYCHAIN_PROFILE" \
        --wait

    echo "Stapling notarization ticket..."
    xcrun stapler staple "$APP_PATH"

    rm "$ZIP_PATH"
    echo "Notarization complete!"
fi

echo ""

# ============================================
# Step 2: Create DMG
# ============================================
echo "=== Step 2: Creating DMG ==="

DMG_PATH="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"

# Remove existing DMG if present
if [ -f "$DMG_PATH" ]; then
    echo "Removing existing DMG..."
    rm -f "$DMG_PATH"
fi

# Check if create-dmg is available (prettier DMG)
if command -v create-dmg &> /dev/null; then
    echo "Using create-dmg for prettier output..."
    create-dmg \
        --volname "AgentIsland" \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "AgentIsland.app" 150 200 \
        --app-drop-link 450 200 \
        --hide-extension "AgentIsland.app" \
        "$DMG_PATH" \
        "$APP_PATH"
else
    echo "Using hdiutil (install create-dmg for prettier DMG: brew install create-dmg)"
    hdiutil create -volname "AgentIsland" \
        -srcfolder "$APP_PATH" \
        -ov -format UDZO \
        "$DMG_PATH"
fi

echo "DMG created: $DMG_PATH"
echo ""

# ============================================
# Step 3: Notarize the DMG
# ============================================
if [ -z "$SKIP_NOTARIZATION" ]; then
    echo "=== Step 3: Notarizing DMG ==="

    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$KEYCHAIN_PROFILE" \
        --wait

    xcrun stapler staple "$DMG_PATH"
    echo "DMG notarized!"
    echo ""
fi

# ============================================
# Step 4: Sign for Sparkle and generate appcast
# ============================================
echo "=== Step 4: Signing for Sparkle ==="

# Find Sparkle tools
SPARKLE_SIGN=""
GENERATE_APPCAST=""

POSSIBLE_PATHS=(
    "$HOME/Library/Developer/Xcode/DerivedData/AgentIsland-*/SourcePackages/artifacts/sparkle/Sparkle/bin"
)

for path_pattern in "${POSSIBLE_PATHS[@]}"; do
    for path in $path_pattern; do
        if [ -x "$path/sign_update" ]; then
            SPARKLE_SIGN="$path/sign_update"
            GENERATE_APPCAST="$path/generate_appcast"
            break 2
        fi
    done
done

if [ -z "$SPARKLE_SIGN" ]; then
    echo "WARNING: Could not find Sparkle tools."
    echo "Build the project in Xcode first to download Sparkle package."
    echo ""
    echo "Skipping Sparkle signing. You'll need to manually:"
    echo "1. Sign the DMG with sign_update"
    echo "2. Generate appcast with generate_appcast"
else
    # Check for private key
    if [ ! -f "$KEYS_DIR/eddsa_private_key" ]; then
        echo "WARNING: No private key found at $KEYS_DIR/eddsa_private_key"
        echo "Run ./scripts/generate-keys.sh first"
        echo ""
        echo "Skipping Sparkle signing."
    else
        # Generate signature
        echo "Signing DMG for Sparkle..."
        SIGNATURE=$("$SPARKLE_SIGN" --ed-key-file "$KEYS_DIR/eddsa_private_key" "$DMG_PATH")

        echo ""
        echo "Sparkle signature:"
        echo "$SIGNATURE"
        echo ""

        # Generate/update appcast
        echo "Generating appcast..."
        APPCAST_DIR="$RELEASE_DIR/appcast"
        mkdir -p "$APPCAST_DIR"

        # Copy DMG to appcast directory
        cp "$DMG_PATH" "$APPCAST_DIR/"

        # Generate appcast.xml
        "$GENERATE_APPCAST" --ed-key-file "$KEYS_DIR/eddsa_private_key" "$APPCAST_DIR"

        echo "Appcast generated at: $APPCAST_DIR/appcast.xml"
    fi
fi

echo ""

# ============================================
# Step 5: Create GitHub Release
# ============================================
echo "=== Step 5: Creating GitHub Release ==="

# 下载地址只由仓库与版本决定：即使没有 gh CLI（手动上传附件），appcast 的 enclosure 也要指向它
GITHUB_DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/v$VERSION/$APP_NAME-$VERSION.dmg"

if ! command -v gh &> /dev/null; then
    echo "WARNING: gh CLI not found. Install with: brew install gh"
    echo "Skipping GitHub release upload; appcast 的下载地址指向 $GITHUB_DOWNLOAD_URL"
    echo "手动把 $DMG_PATH 上传到 tag v$VERSION 后 feed 才可用。"
else
    # Check if release already exists
    if gh release view "v$VERSION" --repo "$GITHUB_REPO" &>/dev/null; then
        echo "Release v$VERSION already exists. Updating..."
        gh release upload "v$VERSION" "$DMG_PATH" --repo "$GITHUB_REPO" --clobber
    else
        echo "Creating release v$VERSION..."
        gh release create "v$VERSION" "$DMG_PATH" \
            --repo "$GITHUB_REPO" \
            --title "AgentIsland v$VERSION" \
            --notes "## AgentIsland v$VERSION

### Installation
1. Download \`$APP_NAME-$VERSION.dmg\`
2. Open the DMG and drag AgentIsland to Applications
3. Launch AgentIsland from Applications

### Auto-updates
After installation, AgentIsland will automatically check for updates."
    fi

    echo "GitHub release created: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
    echo "Download URL: $GITHUB_DOWNLOAD_URL"
fi

echo ""

# ============================================
# Step 6: Publish appcast to GitHub Pages
# ============================================
echo "=== Step 6: Publishing appcast to GitHub Pages ==="

APPCAST_FILE="$RELEASE_DIR/appcast/appcast.xml"
PAGES_BRANCH="gh-pages"

if [ ! -f "$APPCAST_FILE" ]; then
    echo "WARNING: Appcast not generated; skipping Pages publish."
else
    # DMG 不随 Pages 发布：appcast 里的下载地址指回 GitHub Release 附件
    if [ -n "$GITHUB_DOWNLOAD_URL" ]; then
        sed -i '' "s|url=\"[^\"]*$APP_NAME-$VERSION.dmg\"|url=\"$GITHUB_DOWNLOAD_URL\"|g" "$APPCAST_FILE"
        echo "Updated appcast.xml with GitHub download URL"
    fi

    PAGES_WORKTREE="$(mktemp -d)/agent-island-$PAGES_BRANCH"

    if git ls-remote --exit-code --heads origin "$PAGES_BRANCH" >/dev/null 2>&1; then
        git fetch --quiet origin "+refs/heads/$PAGES_BRANCH:refs/heads/$PAGES_BRANCH"
        git worktree add --quiet "$PAGES_WORKTREE" "$PAGES_BRANCH"
    else
        echo "Branch $PAGES_BRANCH does not exist yet; creating it."
        git worktree add --quiet --detach "$PAGES_WORKTREE" HEAD
    fi

    cp "$APPCAST_FILE" "$PAGES_WORKTREE/appcast.xml"

    (
        cd "$PAGES_WORKTREE" || exit 1
        if ! git rev-parse --verify --quiet "refs/heads/$PAGES_BRANCH" >/dev/null; then
            # 首次发布：以孤儿分支起底，只提交 appcast.xml
            git checkout --quiet --orphan "$PAGES_BRANCH"
            git rm -r --quiet --cached .
        fi
        git add appcast.xml
        git commit --quiet -m "appcast: v$VERSION"
        git push --quiet origin "HEAD:refs/heads/$PAGES_BRANCH"
    )

    # 临时 worktree 用完即删，避免在主工作树里留下改动
    git worktree remove --force "$PAGES_WORKTREE"

    echo "Feed published: $PAGES_FEED_URL"
    echo "首次使用需在仓库 Settings → Pages 选 branch：$PAGES_BRANCH /（root）"
fi

echo ""

# ============================================
# Step 7: (legacy) 同步外部站点
# ============================================
if [ -d "$WEBSITE_PUBLIC" ] && [ -f "$APPCAST_FILE" ]; then
    echo "=== Step 7: Updating Website ==="

    # Copy appcast to website
    cp "$APPCAST_FILE" "$WEBSITE_PUBLIC/appcast.xml"

    # Update the download URL in appcast to point to GitHub releases
    if [ -n "$GITHUB_DOWNLOAD_URL" ]; then
        sed -i '' "s|url=\"[^\"]*$APP_NAME-$VERSION.dmg\"|url=\"$GITHUB_DOWNLOAD_URL\"|g" "$WEBSITE_PUBLIC/appcast.xml"
        echo "Updated website appcast.xml with GitHub download URL"
    fi

    # Update src/config.ts with latest version and download URL (preserve other content)
    CONFIG_FILE="$WEBSITE_DIR/src/config.ts"
    if [ -n "$GITHUB_DOWNLOAD_URL" ]; then
        if [ -f "$CONFIG_FILE" ]; then
            # Update existing constants in-place
            sed -i '' "s|export const LATEST_VERSION = .*|export const LATEST_VERSION = \"$VERSION\";|" "$CONFIG_FILE"
            sed -i '' "s|export const DOWNLOAD_URL = .*|export const DOWNLOAD_URL = \"$GITHUB_DOWNLOAD_URL\";|" "$CONFIG_FILE"
        else
            # Create new config file
            cat > "$CONFIG_FILE" << EOF
// Auto-updated by create-release.sh
export const LATEST_VERSION = "$VERSION";
export const DOWNLOAD_URL = "$GITHUB_DOWNLOAD_URL";
EOF
        fi
        echo "Updated src/config.ts with version $VERSION"
    fi

    # Deploy via Cloudflare Pages (manual wrangler deploy — the old GitHub
    # repo is disabled, so git push is no longer an option).
    cd "$WEBSITE_DIR" || exit 1

    WRANGLER_PROJECT="${AGENT_ISLAND_WRANGLER_PROJECT:-vibenotch-website}"

    read -p "Deploy website to Cloudflare Pages ($WRANGLER_PROJECT)? (Y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        if ! command -v wrangler >/dev/null 2>&1; then
            echo "ERROR: wrangler not found. Install with: npm install -g wrangler"
            echo "Skipping website deploy. Appcast updated locally at $WEBSITE_PUBLIC/appcast.xml"
        else
            echo "Building site..."
            npm run build

            echo "Deploying to Cloudflare Pages ($WRANGLER_PROJECT)..."
            wrangler pages deploy dist --project-name="$WRANGLER_PROJECT"
            echo "Website deployed!"
        fi
    else
        echo "Skipped Cloudflare deploy."
        echo "To deploy manually: cd $WEBSITE_DIR && npm run build && wrangler pages deploy dist --project-name=$WRANGLER_PROJECT"
    fi

    cd "$PROJECT_DIR"
elif [ ! -d "$WEBSITE_PUBLIC" ]; then
    echo "Website directory not found; skipping website update."
fi

echo ""


echo "=== Release Complete ==="
echo ""
echo "Files created:"
echo "  - DMG: $DMG_PATH"
if [ -f "$RELEASE_DIR/appcast/appcast.xml" ]; then
    echo "  - Appcast: $RELEASE_DIR/appcast/appcast.xml"
fi
if [ -n "$GITHUB_DOWNLOAD_URL" ]; then
    echo "  - GitHub: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
fi
if [ -f "$APPCAST_FILE" ]; then
    echo "  - Feed: $PAGES_FEED_URL"
fi
