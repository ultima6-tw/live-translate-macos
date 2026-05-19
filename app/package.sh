#!/bin/bash
# JaSub 打包腳本：Release build + DMG
# 輸出：dist/JaSub-<version>.dmg
# 首次啟動需右鍵 → 打開（ad-hoc 簽名，未公證）

set -e

APP_NAME="JaSub"
DERIVED="./build"
RELEASE_APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
DIST="./dist"
TMP_STAGE="$DIST/_staging"

# ─── 1. Release build ─────────────────────────────────────────────────────────

echo "▸ Building $APP_NAME (Release)..."

# iCloud 同步資料夾的檔案帶有 extended attributes，
# 直接啟用簽名時 codesign 會拒絕。
# 解法：build 時停用簽名（command line 覆寫），之後手動清 xattr + 簽名。
rm -rf "$DERIVED/Build/Products/Release"

BUILD_LOG=$(mktemp)
xcodebuild -scheme "$APP_NAME" -configuration Release \
           -derivedDataPath "$DERIVED" \
           CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
           build > "$BUILD_LOG" 2>&1
BUILD_EXIT=$?
grep -E "(error:|warning:|BUILD (SUCCEEDED|FAILED))" "$BUILD_LOG" | \
    grep -v appintentsmetadataprocessor || true
rm -f "$BUILD_LOG"

if [ $BUILD_EXIT -ne 0 ] || [ ! -d "$RELEASE_APP" ]; then
    echo "❌ Build failed (exit $BUILD_EXIT)"
    exit 1
fi

# 清 extended attributes，再 ad-hoc 簽名（含 entitlements）
echo "▸ Signing $APP_NAME (ad-hoc)..."
xattr -cr "$RELEASE_APP"
codesign -s - --force --deep \
    --entitlements "$(pwd)/Resources/JaSub.entitlements" \
    "$RELEASE_APP"

# ─── 2. 讀版號 ────────────────────────────────────────────────────────────────

VERSION=$(defaults read "$(pwd)/$RELEASE_APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "0.1.0")
DMG_PATH="$DIST/$APP_NAME-$VERSION.dmg"

# ─── 3. 組裝 DMG 內容 ────────────────────────────────────────────────────────

echo "▸ Staging DMG contents..."
rm -rf "$TMP_STAGE"
mkdir -p "$TMP_STAGE"
cp -R "$RELEASE_APP" "$TMP_STAGE/"
ln -sf /Applications "$TMP_STAGE/Applications"

# ─── 4. 建立壓縮 DMG ─────────────────────────────────────────────────────────

mkdir -p "$DIST"
rm -f "$DMG_PATH"

echo "▸ Creating $DMG_PATH ..."
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$TMP_STAGE" \
    -ov -format UDZO \
    "$DMG_PATH" > /dev/null

rm -rf "$TMP_STAGE"

# ─── 完成 ────────────────────────────────────────────────────────────────────

SIZE=$(du -sh "$DMG_PATH" | cut -f1)
echo ""
echo "✅  $DMG_PATH  ($SIZE)"
echo ""
echo "安裝方式："
echo "  1. 開啟 DMG → 將 JaSub.app 拖入 Applications → 退出 DMG"
echo "  2. 從 Applications 啟動（不要從 DMG 或專案資料夾直接啟動）"
echo "  3. 首次啟動：右鍵 → 打開（App 未經 Apple 公證）"
echo "  4. 若有「無法開啟」提示：系統設定 → 隱私與安全性 → 點「仍要打開」"
echo ""
echo "⚠️  注意：直接從 DMG 或 build 資料夾啟動會讓 macOS 記錯路徑，"
echo "    導致系統音訊授權失效。請務必先拖進 Applications 再啟動。"
