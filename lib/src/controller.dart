/// The app's state and everything the buttons do, kept apart from the
/// widgets so it reads like the logic it is.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'core.dart';
import 'env.dart';
import 'net.dart';
import 'store.dart';

const appId = 'dev.appmanager.AppManager';
const maxResults = 150;
const _maxParallelChecks = 4;

/// The header is all we need from a .zsync.
const _zsyncHeaderRange = '0-16383';

enum AppPage { installed, browse }

enum UpdateState { unchecked, checking, upToDate, updateAvailable, noSource, checkFailed, updating }

class UpdateStatus {
  final UpdateState state;

  /// Error text or a note.
  final String message;

  /// The newer build, when one is available.
  final ReleaseAsset asset;

  /// Expected SHA-1 of that build, when known.
  final String sha1;

  /// Fraction downloaded, when the size is known.
  double progress;

  /// Bytes downloaded so far.
  int downloaded;

  /// Download done, checking it before swapping it in.
  bool verifying;

  UpdateStatus(this.state,
      {this.message = '',
      ReleaseAsset? asset,
      this.sha1 = '',
      this.progress = 0,
      this.downloaded = 0,
      this.verifying = false})
      : asset = asset ?? ReleaseAsset();

  static UpdateStatus failed(String msg) => UpdateStatus(UpdateState.checkFailed, message: msg);
}

class AppController extends ChangeNotifier {
  Config cfg;
  List<AppImage> apps = [];

  /// AppImage path -> embedded update info.
  final Map<String, String> _embedded = {};
  String status = '';
  bool statusIsError = false;

  AppPage page = AppPage.installed;
  final Map<CatalogSource, List<CatalogApp>> catalogs = {
    for (final s in CatalogSource.values) s: <CatalogApp>[]
  };
  final Set<CatalogSource> catalogLoading = {};

  /// lower-case repo -> GitHub description.
  final Map<String, String> descriptions = {};

  /// Fetching descriptions for the pkgforge-dev list.
  bool describing = false;

  /// Matches in the selected catalog.
  List<CatalogApp> catalogResults = [];
  List<CatalogApp> githubResults = [];

  /// Discards replies to outdated searches.
  int _githubSearches = 0;
  bool searchLoading = false;
  String searchError = '';
  String query = '';

  /// Where Browse searches.
  CatalogSource source = CatalogSource.appImageHub;

  /// repo -> download progress (< 0: looking up).
  final Map<String, double> installing = {};

  /// AppImage path -> update status.
  final Map<String, UpdateStatus> updates = {};
  final List<String> _checkQueue = [];
  int _checksRunning = 0;

  /// "Not now" on the move banner.
  bool moveOfferHidden = false;

  /// AppImages opened from the file manager, awaiting a choice.
  final List<String> opened = [];

  /// Desktop file that opens AppImages ("" = unknown).
  String handler = '';

  AppController(this.cfg) {
    rescan();
    handler = appImageHandler();
  }

  void _changed() => notifyListeners();

  void rescan() {
    apps = findAppImages(cfg);
    _embedded.clear();
    _changed();
  }

  void report(List<String> notes, String success) {
    statusIsError = false;
    status = [success, ...notes].join('\n');
    _changed();
  }

  void fail(String msg) {
    statusIsError = true;
    status = msg;
    _changed();
  }

  void dismissStatus() {
    status = '';
    _changed();
  }

  void _commit(String success) {
    try {
      report(apply(cfg), success);
    } on FileSystemException catch (e) {
      fail('Could not write aliases: ${e.message} ${e.path ?? ''}'.trim());
    }
  }

  void save() {
    try {
      saveConfig(cfg);
    } on FileSystemException catch (e) {
      fail('Could not save settings: ${e.message}');
    }
  }

  // -------------------------------------------------------------------------
  // Aliases

