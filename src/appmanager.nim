## appmanager: a small GTK4 GUI for managing AppImages. It gives installed
## AppImages a command-line alias on PATH, finds and installs new ones from
## AppImageHub or GitHub, keeps them up to date and adds them to the
## application menu.

import std/[os, strutils, tables, sets, json, sequtils]
import owlkettle
import owlkettle/bindings/gtk
import appmanager/[core, store, jobs]

const
  AppId = "dev.appmanager.AppManager"
  MaxResults = 150
  MaxParallelChecks = 4
  ZsyncHeaderRange = "0-16383" ## The header is all we need from a .zsync

type
  Page = enum PageInstalled, PageBrowse

  UpdateState = enum
    Unchecked, Checking, UpToDate, UpdateAvailable, NoSource, CheckFailed, Updating

  UpdateStatus = object
    state: UpdateState
    message: string       ## Error text or a note
    asset: ReleaseAsset   ## The newer build, when one is available
    sha1: string          ## Expected SHA-1 of that build, when known
    progress: float

viewable App:
  cfg: Config
  apps: seq[AppImage]
  embedded: Table[string, string] ## AppImage path -> embedded update info
  drafts: Table[string, string] ## AppImage path -> alias being edited
  status: string
  statusIsError: bool

  page: Page
  catalogs: array[CatalogSource, seq[CatalogApp]] ## Downloaded catalogs
  catalogLoading: set[CatalogSource]
  catalogResults: seq[CatalogApp] ## Matches in the selected catalog
  githubResults: seq[CatalogApp]
  githubSearches: int             ## Discards replies to outdated searches
  searchLoading: bool
  searchError: string
  query: string
  source: CatalogSource           ## Where Browse searches
  installing: Table[string, float] ## repo -> download progress (< 0: looking up)

  updates: Table[string, UpdateStatus] ## AppImage path -> update status
  sourceDrafts: Table[string, string]  ## AppImage path -> update source being edited
  checkQueue: seq[string]
  checksRunning: int

proc rescan(app: AppState) =
  app.apps = findAppImages(app.cfg)
  app.embedded.clear()
  for a in app.apps:
    app.embedded[a.path] = readUpdateInfo(a.path)

var redrawQueued = false

proc refresh(app: AppState) =
  ## Redraws after a background job changed the state. Deferred to an idle
  ## callback: redrawing synchronously inside an event handler would free
  ## the handler's own event object, and this also coalesces the updates of
  ## several downloads into one redraw.
  if redrawQueued: return
  redrawQueued = true
  discard addGlobalIdleTask(proc(): bool =
    redrawQueued = false
    discard app.redraw()
    false)

proc report(app: AppState, notes: seq[string], success: string) =
  app.statusIsError = false
  app.status = (@[success] & notes).join("\n")

proc fail(app: AppState, msg: string) =
  app.statusIsError = true
  app.status = msg

proc commit(app: AppState, success: string) =
  try:
    app.report(apply(app.cfg), success)
  except OSError, IOError:
    app.fail("Could not write aliases: " & getCurrentExceptionMsg())

proc save(app: AppState) =
  try:
    saveConfig(app.cfg)
  except OSError, IOError:
    app.fail("Could not save settings: " & getCurrentExceptionMsg())

proc draftFor(app: AppState, path: string): string =
  if path in app.drafts: app.drafts[path] else: app.cfg.aliasFor(path)

proc effectiveAlias(app: AppState, path: string): string =
  ## What saving the row would assign: the typed text, or the suggested
  ## alias when the entry is empty and nothing is assigned yet.
  result = app.draftFor(path).strip
  if result.len == 0 and app.cfg.aliasFor(path).len == 0 and
      path notin app.drafts:
    result = suggestAlias(path.extractFilename)

proc tildify(path: string): string =
  let home = getHomeDir().strip(leading = false, chars = {'/'})
  if path == home or path.startsWith(home & "/"): "~" & path[home.len .. ^1]
  else: path

proc copyToClipboard(text: string) =
  gdk_clipboard_set_text(gdk_display_get_clipboard(gdk_display_get_default()),
                         text.cstring, text.len.cint)

proc saveAlias(app: AppState, path, alias: string) =
  var cfg = app.cfg
  try:
    cfg.setAlias(path, alias)
  except AliasError:
    app.fail(getCurrentExceptionMsg())
    return
  app.cfg = cfg
  app.drafts.del(path)
  let shadow = if alias.len > 0: cfg.shadowedCommand(alias) else: ""
  var msg =
    if alias.len == 0: "Removed alias for " & path.extractFilename
    else: "'" & alias & "' now launches " & path.extractFilename
  if shadow.len > 0:
    msg.add(" (note: shadows " & shadow & " depending on PATH order)")
  app.commit(msg)

