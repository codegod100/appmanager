import std/[unittest, os, json, strutils, tables, tempfiles]
import appmanager/[core, store]

proc le(v: BiggestInt, size: int): string =
  for i in 0 ..< size: result.add(char((v shr (8 * i)) and 0xFF))

proc fakeElf(sections: openArray[(string, string)]): string =
  ## A minimal 64-bit little-endian ELF with the given sections (plus the
  ## null section and .shstrtab).
  var names = "\0"
  var nameOffs: seq[int]
  for (name, _) in sections:
    nameOffs.add(names.len)
    names.add(name & "\0")
  let shstrName = names.len
  names.add(".shstrtab\0")
  var body = ""
  var offs: seq[int]
  for (_, data) in sections:
    offs.add(64 + body.len)
    body.add(data)
  let strOff = 64 + body.len
  body.add(names)
  let shoff = 64 + body.len
  let shnum = sections.len + 2
  var header = "\x7FELF\x02\x01\x01\x00AI\x02" & repeat('\0', 5)
  header.add(le(2, 2) & le(0x3E, 2) & le(1, 4) & le(0, 8) & le(0, 8) & le(shoff, 8))
  header.add(le(0, 4) & le(64, 2) & le(0, 2) & le(0, 2) & le(64, 2) &
             le(shnum, 2) & le(shnum - 1, 2))
  assert header.len == 64
  proc sh(name, off, size: int): string =
    le(name, 4) & le(1, 4) & le(0, 8) & le(0, 8) & le(off, 8) & le(size, 8) &
      le(0, 4) & le(0, 4) & le(1, 8) & le(0, 8)
  var table = repeat('\0', 64)
  for i, (_, data) in sections:
    table.add(sh(nameOffs[i], offs[i], data.len))
  table.add(sh(shstrName, strOff, names.len))
  header & body & table

proc release(tag: string, assets: openArray[string], pre = false,
             draft = false): JsonNode =
  var list = newJArray()
  for i, name in assets:
    list.add(%*{"id": 100 + i, "name": name, "size": 1000 + i,
                "browser_download_url": "https://github.com/o/r/releases/download/" &
                  tag & "/" & name})
  %*{"tag_name": tag, "prerelease": pre, "draft": draft, "assets": list}

proc writeFakeRuntime(path: string) =
  ## A stand-in AppImage whose runtime supports --appimage-extract. Like
  ## linuxdeploy's, its top-level .desktop is a link into usr/share, and
  ## patterns only match whole paths, so the link comes out on its own.
  createDir(path.parentDir)
  writeFile(path, """#!/bin/sh
[ "$1" = --appimage-extract ] || exit 1
mkdir -p squashfs-root
case "$2" in
  '*.desktop'|foo.desktop) ln -sf usr/share/applications/foo.desktop squashfs-root/foo.desktop ;;
  usr/share/applications/foo.desktop)
    mkdir -p squashfs-root/usr/share/applications
    printf '[Desktop Entry]\nType=Application\nName=Foo\nExec=AppRun %%F\nIcon=foo\n' > squashfs-root/usr/share/applications/foo.desktop ;;
  .DirIcon) ln -sf foo.png squashfs-root/.DirIcon ;;
  foo.png) printf '\211PNG\r\n\032\n\0\0\0\rIHDR\0\0\0\100\0\0\0\100' > squashfs-root/foo.png ;;
esac
""")
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

