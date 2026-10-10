/// The window: an Installed page listing AppImages with their aliases and
/// update state, and a Browse page for finding new ones.
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart' show Icons, SelectableText;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import 'package:flatkit/flatkit.dart';

import 'controller.dart';
import 'core.dart';
import 'env.dart';
import 'store.dart';

class HomePage extends StatelessWidget {
  final AppController app;
  const HomePage(this.app, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final installed = app.page == AppPage.installed;
        final available =
            app.apps.where((a) => app.statusOf(a.path).state == UpdateState.updateAvailable).length;
        final c = KitTheme.of(context);
        return ColoredBox(
          color: c.background,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                decoration: BoxDecoration(
                  color: c.surface,
                  border: Border(bottom: BorderSide(color: c.border)),
                ),
                child: Row(children: [
                  Expanded(
                    child: Row(children: [
                      KitIconButton(
                        Icons.refresh,
                        tooltip: installed
                            ? 'Rescan for AppImages'
                            : app.source.isCatalog
                                ? 'Reload the ${app.source} catalog'
                                : 'Search GitHub again',
                        onPressed: app.reload,
                      ),
                    ]),
                  ),
                  KitSegmented<AppPage>(
                    segments: const [
                      (AppPage.installed, 'Installed'),
                      (AppPage.browse, 'Browse'),
                    ],
                    selected: app.page,
                    onChanged: app.switchTo,
                  ),
                  Expanded(
                    child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                      if (installed && available > 1) ...[
                        KitButton.primary('Update all ($available)', onPressed: app.updateAll),
                        const SizedBox(width: 6),
                      ],
                      if (installed) ...[
                        KitButton(
                          'Check for updates',
                          tooltip: 'Check all AppImages for updates',
                          onPressed: app.checking ? null : app.checkAll,
                        ),
                        const SizedBox(width: 4),
                      ],
                      KitIconButton(
                        Icons.folder_outlined,
                        tooltip: 'Folders to scan',
                        onPressed: () =>
                            showKitDialog<void>(context, (_) => _ScanFoldersDialog(app)),
                      ),
                      KitIconButton(
                        Icons.menu,
                        tooltip: 'Opening AppImages',
                        onPressed: () => showKitDialog<void>(context, (_) => _HandlerDialog(app)),
                      ),
                    ]),
                  ),
                ]),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: installed ? _InstalledPage(app) : _BrowsePage(app)),
                      if (app.status.isNotEmpty) _StatusBar(app),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

TextStyle _dim(BuildContext context, {bool small = false}) => KitText.dim(context, small: small);

TextStyle _heading(BuildContext context) => KitText.heading(context);

void _copy(AppController app, String text) {
  Clipboard.setData(ClipboardData(text: text));
  app.report([], 'Copied $text');
}

class _StatusBar extends StatelessWidget {
  final AppController app;
  const _StatusBar(this.app);

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final color = app.statusIsError ? c.danger : c.success;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: SelectableText(app.status, style: TextStyle(color: color))),
          KitIconButton(Icons.close, size: 16, tooltip: 'Dismiss', onPressed: app.dismissStatus),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Header dialogs

class _ScanFoldersDialog extends StatelessWidget {
  final AppController app;
  const _ScanFoldersDialog(this.app);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => KitDialog(
        title: 'Folders scanned for AppImages',
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, dir) in app.cfg.scanDirs.indexed)
                Row(children: [
                  Expanded(child: Text(tildify(dir), overflow: TextOverflow.ellipsis)),
                  KitIconButton(
                    Icons.remove_circle_outline,
                    tooltip: 'Stop scanning this folder',
                    onPressed: () => app.removeScanDir(i),
                  ),
                ]),
            ],
          ),
        ),
        actions: [
          KitButton(
            'Add folder…',
            onPressed: () async {
              final dir = await getDirectoryPath(confirmButtonText: 'Add');
              if (dir != null) app.addScanDir(dir);
            },
          ),
          KitButton('Close', onPressed: () => Navigator.pop(context)),
        ],
      ),
    );
  }
}