proc pathHint(app: AppState): string =
  if app.cfg.binDirOnPath:
    "Aliases live in " & app.cfg.binDir & " (on your PATH)"
  elif app.cfg.pathSnippetInstalled:
    "Aliases live in " & app.cfg.binDir &
      " — open a new terminal (or log out and back in) to pick up the PATH change"
  else:
    "Aliases live in " & app.cfg.binDir &
      " — save an alias to add this folder to your PATH"

# ---------------------------------------------------------------------------
# Updates

proc statusOf(app: AppState, path: string): UpdateStatus =
  app.updates.getOrDefault(path)

proc failed(msg: string): UpdateStatus =
  UpdateStatus(state: CheckFailed, message: msg)

proc recordInstall(app: AppState, path: string, asset: ReleaseAsset) =
  ## Remembers which release build is installed at `path`.
  if asset.id == 0: return
  var info = app.cfg.installFor(path)
  info.tag = asset.tag
  info.asset = asset.name
  info.assetId = asset.id
  app.cfg.installs[path] = info
  app.save()

proc embeddedInfo(app: AppState, path: string): string =
  if path notin app.embedded:
    app.embedded[path] = readUpdateInfo(path)
  app.embedded[path]

proc sourceOf(app: AppState, path: string): UpdateSource =
  updateSourceFor(app.cfg.installFor(path), app.embeddedInfo(path))

proc checkUpdate(app: AppState, path: string, done: proc() = nil) =
  ## Finds out whether a newer build of the AppImage at `path` exists: by
  ## comparing its SHA-1 with the release's .zsync file when there is one,
  ## otherwise by comparing the release asset with the installed one.
  proc finish(st: UpdateStatus) =
    app.updates[path] = st
    if done != nil: done()
    app.refresh()
  if not fileExists(path):
    finish(failed("the file is missing"))
    return
  let info = app.cfg.installFor(path)
  app.updates[path] = UpdateStatus(state: Checking)

  proc viaZsync(zsyncUrl: string, asset: ReleaseAsset) =
    fetchText(zsyncUrl, proc(text, error: string) =
      if error.len > 0:
        finish(failed(error))
        return
      let z = parseZsync(text, zsyncUrl)
      if z.sha1.len != 40 or z.url.len == 0:
        finish(failed("could not read " & zsyncUrl))
        return
      sha1Async(path, proc(sha1, error: string) =
        if error.len > 0:
          finish(failed(error))
        elif sha1 == z.sha1:
          app.recordInstall(path, asset)
          finish(UpdateStatus(state: UpToDate))
        else:
          var newer = asset
          newer.url = z.url
          if newer.name.len == 0: newer.name = z.filename
          if z.length > 0: newer.size = z.length
          finish(UpdateStatus(state: UpdateAvailable, asset: newer, sha1: z.sha1))),
      ZsyncHeaderRange)

  let src = app.sourceOf(path)
  case src.kind
  of NoUpdateSource:
    finish(UpdateStatus(state: NoSource))
  of ZsyncUrl:
    viaZsync(src.url, ReleaseAsset())
  of GitHubReleases:
    let repo = src.owner & "/" & src.repo
    fetchJson(releasesUrl(repo, src.tag), proc(node: JsonNode, error: string) =
      if error.len > 0:
        finish(failed(error))
        return
      let previous = if info.asset.len > 0: info.asset else: path.extractFilename
      let asset = pickRelease(node, src.tag, src.pattern, previous)
      let size = try: getFileSize(path) except OSError: -1
      if asset.name.len == 0:
        finish(failed("no AppImage for this computer in " & repo & "'s releases"))
      elif info.assetId != 0 and info.assetId == asset.id:
        finish(UpdateStatus(state: UpToDate))
      elif asset.zsyncUrl.len > 0:
        viaZsync(asset.zsyncUrl, asset)
      elif info.assetId == 0 and asset.name == path.extractFilename and
          asset.size == size:
        app.recordInstall(path, asset)
        finish(UpdateStatus(state: UpToDate))
      else:
        finish(UpdateStatus(state: UpdateAvailable, asset: asset)))

proc checkSummary(app: AppState): string =
  var counts: array[UpdateState, int]
  for a in app.apps:
    inc counts[app.statusOf(a.path).state]
  var parts: seq[string]
  if counts[UpdateAvailable] > 0: parts.add($counts[UpdateAvailable] & " update(s) available")
  if counts[UpToDate] > 0: parts.add($counts[UpToDate] & " up to date")
  if counts[NoSource] > 0: parts.add($counts[NoSource] & " without an update source")
  if counts[CheckFailed] > 0: parts.add($counts[CheckFailed] & " could not be checked")
  if parts.len == 0: "Nothing to check" else: parts.join(", ")

