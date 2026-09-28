## Finding, installing and updating AppImages: the AppImageHub and
## pkgforge-dev catalogs, GitHub releases, embedded update information, zsync metadata and
## desktop menu integration.
##
## Nothing here touches the network: callers download with `curlArgs` and
## hand the results to the parsers below, which keeps this module testable
## and lets the GUI run downloads without blocking.

import std/[os, strutils, json, algorithm, osproc, streams, times, tables, sequtils]
import core

const
  AppImageHubFeed* = "https://appimage.github.io/feed.json"
  PkgforgeList* = "https://raw.githubusercontent.com/pkgforge-dev/Anylinux-AppImages/main/README.md"
  GitHubApi* = "https://api.github.com"
  CatalogMaxAge* = initDuration(days = 1)
  DesktopMarkerKey* = "X-AppManager-AppImage"
  DesktopPrefix = "appmanager-"

type
  CatalogSource* = enum
    FromAppImageHub = "AppImageHub"
    FromPkgforge = "pkgforge-dev"
    FromGitHub = "GitHub"

  CatalogApp* = object
    name*: string
    summary*: string
    repo*: string        ## "owner/repo" on GitHub
    license*: string
    categories*: seq[string]
    stars*: int          ## -1 when unknown
    source*: CatalogSource

  ReleaseAsset* = object
    tag*: string
    name*: string        ## AppImage file name
    url*: string         ## Download URL of the AppImage
    size*: BiggestInt
    id*: BiggestInt
    zsyncUrl*: string    ## Download URL of the matching .zsync file, if any

  UpdateKind* = enum
    NoUpdateSource, GitHubReleases, ZsyncUrl

  UpdateSource* = object
    case kind*: UpdateKind
    of NoUpdateSource: discard
    of GitHubReleases:
      owner*, repo*: string
      tag*: string       ## "latest", "latest-pre", "latest-all" or a tag name
      pattern*: string   ## Glob for the asset (the .zsync file if it ends so)
    of ZsyncUrl:
      url*: string

  ZsyncInfo* = object
    filename*: string
    url*: string         ## Absolute URL of the AppImage
    sha1*: string        ## Lower-case hex SHA-1 of the AppImage
    length*: BiggestInt

iterator elems(node: JsonNode): JsonNode =
  ## Like `items`, but yields nothing for a missing or non-array node.
  if not node.isNil and node.kind == JArray:
    for item in node: yield item

# ---------------------------------------------------------------------------
# Networking helpers

proc isGitHubApi(url: string): bool = url.startsWith(GitHubApi & "/")

proc githubTokenConfig*(): string =
  ## Writes a curl config holding $GITHUB_TOKEN (so it never shows up in the
  ## process list) and returns its path, or "" when no token is set.
  let token = getEnv("GITHUB_TOKEN").strip
  if token.len == 0 or token.contains({'"', '\n', '\r', '\\'}): return ""
  result = getCacheDir("appmanager") / "github-token.curlrc"
  try:
    createDir(result.parentDir)
    writeFile(result, "header = \"Authorization: Bearer " & token & "\"\n")
    setFilePermissions(result, {fpUserRead, fpUserWrite})
  except OSError, IOError:
    result = ""

proc curlArgs*(url, outFile: string, range = ""): seq[string] =
  ## Arguments for `curl` that download `url` to `outFile`.
  result = @["-fsSL", "--connect-timeout", "20", "--retry", "2",
             "-A", "appmanager", "-o", outFile]
  if range.len > 0:
    result.add(["-r", range])
  if url.isGitHubApi:
    result.add(["-H", "Accept: application/vnd.github+json"])
    let conf = githubTokenConfig()
    if conf.len > 0:
      result.add(["-K", conf])
  result.add(url)

proc encodeQuery*(s: string): string =
  for c in s:
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', '~'}: result.add(c)
    elif c == ' ': result.add('+')
    else: result.add('%' & toHex(ord(c), 2))

proc githubSearchUrl*(query: string): string =
  ## Repositories matching `query` whose README (or name, description or
  ## topics) mention AppImage, most starred first.
  GitHubApi & "/search/repositories?sort=stars&order=desc&per_page=50&q=" &
    encodeQuery(query.strip & " appimage in:name,description,topics,readme fork:false")

proc releasesUrl*(repo: string, tag = ""): string =
  ## The API URL listing a repository's releases, or a single release when
  ## `tag` names one.
  case tag
  of "", "latest-pre", "latest-all": GitHubApi & "/repos/" & repo & "/releases?per_page=20"
  of "latest": GitHubApi & "/repos/" & repo & "/releases/latest"
  else: GitHubApi & "/repos/" & repo & "/releases/tags/" & encodeQuery(tag)

proc isCatalog*(source: CatalogSource): bool =
  ## Whether `source` is a list we download whole and filter locally (as
  ## opposed to one we query per search).
  source != FromGitHub

proc catalogUrl*(source: CatalogSource): string =
  case source
  of FromAppImageHub: AppImageHubFeed
  of FromPkgforge: PkgforgeList
  of FromGitHub: ""

proc catalogCachePath*(source = FromAppImageHub): string =
  getCacheDir("appmanager") / (case source
    of FromAppImageHub: "appimagehub.json"
    of FromPkgforge: "pkgforge-dev.md"
    of FromGitHub: "github.json")

