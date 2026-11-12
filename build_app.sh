#!/bin/bash
# 构建 FreedomPlayer.app 并打包 zip（本地自签名，无需开发者账号）
set -euo pipefail
cd "$(dirname "$0")"

# 版本号：CI 打 tag（v1.2.3）时取 tag；本地构建默认 1.0.0
VERSION="${GITHUB_REF_NAME:-v1.0.0}"
VERSION="${VERSION#v}"

echo "==> 编译 (release)"
swift build -c release

APP="build/FreedomPlayer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 生成图标"
TMP=$(mktemp -d)
# 图标由 make_icon.swift 代码绘制（渐变背板 + 描边播放三角 + 速度线）
swift make_icon.swift "$TMP/icon_1024.png"
mkdir -p "$TMP/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon_1024.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$TMP/icon_1024.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> 组装 .app"
cp .build/release/FreedomPlayer "$APP/Contents/MacOS/FreedomPlayer"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>FreedomPlayer</string>
    <key>CFBundleDisplayName</key><string>FreedomPlayer</string>
    <key>CFBundleIdentifier</key><string>com.gaochuan.freedomplayer</string>
    <key>CFBundleExecutable</key><string>FreedomPlayer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <!-- 视频直链大量使用 http，放开 ATS 限制 -->
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Video</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.movie</string>
                <string>public.mpeg-4</string>
                <string>com.apple.quicktime-movie</string>
                <string>public.avi</string>
                <string>public.mpeg-2-transport-stream</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "==> 自签名"
codesign --force --deep -s - "$APP"

echo "==> 写安装说明"
cat > build/安装说明.txt <<'README'
FreedomPlayer 安装说明
==================

【要求】
- Apple Silicon 芯片的 Mac（M1/M2/M3/M4 系列）
- macOS 13.0 或更高版本

【安装步骤】
1. 解压本压缩包
2. 把 FreedomPlayer.app 拖进「应用程序」文件夹
3. 第一次双击打开时，系统会提示「无法验证开发者」，这是正常的
   （本应用为本地自签名分发，没有经过 Apple 公证），用下面任一方法解决：

   方法 A（图形界面）：
   · 双击 → 弹出警告 → 点「完成」
   · 打开 系统设置 → 隐私与安全性 → 拉到最底部 → 点「仍要打开」

   方法 B（终端命令，最省事）：
   · 打开「终端」应用，粘贴以下命令回车：
     xattr -cr /Applications/FreedomPlayer.app
   · 然后正常双击打开即可

【常见问题】
Q: 提示"应用已损坏，无法打开"？
A: 在终端执行上面的方法 B 命令即可解决。

Q: 提示需要 Intel 芯片？
A: 本包仅支持 Apple Silicon（M 系芯片），Intel 老款 Mac 暂不支持。

【主要功能】
- 本地视频播放：添加文件夹自动扫描，支持 MP4/MOV/M4V/AVI/TS 等格式
  （AVFoundation 不支持 MKV/WMV/FLV/WebM 容器，这些格式不会被收录）
- 文件夹树形浏览，海报墙展示，自动生成缩略图
- 继续观看：自动记忆播放进度，下次接着看
- 网络视频：支持 http/https 的 MP4 直链、HLS（m3u8）链接
- 字幕：自动加载同名 SRT/VTT 字幕，支持内嵌字幕轨道，可手动加载外挂字幕
- 音轨切换：多音轨视频可在播放界面选择音轨
- 快捷键：空格 播放/暂停，←/→ 快退/快进 10 秒，双击画面全屏，Esc 返回（全屏时先退全屏）
- ⌘O 打开视频文件，⇧⌘O 打开文件夹
README

echo "==> 打 zip"
mkdir -p build/dist
rm -f build/dist/*.zip
(cd build && zip -qry "dist/FreedomPlayer-${VERSION}-macOS-arm64.zip" "FreedomPlayer.app" "安装说明.txt")

echo "==> 安装到 /Applications"
if [ -d "/Applications/FreedomPlayer.app" ]; then
    pkill -x FreedomPlayer 2>/dev/null || true
    rm -rf "/Applications/FreedomPlayer.app"
    cp -R "$APP" /Applications/
    open "/Applications/FreedomPlayer.app"
    echo "✅ 已更新 /Applications/FreedomPlayer.app 并启动"
else
    echo "ℹ️  /Applications 里还没有安装过，请手动把 $APP 拖入应用程序文件夹"
fi

echo "✅ 完成: $PWD/$APP"
echo "📦 分发包: $PWD/build/dist/FreedomPlayer-${VERSION}-macOS-arm64.zip"