class _HandlerDialog extends StatelessWidget {
  final AppController app;
  const _HandlerDialog(this.app);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => KitDialog(
        title: 'Opening AppImages',
        width: 380,
        content: Text(app.handlerText()),
        actions: [
          KitButton.primary(
            'Open AppImages with AppManager',
            tooltip: 'Make AppManager the default app for AppImage files',
            onPressed: app.handler == '$appId.desktop' ? null : app.makeDefaultHandler,
          ),
          KitButton('Close', onPressed: () => Navigator.pop(context)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Installed

class _InstalledPage extends StatelessWidget {
  final AppController app;
  const _InstalledPage(this.app);

  @override
  Widget build(BuildContext context) {
    final strays = app.cfg.offerMove && !app.moveOfferHidden ? app.moveCandidates() : <String>[];
    final central = tildify(defaultInstallDir());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(child: Text(app.pathHint(), style: _dim(context))),
          KitIconButton(
            Icons.copy,
            size: 16,
            tooltip: 'Copy folder path',
            onPressed: () => _copy(app, app.cfg.binDir),
          ),
        ]),
        for (final path in app.opened) _OpenedCard(app, path),
        if (strays.isNotEmpty)
          KitPanel(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(8),
            child: Row(children: [
              Expanded(
                child: KitTooltip(
                  message: strays.map(tildify).join('\n'),
                  child: Text(
                      '${strays.length == 1 ? '${p.basename(strays[0])} is' : '${strays.length} AppImages are'}'
                      ' outside $central. Move ${strays.length == 1 ? 'it' : 'them'} there to keep '
                      'your AppImages in one place? Aliases, update sources and menu entries move along.'),
                ),
              ),
              const SizedBox(width: 8),
              KitButton.primary(strays.length == 1 ? 'Move' : 'Move all',
                  onPressed: () => app.moveToCentral(strays)),
              const SizedBox(width: 4),
              KitButton.ghost('Not now', onPressed: app.hideMoveOffer),
              KitButton.ghost("Don't ask again", onPressed: app.neverOfferMove),
            ]),
          ),
        const SizedBox(height: 4),
        Expanded(
          child: app.apps.isEmpty
              ? Center(
                  child: Text(
                    'No AppImages found.\nPut them in ~/Applications, add a folder to scan, '
                    'or install one from Browse.',
                    textAlign: TextAlign.center,
                    style: _dim(context),
                  ),
                )
              : KitPanel(
                  child: ListView.separated(
                    itemCount: app.apps.length,
                    separatorBuilder: (_, __) => const KitDivider(),
                    itemBuilder: (_, i) =>
                        _AppRow(app, app.apps[i], key: ValueKey(app.apps[i].path)),
                  ),
                ),
        ),
      ],
    );
  }
}

class _OpenedCard extends StatelessWidget {
  final AppController app;
  final String path;
  const _OpenedCard(this.app, this.path);

  @override
  Widget build(BuildContext context) {
    final name = p.basename(path);
    return KitPanel(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Opened $name', style: _heading(context), overflow: TextOverflow.ellipsis),
            KitTooltip(
              message: path,
              child: Text(tildify(path),
                  style: _dim(context, small: true), overflow: TextOverflow.ellipsis),
            ),
          ]),
        ),
        KitButton('Run', tooltip: 'Start $name', onPressed: () => app.launch(path)),
        const SizedBox(width: 6),
        KitButton.primary(
          'Install',
          tooltip: '${needsMove(path) ? 'Move it to ${tildify(defaultInstallDir())}, ' : ''}'
              'add it to the app menu and give it an alias',
          onPressed: () => app.adopt(path),
        ),
        const SizedBox(width: 2),
        KitIconButton(Icons.close, tooltip: 'Dismiss', onPressed: () => app.dismissOpened(path)),
      ]),
    );
  }
}