proc catalogIsFresh*(path = catalogCachePath()): bool =
  fileExists(path) and getTime() - getLastModificationTime(path) < CatalogMaxAge

proc defaultInstallDir*(): string =
  getHomeDir() / "Applications"

# ---------------------------------------------------------------------------
# Catalog

proc normalizeRepo*(s: string): string =
  ## Turns "owner/repo", "github.com/owner/repo" or a GitHub URL (possibly
  ## pointing into the repo) into "owner/repo"; "" if it isn't one.
  var s = s.strip
  for prefix in ["https://", "http://"]:
    if s.startsWith(prefix): s = s[prefix.len .. ^1]
  if s.startsWith("www."): s = s[4 .. ^1]
  if s.startsWith("github.com/"): s = s["github.com/".len .. ^1]
  elif '.' in s.split('/')[0]: return ""  # some other host
  let parts = s.split('/')
  if parts.len < 2: return ""
  var repo = parts[1]
  if repo.endsWith(".git"): repo = repo[0 ..< ^4]
  for part in [parts[0], repo]:
    if part.len == 0: return ""
    for c in part:
      if c notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.'}: return ""
  parts[0] & "/" & repo

proc plainText*(html: string): string =
  ## Strips the HTML tags some catalog descriptions contain, decodes the
  ## common entities and collapses whitespace.
  var text = ""
  var inTag = false
  for c in html:
    if c == '<':
      inTag = true
      text.add(' ')
    elif c == '>' and inTag: inTag = false
    elif not inTag: text.add(c)
  text = text.multiReplace(("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"),
                           ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                           ("&amp;", "&"))
  text.splitWhitespace.join(" ")

proc shortLicense*(license: string): string =
  ## "LicenseRef-proprietary=https://…" -> "proprietary".
  result = license.strip
  if result.startsWith("LicenseRef-"):
    result = result["LicenseRef-".len .. ^1]
  let eq = result.find('=')
  if eq >= 0: result = result[0 ..< eq]

proc parseAppImageHub*(node: JsonNode): seq[CatalogApp] =
  ## Parses https://appimage.github.io/feed.json, keeping apps that are
  ## published on GitHub (the only ones we can install and update).
  for item in elems(node{"items"}):
    var repo = ""
    for link in elems(item{"links"}):
      if link{"type"}.getStr == "GitHub":
        repo = normalizeRepo(link{"url"}.getStr)
        if repo.len > 0: break
    if repo.len == 0: continue
    var app = CatalogApp(name: item{"name"}.getStr.replace('_', ' '),
                         summary: plainText(item{"description"}.getStr),
                         repo: repo, license: shortLicense(item{"license"}.getStr),
                         stars: -1, source: FromAppImageHub)
    for cat in elems(item{"categories"}):
      if cat.getStr.len > 0: app.categories.add(cat.getStr)
    if app.name.len == 0: app.name = repo.split('/')[1]
    result.add(app)

proc parsePkgforge*(markdown: string): seq[CatalogApp] =
  ## Parses the app tables of pkgforge-dev's Anylinux-AppImages README:
  ## one-cell rows of the form `| [Name](https://github.com/owner/repo) |`.
  ## These AppImages bundle all their libraries (sharun + uruntime), so
  ## they run on old, musl and non-FHS distros alike.
  var seen: seq[string]
  for line in markdown.splitLines:
    let row = line.strip
    if not row.startsWith("| [") or not row.endsWith("|"): continue
    let nameEnd = row.find("](")
    if nameEnd < 0: continue
    let urlEnd = row.find(')', nameEnd)
    if urlEnd < 0 or row[urlEnd + 1 .. ^1].strip != "|": continue
    let repo = normalizeRepo(row[nameEnd + 2 ..< urlEnd])
    if repo.len == 0 or repo.toLowerAscii in seen: continue
    seen.add(repo.toLowerAscii)
    let name = row[3 ..< nameEnd].strip
    result.add(CatalogApp(
      name: if name.len > 0: name else: repo.split('/')[1],
      summary: if repo.toLowerAscii.startsWith("pkgforge-dev/"):
                 "Anylinux AppImage built by pkgforge-dev"
               else: "Publishes an Anylinux AppImage",
      repo: repo, categories: @["Anylinux"], stars: -1, source: FromPkgforge))

proc parseCatalog*(source: CatalogSource, data: string): seq[CatalogApp] =
  ## Parses a downloaded catalog. Raises on malformed JSON.
  case source
  of FromAppImageHub: parseAppImageHub(parseJson(data))
  of FromPkgforge: parsePkgforge(data)
  of FromGitHub: @[]

proc parseGitHubSearch*(node: JsonNode): seq[CatalogApp] =
  for item in elems(node{"items"}):
    let repo = item{"full_name"}.getStr
    if repo.len == 0: continue
    var app = CatalogApp(name: item{"name"}.getStr, summary: plainText(item{"description"}.getStr),
                         repo: repo, stars: item{"stargazers_count"}.getInt,
                         source: FromGitHub)
    let license = item{"license", "spdx_id"}.getStr
    if license != "NOASSERTION": app.license = license
    for topic in elems(item{"topics"}):
      app.categories.add(topic.getStr)
    result.add(app)

