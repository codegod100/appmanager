## Core logic for appmanager: discovering AppImages, persisting aliases,
## writing launcher shims and making sure the shim directory is on PATH.
##
## Kept free of any GUI code so it can be unit tested and reused.

import std/[os, strutils, json, tables, algorithm, sets]

const
  ShimMarker* = "# managed-by: appmanager"
  PathBlockStart* = "# >>> appmanager >>>"
  PathBlockEnd* = "# <<< appmanager <<<"
  MaxScanDepth = 2

type
  AppImage* = object
    path*: string   ## Absolute path to the AppImage file
    name*: string   ## File name without the .AppImage extension

  InstallInfo* = object
    ## Where an AppImage's updates come from and which build is installed.
    source*: string      ## "owner/repo" on GitHub or a .zsync URL; "" means
                         ## use the update information embedded in the file
    tag*: string         ## Release tag of the installed build
    asset*: string       ## Release asset name of the installed build
    assetId*: BiggestInt ## GitHub asset id of the installed build (0 = unknown)

  Config* = object
    scanDirs*: seq[string]              ## Directories searched for AppImages
    binDir*: string                     ## Where alias shims are written
    aliases*: OrderedTable[string, string] ## alias -> AppImage path
    installs*: OrderedTable[string, InstallInfo] ## AppImage path -> install info

  AliasError* = object of CatchableError

# ---------------------------------------------------------------------------
# Paths & config

proc xdgDir(envVar, fallback: string): string =
  ## Like getConfigDir(), but also treats an empty variable as unset, as the
  ## XDG spec requires.
  let dir = getEnv(envVar)
  if dir.len > 0: dir else: getHomeDir() / fallback

proc configDir*(): string =
  xdgDir("XDG_CONFIG_HOME", ".config") / "appmanager"

proc configPath*(): string =
  configDir() / "config.json"

proc defaultBinDir*(): string =
  xdgDir("XDG_DATA_HOME", ".local/share") / "appmanager" / "bin"

proc defaultScanDirs*(): seq[string] =
  let home = getHomeDir()
  @[
    home / "Applications",
    home / "AppImages",
    home / ".local" / "bin",
    home / "bin",
    home / "Downloads",
    "/opt",
  ]

proc defaultConfig*(): Config =
  Config(scanDirs: defaultScanDirs(), binDir: defaultBinDir(),
         aliases: initOrderedTable[string, string](),
         installs: initOrderedTable[string, InstallInfo]())

proc toJson*(cfg: Config): JsonNode =
  var aliases = newJObject()
  for alias, target in cfg.aliases:
    aliases[alias] = %target
  var installs = newJObject()
  for path, info in cfg.installs:
    installs[path] = %*{"source": info.source, "tag": info.tag,
                        "asset": info.asset, "assetId": info.assetId}
  %*{"scanDirs": cfg.scanDirs, "binDir": cfg.binDir, "aliases": aliases,
     "installs": installs}

proc fromJson*(node: JsonNode): Config =
  result = defaultConfig()
  if node.kind != JObject: return
  if node.hasKey("scanDirs") and node["scanDirs"].kind == JArray:
    result.scanDirs = @[]
    for dir in node["scanDirs"]:
      if dir.kind == JString: result.scanDirs.add(dir.getStr)
  if node.hasKey("binDir") and node["binDir"].kind == JString and
      node["binDir"].getStr.len > 0:
    result.binDir = node["binDir"].getStr
  if node.hasKey("aliases") and node["aliases"].kind == JObject:
    for alias, target in node["aliases"]:
      if target.kind == JString:
        result.aliases[alias] = target.getStr
  if node.hasKey("installs") and node["installs"].kind == JObject:
    for path, info in node["installs"]:
      if info.kind != JObject: continue
      result.installs[path] = InstallInfo(
        source: info{"source"}.getStr, tag: info{"tag"}.getStr,
        asset: info{"asset"}.getStr, assetId: info{"assetId"}.getBiggestInt)

proc loadConfig*(path = configPath()): Config =
  if not fileExists(path):
    return defaultConfig()
  try:
    fromJson(parseFile(path))
  except JsonParsingError, IOError, ValueError:
    defaultConfig()

proc saveConfig*(cfg: Config, path = configPath()) =
  createDir(path.parentDir)
  let tmp = path & ".tmp"
  writeFile(tmp, pretty(cfg.toJson) & "\n")
  moveFile(tmp, path)

# ---------------------------------------------------------------------------
# Discovery

proc hasAppImageMagic*(path: string): bool =
  ## AppImages are ELF files with "AI" followed by the type byte (1 or 2)
  ## at offset 8.
  var f: File
  if not open(f, path, fmRead): return false
  defer: close(f)
  var buf: array[11, uint8]
  if readBytes(f, buf, 0, buf.len) != buf.len: return false
  buf[0] == 0x7F and buf[1] == uint8('E') and buf[2] == uint8('L') and
    buf[3] == uint8('F') and buf[8] == uint8('A') and buf[9] == uint8('I') and
    buf[10] in {1'u8, 2'u8}