class _AppRow extends StatefulWidget {
  final AppController app;
  final AppImage appImage;
  const _AppRow(this.app, this.appImage, {super.key});

  @override
  State<_AppRow> createState() => _AppRowState();
}

class _AppRowState extends State<_AppRow> {
  late final TextEditingController _alias;

  /// Whether the user typed in the alias entry since it was last saved.
  bool _edited = false;

  AppController get app => widget.app;
  String get path => widget.appImage.path;

  @override
  void initState() {
    super.initState();
    _alias = TextEditingController(text: app.cfg.aliasFor(path));
  }

  @override
  void didUpdateWidget(_AppRow old) {
    super.didUpdateWidget(old);
    final saved = app.cfg.aliasFor(path);
    if (!_edited && _alias.text != saved) _alias.text = saved;
  }

  @override
  void dispose() {
    _alias.dispose();
    super.dispose();
  }

  /// What saving the row would assign: the typed text, or the suggested
  /// alias when the entry is empty and nothing is assigned yet.
  String get effective {
    final text = _alias.text.trim();
    if (text.isEmpty && app.cfg.aliasFor(path).isEmpty && !_edited) {
      return suggestAlias(p.basename(path));
    }
    return text;
  }

  void _save(String alias) {
    app.saveAlias(path, alias);
    final saved = app.cfg.aliasFor(path);
    if (saved == alias.trim()) {
      setState(() {
        _edited = false;
        _alias.text = saved;
      });
    }
  }

