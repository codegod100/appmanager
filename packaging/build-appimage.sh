#!/usr/bin/env bash
# Build appmanager-<version>-<arch>.AppImage (plus a .zsync for delta updates).
#
# Usage: packaging/build-appimage.sh [version]
#
# Env:
#   ARCH                 target arch (default: uname -m)
#   UPDATE_INFORMATION   embedded update info; defaults to this repo's GitHub
#                        releases so AppImageUpdate & co. can self-update.
#   GITHUB_REPOSITORY    owner/repo used for the default update info
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD
APP=appmanager
APP_ID=dev.appmanager.AppManager
ARCH=${ARCH:-$(uname -m)}
VERSION=${1:-$(sed -n 's/^version *= *"\(.*\)"/\1/p' "$APP.nimble")}
REPO=${GITHUB_REPOSITORY:-codegod100/appmanager}
BUILD=$ROOT/build/appimage
TOOLS=$BUILD/tools
APPDIR=$BUILD/AppDir

export UPDATE_INFORMATION=${UPDATE_INFORMATION:-"gh-releases-zsync|${REPO%%/*}|${REPO##*/}|release|$APP-*-$ARCH.AppImage.zsync"}
export LDAI_UPDATE_INFORMATION=$UPDATE_INFORMATION
export LDAI_OUTPUT=$APP-$VERSION-$ARCH.AppImage
export OUTPUT=$LDAI_OUTPUT
export LINUXDEPLOY_OUTPUT_VERSION=$VERSION
export DEPLOY_GTK_VERSION=4
# linuxdeploy is itself an AppImage; don't require FUSE in containers/CI.
export APPIMAGE_EXTRACT_AND_RUN=1

rm -rf "$APPDIR" && mkdir -p "$TOOLS"

fetch() { # url dest
  [ -x "$2" ] || { curl -fsSL -o "$2" "$1" && chmod +x "$2"; }
}
fetch "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-$ARCH.AppImage" "$TOOLS/linuxdeploy"
fetch "https://github.com/linuxdeploy/linuxdeploy-plugin-appimage/releases/download/continuous/linuxdeploy-plugin-appimage-$ARCH.AppImage" "$TOOLS/linuxdeploy-plugin-appimage"
fetch "https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh" "$TOOLS/linuxdeploy-plugin-gtk.sh"
export PATH=$TOOLS:$PATH

if [ ! -x "$APP" ] || [ -n "${REBUILD:-}" ]; then
  nimble build -y -d:release --opt:speed
fi

mkdir -p "$APPDIR/usr/share/icons/hicolor/scalable/apps"
cp data/icons/hicolor/scalable/apps/$APP_ID.svg "$APPDIR/usr/share/icons/hicolor/scalable/apps/"

cd "$BUILD"
rm -f "$LDAI_OUTPUT" "$LDAI_OUTPUT.zsync"

# linuxdeploy-plugin-gtk's own AppRun hook (apprun-hooks/linuxdeploy-plugin-gtk.sh)
# forces GTK_THEME=Adwaita:<light|dark> based on a 1s D-Bus portal probe that
# falls back to GNOME's gsettings on failure. That pinned theme overrides
# GTK4's own native portal-based dark-mode detection, which is what makes the
# source build follow the desktop color scheme. Hooks run in filename-sort
# order, so this one (sorting after "linuxdeploy-plugin-gtk.sh") undoes the
# override and lets GTK4 detect the color scheme itself again.
mkdir -p "$APPDIR/apprun-hooks"
cat > "$APPDIR/apprun-hooks/zz-follow-system-theme.sh" <<'EOF'
unset GTK_THEME
EOF

linuxdeploy \
  --appdir "$APPDIR" \
  --executable "$ROOT/$APP" \
  --desktop-file "$ROOT/data/$APP_ID.desktop" \
  --icon-file "$ROOT/data/icons/hicolor/256x256/apps/$APP_ID.png" \
  --plugin gtk \
  --output appimage

mkdir -p "$ROOT/dist"
mv -f "$LDAI_OUTPUT" "$LDAI_OUTPUT.zsync" "$ROOT/dist/"
echo "Built dist/$LDAI_OUTPUT (update info: $UPDATE_INFORMATION)"