proc hasAppImageExt(path: string): bool =
  path.toLowerAscii.endsWith(".appimage")

proc stripAppImageExt*(filename: string): string =
  if filename.toLowerAscii.endsWith(".appimage"):
    filename[0 ..< filename.len - ".appimage".len]
  else:
    filename

proc isAppImage*(path: string): bool =
  if not fileExists(path): return false
  hasAppImageExt(path) or hasAppImageMagic(path)

proc scan(dir: string, depth: int, skip: HashSet[string],
          seen: var HashSet[string], found: var seq[AppImage]) =
  if depth > MaxScanDepth or not dirExists(dir): return
  try:
    for kind, path in walkDir(dir):
      case kind
      of pcFile, pcLinkToFile:
        if not isAppImage(path): continue
        let real = try: expandFilename(path) except OSError: path
        if real in seen: continue
        seen.incl(real)
        found.add(AppImage(path: path,
                           name: stripAppImageExt(path.extractFilename)))
      of pcDir:
        let name = path.extractFilename
        if name.startsWith(".") or path in skip: continue
        scan(path, depth + 1, skip, seen, found)
      of pcLinkToDir:
        discard
  except OSError:
    discard

proc findAppImages*(cfg: Config): seq[AppImage] =
  ## Finds AppImages in the configured scan directories (searching up to two
  ## levels deep), plus any AppImage already referenced by an alias.
  var seen = initHashSet[string]()
  let skip = [cfg.binDir].toHashSet
  for dir in cfg.scanDirs:
    scan(expandTilde(dir), 0, skip, seen, result)
  for target in cfg.aliases.values:
    let real = try: expandFilename(target) except OSError: target
    if real notin seen:
      seen.incl(real)
      result.add(AppImage(path: target,
                          name: stripAppImageExt(target.extractFilename)))
  result.sort(proc (a, b: AppImage): int =
    cmp(a.name.toLowerAscii, b.name.toLowerAscii))

# ---------------------------------------------------------------------------
# Aliases

proc installFor*(cfg: Config, path: string): InstallInfo =
  cfg.installs.getOrDefault(path)

proc isValidAlias*(alias: string): bool =
  if alias.len == 0 or alias.len > 64: return false
  if alias[0] notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}: return false
  for c in alias:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.', '+'}:
      return false
  alias notin [".", ".."]

proc suggestAlias*(filename: string): string =
  ## Turns e.g. "Krita-5.2.2-x86_64.AppImage" into "krita" and
  ## "LM-Studio-0.3.1.AppImage" into "lm-studio".
  const archTokens = ["x86", "x86_64", "amd64", "aarch64", "arm64", "armhf",
                      "i386", "i686", "linux", "appimage"]
  var parts: seq[string]
  for token in stripAppImageExt(filename).split({'-', '_', ' ', '.'}):
    if token.len == 0: continue
    let lower = token.toLowerAscii
    if lower[0] in Digits or (lower[0] == 'v' and lower.len > 1 and
        lower[1] in Digits) or lower in archTokens:
      break
    parts.add(lower)
  result = parts.join("-")
  if not isValidAlias(result):
    result = ""

proc aliasFor*(cfg: Config, target: string): string =
  for alias, path in cfg.aliases:
    if path == target: return alias

proc shadowedCommand*(cfg: Config, alias: string): string =
  ## Returns the path of an existing command (outside our bin dir) that has
  ## the same name as `alias`, or "" if none.
  for dir in getEnv("PATH").split(PathSep):
    if dir.len == 0 or dir.normalizedPath == cfg.binDir.normalizedPath:
      continue
    let candidate = dir / alias
    if fileExists(candidate) and fpUserExec in getFilePermissions(candidate):
      return candidate

proc setAlias*(cfg: var Config, target, alias: string) =
  ## Assigns `alias` to the AppImage at `target`, replacing any previous alias
  ## of that AppImage. An empty alias removes it.
  let alias = alias.strip
  if alias.len > 0:
    if not isValidAlias(alias):
      raise newException(AliasError, "Invalid alias '" & alias &
        "': use letters, digits, '-', '_', '.' or '+'")
    if cfg.aliases.hasKey(alias) and cfg.aliases[alias] != target:
      raise newException(AliasError, "Alias '" & alias &
        "' is already used by " & cfg.aliases[alias].extractFilename)
  let old = cfg.aliasFor(target)
  if old.len > 0:
    cfg.aliases.del(old)
  if alias.len > 0:
    cfg.aliases[alias] = target

# ---------------------------------------------------------------------------
# Shims

proc shimContent*(target: string): string =
  "#!/bin/sh\n" & ShimMarker & "\nexec " & quoteShell(target) & " \"$@\"\n"