  void saveAlias(String path, String alias) {
    alias = alias.trim();
    try {
      cfg.setAlias(path, alias);
    } on AliasError catch (e) {
      fail(e.message);
      return;
    }
    final shadow = alias.isNotEmpty ? cfg.shadowedCommand(alias) : '';
    var msg = alias.isEmpty
        ? 'Removed alias for ${p.basename(path)}'
        : "'$alias' now launches ${p.basename(path)}";
    if (shadow.isNotEmpty) msg += ' (note: shadows $shadow depending on PATH order)';
    _commit(msg);
  }

  String pathHint() {
    if (cfg.binDirOnPath) return 'Aliases live in ${cfg.binDir} (on your PATH)';
    if (cfg.pathSnippetInstalled) {
      return 'Aliases live in ${cfg.binDir} — open a new terminal (or log out and back in) '
          'to pick up the PATH change';
    }
    return 'Aliases live in ${cfg.binDir} — save an alias to add this folder to your PATH';
  }

  // -------------------------------------------------------------------------
  // Scan folders

  void removeScanDir(int i) {
    cfg.scanDirs.removeAt(i);
    save();
    rescan();
  }

  void addScanDir(String dir) {
    if (!cfg.scanDirs.contains(dir)) cfg.scanDirs.add(dir);
    save();
    rescan();
  }

  // -------------------------------------------------------------------------
  // Updates

  UpdateStatus statusOf(String path) => updates[path] ?? UpdateStatus(UpdateState.unchecked);

  /// Remembers which release build is installed at `path`.
  void _recordInstall(String path, ReleaseAsset asset) {
    if (asset.id == 0) return;
    final info = cfg.installFor(path)
      ..tag = asset.tag
      ..asset = asset.name
      ..assetId = asset.id;
    cfg.installs[path] = info;
    save();
  }

  String embeddedInfo(String path) => _embedded.putIfAbsent(path, () => readUpdateInfo(path));

  UpdateSource sourceOf(String path) => updateSourceFor(cfg.installFor(path), embeddedInfo(path));

  /// Finds out whether a newer build of the AppImage at `path` exists: by
  /// comparing its SHA-1 with the release's .zsync file when there is one,
  /// otherwise by comparing the release asset with the installed one.
  Future<void> checkUpdate(String path) async {
    void finish(UpdateStatus st) {
      updates[path] = st;
      _changed();
    }

    if (!fileExists(path)) {
      finish(UpdateStatus.failed('the file is missing'));
      return;
    }
    final info = cfg.installFor(path);
    finish(UpdateStatus(UpdateState.checking));

    Future<void> viaZsync(String zsyncUrl, ReleaseAsset asset) async {
      final text = await fetchText(zsyncUrl, range: _zsyncHeaderRange);
      final z = parseZsync(text, zsyncUrl);
      if (z.sha1.length != 40 || z.url.isEmpty) {
        finish(UpdateStatus.failed('could not read $zsyncUrl'));
        return;
      }
      final sha = await sha1File(path);
      if (sha == z.sha1) {
        _recordInstall(path, asset);
        finish(UpdateStatus(UpdateState.upToDate));
      } else {
        final newer = asset.copy()..url = z.url;
        if (newer.name.isEmpty) newer.name = z.filename;
        if (z.length > 0) newer.size = z.length;
        finish(UpdateStatus(UpdateState.updateAvailable, asset: newer, sha1: z.sha1));
      }
    }

    try {
      final src = sourceOf(path);
      switch (src.kind) {
        case UpdateKind.none:
          finish(UpdateStatus(UpdateState.noSource));
        case UpdateKind.zsyncUrl:
          await viaZsync(src.url, ReleaseAsset());
        case UpdateKind.gitHubReleases:
          final repo = '${src.owner}/${src.repo}';
          final node = await fetchJson(releasesUrl(repo, src.tag));
          final previous = info.asset.isNotEmpty ? info.asset : p.basename(path);
          final asset = pickRelease(node, tag: src.tag, pattern: src.pattern, previous: previous);
          final size = File(path).lengthSync();
          if (asset.name.isEmpty) {
            finish(UpdateStatus.failed("no AppImage for this computer in $repo's releases"));
          } else if (info.assetId != 0 && info.assetId == asset.id) {
            finish(UpdateStatus(UpdateState.upToDate));
          } else if (asset.zsyncUrl.isNotEmpty) {
            await viaZsync(asset.zsyncUrl, asset);
          } else if (info.assetId == 0 && asset.name == p.basename(path) && asset.size == size) {
            _recordInstall(path, asset);
            finish(UpdateStatus(UpdateState.upToDate));
          } else {
            finish(UpdateStatus(UpdateState.updateAvailable, asset: asset));
          }
      }
    } on Exception catch (e) {
      finish(UpdateStatus.failed(_msg(e)));
    }
  }