proc searchCatalog*(apps: seq[CatalogApp], query: string, limit = 200): seq[CatalogApp] =
  ## Case-insensitive search: every word must occur in the name, summary,
  ## categories or repo. Name matches rank first.
  let q = query.strip.toLowerAscii
  let words = q.splitWhitespace
  var scored: seq[(int, CatalogApp)]
  for app in apps:
    let name = app.name.toLowerAscii
    let hay = name & "\n" & app.summary.toLowerAscii & "\n" &
              app.categories.join(" ").toLowerAscii & "\n" & app.repo.toLowerAscii
    var ok = true
    for w in words:
      if w notin hay:
        ok = false
        break
    if not ok: continue
    let score =
      if q.len == 0: 0
      elif name == q: 100
      elif name.startsWith(q): 50
      elif q in name: 30
      elif q in app.repo.toLowerAscii: 20
      else: 10
    scored.add((score, app))
  scored.sort(proc (a, b: (int, CatalogApp)): int =
    result = cmp(b[0], a[0])
    if result == 0: result = cmp(b[1].stars, a[1].stars)
    if result == 0: result = cmp(a[1].name.toLowerAscii, b[1].name.toLowerAscii))
  for (_, app) in scored:
    if result.len >= limit: break
    result.add(app)

# ---------------------------------------------------------------------------
# Picking a release asset

proc globMatch*(pattern, s: string): bool =
  ## Shell-style match supporting `*` and `?`.
  var p, i = 0
  var star, mark = -1
  while i < s.len:
    if p < pattern.len and (pattern[p] == '?' or pattern[p] == s[i]):
      inc p
      inc i
    elif p < pattern.len and pattern[p] == '*':
      star = p
      mark = i
      inc p
    elif star >= 0:
      p = star + 1
      inc mark
      i = mark
    else:
      return false
  while p < pattern.len and pattern[p] == '*': inc p
  p == pattern.len

const archAliases = [
  @["x86_64", "amd64", "x64", "x86-64"],
  @["aarch64", "arm64"],
  @["armhf", "armv7l", "armv7", "arm"],
  @["i386", "i686", "x86", "ia32"],
]

proc hostArchTokens*(): seq[string] =
  case hostCPU
  of "amd64": archAliases[0]
  of "arm64": archAliases[1]
  of "arm": archAliases[2]
  of "i386": archAliases[3]
  else: @[hostCPU]

proc archScore*(name: string, arch = hostArchTokens()): int =
  ## 2 if the file name names our architecture, 1 if it names none, and -1
  ## if it is for another one.
  let lower = name.toLowerAscii
  var tokens = lower.split({'-', '.', ' ', '+', '(', ')', '[', ']'})
  for t in lower.split({'-', '.', ' ', '+', '_'}):  # "linux_x64"
    tokens.add(t)
  for t in tokens:
    if t in arch: return 2
  for group in archAliases:
    for t in tokens:
      if t in group: return -1
  1

proc assetKey*(name: string): string =
  ## A file name with its version numbers masked, used to find the same
  ## flavour of an AppImage in a newer release.
  var inDigits = false
  for c in name.toLowerAscii:
    if c in Digits:
      if not inDigits: result.add('#')
      inDigits = true
    else:
      result.add(c)
      inDigits = false

proc isAppImageName(name: string): bool = name.toLowerAscii.endsWith(".appimage")

proc pickAsset*(release: JsonNode, pattern = "", previous = "",
                arch = hostArchTokens()): ReleaseAsset =
  ## Picks the AppImage to download from one GitHub release. Returns an
  ## asset with an empty name when the release has none.
  let zsyncPattern = pattern.toLowerAscii.endsWith(".zsync")
  var byName: seq[(string, JsonNode)]
  for asset in elems(release{"assets"}):
    byName.add((asset{"name"}.getStr, asset))
  var candidates: seq[(int, JsonNode)]
  for (name, asset) in byName:
    if name.toLowerAscii.endsWith(".zsync"): continue
    if pattern.len > 0:
      # A .zsync pattern names the file that sits next to the AppImage.
      if not globMatch(pattern, if zsyncPattern: name & ".zsync" else: name):
        continue
    elif not name.isAppImageName:
      continue
    var score = 0
    let arch = archScore(name, arch)
    if arch < 0 and pattern.len == 0: continue
    score += arch * 10
    if previous.len > 0 and assetKey(name) == assetKey(previous): score += 100
    candidates.add((score, asset))
  if candidates.len == 0: return
  candidates.sort(proc (a, b: (int, JsonNode)): int =
    result = cmp(b[0], a[0])
    if result == 0: result = cmp(a[1]{"name"}.getStr.len, b[1]{"name"}.getStr.len))
  let best = candidates[0][1]
  result = ReleaseAsset(tag: release{"tag_name"}.getStr, name: best{"name"}.getStr,
                        url: best{"browser_download_url"}.getStr,
                        size: best{"size"}.getBiggestInt, id: best{"id"}.getBiggestInt)
  for (name, asset) in byName:
    if name == result.name & ".zsync":
      result.zsyncUrl = asset{"browser_download_url"}.getStr