proc pumpChecks(app: AppState) =
  while app.checksRunning < MaxParallelChecks and app.checkQueue.len > 0:
    let path = app.checkQueue[0]
    app.checkQueue.delete(0)
    inc app.checksRunning
    app.checkUpdate(path, proc() =
      dec app.checksRunning
      if app.checksRunning == 0 and app.checkQueue.len == 0:
        app.report(@[], app.checkSummary())
      app.pumpChecks())

proc checkAll(app: AppState) =
  for a in app.apps:
    if a.path notin app.checkQueue and
        app.statusOf(a.path).state notin {Checking, Updating}:
      app.checkQueue.add(a.path)
      app.updates[a.path] = UpdateStatus(state: Checking)
  app.pumpChecks()

proc isVersionTag(tag: string): bool =
  ## Rolling tags such as "continuous" or "release" say nothing about the
  ## version, so we show the file name instead.
  tag.contains(Digits)

proc applyUpdate(app: AppState, path: string) =
  ## Downloads the newer build next to the old one and swaps it in, so the
  ## path (and with it aliases and menu entries) stays the same.
  let st = app.statusOf(path)
  if st.state != UpdateAvailable: return
  let asset = st.asset
  let name = path.extractFilename
  let part = path.parentDir / "." & name & ".part"
  app.updates[path] = UpdateStatus(state: Updating, asset: asset, sha1: st.sha1)

  proc fail(msg: string) =
    removeFile(part)
    app.updates[path] = failed(msg)
    app.fail("Could not update " & name & ": " & msg)
    app.refresh()

  proc swapIn() =
    try:
      setFilePermissions(part, getFilePermissions(path) + {fpUserRead, fpUserWrite, fpUserExec})
      moveFile(part, path)
    except OSError:
      fail(getCurrentExceptionMsg())
      return
    app.recordInstall(path, asset)
    app.embedded[path] = readUpdateInfo(path)
    if isIntegrated(path):
      try: discard integrate(path)  # the icon may have changed
      except OSError, IOError: discard
    app.updates[path] = UpdateStatus(state: UpToDate, message: "Updated")
    app.report(@[], "Updated " & name &
               (if asset.tag.isVersionTag: " to " & asset.tag
                elif asset.name.len > 0 and asset.name != name: " to " & asset.name
                else: ""))
    app.refresh()

  download(asset.url, part,
    proc(error: string) =
      if error.len > 0:
        fail(error)
      elif st.sha1.len > 0:
        sha1Async(part, proc(sha1, error: string) =
          if sha1 != st.sha1: fail("the download is corrupt (SHA-1 mismatch)")
          else: swapIn())
      else:
        swapIn(),
    expected = asset.size,
    onProgress = proc(fraction: float) =
      if path in app.updates:
        app.updates[path].progress = fraction
        app.refresh())

proc setUpdateSource(app: AppState, path, text: string) =
  let text = text.strip
  if text.len > 0 and parseSourceSetting(text).kind == NoUpdateSource:
    app.fail("Update source must be a GitHub repository (owner/repo or its URL) or a .zsync URL")
    return
  var info = app.cfg.installFor(path)
  if info.source != text:
    info.source = text
    info.assetId = 0  # compare against the new source from scratch
  app.cfg.installs[path] = info
  app.sourceDrafts.del(path)
  app.save()
  app.report(@[], if text.len == 0: "Using the update information built into " & path.extractFilename
                  else: "Updates for " & path.extractFilename & " now come from " & text)
  app.checkUpdate(path)

proc updateLine(app: AppState, path: string): string =
  let info = app.cfg.installFor(path)
  let st = app.statusOf(path)
  var parts: seq[string]
  if info.tag.isVersionTag: parts.add(info.tag)
  case st.state
  of Unchecked: discard
  of Checking: parts.add("Checking for updates…")
  of UpToDate: parts.add(if st.message.len > 0: st.message else: "Up to date")
  of UpdateAvailable:
    let newer = if st.asset.tag.isVersionTag and st.asset.tag != info.tag: st.asset.tag
                else: st.asset.name
    parts.add("Update available" & (if newer.len > 0: ": " & newer else: ""))
  of NoSource: parts.add("No update source (set one in the ⋯ menu)")
  of CheckFailed: parts.add("Update check failed: " & st.message)
  of Updating: parts.add("Downloading update… " & $int(st.progress * 100) & "%")
  parts.join(" · ")

# ---------------------------------------------------------------------------
# Menu entries and deleting

