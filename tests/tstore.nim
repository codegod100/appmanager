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

  test "integrates an AppImage into the menu and removes it again":
    # A stand-in AppImage whose runtime supports --appimage-extract.
    let app = home / "Applications" / "Foo-1.0.AppImage"
    createDir(app.parentDir)
    writeFile(app, """#!/bin/sh
[ "$1" = --appimage-extract ] || exit 1
mkdir -p squashfs-root
case "$2" in
  '*.desktop') printf '[Desktop Entry]\nType=Application\nName=Foo\nExec=AppRun %%F\nIcon=foo\n' > squashfs-root/foo.desktop ;;
  .DirIcon) ln -sf foo.png squashfs-root/.DirIcon ;;
  foo.png) printf '\211PNGdata' > squashfs-root/foo.png ;;
esac
""")
    let entry = integrate(app)
    check entry == desktopEntryFor(app)
    check isIntegrated(app)
    check entry.startsWith(home / ".local/share/applications/appmanager-foo-1-0-")
    let content = readFile(entry)
    check "Name=Foo" in content
    check "Exec=" & app & " %F" in content
    let icon = iconsDir() / desktopId(app) & ".png"
    check "Icon=" & icon in content
    check readFile(icon) == "\x89PNGdata"
    check unintegrate(app)
    check not isIntegrated(app)
    check not fileExists(icon)
    check not unintegrate(app)

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
    saveConfig(cfg)
    let loaded = loadConfig()
    check loaded.installFor("/x/A.AppImage").assetId == 1234567890123
    check loaded.installFor("/x/A.AppImage").source == "o/r"
    check loaded.installFor("/nope").tag == ""