  String checkSummary() {
    final counts = {for (final s in UpdateState.values) s: 0};
    for (final a in apps) {
      counts[statusOf(a.path).state] = counts[statusOf(a.path).state]! + 1;
    }
    final parts = [
      if (counts[UpdateState.updateAvailable]! > 0)
        '${counts[UpdateState.updateAvailable]} update(s) available',
      if (counts[UpdateState.upToDate]! > 0) '${counts[UpdateState.upToDate]} up to date',
      if (counts[UpdateState.noSource]! > 0)
        '${counts[UpdateState.noSource]} without an update source',
      if (counts[UpdateState.checkFailed]! > 0)
        '${counts[UpdateState.checkFailed]} could not be checked',
    ];
    return parts.isEmpty ? 'Nothing to check' : parts.join(', ');
  }

  bool get checking => _checkQueue.isNotEmpty || _checksRunning > 0;

  void _pumpChecks() {
    while (_checksRunning < _maxParallelChecks && _checkQueue.isNotEmpty) {
      final path = _checkQueue.removeAt(0);
      _checksRunning++;
      checkUpdate(path).whenComplete(() {
        _checksRunning--;
        if (_checksRunning == 0 && _checkQueue.isEmpty) report([], checkSummary());
        _pumpChecks();
      });
    }
  }

  void checkAll() {
    for (final a in apps) {
      final st = statusOf(a.path).state;
      if (!_checkQueue.contains(a.path) &&
          st != UpdateState.checking &&
          st != UpdateState.updating) {
        _checkQueue.add(a.path);
        updates[a.path] = UpdateStatus(UpdateState.checking);
      }
    }
    _changed();
    _pumpChecks();
  }

  /// Rolling tags such as "continuous" or "release" say nothing about the
  /// version, so we show the file name instead.
  static bool isVersionTag(String tag) => tag.contains(RegExp(r'[0-9]'));

  static String formatBytes(int n) {
    if (n >= 1024 * 1024) return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
    if (n >= 1024) return '${n ~/ 1024} KB';
    return '$n B';
  }

  /// How to call the build `asset` in messages: its version, else its file.
  static String newerName(ReleaseAsset asset, String installedTag) =>
      isVersionTag(asset.tag) && asset.tag != installedTag ? asset.tag : asset.name;