  Future<void> _editSource() async {
    final embedded = parseUpdateInfo(app.embeddedInfo(path));
    final controller = TextEditingController(text: app.cfg.installFor(path).source);
    final result = await showKitDialog<String>(
      context,
      (context) => KitDialog(
        title: 'Update source',
        content: SizedBox(
          width: 420,
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('A GitHub repository or .zsync URL to update from. Leave empty to use '
                    "the AppImage's built-in update information."),
                const SizedBox(height: 8),
                KitTextField(
                  controller: controller,
                  autofocus: true,
                  hint: embedded.kind != UpdateKind.none
                      ? 'Built in: $embedded'
                      : 'owner/repo or .zsync URL',
                  onSubmitted: (v) => Navigator.pop(context, v),
                ),
              ]),
        ),
        actions: [
          KitButton('Cancel', onPressed: () => Navigator.pop(context)),
          KitButton.primary('Save', onPressed: () => Navigator.pop(context, controller.text)),
        ],
      ),
    );
    controller.dispose();
    if (result != null) app.setUpdateSource(path, result);
  }

  Future<void> _confirmDelete() async {
    final name = p.basename(path);
    final ok = await showKitDialog<bool>(
      context,
      (context) => KitDialog(
        title: 'Delete $name?',
        content: const Text('This removes the file, its alias and its app menu entry.'),
        actions: [
          KitButton('Cancel', autofocus: true, onPressed: () => Navigator.pop(context, false)),
          KitButton.danger('Delete', onPressed: () => Navigator.pop(context, true)),
        ],
      ),
    );
    if (ok == true) await app.uninstall(path);
  }

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final saved = app.cfg.aliasFor(path);
    final eff = effective;
    final missing = !fileExists(path);
    final valid = eff.isEmpty || isValidAlias(eff);
    final update = app.statusOf(path);
    final updateText = app.updateLine(path);
    final busy = update.state == UpdateState.checking || update.state == UpdateState.updating;
    final updateColor = switch (update.state) {
      UpdateState.checkFailed => c.danger,
      UpdateState.updateAvailable || UpdateState.updating => c.accent,
      UpdateState.upToDate when update.message.isNotEmpty => c.success,
      _ => c.textDim,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${widget.appImage.name}${missing ? '  (missing)' : ''}',
                style: _heading(context), overflow: TextOverflow.ellipsis),
            KitTooltip(
              message: path,
              child: Text(path, style: _dim(context, small: true), overflow: TextOverflow.ellipsis),
            ),
            if (updateText.isNotEmpty)
              KitTooltip(
                message: updateText,
                child: Text(updateText,
                    overflow: TextOverflow.ellipsis,
                    style: KitText.small(context, color: updateColor)),
              ),
          ]),
        ),
        KitIconButton(
          Icons.copy,
          size: 16,
          tooltip: 'Copy AppImage path',
          onPressed: () => _copy(app, path),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 170,
          child: KitTooltip(
            message: valid
                ? 'Command used to launch this AppImage (Enter to save)'
                : "Use letters, digits, '-', '_', '.' or '+'",
            child: KitTextField(
              controller: _alias,
              hint: suggestAlias(p.basename(path)),
              error: !valid,
              onChanged: (_) => setState(() => _edited = true),
              onSubmitted: (_) => _save(effective),
            ),
          ),
        ),
        const SizedBox(width: 2),
        KitIconButton(
          Icons.check,
          tooltip: 'Save alias',
          color: c.accent,
          onPressed: valid && eff != saved ? () => _save(eff) : null,
        ),
        KitIconButton(
          Icons.backspace_outlined,
          size: 16,
          tooltip: 'Remove alias',
          onPressed: saved.isNotEmpty ? () => _save('') : null,
        ),
        if (update.state == UpdateState.checking ||
            (update.state == UpdateState.updating && (update.verifying || update.asset.size <= 0)))
          KitTooltip(
            message: updateText,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: KitSpinner(size: 18),
            ),
          )
        else if (update.state == UpdateState.updating)
          KitTooltip(
            message: updateText,
            child: SizedBox(
              width: 90,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                KitProgressBar(value: update.progress),
                const SizedBox(height: 2),
                Text('${(update.progress * 100).toInt()}%', style: KitText.small(context)),
              ]),
            ),
          )
        else if (update.state == UpdateState.updateAvailable)
          KitButton.primary(
            'Update',
            tooltip:
                'Download ${update.asset.name.isNotEmpty ? update.asset.name : 'the new version'}',
            onPressed: () => app.applyUpdate(path),
          ),
        KitMenu(
          items: () => [
            KitMenuItem('Run', onSelected: missing ? null : () => app.launch(path)),
            KitMenuItem('Check for updates',
                onSelected: missing || busy ? null : () => app.checkUpdate(path)),
            KitMenuItem('Update source…', onSelected: _editSource),
            const KitMenuDivider(),
            if (needsMove(path))
              KitMenuItem('Move to ${tildify(defaultInstallDir())}',
                  onSelected: busy ? null : () => app.moveToCentral([path])),
            KitMenuItem(isIntegrated(path) ? 'Remove from app menu' : 'Add to app menu',
                onSelected: missing ? null : () => app.toggleMenuEntry(path)),
            KitMenuItem('Delete…', danger: true, onSelected: _confirmDelete),
          ],
          builder: (context, toggle, _) =>
              KitIconButton(Icons.more_horiz, tooltip: 'More actions', onPressed: toggle),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Browse

class _BrowsePage extends StatefulWidget {
  final AppController app;
  const _BrowsePage(this.app);

  @override
  State<_BrowsePage> createState() => _BrowsePageState();
}

class _BrowsePageState extends State<_BrowsePage> {
  late final TextEditingController _query = TextEditingController(text: widget.app.query);

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final items = app.results();
    final installed = app.installedRepos();
    final loading = app.catalogLoading.contains(app.source) || app.searchLoading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(
            child: KitTooltip(
              message: app.source.isCatalog
                  ? 'Filter the ${app.source} catalog'
                  : 'Press Enter to search GitHub',
              child: KitTextField(
                controller: _query,
                autofocus: true,
                prefixIcon: Icons.search,
                hint: 'Search',
                onChanged: app.setQuery,
                onSubmitted: (_) {
                  if (!app.source.isCatalog) app.searchGitHub();
                },
              ),
            ),
          ),
          const SizedBox(width: 8),
          KitTooltip(
            message: 'AppImageHub: the community catalog · pkgforge-dev: self-contained '
                'Anylinux AppImages that run on any distro · GitHub: search all repositories',
            child: KitSelect<CatalogSource>(
              value: app.source,
              options: [for (final s in CatalogSource.values) (s, s.label)],
              onChanged: app.selectSource,
            ),
          ),
        ]),
        const SizedBox(height: 8),
        if (loading)
          Row(children: [
            const KitSpinner(),
            const SizedBox(width: 8),
            Text(app.source.isCatalog ? 'Loading the ${app.source} catalog…' : 'Searching GitHub…',
                style: _dim(context)),
          ]),
        if (app.searchError.isNotEmpty)
          Text(app.searchError, style: TextStyle(color: KitTheme.of(context).danger)),
        if (items.isEmpty)
          Expanded(
            child: Center(
              child: Text(
                loading
                    ? ''
                    : app.source == CatalogSource.gitHub && app.query.trim().isEmpty
                        ? 'Type a name and press Enter to search GitHub for projects that publish AppImages.'
                        : app.source == CatalogSource.gitHub && app.searchError.isEmpty
                            ? 'No GitHub projects found.'
                            : app.source.isCatalog && app.catalogs[app.source]!.isNotEmpty
                                ? 'No apps match your search.'
                                : '',
                textAlign: TextAlign.center,
                style: _dim(context),
              ),
            ),
          )
        else ...[
          Text(
            '${items.length > maxResults ? 'Showing $maxResults of ${items.length} matches — type to narrow down' : '${items.length} app(s)'}'
            ' · installs go to ${tildify(defaultInstallDir())}',
            style: _dim(context, small: true),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: KitPanel(
              child: ListView.separated(
                itemCount: items.length < maxResults ? items.length : maxResults,
                separatorBuilder: (_, __) => const KitDivider(),
                itemBuilder: (_, i) => _CatalogRow(app, items[i], installed),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _CatalogRow extends StatelessWidget {
  final AppController app;
  final CatalogApp item;
  final Set<String> installed;
  const _CatalogRow(this.app, this.item, this.installed);

  @override
  Widget build(BuildContext context) {
    final repo = item.repo;
    final progress = app.installing[repo];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.name, style: _heading(context), overflow: TextOverflow.ellipsis),
            if (item.summary.isNotEmpty)
              KitTooltip(
                message: item.summary,
                child: Text(item.summary, overflow: TextOverflow.ellipsis),
              ),
            Text(AppController.describe(item),
                style: _dim(context, small: true), overflow: TextOverflow.ellipsis),
          ]),
        ),
        KitButton.ghost(
          'GitHub',
          tooltip: 'Open github.com/$repo',
          onPressed: () => Process.start('xdg-open', ['https://github.com/$repo'],
              mode: ProcessStartMode.detached, environment: childEnvironment()),
        ),
        const SizedBox(width: 6),
        if (installed.contains(repo.toLowerCase()))
          const KitButton.primary('Installed', onPressed: null)
        else if (progress != null && progress < 0)
          const KitTooltip(
            message: 'Looking for the latest release…',
            child: KitSpinner(size: 18),
          )
        else if (progress != null)
          KitTooltip(
            message: 'Downloading…',
            child: SizedBox(width: 80, child: KitProgressBar(value: progress)),
          )
        else
          KitButton.primary(
            'Install',
            tooltip: 'Download the latest AppImage release into ${tildify(defaultInstallDir())}',
            onPressed: () => app.install(item),
          ),
      ]),
    );
  }
}