proc pickRelease*(releases: JsonNode, tag = "", pattern = "", previous = "",
                  arch = hostArchTokens()): ReleaseAsset =
  ## Picks the release asset to install from the reply to `releasesUrl`
  ## (a single release or a list). Unless `tag` is "latest-pre" or
  ## "latest-all", stable releases are preferred over pre-releases.
  if releases.kind == JObject:
    return pickAsset(releases, pattern, previous, arch)
  if releases.kind != JArray: return
  let passes = if tag in ["latest-pre", "latest-all"]: @[{false, true}]
               else: @[{false}, {true}]
  for allowed in passes:
    for release in releases:
      if release{"draft"}.getBool or release{"prerelease"}.getBool notin allowed:
        continue
      let asset = pickAsset(release, pattern, previous, arch)
      if asset.name.len > 0: return asset

# ---------------------------------------------------------------------------
# Embedded update information

proc readLE(data: string, pos, size: int): BiggestInt =
  for i in countdown(size - 1, 0):
    result = (result shl 8) or BiggestInt(ord(data[pos + i]))

proc readElfSection*(path, section: string): string =
  ## Returns the contents of the named section of a little-endian ELF file,
  ## or "" if there is no such section.
  var s = newFileStream(path, fmRead)
  if s.isNil: return ""
  defer: s.close()
  try:
    let ident = s.readStr(64)
    if ident.len < 64 or not ident.startsWith("\x7FELF") or ident[5] != '\x01':
      return ""
    let is64 = ident[4] == '\x02'
    let (shoff, shentsize, shnum, shstrndx) =
      if is64: (readLE(ident, 0x28, 8), readLE(ident, 0x3A, 2),
                readLE(ident, 0x3C, 2), readLE(ident, 0x3E, 2))
      else: (readLE(ident, 0x20, 4), readLE(ident, 0x2E, 2),
             readLE(ident, 0x30, 2), readLE(ident, 0x32, 2))
    if shoff <= 0 or shnum <= 0 or shnum > 4096 or shstrndx >= shnum or
        shentsize < (if is64: 0x40 else: 0x28):
      return ""
    s.setPosition(int(shoff))
    let table = s.readStr(int(shentsize * shnum))
    if table.len < int(shentsize * shnum): return ""
    proc header(i: BiggestInt): (BiggestInt, BiggestInt, BiggestInt) =
      let base = int(i * shentsize)
      if is64: (readLE(table, base, 4), readLE(table, base + 0x18, 8),
                readLE(table, base + 0x20, 8))
      else: (readLE(table, base, 4), readLE(table, base + 0x10, 4),
             readLE(table, base + 0x14, 4))
    let (_, strOff, strSize) = header(shstrndx)
    if strSize <= 0 or strSize > 1_000_000: return ""
    s.setPosition(int(strOff))
    let names = s.readStr(int(strSize))
    for i in 0 ..< shnum:
      let (nameOff, off, size) = header(i)
      if nameOff >= names.len: continue
      let stop = names.find('\0', int(nameOff))
      let name = names[int(nameOff) ..< (if stop < 0: names.len else: stop)]
      if name == section:
        if size <= 0 or size > 1_000_000: return ""
        s.setPosition(int(off))
        return s.readStr(int(size))
  except IOError, OSError:
    return ""

proc readUpdateInfo*(path: string): string =
  ## The update information embedded in an AppImage (its `.upd_info`
  ## section), e.g. "gh-releases-zsync|owner|repo|latest|App-*.zsync".
  let raw = readElfSection(path, ".upd_info")
  let stop = raw.find('\0')
  (if stop < 0: raw else: raw[0 ..< stop]).strip

proc parseUpdateInfo*(info: string): UpdateSource =
  let parts = info.strip.split('|')
  case parts[0]
  of "zsync":
    if parts.len >= 2 and parts[1].len > 0:
      return UpdateSource(kind: ZsyncUrl, url: parts[1 .. ^1].join("|"))
  of "gh-releases-zsync", "gh-releases-direct":
    if parts.len >= 5 and parts[1].len > 0 and parts[2].len > 0:
      return UpdateSource(kind: GitHubReleases, owner: parts[1], repo: parts[2],
                          tag: (if parts[3].len > 0: parts[3] else: "latest"),
                          pattern: parts[4])
  else: discard
  UpdateSource(kind: NoUpdateSource)

proc parseSourceSetting*(s: string): UpdateSource =
  ## Parses what a user typed as an update source: a GitHub repo (or any URL
  ## within it), a .zsync URL or a full update information string.
  let s = s.strip
  if '|' in s: return parseUpdateInfo(s)
  if s.toLowerAscii.endsWith(".zsync") and "://" in s:
    return UpdateSource(kind: ZsyncUrl, url: s)
  let repo = normalizeRepo(s)
  if repo.len > 0:
    let parts = repo.split('/')
    return UpdateSource(kind: GitHubReleases, owner: parts[0], repo: parts[1])
  UpdateSource(kind: NoUpdateSource)

proc updateSourceFor*(info: InstallInfo, embedded: string): UpdateSource =
  ## Where to look for updates: the source the user set (or that the app was
  ## installed from) wins over the information embedded in the AppImage.
  if info.source.len > 0:
    result = parseSourceSetting(info.source)
    if result.kind != NoUpdateSource: return
  result = parseUpdateInfo(embedded)