  /// Downloads the newer build next to the old one and swaps it in, so the
  /// path (and with it aliases and menu entries) stays the same.
  Future<void> applyUpdate(String path) async {
    final st = statusOf(path);
    if (st.state != UpdateState.updateAvailable) return;
    final asset = st.asset;
    final name = p.basename(path);
    final part = p.join(p.dirname(path), '.$name.part');
    final target = newerName(asset, cfg.installFor(path).tag);
    final current = UpdateStatus(UpdateState.updating, asset: asset, sha1: st.sha1);
    updates[path] = current;
    report([], 'Updating $name${target.isNotEmpty ? ' to $target' : ''}…');

    void failUpdate(String msg) {
      removeFile(part);
      updates[path] = UpdateStatus.failed(msg);
      fail('Could not update $name: $msg');
    }

    try {
      await download(asset.url, part, expected: asset.size, onProgress: (received, total) {
        current.downloaded = received;
        if (total > 0) current.progress = (received / total).clamp(0.0, 1.0);
        _changed();
      });
      current
        ..verifying = true
        ..progress = 1.0;
      _changed();
      final sha = await sha1File(part);
      if (st.sha1.isNotEmpty && sha != st.sha1) {
        failUpdate('the download is corrupt (SHA-1 mismatch)');
        return;
      }
      if (st.sha1.isEmpty) {
        // Without a .zsync we only guessed that this build is newer.
        String old;
        try {
          old = await sha1File(path);
        } on Exception {
          old = '';
        }
        if (old == sha) {
          // The "new" build turned out to be the one we have.
          removeFile(part);
          _recordInstall(path, asset);
          updates[path] = UpdateStatus(UpdateState.upToDate, message: 'Already the latest build');
          report([], '$name was already the latest build; nothing changed');
          return;
        }
      }
      chmod(part, fileMode(path) | 0x1c0); // u+rwx
      moveFile(part, path);
    } on Exception catch (e) {
      failUpdate(_msg(e));
      return;
    }
    _recordInstall(path, asset);
    _embedded[path] = readUpdateInfo(path);
    final to = isVersionTag(asset.tag)
        ? ' to ${asset.tag}'
        : asset.name.isNotEmpty && asset.name != name
            ? ' to ${asset.name}'
            : '';
    updates[path] = UpdateStatus(UpdateState.upToDate, message: 'Updated$to');
    report([], 'Updated $name$to');
    if (isIntegrated(path)) {
      // The icon may have changed.
      try {
        await integrate(path);
        await refreshMenus();
      } on Exception {
        // The old entry still works.
      }
    }
  }

  void updateAll() {
    var n = 0;
    for (final a in apps) {
      if (statusOf(a.path).state == UpdateState.updateAvailable) {
        applyUpdate(a.path);
        n++;
      }
    }
    if (n > 1) report([], 'Updating $n AppImages…');
  }

  void setUpdateSource(String path, String text) {
    text = text.trim();
    if (text.isNotEmpty && parseSourceSetting(text).kind == UpdateKind.none) {
      fail('Update source must be a GitHub repository (owner/repo or its URL) or a .zsync URL');
      return;
    }
    final info = cfg.installFor(path);
    if (info.source != text) {
      info.source = text;
      info.assetId = 0; // compare against the new source from scratch
    }
    cfg.installs[path] = info;
    save();
    report(
        [],
        text.isEmpty
            ? 'Using the update information built into ${p.basename(path)}'
            : 'Updates for ${p.basename(path)} now come from $text');
    checkUpdate(path);
  }

  String updateLine(String path) {
    final info = cfg.installFor(path);
    final st = statusOf(path);
    final parts = <String>[if (isVersionTag(info.tag)) info.tag];
    switch (st.state) {
      case UpdateState.unchecked:
        break;
      case UpdateState.checking:
        parts.add('Checking for updates…');
      case UpdateState.upToDate:
        parts.add(st.message.isNotEmpty ? st.message : 'Up to date');
      case UpdateState.updateAvailable:
        final newer = newerName(st.asset, info.tag);
        parts.add('Update available${newer.isNotEmpty ? ': $newer' : ''}');
      case UpdateState.noSource:
        parts.add('No update source (set one in the ⋯ menu)');
      case UpdateState.checkFailed:
        parts.add('Update check failed: ${st.message}');
      case UpdateState.updating:
        if (st.verifying) {
          parts.add('Verifying and installing the update…');
        } else if (st.asset.size > 0) {
          parts.add('Downloading update… ${(st.progress * 100).toInt()}% '
              '(${formatBytes(st.downloaded)} of ${formatBytes(st.asset.size)})');
        } else if (st.downloaded > 0) {
          parts.add('Downloading update… ${formatBytes(st.downloaded)}');
        } else {
          parts.add('Starting download…');
        }
    }
    return parts.join(' · ');
  }

  // -------------------------------------------------------------------------
  // Menu entries and deleting

  Future<void> toggleMenuEntry(String path) async {
    final name = p.basename(path);
    try {
      if (unintegrate(path)) {
        report([], 'Removed $name from the app menu');
      } else {
        report([], 'Adding $name to the app menu…');
        await integrate(path);
        report([], 'Added $name to the app menu');
      }
      await refreshMenus();
    } on Exception catch (e) {
      fail('Could not change the menu entry: ${_msg(e)}');
    }
  }

