#!/bin/zsh
# Build, sign, notarize and package Tiler for a GitHub release: a zip (used by the
# Homebrew cask) and a drag-to-Applications disk image, plus SHA256SUMS and the
# Homebrew cask for that version (homebrew-tap/Casks/tiler.rb).
#
# Required environment:
#   TILER_SIGN_IDENTITY  Developer ID Application identity, by SHA-1 (two identities share
#                        the name): 2C7D6068C232BA74073D56085DDBB04E5F14DF30.
#                        List them: security find-identity -v -p codesigning
#   NOTARY_PROFILE       notarytool keychain profile (tiler-notary). Every public release is
#                        notarized; see docs/design/release-runbook.md, step 0.3.
#
# Usage: TILER_SIGN_IDENTITY=… NOTARY_PROFILE=tiler-notary scripts/package.sh
# VERSION and BUILD come from scripts/build-app.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' scripts/build-app.sh)"
BUILD="$(sed -n 's/^BUILD="\(.*\)"$/\1/p' scripts/build-app.sh)"
APP="$ROOT/build/Tiler.app"
DIST="$ROOT/dist"
ZIP="$DIST/Tiler-$VERSION.zip"
DMG="$DIST/Tiler-$VERSION.dmg"
SUMS="$DIST/SHA256SUMS"
CASK="$ROOT/homebrew-tap/Casks/tiler.rb"

[[ -n "$VERSION" && -n "$BUILD" ]] || { echo "error: could not read VERSION / BUILD from scripts/build-app.sh" >&2; exit 1; }
[[ -n "${TILER_SIGN_IDENTITY:-}" ]] || { echo "error: TILER_SIGN_IDENTITY is not set (Developer ID Application SHA-1)" >&2; exit 1; }
[[ -n "${NOTARY_PROFILE:-}" ]] || { echo "error: NOTARY_PROFILE is not set (a release must be notarized)" >&2; exit 1; }

echo "=== Packaging Tiler $VERSION (build $BUILD) ==="

# 1. Tests: a release is never packaged from a red tree.
swift test

# 2. Build + sign.
scripts/build-app.sh

# 3. The signature must be Developer ID with the hardened runtime.
codesign --verify --deep --strict --verbose=2 "$APP"
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
[[ "$SIGNATURE" == *"Authority=Developer ID Application"* ]] \
  || { echo "error: not signed with a Developer ID Application identity" >&2; exit 1; }
[[ "$SIGNATURE" =~ "flags=0x[0-9a-f]+\(runtime\)" ]] \
  || { echo "error: hardened runtime is not enabled" >&2; exit 1; }

# 4. Zip, notarize, staple, zip again (ditto is the format Apple recommends).
mkdir -p "$DIST"
make_zip() { rm -f "$ZIP"; ditto -c -k --norsrc --keepParent "$APP" "$ZIP"; }
make_zip
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
make_zip
spctl --assess --type execute --verbose=2 "$APP"

# 5. Disk image with the install notes, signed, notarized and stapled.
STAGE="$ROOT/build/dmg-root"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Tiler.app"
ln -s /Applications "$STAGE/Applications"
cp packaging/macos/INSTALL.txt "$STAGE/INSTALL.txt"
hdiutil create -volname "Tiler $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$TILER_SIGN_IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

# 6. Checksums.
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > "$SUMS")

# 7. Homebrew cask for this version (copied into biks2013-tools/homebrew-tiler on release).
mkdir -p "$(dirname "$CASK")"
cat > "$CASK" <<CASKEOF
cask "tiler" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/biks2013-tools/tiler/releases/download/v#{version}/Tiler-#{version}.zip"
  name "Tiler"
  desc "Menu bar tiling window manager for one desktop at a time"
  homepage "https://github.com/biks2013-tools/tiler"

  depends_on macos: :sonoma

  app "Tiler.app"

  postflight_steps do
    run "/usr/bin/osascript",
        args: [
          "-e",
          'display notification "Open Tiler and allow Accessibility when asked." with title "Tiler installed"',
        ]
  end

  uninstall quit: "com.giorgosmarinos.tiler"

  zap trash: "~/Library/Application Support/Tiler"

  caveats <<~EOS
    First launch: open Tiler (menu bar icon, no Dock icon) and allow Accessibility:
      System Settings > Privacy & Security > Accessibility > enable Tiler
    It is the only permission Tiler needs.

    Tile a desktop: menu bar icon > Tile This Desktop, or Ctrl+Cmd+P.
    Only that desktop on that display is tiled; everything else is left alone.

    Show every shortcut: Ctrl+Cmd+/   Settings: menu bar icon > Settings...
    Move or resize any untiled window with the keyboard: Ctrl+Cmd+M, then arrows
    (Shift resizes, Option = fine, C centre, M fill, Return done).
    Move the focused window to the previous / next desktop: Ctrl+Cmd+, / Ctrl+Cmd+.
    (keep Mission Control "Move left/right a space" shortcuts turned on).
    Focus follows mouse (optional): menu bar icon > Focus Follows Mouse.
    Upgrading: Settings > General > Add Missing Settings (adds new settings only).
    Launch at login: Settings > General.

    Decks: https://biks2013-tools.github.io/tiler/
  EOS
end
CASKEOF

echo ""
echo "=== Package complete ==="
echo "Version:    $VERSION (build $BUILD)"
echo "Zip:        $ZIP"
echo "Zip SHA256: $SHA"
echo "DMG:        $DMG"
echo "Cask:       $CASK"
echo "Next: docs/design/release-runbook.md, steps 5-7 (tag, GitHub release, tap)."