proc `$`*(src: UpdateSource): string =
  case src.kind
  of NoUpdateSource: "none"
  of GitHubReleases: "github.com/" & src.owner & "/" & src.repo
  of ZsyncUrl: src.url

# ---------------------------------------------------------------------------
# zsync

proc resolveUrl*(base, rel: string): string =
  if "://" in rel: return rel
  let schemeEnd = base.find("://")
  if rel.startsWith("/"):
    let hostEnd = base.find('/', schemeEnd + 3)
    return (if hostEnd < 0: base else: base[0 ..< hostEnd]) & rel
  let q = base.find({'?', '#'})
  let path = if q < 0: base else: base[0 ..< q]
  path[0 .. path.rfind('/')] & rel

proc parseZsync*(data, zsyncUrl: string): ZsyncInfo =
  ## Parses the header of a .zsync file.
  for line in data.splitLines:
    if line.len == 0: break
    let colon = line.find(':')
    if colon < 0: continue
    let key = line[0 ..< colon].strip
    let value = line[colon + 1 .. ^1].strip
    case key
    of "Filename": result.filename = value
    of "URL": result.url = resolveUrl(zsyncUrl, value)
    of "SHA-1": result.sha1 = value.toLowerAscii
    of "Length":
      try: result.length = parseBiggestInt(value)
      except ValueError: discard
    else: discard
  if result.url.len == 0 and result.filename.len > 0:
    result.url = resolveUrl(zsyncUrl, result.filename)

# ---------------------------------------------------------------------------
# Desktop integration

proc applicationsDir*(): string =
  let dir = getEnv("XDG_DATA_HOME")
  (if dir.len > 0: dir else: getHomeDir() / ".local/share") / "applications"

proc iconThemeDir*(): string =
  ## The user's hicolor icon theme, where menu icons are installed.
  let dir = getEnv("XDG_DATA_HOME")
  (if dir.len > 0: dir else: getHomeDir() / ".local/share") / "icons" / "hicolor"

proc legacyIconsDir(): string =
  ## Where older versions put menu icons; cleaned up on (un)integrate.
  let dir = getEnv("XDG_DATA_HOME")
  (if dir.len > 0: dir else: getHomeDir() / ".local/share") / "appmanager" / "icons"

proc fnv1a(s: string): uint32 =
  result = 2166136261'u32
  for c in s:
    result = (result xor uint32(ord(c))) * 16777619'u32

proc desktopId*(appPath: string): string =
  ## A stable, unique file name stem for the menu entry of an AppImage.
  var slug = ""
  for c in stripAppImageExt(appPath.extractFilename).toLowerAscii:
    if c in {'a'..'z', '0'..'9'}: slug.add(c)
    elif slug.len > 0 and slug[^1] != '-': slug.add('-')
  slug = slug.strip(chars = {'-'})
  if slug.len > 40: slug = slug[0 ..< 40]
  DesktopPrefix & slug & "-" & toHex(fnv1a(appPath), 8).toLowerAscii

proc desktopExecArg*(path: string): string =
  ## Quotes `path` for an Exec= key (desktop entry spec: reserved characters
  ## need double quotes; `%` and the string escape `\` are doubled).
  const reserved = {' ', '\t', '\n', '"', '\'', '\\', '>', '<', '~', '|', '&',
                    ';', '$', '*', '?', '#', '(', ')', '`'}
  var arg = path
  if path.contains(reserved):
    arg = "\""
    for c in path:
      if c in {'"', '`', '$', '\\'}: arg.add('\\')
      arg.add(c)
    arg.add('"')
  arg.replace("\\", "\\\\").replace("%", "%%")

proc replaceExec(value, exec: string): string =
  ## Replaces the program of an Exec= value, keeping its arguments.
  var i = 0
  if value.startsWith("\""):
    i = 1
    while i < value.len and value[i] != '"':
      if value[i] == '\\': inc i
      inc i
    inc i
  else:
    while i < value.len and value[i] notin {' ', '\t'}: inc i
  exec & (if i < value.len: value[i .. ^1] else: "")

proc rewriteDesktopEntry*(content, appPath, icon: string): string =
  ## Adapts an AppImage's own .desktop file so the menu launches `appPath`
  ## and shows `icon`. Builds a minimal entry when `content` is empty.
  let exec = desktopExecArg(appPath)
  var content = content
  if "[Desktop Entry]" notin content:
    content = "[Desktop Entry]\nType=Application\nName=" &
      stripAppImageExt(appPath.extractFilename) & "\nExec=" & exec &
      "\nTerminal=false\nCategories=Utility;\n"
  var group = ""
  var lines: seq[string]
  for line in content.splitLines:
    let trimmed = line.strip
    if trimmed.startsWith("[") and trimmed.endsWith("]"):
      if group == "[Desktop Entry]":
        while lines.len > 0 and lines[^1].strip.len == 0: lines.setLen(lines.len - 1)
        lines.add(DesktopMarkerKey & "=" & appPath)
        if icon.len > 0: lines.add("Icon=" & icon)
        lines.add("")
      group = trimmed
      lines.add(line)
      continue
    let eq = line.find('=')
    let key = if eq < 0: "" else: line[0 ..< eq].strip
    if key in ["TryExec", DesktopMarkerKey]: continue
    if key == "Icon" and icon.len > 0 and group == "[Desktop Entry]": continue
    if key == "Exec" and group.startsWith("[Desktop"):
      lines.add("Exec=" & replaceExec(line[eq + 1 .. ^1].strip, exec))
      continue
    lines.add(line)
  if group == "[Desktop Entry]":
    while lines.len > 0 and lines[^1].strip.len == 0: lines.setLen(lines.len - 1)
    lines.add(DesktopMarkerKey & "=" & appPath)
    if icon.len > 0: lines.add("Icon=" & icon)
  lines.join("\n").strip(leading = false) & "\n"