  /// Rebuilds menu entries written by older versions (which could miss the
  /// AppImage's own .desktop file). Entries the user removed stay removed.
  Future<void> redoOldMenuEntries() async {
    final queue = apps.map((a) => a.path).where(needsReintegration).toList();
    var redone = 0;
    for (final path in queue) {
      try {
        await integrate(path);
        redone++;
      } on Exception {
        // Keep the old entry.
      }
    }
    if (redone > 0) {
      await refreshMenus();
      if (status.isEmpty) {
        report([], 'Updated the app menu entries of $redone '
            '${redone == 1 ? 'AppImage' : 'AppImages'}');
      }
    }
  }

  Future<void> uninstall(String path) async {
    final name = p.basename(path);
    try {
      if (fileExists(path)) File(path).deleteSync();
    } on FileSystemException catch (e) {
      fail('Could not delete $path: ${e.message}');
      return;
    }
    final hadMenuEntry = unintegrate(path);
    final hadAlias = cfg.aliasFor(path).isNotEmpty;
    cfg.forget(path);
    updates.remove(path);
    rescan();
    if (hadAlias) {
      _commit('Deleted $name'); // also removes its launcher
    } else {
      save();
      report([], 'Deleted $name');
    }
    if (hadMenuEntry) await refreshMenus();
  }

  // -------------------------------------------------------------------------
  // Moving AppImages to ~/Applications

  /// AppImages outside ~/Applications that we could move there now.
  List<String> moveCandidates() => [
        for (final a in apps)
          if (needsMove(a.path) &&
              statusOf(a.path).state != UpdateState.checking &&
              statusOf(a.path).state != UpdateState.updating)
            a.path
      ];

  /// Carries the per-AppImage UI state over to its new path.
  void _renamePath(String src, String dest) {
    final st = updates.remove(src);
    if (st != null) updates[dest] = st;
    _embedded.remove(src);
  }

  /// Moves AppImages into ~/Applications, keeping their aliases, update
  /// sources and menu entries.
  Future<void> moveToCentral(List<String> paths) async {
    final dir = defaultInstallDir();
    var notes = <String>[];
    final failed = <String>[];
    var moved = 0;
    var aliasesMoved = false;
    for (final src in paths) {
      final hadAlias = cfg.aliasFor(src).isNotEmpty;
      try {
        final dest = await relocate(cfg, src, dir, notes);
        _renamePath(src, dest);
        moved++;
        aliasesMoved = aliasesMoved || hadAlias;
      } on FileSystemException catch (e) {
        failed.add('Could not move ${p.basename(src)}: ${e.message}');
      }
    }
    rescan();
    final summary = moved == 1 && paths.length == 1
        ? 'Moved ${p.basename(paths[0])} to ${tildify(dir)}'
        : moved == paths.length
            ? 'Moved $moved AppImages to ${tildify(dir)}'
            : 'Moved $moved of ${paths.length} AppImages to ${tildify(dir)}';
    try {
      // Launchers of moved aliases must point at the new paths.
      if (aliasesMoved) {
        notes = [...apply(cfg), ...notes];
      } else {
        saveConfig(cfg);
      }
    } on FileSystemException catch (e) {
      failed.add('Could not save the new paths: ${e.message}');
    }
    if (failed.isNotEmpty) {
      fail([summary, ...failed, ...notes].join('\n'));
    } else {
      report(notes, summary);
    }
    if (moved > 0) await refreshMenus();
  }

  void hideMoveOffer() {
    moveOfferHidden = true;
    _changed();
  }

  void neverOfferMove() {
    cfg.offerMove = false;
    save();
    report([], 'You can still move an AppImage from its ⋯ menu');
  }

  // -------------------------------------------------------------------------
  // Browsing and installing

