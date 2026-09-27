## appmanager: a small GTK4 GUI for giving installed AppImages a command-line
## alias and putting those aliases on PATH.

import std/[os, strutils, tables]
import owlkettle
import owlkettle/bindings/gtk
import appmanager/core

const AppId = "dev.appmanager.AppManager"

proc gtk_label_set_selectable(label: GtkWidget, setting: cbool) {.importc, cdecl.}

renderable SelectableLabel of BaseWidget:
  ## Label whose text can be selected and copied (owlkettle's Label can't).
  text: string
  xAlign: float = 0.5
  ellipsize: EllipsizeMode

  hooks:
    beforeBuild:
      state.internalWidget = gtk_label_new("")
      gtk_label_set_selectable(state.internalWidget, cbool(1))

  hooks text:
    property:
      gtk_label_set_text(state.internalWidget, state.text.cstring)

  hooks xAlign:
    property:
      gtk_label_set_xalign(state.internalWidget, state.xAlign.cfloat)

  hooks ellipsize:
    property:
      gtk_label_set_ellipsize(state.internalWidget,
                              PangoEllipsizeMode(ord(state.ellipsize)))

viewable App:
  cfg: Config
  apps: seq[AppImage]
  drafts: Table[string, string] ## AppImage path -> alias being edited
  status: string
  statusIsError: bool

proc rescan(app: AppState) =
  app.apps = findAppImages(app.cfg)

proc report(app: AppState, notes: seq[string], success: string) =
  app.statusIsError = false
  app.status = if notes.len > 0: notes.join("\n") else: success

proc fail(app: AppState, msg: string) =
  app.statusIsError = true
  app.status = msg

proc commit(app: AppState, success: string) =
  try:
    app.report(apply(app.cfg), success)
  except OSError, IOError:
    app.fail("Could not write aliases: " & getCurrentExceptionMsg())

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
    "Aliases live in " & tildify(app.cfg.binDir) & " (on your PATH)"
  elif app.cfg.pathSnippetInstalled:
    "Aliases live in " & tildify(app.cfg.binDir) &
      " — open a new terminal (or log out and back in) to pick up the PATH change"
  else:
    "Aliases live in " & tildify(app.cfg.binDir) &
      " — save an alias to add this folder to your PATH"

method view(app: AppState): Widget =
  result = gui:
    Window:
      title = "AppImage Aliases"
      defaultSize = (760, 520)
      # Shown by the "icon" button of the titlebar decoration layout; without
      # one GTK draws a missing-image placeholder there.
      iconName = AppId

      HeaderBar {.addTitlebar.}:
        Button {.addLeft.}:
          icon = "view-refresh-symbolic"
          tooltip = "Rescan for AppImages"
          proc clicked() =
            app.rescan()
            app.report(@[], "Found " & $app.apps.len & " AppImage(s)")

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

      Box(orient = OrientY, spacing = 8, margin = 12):
        Box(orient = OrientX, spacing = 8) {.expand: false.}:
          Label:
            text = app.pathHint()
            xAlign = 0
            wrap = true
            style = [StyleClass("dim-label")]
          Button {.expand: false.}:
            text = "Change…"
            tooltip = "Choose the folder aliases are written to"
            proc clicked() =
              let (res, state) = app.open: gui:
                FileChooserDialog:
                  title = "Folder for alias launchers"
                  action = FileChooserSelectFolder
                  DialogButton {.addButton.}:
                    text = "Cancel"
                    res = DialogCancel
                  DialogButton {.addButton.}:
                    text = "Use Folder"
                    res = DialogAccept
                    style = [ButtonSuggested]
              if res.kind == DialogAccept:
                let files = FileChooserDialogState(state).filenames
                if files.len > 0:
                  var cfg = app.cfg
                  try:
                    cfg.setBinDir(files[0])
                  except OSError:
                    app.fail("Could not clean up old aliases: " &
                             getCurrentExceptionMsg())
                    return
                  app.cfg = cfg
                  app.rescan()
                  app.commit("Aliases now live in " & tildify(cfg.binDir))

        if app.apps.len == 0:
          Label:
            text = "No AppImages found.\nPut them in ~/Applications or add a folder to scan."
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
                  Box(orient = OrientX, spacing = 8, margin = 8):
                    Box(orient = OrientY, spacing = 2):
                      Label:
                        text = appImage.name & (if missing: "  (missing)" else: "")
                        xAlign = 0
                        ellipsize = EllipsizeEnd
                        style = [LabelHeading]
                      SelectableLabel:
                        text = path
                        xAlign = 0
                        ellipsize = EllipsizeMiddle
                        tooltip = path
                        style = [StyleClass("dim-label"), StyleClass("caption")]
                    Entry {.expand: false.}:
                      text = draft
                      placeholder = suggestAlias(path.extractFilename)
                      sizeRequest = (180, -1)
                      tooltip = if valid: "Command used to launch this AppImage (Enter to save)"
                                else: "Use letters, digits, '-', '_', '.' or '+'"
                      if not valid:
                        style = [EntryError]
                      proc changed(text: string) =
                        app.drafts[path] = text
                      proc activate() =
                        app.saveAlias(path, app.effectiveAlias(path))
                    Button {.expand: false.}:
                      icon = "object-select-symbolic"
                      tooltip = "Save alias"
                      style = [ButtonSuggested]
                      sensitive = valid and effective != saved
                      proc clicked() =
                        app.saveAlias(path, app.effectiveAlias(path))
                    Button {.expand: false.}:
                      icon = "edit-clear-symbolic"
                      tooltip = "Remove alias"
                      sensitive = saved.len > 0
                      proc clicked() =
                        app.saveAlias(path, "")

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