proc desktopEntryFor*(appPath: string): string =
  ## The menu entry appmanager created for `appPath`, or "".
  let path = applicationsDir() / desktopId(appPath) & ".desktop"
  if fileExists(path): path else: ""

proc isIntegrated*(appPath: string): bool = desktopEntryFor(appPath).len > 0

proc iconExt(data: string): string =
  if data.startsWith("\x89PNG"): ".png"
  elif data.startsWith("/* XPM"): ".xpm"
  elif "<svg" in data[0 ..< min(data.len, 4096)]: ".svg"
  else: ""

const HicolorSizes = [16, 22, 24, 32, 36, 48, 64, 72, 96, 128, 192, 256, 512]

proc iconSize*(data: string): int =
  ## The larger dimension of a PNG or XPM image, or 0 if unknown.
  if data.startsWith("\x89PNG") and data.len >= 24 and data[12 ..< 16] == "IHDR":
    var w, h = 0
    for i in 0 ..< 4:
      w = w shl 8 or ord(data[16 + i])
      h = h shl 8 or ord(data[20 + i])
    return max(w, h)
  if data.startsWith("/* XPM"):
    # The first string holds "<width> <height> <colors> <chars per pixel>".
    let start = data.find('"')
    if start < 0: return 0
    let stop = data.find('"', start + 1)
    if stop < 0: return 0
    let fields = data[start + 1 ..< stop].splitWhitespace
    if fields.len >= 2:
      try: return max(parseInt(fields[0]), parseInt(fields[1]))
      except ValueError: discard
  0

proc iconSubdir*(data: string): string =
  ## The hicolor directory an icon belongs in: `scalable` for SVGs, else the
  ## standard size closest to the image's (256x256 if it can't be read).
  if iconExt(data) == ".svg": return "scalable"
  var size = iconSize(data)
  if size <= 0: size = 256
  var best = HicolorSizes[0]
  for s in HicolorSizes:
    if abs(s - size) < abs(best - size): best = s
  $best & "x" & $best

proc removeIcons(id: string) =
  ## Deletes every icon named `id` from the hicolor theme and the old folder.
  if dirExists(iconThemeDir()):
    for kind, dir in walkDir(iconThemeDir()):
      if kind in {pcDir, pcLinkToDir}:
        for ext in [".png", ".svg", ".xpm"]:
          removeFile(dir / "apps" / id & ext)
  for ext in [".png", ".svg", ".xpm"]:
    removeFile(legacyIconsDir() / id & ext)

proc touchIconTheme() =
  ## Bumps the theme folder's mtime so running apps rescan it and ignore a
  ## stale icon cache.
  if dirExists(iconThemeDir()):
    try: setLastModificationTime(iconThemeDir(), getTime())
    except OSError: discard

proc runWithTimeout(exe: string, args: seq[string], dir: string,
                    timeoutMs = 15_000): bool =
  ## Runs `exe` with its output discarded, killing it after `timeoutMs`.
  var p: Process
  try:
    p = startProcess("/bin/sh", workingDir = dir,
                     args = @["-c", "exec \"$0\" \"$@\" >/dev/null 2>&1", exe] & args)
  except OSError:
    return false
  defer: p.close()
  let start = epochTime()
  while p.running:
    if (epochTime() - start) * 1000 > timeoutMs.float:
      p.kill()
      discard p.waitForExit()
      return false
    sleep(20)
  p.peekExitCode == 0

proc extractFromAppImage*(appPath, pattern, dir: string): bool =
  ## Extracts files matching `pattern` with the AppImage runtime's
  ## `--appimage-extract` into `dir`/squashfs-root. Gives up after 15 s, in
  ## case an unusual runtime starts the app instead.
  runWithTimeout(appPath, @["--appimage-extract", pattern], dir)

proc readDesktopKey(content, key: string): string =
  var inEntry = false
  for line in content.splitLines:
    let t = line.strip
    if t.startsWith("["): inEntry = t == "[Desktop Entry]"
    elif inEntry and t.startsWith(key & "="): return t[key.len + 1 .. ^1].strip