suite "store":
  var home: string
  setup:
    home = createTempDir("appmanager", "home")
    putEnv("HOME", home)
    delEnv("XDG_DATA_HOME")
    delEnv("XDG_CONFIG_HOME")
  teardown:
    removeDir(home)

  test "normalizeRepo":
    check normalizeRepo("owner/repo") == "owner/repo"
    check normalizeRepo("https://github.com/owner/repo.git") == "owner/repo"
    check normalizeRepo("github.com/owner/repo/releases/latest") == "owner/repo"
    check normalizeRepo("https://gitlab.com/owner/repo") == ""
    check normalizeRepo("krita") == ""
    check normalizeRepo("a b/c") == ""

  test "parses and searches the AppImageHub feed":
    let feed = %*{"items": [
      {"name": "Kdenlive", "description": "Video editor",
       "categories": ["AudioVideo"],
       "links": [{"type": "GitHub", "url": "KDE/kdenlive"}]},
      {"name": "No_Source", "links": []},
      {"name": "Video_Tool", "description": "Converts files",
       "links": [{"type": "GitHub", "url": "someone/videotool"}]},
      {"name": "Editor", "description": "A video thing",
       "links": [{"type": "GitHub", "url": "x/editor"}]}]}
    let apps = parseAppImageHub(feed)
    check apps.len == 3
    check apps[1].name == "Video Tool"
    check apps[0].repo == "KDE/kdenlive"
    let hits = searchCatalog(apps, "video")
    check hits.len == 3
    check hits[0].name == "Video Tool"   # name match beats description match
    check searchCatalog(apps, "video editor").len == 2
    check searchCatalog(apps, "audiovideo")[0].name == "Kdenlive"
    check searchCatalog(apps, "zzz").len == 0

  test "parses the pkgforge-dev app list":
    let md = """
Intro with a [link](https://github.com/pkgforge-dev/sharun) inline.
<!-- APPS_LIST_START -->
| Applications |
| --- |
| [86Box](https://github.com/pkgforge-dev/86box-AppImage-Enhanced) |
| [Android Tools](https://github.com/pkgforge-dev/android-tools-AppImage) |
| [Dupe](https://github.com/pkgforge-dev/86box-AppImage-Enhanced) |
| [Elsewhere](https://gitlab.com/x/y) |
| [Two](https://github.com/a/b) | extra cell |
<!-- APPS_LIST_END -->

| Projects with Anylinux AppImages |
| --- |
| [AM-GUI](https://github.com/Shikakiben/AM-GUI) |
"""
    let apps = parsePkgforge(md)
    check apps.len == 3
    check apps[0].name == "86Box"
    check apps[0].repo == "pkgforge-dev/86box-AppImage-Enhanced"
    check apps[0].source == FromPkgforge
    check apps[1].name == "Android Tools"
    check apps[2].repo == "Shikakiben/AM-GUI"
    check "pkgforge-dev" in apps[0].summary
    check searchCatalog(apps, "android")[0].name == "Android Tools"
    check parseCatalog(FromPkgforge, md).len == 3
    check catalogCachePath(FromPkgforge) != catalogCachePath(FromAppImageHub)
    check FromPkgforge.isCatalog and not FromGitHub.isCatalog

  test "cleans up catalog text":
    check plainText("<p>Audio &amp; video</p>\n<ul>\n  <li>Cut</li></ul>") ==
      "Audio & video Cut"
    check shortLicense("LicenseRef-proprietary=https://x/LICENSE") == "proprietary"
    check shortLicense("MIT") == "MIT"

  test "parses GitHub search results":
    let apps = parseGitHubSearch(%*{"items": [
      {"full_name": "a/b", "name": "b", "description": "d",
       "stargazers_count": 42, "license": {"spdx_id": "MIT"}, "topics": ["appimage"]}]})
    check apps.len == 1
    check apps[0].stars == 42 and apps[0].license == "MIT"
    check "appimage" in githubSearchUrl("my app")
    check "q=my+app+appimage" in githubSearchUrl("my app")

  test "globMatch":
    check globMatch("appmanager-*-x86_64.AppImage.zsync",
                    "appmanager-0.1.5-x86_64.AppImage.zsync")
    check not globMatch("appmanager-*-x86_64.AppImage.zsync",
                        "appmanager-0.1.5-aarch64.AppImage.zsync")
    check globMatch("a?c*", "abcdef")
    check globMatch("*", "")
    check not globMatch("a*b", "acd")

  test "picks the AppImage for this architecture":
    let x64 = @["x86_64", "amd64", "x64", "x86-64"]
    let rel = release("v2", ["App-2.0-aarch64.AppImage", "App-2.0-x86_64.AppImage",
                             "App-2.0-x86_64.AppImage.zsync", "App-2.0.tar.gz"])
    let asset = pickAsset(rel, arch = x64)
    check asset.name == "App-2.0-x86_64.AppImage"
    check asset.tag == "v2"
    check asset.zsyncUrl.endsWith("App-2.0-x86_64.AppImage.zsync")
    check pickAsset(release("v1", ["App.tar.gz"]), arch = x64).name == ""
    # A glob for the .zsync file selects the AppImage next to it.
    check pickAsset(rel, pattern = "App-*-aarch64.AppImage.zsync", arch = x64).name ==
      "App-2.0-aarch64.AppImage"
    # The same flavour as before wins.
    let flavours = release("v3", ["App-3.0-x86_64.AppImage", "App-Qt6-3.0-x86_64.AppImage"])
    check pickAsset(flavours, previous = "App-Qt6-2.0-x86_64.AppImage", arch = x64).name ==
      "App-Qt6-3.0-x86_64.AppImage"
    check pickAsset(flavours, arch = x64).name == "App-3.0-x86_64.AppImage"

  test "prefers stable releases":
    let x64 = @["x86_64"]
    let list = %*[release("nightly", ["A-n.AppImage"], pre = true),
                  release("v3", ["A-3.AppImage"], draft = true),
                  release("v2", ["notes.txt"]),
                  release("v1", ["A-1.AppImage"])]
    check pickRelease(list, arch = x64).tag == "v1"
    check pickRelease(list, tag = "latest-pre", arch = x64).tag == "nightly"
    check pickRelease(%*[release("nightly", ["A-n.AppImage"], pre = true)], arch = x64).tag ==
      "nightly"
    check pickRelease(release("v9", ["A-9.AppImage"]), arch = x64).tag == "v9"

  test "reads embedded update information":
    let info = "gh-releases-zsync|codegod100|appmanager|release|appmanager-*-x86_64.AppImage.zsync"
    let path = home / "a.AppImage"
    writeFile(path, fakeElf([(".text", "code"), (".upd_info", info & repeat('\0', 100)),
                             (".sha256_sig", "sig")]))
    check readUpdateInfo(path) == info
    let src = parseUpdateInfo(readUpdateInfo(path))
    check src.kind == GitHubReleases
    check src.owner == "codegod100" and src.repo == "appmanager"
    check src.tag == "release"
    writeFile(path, fakeElf([(".text", "code")]))
    check readUpdateInfo(path) == ""
    writeFile(path, "not an elf")
    check readUpdateInfo(path) == ""
    check parseUpdateInfo("zsync|https://x/y.zsync").url == "https://x/y.zsync"
    check parseUpdateInfo("pling-v1-zsync|123").kind == NoUpdateSource

  test "update source precedence":
    let embedded = "zsync|https://example.com/a.zsync"
    check updateSourceFor(InstallInfo(), embedded).kind == ZsyncUrl
    let src = updateSourceFor(InstallInfo(source: "https://github.com/o/r"), embedded)
    check src.kind == GitHubReleases and src.owner == "o" and src.repo == "r"
    check updateSourceFor(InstallInfo(), "").kind == NoUpdateSource
    check parseSourceSetting("nonsense").kind == NoUpdateSource

  test "parses zsync headers":
    let z = parseZsync("zsync: 0.6.2\nFilename: App-2.AppImage\nMTime: x\n" &
                       "Length: 12345\nURL: App-2.AppImage\nSHA-1: ABCDEF\n\n\x00\x01binary",
                       "https://example.com/dl/App.zsync?x=1")
    check z.url == "https://example.com/dl/App-2.AppImage"
    check z.sha1 == "abcdef"
    check z.length == 12345
    check resolveUrl("https://h.com/a/b.zsync", "/c") == "https://h.com/c"
    check resolveUrl("https://h.com/a/b.zsync", "https://o/x") == "https://o/x"

  test "desktop entries launch the AppImage":
    check desktopExecArg("/opt/app.AppImage") == "/opt/app.AppImage"
    check desktopExecArg("/home/me/My Apps/a$b.AppImage") ==
      "\"/home/me/My Apps/a\\\\$b.AppImage\""
    check desktopExecArg("/x/100%.AppImage") == "/x/100%%.AppImage"
    let entry = rewriteDesktopEntry(
      "[Desktop Entry]\nName=Foo\nExec=foo %U\nTryExec=foo\nIcon=foo\n\n" &
      "[Desktop Action new]\nExec=\"foo bar\" --new\n",
      "/apps/Foo.AppImage", "/icons/foo.png")
    check "Exec=/apps/Foo.AppImage %U" in entry
    check "Exec=/apps/Foo.AppImage --new" in entry
    check "TryExec" notin entry
    check "Icon=/icons/foo.png" in entry
    check "Icon=foo\n" notin entry
    check entry.count(DesktopMarkerKey) == 1
    check entry.find(DesktopMarkerKey) < entry.find("[Desktop Action new]")
    let generated = rewriteDesktopEntry("", "/apps/Bar-1.0.AppImage", "")
    check "Name=Bar-1.0" in generated
    check "Exec=/apps/Bar-1.0.AppImage" in generated

  test "picks a hicolor folder for icons":
    proc png(w, h: int): string =
      result = "\x89PNG\r\n\x1a\n\0\0\0\rIHDR"
      for v in [w, h]:
        for shift in [24, 16, 8, 0]: result.add(chr((v shr shift) and 0xff))
    check iconSize(png(48, 48)) == 48
    check iconSubdir(png(48, 48)) == "48x48"
    check iconSubdir(png(200, 180)) == "192x192"
    check iconSubdir(png(1024, 1024)) == "512x512"
    check iconSubdir("\x89PNGdata") == "256x256"
    check iconSubdir("<?xml?><svg xmlns='x'/>") == "scalable"
    check iconSubdir("/* XPM */\nstatic char *x[] = {\n\"32 32 2 1\",") == "32x32"

  test "integrates an AppImage into the menu and removes it again":
    # A stand-in AppImage whose runtime supports --appimage-extract.
    let app = home / "Applications" / "Foo-1.0.AppImage"
    writeFakeRuntime(app)
    let entry = integrate(app)
    check entry == desktopEntryFor(app)
    check isIntegrated(app)
    check entry.startsWith(home / ".local/share/applications/appmanager-foo-1-0-")
    let content = readFile(entry)
    check "Name=Foo\n" in content
    check "Exec=" & app & " %F" in content
    let icon = home / ".local/share/icons/hicolor/64x64/apps" / desktopId(app) & ".png"
    check "Icon=" & desktopId(app) & "\n" in content
    check readFile(icon).startsWith("\x89PNG")
    check unintegrate(app)
    check not isIntegrated(app)
    check not fileExists(icon)
    check not unintegrate(app)

  test "sets the default app for AppImages in mimeapps.list":
    let before = "[Default Applications]\ntext/plain=gedit.desktop;\n" &
      "application/vnd.appimage=it.mijorus.gearlever.desktop;\n\n" &
      "[Added Associations]\napplication/vnd.appimage=it.mijorus.gearlever.desktop;\n"
    let after = setDefaultApp(before, "am.desktop", AppImageMimeTypes)
    check defaultFor(after, "application/vnd.appimage") == "am.desktop"
    check defaultFor(after, "application/x-iso9660-appimage") == "am.desktop"
    check defaultFor(after, "text/plain") == "gedit.desktop"
    check "application/vnd.appimage=am.desktop;it.mijorus.gearlever.desktop;" in after
    check "application/x-iso9660-appimage=am.desktop;" in after
    check after.count("[Default Applications]") == 1
    check after.count("application/vnd.appimage=") == 2
    check setDefaultApp(after, "am.desktop", AppImageMimeTypes) == after
    let fresh = setDefaultApp("", "am.desktop", AppImageMimeTypes)
    check fresh.startsWith("[Default Applications]\n")
    check defaultFor(fresh, "application/vnd.appimage") == "am.desktop"
    check "[Added Associations]\napplication/vnd.appimage=am.desktop;" in fresh

  test "registers itself as the AppImage handler":
    putEnv("XDG_CURRENT_DESKTOP", "GNOME")
    defer: delEnv("XDG_CURRENT_DESKTOP")
    let gnomeList = home / ".config/gnome-mimeapps.list"
    createDir(gnomeList.parentDir)
    writeFile(gnomeList, "[Default Applications]\napplication/vnd.appimage=gearlever.desktop;\n")
    check appImageHandler() == "gearlever.desktop"
    makeAppImageHandler("dev.x.Am", "/opt/My Apps/am.AppImage")
    check appImageHandler() == "dev.x.Am.desktop"
    check defaultFor(readFile(home / ".config/mimeapps.list"),
                     "application/vnd.appimage") == "dev.x.Am.desktop"
    let entry = readFile(home / ".local/share/applications/dev.x.Am.desktop")
    check "Exec=\"/opt/My Apps/am.AppImage\" %F" in entry
    check "MimeType=application/vnd.appimage;application/x-iso9660-appimage;" in entry
    # An entry some other tool installed is left alone.
    writeFile(home / ".local/share/applications/dev.x.Am.desktop", "[Desktop Entry]\nName=Pkg\n")
    makeAppImageHandler("dev.x.Am", "/elsewhere/am")
    check readFile(home / ".local/share/applications/dev.x.Am.desktop") ==
      "[Desktop Entry]\nName=Pkg\n"

  test "relocate moves an AppImage with its alias, source and menu entry":
    let src = home / "Downloads" / "Foo-1.0.AppImage"
    writeFakeRuntime(src)
    var cfg = defaultConfig()
    cfg.setAlias(src, "foo")
    cfg.installs[src] = InstallInfo(source: "o/r", tag: "v1")
    discard integrate(src)
    check needsMove(src)
    check not needsMove(home / "Applications" / "x.AppImage")  # missing
    var notes: seq[string]
    let dest = cfg.relocate(src, defaultInstallDir(), notes)
    check notes.len == 0
    check dest == home / "Applications" / "Foo-1.0.AppImage"
    check fileExists(dest) and not fileExists(src)
    check fpUserExec in getFilePermissions(dest)
    check not needsMove(dest)
    check cfg.aliases["foo"] == dest
    check cfg.installFor(dest).source == "o/r" and src notin cfg.installs
    check not isIntegrated(src) and isIntegrated(dest)
    check ("Exec=" & dest & " %F") in readFile(desktopEntryFor(dest))
    # A symlink into the central folder isn't offered for moving.
    createSymlink(dest, home / "bin-foo.AppImage")
    check not needsMove(home / "bin-foo.AppImage")
    # Never overwrites a file that's already there.
    writeFakeRuntime(src)
    expect OSError:
      discard cfg.relocate(src, defaultInstallDir(), notes)
    check fileExists(src)

  test "forget removes aliases and install records":
    var cfg = defaultConfig()
    cfg.setAlias("/a.AppImage", "a")
    cfg.installs["/a.AppImage"] = InstallInfo(source: "o/r", tag: "v1")
    cfg.forget("/a.AppImage")
    check cfg.aliases.len == 0 and cfg.installs.len == 0

  test "install records round-trip through the config":
    var cfg = defaultConfig()
    cfg.installs["/x/A.AppImage"] = InstallInfo(source: "o/r", tag: "v1",
                                               asset: "A.AppImage", assetId: 1234567890123)
    check cfg.offerMove
    cfg.offerMove = false
    saveConfig(cfg)
    let loaded = loadConfig()
    check not loaded.offerMove
    check loaded.installFor("/x/A.AppImage").assetId == 1234567890123
    check loaded.installFor("/x/A.AppImage").source == "o/r"
    check loaded.installFor("/nope").tag == ""