  void _refreshCatalog() {
    if (!source.isCatalog) return;
    if (source == CatalogSource.pkgforge) {
      applyDescriptions(catalogs[CatalogSource.pkgforge]!, descriptions);
      enrichPkgforge(catalogs[CatalogSource.pkgforge]!, catalogs[CatalogSource.appImageHub]!);
    }
    catalogResults = searchCatalog(catalogs[source]!, query, 1 << 30);
  }

  /// Loads a catalog from its daily cache, downloading it when the cache is
  /// missing or stale (or when `force` is set).
  Future<void> loadCatalog(CatalogSource src, {bool force = false}) async {
    if (!src.isCatalog || catalogLoading.contains(src)) return;
    final cache = src.cachePath;
    bool useCache() {
      try {
        final apps = parseCatalog(src, File(cache).readAsStringSync());
        if (apps.isEmpty) return false;
        catalogs[src] = apps;
        _refreshCatalog();
        if (src == CatalogSource.pkgforge) _loadDescriptions();
        _changed();
        return true;
      } on Exception {
        return false;
      }
    }

    if (!force && catalogIsFresh(cache) && useCache()) return;
    catalogLoading.add(src);
    searchError = '';
    _changed();
    final part = '$cache.part';
    var error = '';
    try {
      Directory(p.dirname(cache)).createSync(recursive: true);
      await download(src.url, part);
      File(part).renameSync(cache);
    } on Exception catch (e) {
      error = _msg(e);
    }
    catalogLoading.remove(src);
    // A stale copy beats nothing when we're offline.
    if (!useCache() && src == source) {
      searchError = 'Could not load the $src catalog${error.isNotEmpty ? ': $error' : ''}';
    }
    _changed();
  }

  void _saveDescriptions() {
    try {
      Directory(p.dirname(descriptionsCachePath())).createSync(recursive: true);
      File(descriptionsCachePath()).writeAsStringSync(jsonEncode(descriptions));
    } on FileSystemException {
      // Only a cache.
    }
  }

  /// The pkgforge-dev README has names only, so fetch each repository's
  /// GitHub description: the organization's repos in bulk, then the few
  /// listed projects that live elsewhere one by one. Cached for a day.
  Future<void> _loadDescriptions() async {
    if (describing || catalogs[CatalogSource.pkgforge]!.isEmpty) return;
    if (catalogIsFresh(descriptionsCachePath())) {
      try {
        final node = jsonDecode(File(descriptionsCachePath()).readAsStringSync());
        if (node is Map) {
          node.forEach((k, v) {
            if (k is String && v is String) descriptions[k] = v;
          });
          _refreshCatalog();
          _changed();
          return;
        }
      } on Exception {
        // Refetch below.
      }
    }
    describing = true;
    for (var page = 1; page <= 20; page++) {
      Object? node;
      try {
        node = await fetchJson(orgReposUrl('pkgforge-dev', page));
      } on Exception {
        break;
      }
      descriptions.addAll(parseRepoDescriptions(node));
      _refreshCatalog();
      _changed();
      if (node is! List || node.length < orgPageSize) break;
    }
    // Whatever the organization's listing lacks is archived or private, or
    // lives elsewhere.
    final missing = [
      for (final a in catalogs[CatalogSource.pkgforge]!)
        if (!descriptions.containsKey(a.repo.toLowerCase()) &&
            !a.repo.toLowerCase().startsWith('pkgforge-dev/'))
          a.repo
    ];
    for (final repo in missing) {
      try {
        descriptions.addAll(parseRepoDescriptions(await fetchJson(repoUrl(repo))));
      } on Exception {
        continue;
      }
      _refreshCatalog();
      _changed();
    }
    describing = false;
    _saveDescriptions();
    _refreshCatalog();
    _changed();
  }

  Future<void> searchGitHub() async {
    final q = query.trim();
    final id = ++_githubSearches;
    githubResults = [];
    searchError = '';
    if (q.isEmpty) {
      searchLoading = false;
      _changed();
      return;
    }
    searchLoading = true;
    _changed();
    try {
      final node = await fetchJson(githubSearchUrl(q));
      if (id != _githubSearches) return;
      githubResults = parseGitHubSearch(node);
    } on Exception catch (e) {
      if (id != _githubSearches) return;
      searchError = 'GitHub search failed: ${_msg(e)}';
    }
    searchLoading = false;
    _changed();
  }