proc toggleMenuEntry(app: AppState, path: string) =
  let name = path.extractFilename
  try:
    if unintegrate(path):
      app.report(@[], "Removed " & name & " from the app menu")
    else:
      discard integrate(path)
      app.report(@[], "Added " & name & " to the app menu")
    refreshMenus()
  except OSError, IOError:
    app.fail("Could not change the menu entry: " & getCurrentExceptionMsg())

proc uninstall(app: AppState, path: string) =
  let name = path.extractFilename
  let (res, _) = app.open: gui:
    MessageDialog:
      message = "Delete " & name & "?\n\nThis removes the file, its alias and its app menu entry."
      DialogButton {.addButton.}:
        text = "Cancel"
        res = DialogCancel
      DialogButton {.addButton.}:
        text = "Delete"
        res = DialogAccept
        style = [ButtonDestructive]
  if res.kind != DialogAccept: return
  try:
    if fileExists(path): removeFile(path)
  except OSError:
    app.fail("Could not delete " & path & ": " & getCurrentExceptionMsg())
    return
  if unintegrate(path): refreshMenus()
  let hadAlias = app.cfg.aliasFor(path).len > 0
  app.cfg.forget(path)
  app.updates.del(path)
  app.drafts.del(path)
  app.sourceDrafts.del(path)
  app.rescan()
  if hadAlias:
    app.commit("Deleted " & name)  # also removes its launcher
  else:
    app.save()
    app.report(@[], "Deleted " & name)

# ---------------------------------------------------------------------------
# Browsing and installing

proc refreshCatalog(app: AppState) =
  if app.source.isCatalog:
    app.catalogResults = searchCatalog(app.catalogs[app.source], app.query, int.high)

proc loadCatalog(app: AppState, source: CatalogSource, force = false) =
  ## Loads a catalog from its daily cache, downloading it when the cache is
  ## missing or stale (or when `force` is set).
  if not source.isCatalog or source in app.catalogLoading: return
  let cache = catalogCachePath(source)
  proc useCache(): bool =
    try:
      let apps = parseCatalog(source, readFile(cache))
      if apps.len == 0: return false
      app.catalogs[source] = apps
      app.refreshCatalog()
      true
    except CatchableError:
      false
  if not force and catalogIsFresh(cache) and useCache(): return
  app.catalogLoading.incl(source)
  app.searchError = ""
  let part = cache & ".part"
  try: createDir(cache.parentDir)
  except OSError: discard
  download(catalogUrl(source), part, proc(error: string) =
    app.catalogLoading.excl(source)
    if error.len == 0:
      try: moveFile(part, cache)
      except OSError: discard
    # A stale copy beats nothing when we're offline.
    if not useCache() and source == app.source:
      app.searchError = "Could not load the " & $source & " catalog" &
        (if error.len > 0: ": " & error else: "")
    app.refresh())

proc searchGitHub(app: AppState) =
  let q = app.query.strip
  inc app.githubSearches
  let id = app.githubSearches
  app.githubResults = @[]
  app.searchError = ""
  if q.len == 0:
    app.searchLoading = false
    return
  app.searchLoading = true
  fetchJson(githubSearchUrl(q), proc(node: JsonNode, error: string) =
    if id != app.githubSearches: return
    app.searchLoading = false
    if error.len > 0: app.searchError = "GitHub search failed: " & error
    else: app.githubResults = parseGitHubSearch(node)
    app.refresh())

proc installedRepos(app: AppState): HashSet[string] =
  for path, info in app.cfg.installs:
    let src = parseSourceSetting(info.source)
    if src.kind == GitHubReleases and fileExists(path):
      result.incl((src.owner & "/" & src.repo).toLowerAscii)

proc finishInstall(app: AppState, dest, repo: string, asset: ReleaseAsset) =
  ## Records a freshly downloaded AppImage, adds it to the app menu and
  ## gives it an alias when the obvious one is free.
  var notes: seq[string]
  app.cfg.installs[dest] = InstallInfo(source: repo, tag: asset.tag,
                                       asset: asset.name, assetId: asset.id)
  if not app.cfg.scanDirs.anyIt(expandTilde(it).normalizedPath == dest.parentDir.normalizedPath):
    app.cfg.scanDirs.add(dest.parentDir)
  try:
    discard integrate(dest)
    refreshMenus()
  except OSError, IOError:
    notes.add("Could not add it to the app menu: " & getCurrentExceptionMsg())
  let alias = suggestAlias(dest.extractFilename)
  var msg = "Installed " & asset.name
  var aliased = false
  if alias.len > 0 and not app.cfg.aliases.hasKey(alias) and
      app.cfg.shadowedCommand(alias).len == 0:
    try:
      app.cfg.setAlias(dest, alias)
      aliased = true
      msg.add(" — run it with '" & alias & "' or from your app menu")
    except AliasError:
      discard
  app.rescan()
  app.updates[dest] = UpdateStatus(state: UpToDate)
  if not aliased:
    app.save()
    app.report(notes, msg)
    return
  try:
    app.report(apply(app.cfg) & notes, msg)
  except OSError, IOError:
    app.fail("Installed " & asset.name & " but could not write aliases: " &
             getCurrentExceptionMsg())

