#!/bin/bash
# pp-hub 构建：swiftc 直编，不依赖 Xcode 工程
#   ./build.sh        编译并打包成 .app
#   ./build.sh run    编译后前台运行（便于看日志）
set -euo pipefail
cd "$(dirname "$0")"

APP="build/pp-hub.app"
BIN="$APP/Contents/MacOS/pp-hub"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 入口必须是 main.swift（顶层可执行代码不能配 -parse-as-library）
FILES=$(find Sources -name '*.swift' | sort)
echo "编译 $(echo "$FILES" | wc -l | tr -d ' ') 个文件…"

swiftc -O -target arm64-apple-macos26.0 -o "$BIN" $FILES \
  -framework AppKit -framework SwiftUI \
  -lsqlite3 2>&1 | grep -v "In-process dependency scan query failed" || true

if [ ! -f "$BIN" ]; then
  echo "❌ 编译失败" >&2
  exit 1
fi

cp Resources/Info.plist "$APP/Contents/Info.plist"

# 签名：优先用本机稳定的自签证书
# 为什么不能用 ad-hoc：ad-hoc 的 designated requirement 绑 cdhash，每次重建都变，
# macOS 的辅助功能授权随之失效 —— 每改一版就要重新授权一次，开发期不可接受。
IDENTITY="${PPHUB_IDENTITY:-TypelessCore Local Signing}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1 \
    && echo "🔏 已用「$IDENTITY」签名（授权可跨重建保留）" \
    || echo "⚠️  签名失败，退回 ad-hoc（每次重建需重新授权）"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "⚠️  ad-hoc 签名失败"
  echo "⚠️  未找到稳定证书，使用 ad-hoc：每次重建都要重新授权"
fi

echo "✅ 构建完成：$APP"
echo "   数据目录：~/Library/Application Support/pp-hub/"

if [ "${1:-}" = "package" ]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
  OUT="build/pp-hub-$VERSION-macos26-arm64.zip"
  rm -f "$OUT"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT"
  echo "📦 发布包：$OUT（$(du -h "$OUT" | awk '{print $1}')）"
  exit 0
fi

if [ "${1:-}" = "run" ]; then
  echo "---- 前台运行（Ctrl-C 退出）----"
  exec "$BIN"
fi