  void setQuery(String q) {
    query = q;
    _refreshCatalog();
    _changed();
  }

  Set<String> installedRepos() => {
        for (final e in cfg.installs.entries)
          if (parseSourceSetting(e.value.source) case final src
              when src.kind == UpdateKind.gitHubReleases && fileExists(e.key))
            '${src.owner}/${src.repo}'.toLowerCase()
      };

  /// Adds a newly installed AppImage to the app menu and gives it an alias
  /// when the obvious one is free.
  Future<void> _settleIn(String dest, String name) async {
    final notes = <String>[];
    cfg.addScanDir(p.dirname(dest));
    try {
      await integrate(dest);
      await refreshMenus();
    } on Exception catch (e) {
      notes.add('Could not add it to the app menu: ${_msg(e)}');
    }
    final alias = suggestAlias(p.basename(dest));
    var msg = 'Installed $name';
    var aliased = false;
    if (alias.isNotEmpty && !cfg.aliases.containsKey(alias) && cfg.shadowedCommand(alias).isEmpty) {
      try {
        cfg.setAlias(dest, alias);
        aliased = true;
        msg += " — run it with '$alias' or from your app menu";
      } on AliasError {
        // Leave it without one.
      }
    }
    rescan();
    if (!aliased) {
      save();
      report(notes, msg);
      return;
    }
    try {
      report([...apply(cfg), ...notes], msg);
    } on FileSystemException catch (e) {
      fail('Installed $name but could not write aliases: ${e.message}');
    }
  }

  /// Downloads the newest AppImage release of `item` into ~/Applications.
  Future<void> install(CatalogApp item) async {
    final repo = item.repo;
    if (installing.containsKey(repo)) return;
    installing[repo] = -1;
    _changed();

    void failInstall(String msg) {
      installing.remove(repo);
      fail(msg);
    }

    ReleaseAsset asset;
    try {
      asset = pickRelease(await fetchJson(releasesUrl(repo)));
    } on Exception catch (e) {
      failInstall('Could not look up $repo: ${_msg(e)}');
      return;
    }
    if (asset.name.isEmpty) {
      failInstall('$repo has no AppImage release for this computer');
      return;
    }
    final dir = defaultInstallDir();
    final dest = p.join(dir, asset.name);
    if (pathExists(dest)) {
      failInstall('${tildify(dest)} already exists');
      return;
    }
    final part = p.join(dir, '.${asset.name}.part');
    try {
      Directory(dir).createSync(recursive: true);
      installing[repo] = 0;
      _changed();
      await download(asset.url, part, expected: asset.size, onProgress: (received, total) {
        if (installing.containsKey(repo) && total > 0) {
          installing[repo] = (received / total).clamp(0.0, 1.0);
          _changed();
        }
      });
      chmod(part, 0x1ed); // 0755
      moveFile(part, dest);
    } on Exception catch (e) {
      removeFile(part);
      failInstall('Could not install ${asset.name}: ${_msg(e)}');
      return;
    }
    installing.remove(repo);
    cfg.installs[dest] =
        InstallInfo(source: repo, tag: asset.tag, asset: asset.name, assetId: asset.id);
    updates[dest] = UpdateStatus(UpdateState.upToDate);
    report([], 'Adding ${asset.name} to the app menu…');
    await _settleIn(dest, asset.name);
  }

  List<CatalogApp> results() => source.isCatalog ? catalogResults : githubResults;

  void selectSource(CatalogSource src) {
    source = src;
    searchError = '';
    if (src.isCatalog) {
      _refreshCatalog();
      if (catalogs[src]!.isEmpty) loadCatalog(src);
      if (src == CatalogSource.pkgforge && catalogs[CatalogSource.appImageHub]!.isEmpty) {
        loadCatalog(CatalogSource.appImageHub); // supplies the descriptions
      }
    } else if (query.trim().isNotEmpty) {
      searchGitHub();
    }
    _changed();
  }

