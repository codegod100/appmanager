/// The window: an Installed page listing AppImages with their aliases and
/// update state, and a Browse page for finding new ones.
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

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
        return Scaffold(
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: installed
                  ? 'Rescan for AppImages'
                  : app.source.isCatalog
                      ? 'Reload the ${app.source} catalog'
                      : 'Search GitHub again',
              onPressed: app.reload,
            ),
            centerTitle: true,
            title: SegmentedButton<AppPage>(
              segments: const [
                ButtonSegment(value: AppPage.installed, label: Text('Installed')),
                ButtonSegment(value: AppPage.browse, label: Text('Browse')),
              ],
              selected: {app.page},
              showSelectedIcon: false,
              onSelectionChanged: (s) => app.switchTo(s.first),
            ),
            actions: [
              if (installed && available > 1)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilledButton(
                    onPressed: app.updateAll,
                    child: Text('Update all ($available)'),
                  ),
                ),
              if (installed)
                Tooltip(
                  message: 'Check all AppImages for updates',
                  child: OutlinedButton(
                    onPressed: app.checking ? null : app.checkAll,
                    child: const Text('Check for updates'),
                  ),
                ),
              IconButton(
                icon: const Icon(Icons.folder_outlined),
                tooltip: 'Folders to scan',
                onPressed: () => showDialog<void>(
                    context: context, builder: (_) => _ScanFoldersDialog(app)),
              ),
              IconButton(
                icon: const Icon(Icons.menu),
                tooltip: 'Opening AppImages',
                onPressed: () => showDialog<void>(
                    context: context, builder: (_) => _HandlerDialog(app)),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: installed ? _InstalledPage(app) : _BrowsePage(app)),
                if (app.status.isNotEmpty) _StatusBar(app),
              ],
            ),
          ),
        );
      },
    );
  }
}

TextStyle? _dim(BuildContext context, {bool small = false}) =>
    (small ? Theme.of(context).textTheme.bodySmall : Theme.of(context).textTheme.bodyMedium)
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);

TextStyle? _heading(BuildContext context) =>
    Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold);

void _copy(AppController app, String text) {
  Clipboard.setData(ClipboardData(text: text));
  app.report([], 'Copied $text');
}