proc install(app: AppState, item: CatalogApp) =
  ## Downloads the newest AppImage release of `item` into ~/Applications.
  let repo = item.repo
  if repo in app.installing: return
  app.installing[repo] = -1

  proc fail(msg: string) =
    app.installing.del(repo)
    app.fail(msg)
    app.refresh()

  fetchJson(releasesUrl(repo), proc(node: JsonNode, error: string) =
    if error.len > 0:
      fail("Could not look up " & repo & ": " & error)
      return
    let asset = pickRelease(node)
    if asset.name.len == 0:
      fail(repo & " has no AppImage release for this computer")
      return
    let dir = defaultInstallDir()
    let dest = dir / asset.name
    if fileExists(dest):
      fail(tildify(dest) & " already exists")
      return
    try:
      createDir(dir)
    except OSError:
      fail("Could not create " & dir & ": " & getCurrentExceptionMsg())
      return
    let part = dir / "." & asset.name & ".part"
    app.installing[repo] = 0
    app.refresh()
    download(asset.url, part,
      proc(error: string) =
        if error.len > 0:
          fail("Could not download " & asset.name & ": " & error)
          return
        try:
          setFilePermissions(part, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead,
                                    fpGroupExec, fpOthersRead, fpOthersExec})
          moveFile(part, dest)
        except OSError:
          removeFile(part)
          fail("Could not install " & asset.name & ": " & getCurrentExceptionMsg())
          return
        app.installing.del(repo)
        app.finishInstall(dest, repo, asset)
        app.refresh(),
      expected = asset.size,
      onProgress = proc(fraction: float) =
        if repo in app.installing:
          app.installing[repo] = fraction
          app.refresh()))

proc results(app: AppState): seq[CatalogApp] =
  if app.source.isCatalog: app.catalogResults else: app.githubResults

proc selectSource(app: AppState, source: CatalogSource) =
  app.source = source
  app.searchError = ""
  if source.isCatalog:
    app.refreshCatalog()
    if app.catalogs[source].len == 0: app.loadCatalog(source)
  elif app.query.strip.len > 0:
    app.searchGitHub()

proc describe(item: CatalogApp): string =
  var parts = @[item.repo]
  if item.categories.len > 0: parts.add(item.categories[0 ..< min(3, item.categories.len)].join(", "))
  if item.stars >= 0: parts.add("★ " & $item.stars)
  if item.license.len > 0: parts.add(item.license)
  parts.join(" · ")

proc switchTo(app: AppState, page: Page) =
  app.page = page
  if page == PageBrowse and app.source.isCatalog and app.catalogs[app.source].len == 0:
    app.loadCatalog(app.source)

