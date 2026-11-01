#!/bin/bash
# make_deb_linux.sh — builds a rootful Opaline .deb on Ubuntu/Linux with Theos.
#
# What it does
#   1. Compiles all Swift sources (Opaline/**/*.swift) with Theos' Swift
#      toolchain against the iPhoneOS SDK.
#   2. Takes everything that is NOT code (Assets.car, icons, strings, launch
#      storyboard, Swift back-deploy dylibs, the OpenIn share extension) from
#      an existing official Opaline .deb, because Assets.car and the storyboard
#      can only be produced by Xcode tools (actool/ibtool).
#   3. Swaps in the new binary, allows http loads in Info.plist, signs with
#      ldid and repacks a .deb.
#
# Usage:
#   ./make_deb_linux.sh /path/to/Opaline_1.12.0_iphoneos-arm.deb
#
# Env overrides (all optional):
#   THEOS             Theos checkout            (default: ~/theos or $THEOS)
#   SDK               iPhoneOS SDK directory    (default: newest in $THEOS/sdks)
#   SWIFTC            swiftc to use             (default: Theos toolchain, then PATH)
#   LDID              ldid binary               (default: Theos toolchain, then PATH)
#   DEPLOY_TARGET     minimum iOS               (default: 12.2)
#   DEB_VERSION       package version           (default: <original>-dl1)
#   PREBUILT_BINARY   skip compiling, use this arm64 Mach-O instead

set -euo pipefail

ORIG_DEB="${1:-}"
[ -f "$ORIG_DEB" ] || { echo "Usage: $0 <original Opaline .deb>"; exit 1; }
ORIG_DEB=$(readlink -f "$ORIG_DEB")

ROOT=$(cd "$(dirname "$0")" && pwd)
THEOS="${THEOS:-$HOME/theos}"
TC="$THEOS/toolchain/linux/iphone/bin"
SWIFTC="${SWIFTC:-$( [ -x "$TC/swiftc" ] && echo "$TC/swiftc" || command -v swiftc || true )}"  # Theos puts swiftc in the iphone toolchain
LDID="${LDID:-$( [ -x "$TC/ldid" ] && echo "$TC/ldid" || command -v ldid || true )}"
SDK="${SDK:-$(ls -d "$THEOS"/sdks/iPhoneOS*.sdk 2>/dev/null | sort -V | tail -1 || true)}"
# The Linux Swift toolchain (kabiroberai/swift-toolchain-linux) has no
# swift-5.0 back-deploy libs, so it only supports iOS 12.2+.
DEPLOY_TARGET="${DEPLOY_TARGET:-12.2}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PKG="$WORK/pkg"
dpkg-deb -R "$ORIG_DEB" "$PKG"
APP="$PKG/Applications/Opaline.app"
[ -d "$APP" ] || { echo "❌ $ORIG_DEB has no Applications/Opaline.app"; exit 1; }

# ── 1. Compile ──────────────────────────────────────────────────────────────
if [ -n "${PREBUILT_BINARY:-}" ]; then
  echo "▶ Using prebuilt binary $PREBUILT_BINARY"
  cp "$PREBUILT_BINARY" "$WORK/Opaline"
else
  [ -n "$SWIFTC" ] || { echo "❌ swiftc not found. Install Theos' Swift toolchain (see README of kabiroberai/swift-toolchain-linux)."; exit 1; }
  [ -d "$SDK" ] || { echo "❌ iPhoneOS SDK not found in $THEOS/sdks (set SDK=...)."; exit 1; }
  echo "▶ Compiling with $SWIFTC"
  echo "  SDK: $SDK   target: arm64-apple-ios$DEPLOY_TARGET"
  find "$ROOT/Opaline" -name '*.swift' | sort > "$WORK/sources.txt"
  echo "  $(wc -l < "$WORK/sources.txt") Swift files"
  "$SWIFTC" \
    -target "arm64-apple-ios$DEPLOY_TARGET" \
    -sdk "$SDK" \
    -module-name Opaline \
    -swift-version 5 \
    -O -whole-module-optimization \
    -parse-as-library \
    -Xlinker -rpath -Xlinker @executable_path/Frameworks \
    -o "$WORK/Opaline" \
    @"$WORK/sources.txt"
fi

# ── 2. Assemble the bundle ──────────────────────────────────────────────────
cp "$WORK/Opaline" "$APP/Opaline"
chmod 755 "$APP/Opaline"

# Allow plain-http media links (the web-download screen).
python3 - "$APP/Info.plist" <<'EOF'
import plistlib, sys
path = sys.argv[1]
with open(path, "rb") as f:
    data = f.read()
fmt = plistlib.FMT_BINARY if data[:6] == b"bplist" else plistlib.FMT_XML
plist = plistlib.loads(data)
ats = plist.setdefault("NSAppTransportSecurity", {})
ats["NSAllowsArbitraryLoads"] = True
with open(path, "wb") as f:
    plistlib.dump(plist, f, fmt=fmt)
EOF

# The old seal no longer matches; ldid re-seals the binary below.
rm -rf "$APP/_CodeSignature"

# ── 3. Sign (same fixed application-identifier as official builds, so the
#       keychain items of an already installed Opaline keep working) ───────
ENT="$WORK/ent.plist"
cat > "$ENT" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>4RAT6786W6.com.verback.YTLite</string>
	<key>com.apple.developer.team-identifier</key>
	<string>4RAT6786W6</string>
	<key>get-task-allow</key>
	<true/>
</dict>
</plist>
EOF
if [ -n "$LDID" ]; then
  "$LDID" -S"$ENT" "$APP/Opaline"
  echo "▶ Signed with ldid"
else
  echo "⚠ ldid not found — binary left unsigned (install ldid, or sign on the device with 'ldid -S')"
fi

# ── 4. Control file + repack ────────────────────────────────────────────────
ORIG_VERSION=$(sed -n 's/^Version: //p' "$PKG/DEBIAN/control")
VERSION="${DEB_VERSION:-$ORIG_VERSION-dl1}"
sed -i \
  -e "s/^Version: .*/Version: $VERSION/" \
  -e "s/^Name: .*/Name: Opaline (Downloader)/" \
  -e "s/^Installed-Size: .*/Installed-Size: $(du -sk "$PKG/Applications" | cut -f1)/" \
  "$PKG/DEBIAN/control"
sed -i 's/^ SponsorBlock, / Adds download from any link and M4A audio export. SponsorBlock, /' \
  "$PKG/DEBIAN/control"
chmod 755 "$PKG/DEBIAN/postinst" "$PKG/DEBIAN/postrm"

OUT="$ROOT/Opaline-Downloader_${VERSION}_iphoneos-arm.deb"
rm -f "$OUT"
dpkg-deb --root-owner-group -Zgzip -b "$PKG" "$OUT"
echo "✅ $OUT ($(du -sh "$OUT" | cut -f1))"