proc integrate*(appPath: string): string =
  ## Adds `appPath` to the application menu (like Gear Lever): copies its
  ## .desktop file and icon out of the AppImage and points them at it.
  ## Returns the path of the written .desktop file.
  let tmp = getTempDir() / "appmanager-extract-" & $getCurrentProcessId() & "-" &
            toHex(fnv1a(appPath & $epochTime()), 8)
  createDir(tmp)
  defer: removeDir(tmp)
  if fpUserExec notin getFilePermissions(appPath):
    setFilePermissions(appPath, getFilePermissions(appPath) + {fpUserExec})
  let root = tmp / "squashfs-root"
  var desktop = ""
  if extractFromAppImage(appPath, "*.desktop", tmp) and dirExists(root):
    # The entry the AppImage spec requires sits at the top level.
    var found = ""
    for kind, path in walkDir(root):
      if kind == pcFile and path.endsWith(".desktop"): found = path
    if found.len == 0:
      for path in walkDirRec(root):
        if path.endsWith(".desktop"):
          found = path
          break
    if found.len > 0:
      try: desktop = readFile(found)
      except IOError: discard
  var iconData = ""
  var want = ".DirIcon"
  for _ in 0 ..< 4:
    if not extractFromAppImage(appPath, want, tmp): break
    let got = root / want
    if symlinkExists(got):
      want = (want.parentDir / expandSymlink(got)).normalizedPath
      if want.startsWith("/") or want.startsWith(".."): break
      continue
    if fileExists(got):
      try: iconData = readFile(got)
      except IOError: discard
    break
  if iconData.len == 0 and desktop.len > 0:
    let name = readDesktopKey(desktop, "Icon")
    if name.len > 0 and '/' notin name:
      for ext in [".png", ".svg", ".xpm"]:
        if extractFromAppImage(appPath, name & ext, tmp) and fileExists(root / name & ext):
          iconData = readFile(root / name & ext)
          break
  let id = desktopId(appPath)
  var icon = ""
  let ext = iconExt(iconData)
  removeIcons(id)
  if ext.len > 0:
    let dir = iconThemeDir() / iconSubdir(iconData) / "apps"
    createDir(dir)
    writeFile(dir / id & ext, iconData)
    icon = id
  touchIconTheme()
  createDir(applicationsDir())
  result = applicationsDir() / id & ".desktop"
  writeFile(result, rewriteDesktopEntry(desktop, appPath, icon))

proc unintegrate*(appPath: string): bool =
  ## Removes the menu entry and icon `integrate` created. Returns whether
  ## there was one.
  let id = desktopId(appPath)
  let entry = applicationsDir() / id & ".desktop"
  result = fileExists(entry)
  removeFile(entry)
  removeIcons(id)
  touchIconTheme()

proc refreshMenus*() =
  ## Asks the desktop to notice changed menu entries and icons, if the
  ## tools exist. The icon cache is only rebuilt if the user already has
  ## one, since a stale cache would hide new icons.
  let tool = findExe("update-desktop-database")
  if tool.len > 0:
    discard runWithTimeout(tool, @["-q", applicationsDir()], getTempDir(), 5_000)
  if fileExists(iconThemeDir() / "icon-theme.cache"):
    for name in ["gtk-update-icon-cache", "gtk4-update-icon-cache"]:
      let cacheTool = findExe(name)
      if cacheTool.len > 0:
        discard runWithTimeout(cacheTool, @["-q", "-t", "-f", iconThemeDir()],
                               getTempDir(), 15_000)
        break

# ---------------------------------------------------------------------------
# Opening AppImages from the file manager

const
  AppImageMimeTypes* = ["application/vnd.appimage", "application/x-iso9660-appimage"]
  SelfMarkerKey = "X-AppManager-Self"

proc userConfigHome(): string =
  let dir = getEnv("XDG_CONFIG_HOME")
  if dir.len > 0: dir else: getHomeDir() / ".config"

proc mimeappsLists*(): seq[string] =
  ## The user's mimeapps.list files, highest precedence first (XDG MIME
  ## Applications spec): desktop-specific ones, then the generic one, then
  ## the deprecated copy in the applications folder.
  for desktop in getEnv("XDG_CURRENT_DESKTOP").toLowerAscii.split(':'):
    if desktop.len > 0:
      result.add(userConfigHome() / desktop & "-mimeapps.list")
  result.add(userConfigHome() / "mimeapps.list")
  result.add(applicationsDir() / "mimeapps.list")

proc listValue(value: string): seq[string] =
  for id in value.split(';'):
    if id.strip.len > 0: result.add(id.strip)

proc defaultFor*(content, mimeType: string): string =
  ## The first desktop file named for `mimeType` under [Default Applications]
  ## in a mimeapps.list, or "".
  var group = ""
  for line in content.splitLines:
    let t = line.strip
    if t.startsWith("["): group = t
    elif group == "[Default Applications]":
      let eq = t.find('=')
      if eq > 0 and t[0 ..< eq].strip == mimeType:
        let ids = listValue(t[eq + 1 .. ^1])
        return if ids.len > 0: ids[0] else: ""