method view(app: AppState): Widget =
  result = gui:
    Window:
      title = "AppImage Manager"
      defaultSize = (880, 560)
      # Shown by the "icon" button of the titlebar decoration layout; without
      # one GTK draws a missing-image placeholder there.
      iconName = AppId

      HeaderBar {.addTitlebar.}:
        Box(orient = OrientX) {.addTitle.}:
          style = [StyleClass("linked")]
          ToggleButton:
            text = "Installed"
            state = app.page == PageInstalled
            proc changed(state: bool) =
              if state: app.switchTo(PageInstalled)
          ToggleButton:
            text = "Browse"
            state = app.page == PageBrowse
            proc changed(state: bool) =
              if state: app.switchTo(PageBrowse)

        Button {.addLeft.}:
          icon = "view-refresh-symbolic"
          tooltip = if app.page == PageInstalled: "Rescan for AppImages"
                    elif app.source.isCatalog: "Reload the " & $app.source & " catalog"
                    else: "Search GitHub again"
          proc clicked() =
            if app.page == PageInstalled:
              app.rescan()
              app.report(@[], "Found " & $app.apps.len & " AppImage(s)")
            elif app.source.isCatalog:
              app.loadCatalog(app.source, force = true)
            else:
              app.searchGitHub()

        MenuButton {.addRight.}:
          icon = "folder-symbolic"
          tooltip = "Folders to scan"
          Popover:
            Box(orient = OrientY, spacing = 4, margin = 8, sizeRequest = (360, -1)):
              Label {.expand: false.}:
                text = "Folders scanned for AppImages"
                xAlign = 0
                style = [LabelHeading]
              for i, dir in app.cfg.scanDirs:
                Box(orient = OrientX, spacing = 6) {.expand: false.}:
                  Label:
                    text = tildify(dir)
                    xAlign = 0
                    ellipsize = EllipsizeMiddle
                  Button {.expand: false.}:
                    icon = "list-remove-symbolic"
                    tooltip = "Stop scanning this folder"
                    style = [ButtonFlat]
                    proc clicked() =
                      app.cfg.scanDirs.delete(i)
                      saveConfig(app.cfg)
                      app.rescan()
              Box(orient = OrientX) {.expand: false.}:
                Button {.expand: false.}:
                  text = "Add folder…"
                  proc clicked() =
                    let (res, state) = app.open: gui:
                      FileChooserDialog:
                        title = "Scan a folder for AppImages"
                        action = FileChooserSelectFolder
                        DialogButton {.addButton.}:
                          text = "Cancel"
                          res = DialogCancel
                        DialogButton {.addButton.}:
                          text = "Add"
                          res = DialogAccept
                          style = [ButtonSuggested]
                    if res.kind == DialogAccept:
                      for dir in FileChooserDialogState(state).filenames:
                        if dir notin app.cfg.scanDirs:
                          app.cfg.scanDirs.add(dir)
                      saveConfig(app.cfg)
                      app.rescan()

        if app.page == PageInstalled:
          Button {.addRight.}:
            text = "Check for updates"
            tooltip = "Check all AppImages for updates"
            sensitive = app.checkQueue.len == 0 and app.checksRunning == 0
            proc clicked() =
              app.checkAll()

      Box(orient = OrientY, spacing = 8, margin = 12):
        if app.page == PageInstalled:
          Box(orient = OrientX, spacing = 6) {.expand: false.}:
            Label:
              text = app.pathHint()
              xAlign = 0
              wrap = true
              style = [StyleClass("dim-label")]
            Button {.expand: false.}:
              icon = "edit-copy-symbolic"
              tooltip = "Copy folder path"
              style = [ButtonFlat]
              proc clicked() =
                copyToClipboard(app.cfg.binDir)
                app.report(@[], "Copied " & app.cfg.binDir)

          if app.apps.len == 0:
            Label:
              text = "No AppImages found.\nPut them in ~/Applications, add a folder to scan, or install one from Browse."
              style = [StyleClass("dim-label")]
          else:
            Frame:
              ScrolledWindow:
                ListBox:
                  selectionMode = SelectionNone
                  for appImage in app.apps:
                    let
                      path = appImage.path
                      saved = app.cfg.aliasFor(path)
                      draft = app.draftFor(path)
                      effective = app.effectiveAlias(path)
                      missing = not fileExists(path)
                      valid = effective.len == 0 or isValidAlias(effective)
                      update = app.statusOf(path)
                      updateText = app.updateLine(path)
                      embeddedSource = parseUpdateInfo(app.embeddedInfo(path))
                      sourceDraft = app.sourceDrafts.getOrDefault(path, app.cfg.installFor(path).source)
                      integrated = isIntegrated(path)
                    Box(orient = OrientX, spacing = 8, margin = 8):
                      Box(orient = OrientY, spacing = 2):
                        Label:
                          text = appImage.name & (if missing: "  (missing)" else: "")
                          xAlign = 0
                          ellipsize = EllipsizeEnd
                          style = [LabelHeading]
                        Label:
                          text = path
                          xAlign = 0
                          ellipsize = EllipsizeMiddle
                          tooltip = path
                          style = [StyleClass("dim-label"), StyleClass("caption")]
                        if updateText.len > 0:
                          Label:
                            text = updateText
                            xAlign = 0
                            ellipsize = EllipsizeEnd
                            tooltip = updateText
                            style = (if update.state == CheckFailed: [StyleClass("error"), StyleClass("caption")]
                                     elif update.state == UpdateAvailable: [StyleClass("accent"), StyleClass("caption")]
                                     else: [StyleClass("dim-label"), StyleClass("caption")])
                      Button {.expand: false, vAlign: AlignCenter.}:
                        icon = "edit-copy-symbolic"
                        tooltip = "Copy AppImage path"
                        style = [ButtonFlat]
                        proc clicked() =
                          copyToClipboard(path)
                          app.report(@[], "Copied " & path)
                      Entry {.expand: false, vAlign: AlignCenter.}:
                        text = draft
                        placeholder = suggestAlias(path.extractFilename)
                        sizeRequest = (170, -1)
                        tooltip = if valid: "Command used to launch this AppImage (Enter to save)"
                                  else: "Use letters, digits, '-', '_', '.' or '+'"
                        if not valid:
                          style = [EntryError]
                        proc changed(text: string) =
                          app.drafts[path] = text
                        proc activate() =
                          app.saveAlias(path, app.effectiveAlias(path))
                      Button {.expand: false, vAlign: AlignCenter.}:
                        icon = "object-select-symbolic"
                        tooltip = "Save alias"
                        style = [ButtonSuggested]
                        sensitive = valid and effective != saved
                        proc clicked() =
                          app.saveAlias(path, app.effectiveAlias(path))
                      Button {.expand: false, vAlign: AlignCenter.}:
                        icon = "edit-clear-symbolic"
                        tooltip = "Remove alias"
                        sensitive = saved.len > 0
                        proc clicked() =
                          app.saveAlias(path, "")
                      case update.state
                      of Checking:
                        Spinner {.expand: false, vAlign: AlignCenter.}:
                          spinning = true
                          tooltip = "Checking for updates…"
                      of Updating:
                        ProgressBar {.expand: false, vAlign: AlignCenter.}:
                          fraction = update.progress
                          sizeRequest = (60, -1)
                          tooltip = "Downloading update…"
                      of UpdateAvailable:
                        Button {.expand: false, vAlign: AlignCenter.}:
                          text = "Update"
                          tooltip = "Download " & (if update.asset.name.len > 0: update.asset.name
                                                   else: "the new version")
                          style = [ButtonSuggested]
                          proc clicked() =
                            app.applyUpdate(path)
                      else:
                        discard
                      MenuButton {.expand: false, vAlign: AlignCenter.}:
                        icon = "view-more-symbolic"
                        tooltip = "More actions"
                        style = [ButtonFlat]
                        Popover:
                          Box(orient = OrientY, spacing = 6, margin = 8, sizeRequest = (340, -1)):
                            Button {.expand: false.}:
                              text = "Check for updates"
                              sensitive = not missing and update.state notin {Checking, Updating}
                              proc clicked() =
                                app.checkUpdate(path)
                            Label {.expand: false.}:
                              text = "Update source"
                              xAlign = 0
                              style = [LabelHeading]
                            Box(orient = OrientX, spacing = 6) {.expand: false.}:
                              Entry:
                                text = sourceDraft
                                placeholder = if embeddedSource.kind != NoUpdateSource:
                                                "Built in: " & $embeddedSource
                                              else: "owner/repo or .zsync URL"
                                tooltip = "A GitHub repository or .zsync URL to update from. " &
                                          "Leave empty to use the AppImage's built-in update information."
                                proc changed(text: string) =
                                  app.sourceDrafts[path] = text
                                proc activate() =
                                  app.setUpdateSource(path, sourceDraft)
                              Button {.expand: false.}:
                                icon = "object-select-symbolic"
                                tooltip = "Save update source"
                                proc clicked() =
                                  app.setUpdateSource(path, sourceDraft)
                            Separator {.expand: false.}
                            Button {.expand: false.}:
                              text = if integrated: "Remove from app menu" else: "Add to app menu"
                              sensitive = not missing
                              proc clicked() =
                                app.toggleMenuEntry(path)
                            Button {.expand: false.}:
                              text = "Delete…"
                              style = [ButtonDestructive]
                              proc clicked() =
                                app.uninstall(path)

        else:
          let items = app.results()
          let installed = app.installedRepos()
          Box(orient = OrientX, spacing = 6) {.expand: false.}:
            SearchEntry:
              text = app.query
              tooltip = if app.source.isCatalog: "Filter the " & $app.source & " catalog"
                        else: "Press Enter to search GitHub"
              proc changed(query: string) =
                app.query = query
                app.refreshCatalog()
              proc activate() =
                if not app.source.isCatalog: app.searchGitHub()
            DropDown {.expand: false.}:
              items = CatalogSource.toSeq.mapIt($it)
              selected = ord(app.source)
              tooltip = "AppImageHub: the community catalog · pkgforge-dev: self-contained " &
                        "Anylinux AppImages that run on any distro · GitHub: search all repositories"
              proc select(item: int) =
                app.selectSource(CatalogSource(item))

          if app.source in app.catalogLoading or app.searchLoading:
            Box(orient = OrientX, spacing = 8) {.expand: false.}:
              Spinner {.expand: false.}:
                spinning = true
              Label:
                text = if app.source.isCatalog: "Loading the " & $app.source & " catalog…"
                       else: "Searching GitHub…"
                xAlign = 0
                style = [StyleClass("dim-label")]

          if app.searchError.len > 0:
            Label {.expand: false.}:
              text = app.searchError
              xAlign = 0
              wrap = true
              style = [StyleClass("error")]

          if items.len == 0:
            if app.source notin app.catalogLoading and not app.searchLoading:
              Label:
                text = if app.source == FromGitHub and app.query.strip.len == 0:
                         "Type a name and press Enter to search GitHub for projects that publish AppImages."
                       elif app.source == FromGitHub and app.searchError.len == 0: "No GitHub projects found."
                       elif app.source.isCatalog and app.catalogs[app.source].len > 0: "No apps match your search."
                       else: ""
                wrap = true
                style = [StyleClass("dim-label")]
          else:
            Label {.expand: false.}:
              text = (if items.len > MaxResults: "Showing " & $MaxResults & " of " & $items.len &
                        " matches — type to narrow down"
                      else: $items.len & " app(s)") &
                     " · installs go to " & tildify(defaultInstallDir())
              xAlign = 0
              style = [StyleClass("dim-label"), StyleClass("caption")]
            Frame:
              ScrolledWindow:
                ListBox:
                  selectionMode = SelectionNone
                  for item in items[0 ..< min(items.len, MaxResults)]:
                    let repo = item.repo
                    Box(orient = OrientX, spacing = 8, margin = 8):
                      Box(orient = OrientY, spacing = 2):
                        Label:
                          text = item.name
                          xAlign = 0
                          ellipsize = EllipsizeEnd
                          style = [LabelHeading]
                        if item.summary.len > 0:
                          Label:
                            text = item.summary
                            xAlign = 0
                            ellipsize = EllipsizeEnd
                            tooltip = item.summary
                        Label:
                          text = describe(item)
                          xAlign = 0
                          ellipsize = EllipsizeEnd
                          style = [StyleClass("dim-label"), StyleClass("caption")]
                      LinkButton {.expand: false, vAlign: AlignCenter.}:
                        text = "GitHub"
                        uri = "https://github.com/" & repo
                        tooltip = "Open github.com/" & repo
                      if repo.toLowerAscii in installed:
                        Button {.expand: false, vAlign: AlignCenter.}:
                          text = "Installed"
                          sensitive = false
                      elif repo in app.installing:
                        if app.installing[repo] < 0:
                          Spinner {.expand: false, vAlign: AlignCenter.}:
                            spinning = true
                            tooltip = "Looking for the latest release…"
                        else:
                          ProgressBar {.expand: false, vAlign: AlignCenter.}:
                            fraction = app.installing[repo]
                            sizeRequest = (80, -1)
                            tooltip = "Downloading…"
                      else:
                        Button {.expand: false, vAlign: AlignCenter.}:
                          text = "Install"
                          style = [ButtonSuggested]
                          tooltip = "Download the latest AppImage release into " &
                                    tildify(defaultInstallDir())
                          proc clicked() =
                            app.install(item)

        if app.status.len > 0:
          Label {.expand: false.}:
            text = app.status
            xAlign = 0
            wrap = true
            style = (if app.statusIsError: [StyleClass("error")]
                     else: [StyleClass("success")])

