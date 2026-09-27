import std/[unittest, os, osproc, strutils, tables, tempfiles]
import appmanager/core

proc fakeAppImage(path: string) =
  ## Minimal file with the AppImage type-2 ELF magic.
  createDir(path.parentDir)
  var data = "\x7FELF\x02\x01\x01\x00AI\x02"
  data.add(repeat('\0', 32))
  writeFile(path, data)

suite "core":
  var home: string
  setup:
    home = createTempDir("appmanager", "home")
    putEnv("HOME", home)
    putEnv("XDG_CONFIG_HOME", "")  # empty must behave like unset
    delEnv("XDG_DATA_HOME")
  teardown:
    removeDir(home)

  test "suggestAlias strips versions and architectures":
    check suggestAlias("Krita-5.2.2-x86_64.appimage") == "krita"
    check suggestAlias("LM-Studio-0.3.1.AppImage") == "lm-studio"
    check suggestAlias("nvim.appimage") == "nvim"
    check suggestAlias("Obsidian-v1.5.3.AppImage") == "obsidian"
    check suggestAlias("1234.AppImage") == ""

  test "isValidAlias":
    check isValidAlias("code")
    check isValidAlias("my-app_2.0+")
    check not isValidAlias("")
    check not isValidAlias("-rf")
    check not isValidAlias("a/b")
    check not isValidAlias("has space")

  test "finds AppImages by extension and by magic":
    fakeAppImage(home / "Applications" / "Foo-1.0.AppImage")
    fakeAppImage(home / "Applications" / "nested" / "bar")
    writeFile(home / "Applications" / "notes.txt", "hi")
    let apps = findAppImages(defaultConfig())
    check apps.len == 2
    check apps[0].name == "bar"
    check apps[1].name == "Foo-1.0"

  test "setAlias rejects duplicates and replaces old alias":
    var cfg = defaultConfig()
    cfg.setAlias("/a.AppImage", "a")
    expect AliasError: cfg.setAlias("/b.AppImage", "a")
    expect AliasError: cfg.setAlias("/b.AppImage", "bad name")
    cfg.setAlias("/a.AppImage", "aa")
    check cfg.aliases.len == 1
    check cfg.aliasFor("/a.AppImage") == "aa"
    cfg.setAlias("/a.AppImage", "")
    check cfg.aliases.len == 0

  test "config round-trips":
    var cfg = defaultConfig()
    cfg.setAlias("/x/y.AppImage", "y")
    saveConfig(cfg)
    let loaded = loadConfig()
    check loaded.aliases["y"] == "/x/y.AppImage"
    check loaded.binDir == cfg.binDir
    check loaded.scanDirs == cfg.scanDirs
    check fileExists(home / ".config" / "appmanager" / "config.json")

  test "apply writes runnable shims and PATH snippet":
    let target = home / "Applications" / "Echo Tool.AppImage"
    createDir(target.parentDir)
    writeFile(target, "#!/bin/sh\necho \"hello $1\"\n") # not yet executable
    writeFile(home / ".bashrc", "alias ll='ls -l'")
    var cfg = defaultConfig()
    cfg.setAlias(target, "echotool")
    discard apply(cfg)

    let shim = cfg.binDir / "echotool"
    check isManagedShim(shim)
    check fpUserExec in getFilePermissions(target)
    check execProcess(shim, args = ["world"], options = {}).strip == "hello world"

    let bashrc = readFile(home / ".bashrc")
    check bashrc.startsWith("alias ll='ls -l'\n")
    check bashrc.count(PathBlockStart) == 1
    check fileExists(home / ".profile")

    # Sourcing the snippet puts the bin dir on PATH, and applying again
    # doesn't duplicate it.
    discard apply(cfg)
    check readFile(home / ".bashrc").count(PathBlockStart) == 1
    let path = execProcess("/bin/sh", args = ["-c", ". \"$HOME/.profile\"; command -v echotool"],
                           options = {}).strip
    check path == shim

  test "removing an alias removes only managed shims":
    let target = home / "t.AppImage"
    writeFile(target, "#!/bin/sh\n")
    var cfg = defaultConfig()
    cfg.setAlias(target, "t")
    discard apply(cfg)
    writeFile(cfg.binDir / "foreign", "#!/bin/sh\n")
    cfg.setAlias(target, "")
    discard apply(cfg)
    check not fileExists(cfg.binDir / "t")
    check fileExists(cfg.binDir / "foreign")

  test "setBinDir moves shims and updates PATH snippet":
    let target = home / "t.AppImage"
    writeFile(target, "#!/bin/sh\n")
    writeFile(home / ".bashrc", "")
    var cfg = defaultConfig()
    cfg.setAlias(target, "t")
    discard apply(cfg)
    let oldDir = cfg.binDir
    writeFile(oldDir / "foreign", "#!/bin/sh\n")
    let newDir = home / "mybin"
    cfg.setBinDir(newDir)
    discard apply(cfg)
    check cfg.binDir == newDir
    check isManagedShim(newDir / "t")
    check not fileExists(oldDir / "t")
    check fileExists(oldDir / "foreign")
    check loadConfig().binDir == newDir
    let bashrc = readFile(home / ".bashrc")
    check bashrc.count(PathBlockStart) == 1
    check newDir in bashrc and oldDir notin bashrc

  test "does not overwrite files it did not create":
    let target = home / "t.AppImage"
    writeFile(target, "#!/bin/sh\n")
    var cfg = defaultConfig()
    createDir(cfg.binDir)
    writeFile(cfg.binDir / "t", "mine")
    cfg.setAlias(target, "t")
    let notes = apply(cfg)
    check readFile(cfg.binDir / "t") == "mine"
    check notes.len > 0 and "Skipped" in notes[0]

  test "replaceBlock updates an existing block in place":
    let old = "a\n" & posixPathBlock("/old") & "b\n"
    let updated = replaceBlock(old, posixPathBlock("/new"))
    check updated == "a\n" & posixPathBlock("/new") & "b\n"
