#!/usr/bin/env bash
# Build appmanager-<version>-<arch>.AppImage (plus a .zsync for delta updates)
# from the Flutter Linux bundle.
#
# Usage: packaging/build-appimage.sh [version]
#
# Env:
#   ARCH                 target arch (default: uname -m)
#   UPDATE_INFORMATION   embedded update info; defaults to this repo's GitHub
#                        releases so AppImageUpdate & co. can self-update.
#   GITHUB_REPOSITORY    owner/repo used for the default update info
#   REBUILD              set to rebuild the Flutter bundle even if one exists
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
APP=appmanager
APP_ID=dev.appmanager.AppManager
ARCH=${ARCH:-$(uname -m)}
VERSION=${1:-$(sed -n 's/^version: *\([^+]*\).*/\1/p' pubspec.yaml)}
REPO=${GITHUB_REPOSITORY:-codegod100/appmanager}
BUILD=$ROOT/build/appimage
TOOLS=$BUILD/tools
APPDIR=$BUILD/AppDir
case "$ARCH" in
  x86_64) FLUTTER_ARCH=x64 ;;
  aarch64) FLUTTER_ARCH=arm64 ;;
  *) echo "unsupported arch $ARCH" >&2; exit 1 ;;
esac
BUNDLE=$ROOT/build/linux/$FLUTTER_ARCH/release/bundle
OUTPUT=$APP-$VERSION-$ARCH.AppImage
UPDATE_INFORMATION=${UPDATE_INFORMATION:-"gh-releases-zsync|${REPO%%/*}|${REPO##*/}|release|$APP-*-$ARCH.AppImage.zsync"}
# appimagetool is itself an AppImage; don't require FUSE in containers/CI.
export APPIMAGE_EXTRACT_AND_RUN=1

mkdir -p "$TOOLS"
if [ ! -x "$TOOLS/appimagetool" ]; then
  curl -fsSL -o "$TOOLS/appimagetool" \
    "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$ARCH.AppImage"
  chmod +x "$TOOLS/appimagetool"
fi

if [ ! -x "$BUNDLE/$APP" ] || [ -n "${REBUILD:-}" ]; then
  flutter build linux --release
fi

# The Flutter bundle (binary, lib/, data/) goes into usr/bin as is: the
# binary finds its libraries through its $ORIGIN/lib RPATH. GTK 3 comes from
# the system, as it does for other Flutter apps.
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/share/applications" \
  "$APPDIR/usr/share/icons/hicolor/scalable/apps" "$APPDIR/usr/share/icons/hicolor/256x256/apps"
cp -a "$BUNDLE/." "$APPDIR/usr/bin/"
cp "data/$APP_ID.desktop" "$APPDIR/usr/share/applications/"
cp "data/$APP_ID.desktop" "$APPDIR/"
cp "data/icons/hicolor/scalable/apps/$APP_ID.svg" "$APPDIR/usr/share/icons/hicolor/scalable/apps/"
cp "data/icons/hicolor/256x256/apps/$APP_ID.png" "$APPDIR/usr/share/icons/hicolor/256x256/apps/"
cp "data/icons/hicolor/256x256/apps/$APP_ID.png" "$APPDIR/$APP_ID.png"
ln -sf "$APP_ID.png" "$APPDIR/.DirIcon"
cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
HERE=$(dirname "$(readlink -f "$0")")
# Lets a running appmanager find its own icon when it isn't installed.
export XDG_DATA_DIRS="$HERE/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
exec "$HERE/usr/bin/appmanager" "$@"
EOF
chmod +x "$APPDIR/AppRun"

cd "$BUILD"
rm -f "$OUTPUT" "$OUTPUT.zsync"
# -u embeds the update information and, with zsyncmake installed, writes
# the matching .zsync file.
ARCH=$ARCH "$TOOLS/appimagetool" --no-appstream -u "$UPDATE_INFORMATION" "$APPDIR" "$OUTPUT"

mkdir -p "$ROOT/dist"
mv -f "$OUTPUT" "$ROOT/dist/"
[ -f "$OUTPUT.zsync" ] && mv -f "$OUTPUT.zsync" "$ROOT/dist/"
echo "Built dist/$OUTPUT (update info: $UPDATE_INFORMATION)"