class _StatusBar extends StatelessWidget {
  final AppController app;
  const _StatusBar(this.app);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = app.statusIsError ? scheme.error : Colors.green.shade600;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: SelectableText(app.status, style: TextStyle(color: color))),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            tooltip: 'Dismiss',
            visualDensity: VisualDensity.compact,
            onPressed: app.dismissStatus,
          ),
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
      builder: (context, _) => AlertDialog(
        title: const Text('Folders scanned for AppImages'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, dir) in app.cfg.scanDirs.indexed)
                Row(children: [
                  Expanded(child: Text(tildify(dir), overflow: TextOverflow.ellipsis)),
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    tooltip: 'Stop scanning this folder',
                    onPressed: () => app.removeScanDir(i),
                  ),
                ]),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final dir = await getDirectoryPath(confirmButtonText: 'Add');
              if (dir != null) app.addScanDir(dir);
            },
            child: const Text('Add folder…'),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
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
      builder: (context, _) => AlertDialog(
        title: const Text('Opening AppImages'),
        content: SizedBox(width: 380, child: Text(app.handlerText())),
        actions: [
          Tooltip(
            message: 'Make AppManager the default app for AppImage files',
            child: FilledButton(
              onPressed: app.handler == '$appId.desktop' ? null : app.makeDefaultHandler,
              child: const Text('Open AppImages with AppManager'),
            ),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
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
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            tooltip: 'Copy folder path',
            onPressed: () => _copy(app, app.cfg.binDir),
          ),
        ]),
        for (final path in app.opened) _OpenedCard(app, path),
        if (strays.isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(children: [
                Expanded(
                  child: Tooltip(
                    message: strays.map(tildify).join('\n'),
                    child: Text(
                        '${strays.length == 1 ? '${p.basename(strays[0])} is' : '${strays.length} AppImages are'}'
                        ' outside $central. Move ${strays.length == 1 ? 'it' : 'them'} there to keep '
                        'your AppImages in one place? Aliases, update sources and menu entries move along.'),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => app.moveToCentral(strays),
                  child: Text(strays.length == 1 ? 'Move' : 'Move all'),
                ),
                TextButton(onPressed: app.hideMoveOffer, child: const Text('Not now')),
                TextButton(onPressed: app.neverOfferMove, child: const Text("Don't ask again")),
              ]),
            ),
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
              : Card(
                  clipBehavior: Clip.antiAlias,
                  margin: EdgeInsets.zero,
                  child: ListView.separated(
                    itemCount: app.apps.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Opened $name', style: _heading(context), overflow: TextOverflow.ellipsis),
              Tooltip(
                message: path,
                child: Text(tildify(path),
                    style: _dim(context, small: true), overflow: TextOverflow.ellipsis),
              ),
            ]),
          ),
          Tooltip(
            message: 'Start $name',
            child: OutlinedButton(onPressed: () => app.launch(path), child: const Text('Run')),
          ),
          const SizedBox(width: 6),
          Tooltip(
            message: '${needsMove(path) ? 'Move it to ${tildify(defaultInstallDir())}, ' : ''}'
                'add it to the app menu and give it an alias',
            child: FilledButton(onPressed: () => app.adopt(path), child: const Text('Install')),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Dismiss',
            onPressed: () => app.dismissOpened(path),
          ),
        ]),
      ),
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
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Update source'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('A GitHub repository or .zsync URL to update from. Leave empty to use '
                "the AppImage's built-in update information."),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: embedded.kind != UpdateKind.none
                    ? 'Built in: $embedded'
                    : 'owner/repo or .zsync URL',
              ),
              onSubmitted: (v) => Navigator.pop(context, v),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text), child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (result != null) app.setUpdateSource(path, result);
  }

  Future<void> _confirmDelete() async {
    final name = p.basename(path);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete $name?'),
        content: const Text('This removes the file, its alias and its app menu entry.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) await app.uninstall(path);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final saved = app.cfg.aliasFor(path);
    final eff = effective;
    final missing = !fileExists(path);
    final valid = eff.isEmpty || isValidAlias(eff);
    final update = app.statusOf(path);
    final updateText = app.updateLine(path);
    final busy = update.state == UpdateState.checking || update.state == UpdateState.updating;
    final updateColor = switch (update.state) {
      UpdateState.checkFailed => scheme.error,
      UpdateState.updateAvailable || UpdateState.updating => scheme.primary,
      UpdateState.upToDate when update.message.isNotEmpty => Colors.green.shade600,
      _ => scheme.onSurfaceVariant,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${widget.appImage.name}${missing ? '  (missing)' : ''}',
                style: _heading(context), overflow: TextOverflow.ellipsis),
            Tooltip(
              message: path,
              child: Text(path, style: _dim(context, small: true), overflow: TextOverflow.ellipsis),
            ),
            if (updateText.isNotEmpty)
              Tooltip(
                message: updateText,
                child: Text(updateText,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: updateColor)),
              ),
          ]),
        ),
        IconButton(
          icon: const Icon(Icons.copy, size: 18),
          tooltip: 'Copy AppImage path',
          onPressed: () => _copy(app, path),
        ),
        SizedBox(
          width: 170,
          child: Tooltip(
            message: valid
                ? 'Command used to launch this AppImage (Enter to save)'
                : "Use letters, digits, '-', '_', '.' or '+'",
            child: TextField(
              controller: _alias,
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                hintText: suggestAlias(p.basename(path)),
                errorText: valid ? null : '',
                errorStyle: const TextStyle(height: 0, fontSize: 0),
              ),
              onChanged: (_) => setState(() => _edited = true),
              onSubmitted: (_) => _save(effective),
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.check),
          tooltip: 'Save alias',
          color: scheme.primary,
          onPressed: valid && eff != saved ? () => _save(eff) : null,
        ),
        IconButton(
          icon: const Icon(Icons.backspace_outlined),
          tooltip: 'Remove alias',
          onPressed: saved.isNotEmpty ? () => _save('') : null,
        ),
        if (update.state == UpdateState.checking ||
            (update.state == UpdateState.updating &&
                (update.verifying || update.asset.size <= 0)))
          Tooltip(
            message: updateText,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: SizedBox(
                  width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          )
        else if (update.state == UpdateState.updating)
          Tooltip(
            message: updateText,
            child: SizedBox(
              width: 90,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                LinearProgressIndicator(value: update.progress),
                Text('${(update.progress * 100).toInt()}%',
                    style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
          )
        else if (update.state == UpdateState.updateAvailable)
          Tooltip(
            message:
                'Download ${update.asset.name.isNotEmpty ? update.asset.name : 'the new version'}',
            child: FilledButton(
                onPressed: () => app.applyUpdate(path), child: const Text('Update')),
          ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_horiz),
          tooltip: 'More actions',
          onSelected: (action) {
            switch (action) {
              case 'run':
                app.launch(path);
              case 'check':
                app.checkUpdate(path);
              case 'source':
                _editSource();
              case 'move':
                app.moveToCentral([path]);
              case 'menu':
                app.toggleMenuEntry(path);
              case 'delete':
                _confirmDelete();
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'run', enabled: !missing, child: const Text('Run')),
            PopupMenuItem(
                value: 'check', enabled: !missing && !busy, child: const Text('Check for updates')),
            const PopupMenuItem(value: 'source', child: Text('Update source…')),
            const PopupMenuDivider(),
            if (needsMove(path))
              PopupMenuItem(
                value: 'move',
                enabled: !busy,
                child: Text('Move to ${tildify(defaultInstallDir())}'),
              ),
            PopupMenuItem(
              value: 'menu',
              enabled: !missing,
              child: Text(isIntegrated(path) ? 'Remove from app menu' : 'Add to app menu'),
            ),
            PopupMenuItem(
              value: 'delete',
              child: Text('Delete…', style: TextStyle(color: scheme.error)),
            ),
          ],
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
            child: Tooltip(
              message: app.source.isCatalog
                  ? 'Filter the ${app.source} catalog'
                  : 'Press Enter to search GitHub',
              child: TextField(
                controller: _query,
                autofocus: true,
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                  hintText: 'Search',
                ),
                onChanged: app.setQuery,
                onSubmitted: (_) {
                  if (!app.source.isCatalog) app.searchGitHub();
                },
              ),
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: 'AppImageHub: the community catalog · pkgforge-dev: self-contained '
                'Anylinux AppImages that run on any distro · GitHub: search all repositories',
            child: DropdownButton<CatalogSource>(
              value: app.source,
              items: [
                for (final s in CatalogSource.values)
                  DropdownMenuItem(value: s, child: Text(s.label)),
              ],
              onChanged: (s) {
                if (s != null) app.selectSource(s);
              },
            ),
          ),
        ]),
        const SizedBox(height: 8),
        if (loading)
          Row(children: [
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
            Text(
                app.source.isCatalog
                    ? 'Loading the ${app.source} catalog…'
                    : 'Searching GitHub…',
                style: _dim(context)),
          ]),
        if (app.searchError.isNotEmpty)
          Text(app.searchError, style: TextStyle(color: Theme.of(context).colorScheme.error)),
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
            child: Card(
              clipBehavior: Clip.antiAlias,
              margin: EdgeInsets.zero,
              child: ListView.separated(
                itemCount: items.length < maxResults ? items.length : maxResults,
                separatorBuilder: (_, __) => const Divider(height: 1),
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
              Tooltip(
                message: item.summary,
                child: Text(item.summary, overflow: TextOverflow.ellipsis),
              ),
            Text(AppController.describe(item),
                style: _dim(context, small: true), overflow: TextOverflow.ellipsis),
          ]),
        ),
        Tooltip(
          message: 'Open github.com/$repo',
          child: TextButton(
            onPressed: () => Process.start('xdg-open', ['https://github.com/$repo'],
                mode: ProcessStartMode.detached, environment: childEnvironment()),
            child: const Text('GitHub'),
          ),
        ),
        const SizedBox(width: 6),
        if (installed.contains(repo.toLowerCase()))
          const FilledButton(onPressed: null, child: Text('Installed'))
        else if (progress != null && progress < 0)
          const Tooltip(
            message: 'Looking for the latest release…',
            child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (progress != null)
          Tooltip(
            message: 'Downloading…',
            child: SizedBox(width: 80, child: LinearProgressIndicator(value: progress)),
          )
        else
          Tooltip(
            message: 'Download the latest AppImage release into ${tildify(defaultInstallDir())}',
            child: FilledButton(onPressed: () => app.install(item), child: const Text('Install')),
          ),
      ]),
    );
  }
}