proc isManagedShim*(path: string): bool =
  if not fileExists(path) or symlinkExists(path): return false
  try:
    var f = open(path)
    defer: close(f)
    var line: string
    for _ in 0 ..< 3:
      if not f.readLine(line): return false
      if line == ShimMarker: return true
  except IOError:
    discard
  false

proc syncShims*(cfg: Config): seq[string] =
  ## Writes one launcher script per alias into `cfg.binDir` and removes
  ## launchers for aliases that no longer exist. Files in the bin dir not
  ## created by appmanager are never touched. Returns warnings.
  createDir(cfg.binDir)
  for kind, path in walkDir(cfg.binDir):
    let name = path.extractFilename
    if not cfg.aliases.hasKey(name) and isManagedShim(path):
      removeFile(path)
  for alias, target in cfg.aliases:
    let shim = cfg.binDir / alias
    if (fileExists(shim) or symlinkExists(shim)) and not isManagedShim(shim):
      result.add("Skipped '" & alias & "': " & shim &
                 " exists and was not created by appmanager")
      continue
    writeFile(shim, shimContent(target))
    setFilePermissions(shim, {fpUserRead, fpUserWrite, fpUserExec,
                              fpGroupRead, fpGroupExec,
                              fpOthersRead, fpOthersExec})
    if fileExists(target):
      let perms = getFilePermissions(target)
      if fpUserExec notin perms:
        try:
          setFilePermissions(target, perms + {fpUserExec})
        except OSError:
          result.add("Could not make " & target & " executable")
    else:
      result.add("'" & alias & "' points to a missing file: " & target)

# ---------------------------------------------------------------------------
# PATH

proc binDirOnPath*(cfg: Config): bool =
  let wanted = cfg.binDir.normalizedPath
  for dir in getEnv("PATH").split(PathSep):
    if dir.len > 0 and dir.normalizedPath == wanted:
      return true

proc dquote(s: string): string =
  ## Escapes `s` for use inside a double-quoted POSIX shell string.
  for c in s:
    if c in {'"', '\\', '$', '`'}: result.add('\\')
    result.add(c)

proc posixPathBlock*(binDir: string): string =
  let dir = dquote(binDir)
  PathBlockStart & "\n" &
    "case \":$PATH:\" in\n" &
    "  *\":" & dir & ":\"*) ;;\n" &
    "  *) export PATH=\"" & dir & ":$PATH\" ;;\n" &
    "esac\n" &
    PathBlockEnd & "\n"

proc fishPathBlock*(binDir: string): string =
  PathBlockStart & "\n" &
    "fish_add_path --global " & quoteShell(binDir) & "\n" &
    PathBlockEnd & "\n"

proc replaceBlock*(content, blk: string): string =
  ## Replaces an existing appmanager block in `content` with `blk`, or
  ## appends `blk` if there is none.
  let start = content.find(PathBlockStart)
  if start >= 0:
    let stop = content.find(PathBlockEnd, start)
    if stop >= 0:
      var after = stop + PathBlockEnd.len
      if after < content.len and content[after] == '\n': inc after
      return content[0 ..< start] & blk & content[after .. ^1]
  result = content
  if result.len > 0 and not result.endsWith("\n"):
    result.add('\n')
  if result.len > 0:
    result.add('\n')
  result.add(blk)

proc shellRcFiles*(): seq[tuple[path: string, fish: bool]] =
  ## Startup files that get the PATH snippet: ~/.profile always, plus the
  ## rc files of any shells the user appears to use.
  let home = getHomeDir()
  result.add((home / ".profile", false))
  for rc in [".bashrc", ".zshrc"]:
    if fileExists(home / rc):
      result.add((home / rc, false))
  let fishDir = xdgDir("XDG_CONFIG_HOME", ".config") / "fish"
  if dirExists(fishDir):
    result.add((fishDir / "conf.d" / "appmanager.fish", true))

proc installPathSnippet*(cfg: Config): seq[string] =
  ## Adds (or updates) the snippet that puts `cfg.binDir` on PATH in the
  ## user's shell startup files. Returns the files that were changed.
  for (path, fish) in shellRcFiles():
    let blk = if fish: fishPathBlock(cfg.binDir) else: posixPathBlock(cfg.binDir)
    let old = if fileExists(path): readFile(path) else: ""
    let updated = replaceBlock(old, blk)
    if updated != old:
      createDir(path.parentDir)
      writeFile(path, updated)
      result.add(path)

proc pathSnippetInstalled*(cfg: Config): bool =
  let profile = getHomeDir() / ".profile"
  fileExists(profile) and posixPathBlock(cfg.binDir) in readFile(profile)

proc apply*(cfg: Config): seq[string] =
  ## Persists the config, writes shims and makes sure they're on PATH.
  ## Returns human readable notes/warnings.
  saveConfig(cfg)
  result = syncShims(cfg)
  for file in installPathSnippet(cfg):
    result.add("Added " & cfg.binDir & " to PATH in " & file)