proc setDefaultApp*(content, desktopFile: string,
                    mimeTypes: openArray[string]): string =
  ## Makes `desktopFile` the default for `mimeTypes` in a mimeapps.list and
  ## lists it under [Added Associations], keeping everything else.
  let mimeTypes = @mimeTypes
  var lines: seq[string]
  var seen: seq[string]
  var group = ""
  proc closeGroup() =
    if group notin ["[Default Applications]", "[Added Associations]"]: return
    while lines.len > 0 and lines[^1].strip.len == 0: lines.setLen(lines.len - 1)
    for mime in mimeTypes:
      if group == "[Default Applications]":
        lines.add(mime & "=" & desktopFile & ";")
      elif (group & mime) notin seen:
        lines.add(mime & "=" & desktopFile & ";")
    lines.add("")
    seen.add(group)
  for line in content.splitLines:
    let t = line.strip
    if t.startsWith("[") and t.endsWith("]"):
      closeGroup()
      group = t
      lines.add(line)
      continue
    let eq = t.find('=')
    let key = if eq > 0: t[0 ..< eq].strip else: ""
    if key in mimeTypes:
      if group == "[Default Applications]": continue
      if group == "[Added Associations]":
        var ids = listValue(t[eq + 1 .. ^1])
        ids.keepItIf(it != desktopFile)
        lines.add(key & "=" & (@[desktopFile] & ids).join(";") & ";")
        seen.add(group & key)
        continue
    lines.add(line)
  closeGroup()
  for g in ["[Default Applications]", "[Added Associations]"]:
    if g notin seen:
      while lines.len > 0 and lines[^1].strip.len == 0: lines.setLen(lines.len - 1)
      if lines.len > 0: lines.add("")
      lines.add(g)
      group = g
      closeGroup()
  lines.join("\n").strip(leading = false) & "\n"

proc selfExecutable*(): string =
  ## How to start this program again: the AppImage it runs from, if any.
  let appImage = getEnv("APPIMAGE")
  if appImage.len > 0 and fileExists(appImage): appImage else: getAppFilename()

proc selfDesktopEntry*(appId, exe: string): string =
  ## A menu entry for appmanager itself that opens AppImages with it.
  "[Desktop Entry]\nType=Application\nName=AppManager\n" &
    "GenericName=AppImage Manager\n" &
    "Comment=Find, install, update and alias AppImages\n" &
    "Exec=" & desktopExecArg(exe) & " %F\nIcon=" & appId & "\n" &
    "Terminal=false\nCategories=Utility;GTK;\n" &
    "MimeType=" & AppImageMimeTypes.join(";") & ";\n" &
    "StartupWMClass=" & appId & "\n" & SelfMarkerKey & "=true\n"

proc appImageHandler*(): string =
  ## The desktop file the user's mimeapps.list files pick for AppImages,
  ## or "" when they don't name one (the desktop then picks any app that
  ## accepts AppImages, e.g. Gear Lever).
  for list in mimeappsLists():
    if not fileExists(list): continue
    let id = try: defaultFor(readFile(list), AppImageMimeTypes[0])
             except IOError: ""
    if id.len > 0: return id

proc makeAppImageHandler*(appId: string, exe = selfExecutable()) =
  ## Makes double-clicking an AppImage open appmanager: writes a menu entry
  ## for it that accepts AppImages (unless another tool installed one) and
  ## makes that the default in the user's mimeapps.list files.
  let desktopFile = appId & ".desktop"
  let entry = applicationsDir() / desktopFile
  if not fileExists(entry) or (SelfMarkerKey & "=true") in readFile(entry):
    createDir(applicationsDir())
    writeFile(entry, selfDesktopEntry(appId, exe))
  for list in mimeappsLists():
    # Always write the generic list; the others only matter if they exist,
    # since they would otherwise override it.
    if list != userConfigHome() / "mimeapps.list" and not fileExists(list): continue
    let content = if fileExists(list): readFile(list) else: ""
    createDir(list.parentDir)
    writeFile(list, setDefaultApp(content, desktopFile, AppImageMimeTypes))
  refreshMenus()

# ---------------------------------------------------------------------------
# Moving to a central folder

proc isInside*(path, dir: string): bool =
  path.normalizedPath.startsWith(dir.normalizedPath & "/")

proc needsMove*(path: string, dir = defaultInstallDir()): bool =
  ## Whether the AppImage at `path` lives outside `dir`. Symlinks are left
  ## alone: they usually already point into it.
  fileExists(path) and not symlinkExists(path) and not path.isInside(dir)

proc relocate*(cfg: var Config, src, destDir: string, notes: var seq[string]): string =
  ## Moves the AppImage at `src` into `destDir` and points its alias, update
  ## source and menu entry at the new path, which it returns. Raises
  ## OSError when the move fails or a file of that name is already there.
  ## The caller must `apply` the config afterwards if `src` had an alias.
  result = destDir / src.extractFilename
  if fileExists(result) or symlinkExists(result) or dirExists(result):
    raise newException(OSError, tildify(result) & " already exists")
  let integrated = isIntegrated(src)
  createDir(destDir)
  moveFile(src, result)
  let alias = cfg.aliasFor(src)
  if alias.len > 0: cfg.aliases[alias] = result
  if src in cfg.installs:
    cfg.installs[result] = cfg.installs[src]
    cfg.installs.del(src)
  if not cfg.scanDirs.anyIt(expandTilde(it).normalizedPath == destDir.normalizedPath):
    cfg.scanDirs.add(destDir)
  if integrated:
    discard unintegrate(src)
    try:
      discard integrate(result)
    except OSError, IOError:
      notes.add("Could not re-add " & result.extractFilename & " to the app menu: " &
                getCurrentExceptionMsg())

# ---------------------------------------------------------------------------
# Uninstalling

proc forget*(cfg: var Config, appPath: string) =
  ## Drops everything the config knows about `appPath`.
  let alias = cfg.aliasFor(appPath)
  if alias.len > 0: cfg.aliases.del(alias)
  cfg.installs.del(appPath)