const AppIconSvg = staticRead("../data/icons/hicolor/scalable/apps/" & AppId & ".svg")

proc g_set_prgname(name: cstring) {.importc, cdecl.}
proc gtk_window_set_default_icon_name(name: cstring) {.importc, cdecl.}

proc sourceIconDirs(): seq[string] =
  ## When run from a checkout (`./appmanager` or `src/appmanager`) the icon
  ## isn't installed, so point GTK at the repo's hicolor tree. GTK only builds
  ## window icons from theme directories, hence the hicolor layout.
  for dir in [getAppDir() / "data" / "icons", getAppDir() / ".." / "data" / "icons"]:
    if fileExists(dir / "hicolor" / "scalable" / "apps" / AppId & ".svg"):
      result.add(dir.normalizedPath)

proc embeddedIconDir(): seq[string] =
  ## Fallback for a binary installed without its icon (e.g. `nimble install`):
  ## write the icon compiled into the binary to a private hicolor tree, so the
  ## titlebar and window icon never fall back to a placeholder.
  let
    dir = getCacheDir("appmanager") / "icons"
    file = dir / "hicolor" / "scalable" / "apps" / AppId & ".svg"
  try:
    if not fileExists(file) or readFile(file) != AppIconSvg:
      createDir(file.parentDir)
      writeFile(file, AppIconSvg)
    result.add(dir)
  except OSError, IOError:
    discard

when isMainModule:
  let cfg = loadConfig()
  # Without this the X11 WM_CLASS is the binary name ("AppRun.wrapped" inside
  # the AppImage), so docks can't match the window to our .desktop file's
  # StartupWMClass and show a generic icon.
  g_set_prgname(AppId)
  gtk_window_set_default_icon_name(AppId)
  brew(AppId, gui(App(cfg = cfg, apps = findAppImages(cfg))),
       icons = sourceIconDirs() & embeddedIconDir())