  void switchTo(AppPage pg) {
    page = pg;
    if (pg == AppPage.browse && source.isCatalog && catalogs[source]!.isEmpty) {
      loadCatalog(source);
    }
    _changed();
  }

  /// The refresh button: rescan, reload the catalog or search again.
  void reload() {
    if (page == AppPage.installed) {
      rescan();
      report([], 'Found ${apps.length} AppImage(s)');
    } else if (source.isCatalog) {
      loadCatalog(source, force: true);
    } else {
      searchGitHub();
    }
  }

  // -------------------------------------------------------------------------
  // AppImages opened from the file manager

  /// Called when the desktop opens files with appmanager, e.g. when the user
  /// double-clicks an AppImage.
  void openFiles(List<String> paths) {
    switchTo(AppPage.installed);
    final rejected = <String>[];
    for (var path in paths) {
      path = p.normalize(p.absolute(path));
      if (!isAppImage(path)) {
        rejected.add(p.basename(path));
      } else if (!opened.contains(path)) {
        opened.add(path);
      }
    }
    if (rejected.isNotEmpty) {
      fail('Not an AppImage: ${rejected.join(', ')}');
    } else {
      _changed();
    }
  }

  void dismissOpened(String path) {
    opened.remove(path);
    _changed();
  }

  Future<void> launch(String path) async {
    final name = p.basename(path);
    try {
      makeExecutable(path);
    } on FileSystemException catch (e) {
      fail('Could not make $name executable: ${e.message}');
      return;
    }
    try {
      // Detached, so the app outlives us and isn't our child.
      await Process.start(path, [], mode: ProcessStartMode.detached);
      report([], 'Started $name');
    } on ProcessException catch (e) {
      fail('Could not start $name: ${e.message}');
    }
  }

  /// Installs an AppImage opened from the file manager: moves it to
  /// ~/Applications (keeping any alias, update source and menu entry), then
  /// adds it to the app menu and gives it an alias.
  Future<void> adopt(String path) async {
    final name = p.basename(path);
    var dest = path;
    if (needsMove(path)) {
      final hadAlias = cfg.aliasFor(path).isNotEmpty;
      try {
        dest = await relocate(cfg, path, defaultInstallDir(), []);
        _renamePath(path, dest);
        // Its launcher must point at the new path.
        if (hadAlias) apply(cfg);
      } on FileSystemException catch (e) {
        fail('Could not move $name: ${e.message}');
        return;
      }
    }
    try {
      makeExecutable(dest);
    } on FileSystemException {
      // integrate() reports it.
    }
    opened.remove(path);
    report([], 'Installing $name…');
    await _settleIn(dest, name);
  }

  Future<void> makeDefaultHandler() async {
    try {
      makeAppImageHandler(appId);
      handler = appImageHandler();
      report([], 'Double-clicking an AppImage now opens AppManager');
      await refreshMenus();
    } on FileSystemException catch (e) {
      fail('Could not change the default app: ${e.message}');
    }
  }

  String handlerText() {
    if (handler == '$appId.desktop') {
      return 'Double-clicking an AppImage opens it here, where you can run or install it.';
    }
    if (handler.isNotEmpty) {
      return 'Double-clicking an AppImage currently opens ${handler.replaceAll('.desktop', '')}.';
    }
    return 'Your desktop picks which app opens AppImages (for example Gear Lever).';
  }

  static String describe(CatalogApp item) => [
        item.repo,
        if (item.categories.isNotEmpty) item.categories.take(3).join(', '),
        if (item.stars >= 0) '★ ${item.stars}',
        if (item.license.isNotEmpty) item.license,
      ].join(' · ');

  static String _msg(Object e) => switch (e) {
        FileSystemException(:final message, :final path) =>
          path == null || message.contains(path) ? message : '$message: $path',
        _ => '$e'.replaceFirst(RegExp(r'^(Exception|ProcessException): '), ''),
      };

  @override
  void dispose() {
    stopDownloads();
    killRunning();
    super.dispose();
  }
}
