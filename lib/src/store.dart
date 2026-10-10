/// Finding, installing and updating AppImages: the AppImageHub and
/// pkgforge-dev catalogs, GitHub releases, embedded update information,
/// zsync metadata and desktop menu integration.
///
/// Nothing here touches the network: callers download (see net.dart) and
/// hand the results to the parsers below, which keeps this module testable.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'core.dart';
import 'env.dart';

const appImageHubFeed = 'https://appimage.github.io/feed.json';
const pkgforgeList =
    'https://raw.githubusercontent.com/pkgforge-dev/Anylinux-AppImages/main/README.md';
const gitHubApi = 'https://api.github.com';
const orgPageSize = 100;
const catalogMaxAge = Duration(days: 1);
const desktopMarkerKey = 'X-AppManager-AppImage';
const desktopVersionKey = 'X-AppManager-Version';

/// Bump when `integrate` gets better, to redo old entries.
const desktopVersion = '2';
const _desktopPrefix = 'appmanager-';

enum CatalogSource {
  appImageHub('AppImageHub'),
  pkgforge('pkgforge-dev'),
  gitHub('GitHub');

  final String label;
  const CatalogSource(this.label);

  /// Whether this is a list we download whole and filter locally (as opposed
  /// to one we query per search).
  bool get isCatalog => this != CatalogSource.gitHub;

  String get url => switch (this) {
        CatalogSource.appImageHub => appImageHubFeed,
        CatalogSource.pkgforge => pkgforgeList,
        CatalogSource.gitHub => '',
      };

  String get cachePath => p.join(
      cacheDir(),
      switch (this) {
        CatalogSource.appImageHub => 'appimagehub.json',
        CatalogSource.pkgforge => 'pkgforge-dev.md',
        CatalogSource.gitHub => 'github.json',
      });

  @override
  String toString() => label;
}

class CatalogApp {
  String name;
  String summary;

  /// "owner/repo" on GitHub.
  final String repo;
  final String license;
  final List<String> categories;

  /// -1 when unknown.
  final int stars;
  final CatalogSource source;

  CatalogApp({
    required this.name,
    this.summary = '',
    required this.repo,
    this.license = '',
    List<String>? categories,
    this.stars = -1,
    required this.source,
  }) : categories = categories ?? [];

  CatalogApp copy() => CatalogApp(
      name: name,
      summary: summary,
      repo: repo,
      license: license,
      categories: List.of(categories),
      stars: stars,
      source: source);
}

class ReleaseAsset {
  String tag;

  /// AppImage file name.
  String name;

  /// Download URL of the AppImage.
  String url;
  int size;
  int id;

  /// Download URL of the matching .zsync file, if any.
  String zsyncUrl;

  ReleaseAsset({
    this.tag = '',
    this.name = '',
    this.url = '',
    this.size = 0,
    this.id = 0,
    this.zsyncUrl = '',
  });

  ReleaseAsset copy() =>
      ReleaseAsset(tag: tag, name: name, url: url, size: size, id: id, zsyncUrl: zsyncUrl);
}

enum UpdateKind { none, gitHubReleases, zsyncUrl }

class UpdateSource {
  final UpdateKind kind;
  final String owner, repo;

  /// "latest", "latest-pre", "latest-all" or a tag name.
  final String tag;

  /// Glob for the asset (the .zsync file if it ends so).
  final String pattern;
  final String url;

  const UpdateSource.none()
      : kind = UpdateKind.none,
        owner = '',
        repo = '',
        tag = '',
        pattern = '',
        url = '';

  const UpdateSource.gitHub(this.owner, this.repo, {this.tag = '', this.pattern = ''})
      : kind = UpdateKind.gitHubReleases,
        url = '';

  const UpdateSource.zsync(this.url)
      : kind = UpdateKind.zsyncUrl,
        owner = '',
        repo = '',
        tag = '',
        pattern = '';

  @override
  String toString() => switch (kind) {
        UpdateKind.none => 'none',
        UpdateKind.gitHubReleases => 'github.com/$owner/$repo',
        UpdateKind.zsyncUrl => url,
      };
}

class ZsyncInfo {
  String filename = '';

  /// Absolute URL of the AppImage.
  String url = '';

  /// Lower-case hex SHA-1 of the AppImage.
  String sha1 = '';
  int length = 0;
}

Iterable<Object?> _elems(Object? node) => node is List ? node : const [];

String _str(Object? map, String key) {
  if (map is Map && map[key] is String) return map[key] as String;
  return '';
}

int _int(Object? map, String key) {
  if (map is Map && map[key] is num) return (map[key] as num).toInt();
  return 0;
}

bool _bool(Object? map, String key) => map is Map && map[key] == true;

// ---------------------------------------------------------------------------
// URLs

String encodeQuery(String s) {
  final out = StringBuffer();
  for (final b in utf8.encode(s)) {
    final c = String.fromCharCode(b);
    if (RegExp(r'[A-Za-z0-9\-_.~]').hasMatch(c) && b < 128) {
      out.write(c);
    } else if (c == ' ') {
      out.write('+');
    } else {
      out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}

/// Repositories matching `query` whose README (or name, description or
/// topics) mention AppImage, most starred first.
String githubSearchUrl(String query) {
  final q = encodeQuery('${query.trim()} appimage in:name,description,topics,readme fork:false');
  return '$gitHubApi/search/repositories?sort=stars&order=desc&per_page=50&q=$q';
}

/// The API URL listing a repository's releases, or a single release when
/// `tag` names one.
String releasesUrl(String repo, [String tag = '']) => switch (tag) {
      '' || 'latest-pre' || 'latest-all' => '$gitHubApi/repos/$repo/releases?per_page=20',
      'latest' => '$gitHubApi/repos/$repo/releases/latest',
      _ => '$gitHubApi/repos/$repo/releases/tags/${encodeQuery(tag)}',
    };

String repoUrl(String repo) => '$gitHubApi/repos/$repo';

/// One page (up to `orgPageSize` repositories) of an organization's repos.
String orgReposUrl(String org, int page) =>
    '$gitHubApi/orgs/$org/repos?per_page=$orgPageSize&page=$page';

String descriptionsCachePath() => p.join(cacheDir(), 'descriptions.json');

bool catalogIsFresh(String path) {
  try {
    final st = FileStat.statSync(path);
    if (st.type == FileSystemEntityType.notFound) return false;
    return DateTime.now().difference(st.modified) < catalogMaxAge;
  } on FileSystemException {
    return false;
  }
}

String defaultInstallDir() => p.join(homeDir(), 'Applications');

// ---------------------------------------------------------------------------
// Catalog

final _repoPart = RegExp(r'^[A-Za-z0-9\-_.]+$');

/// Turns "owner/repo", "github.com/owner/repo" or a GitHub URL (possibly
/// pointing into the repo) into "owner/repo"; "" if it isn't one.
String normalizeRepo(String s) {
  s = s.trim();
  for (final prefix in ['https://', 'http://']) {
    if (s.startsWith(prefix)) s = s.substring(prefix.length);
  }
  if (s.startsWith('www.')) s = s.substring(4);
  if (s.startsWith('github.com/')) {
    s = s.substring('github.com/'.length);
  } else if (s.split('/')[0].contains('.')) {
    return ''; // some other host
  }
  final parts = s.split('/');
  if (parts.length < 2) return '';
  var repo = parts[1];
  if (repo.endsWith('.git')) repo = repo.substring(0, repo.length - 4);
  for (final part in [parts[0], repo]) {
    if (!_repoPart.hasMatch(part)) return '';
  }
  return '${parts[0]}/$repo';
}

/// Strips the HTML tags some catalog descriptions contain, decodes the
/// common entities and collapses whitespace.
String plainText(String html) {
  final text = StringBuffer();
  var inTag = false;
  for (final c in html.split('')) {
    if (c == '<') {
      inTag = true;
      text.write(' ');
    } else if (c == '>' && inTag) {
      inTag = false;
    } else if (!inTag) {
      text.write(c);
    }
  }
  final decoded = text
      .toString()
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
  return decoded.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');
}

/// "LicenseRef-proprietary=https://…" -> "proprietary".
String shortLicense(String license) {
  var result = license.trim();
  if (result.startsWith('LicenseRef-')) result = result.substring('LicenseRef-'.length);
  final eq = result.indexOf('=');
  if (eq >= 0) result = result.substring(0, eq);
  return result;
}

/// Parses https://appimage.github.io/feed.json, keeping apps that are
/// published on GitHub (the only ones we can install and update).
List<CatalogApp> parseAppImageHub(Object? node) {
  final result = <CatalogApp>[];
  for (final item in _elems(node is Map ? node['items'] : null)) {
    var repo = '';
    for (final link in _elems(item is Map ? item['links'] : null)) {
      if (_str(link, 'type') == 'GitHub') {
        repo = normalizeRepo(_str(link, 'url'));
        if (repo.isNotEmpty) break;
      }
    }
    if (repo.isEmpty) continue;
    var name = _str(item, 'name').replaceAll('_', ' ');
    if (name.isEmpty) name = repo.split('/')[1];
    result.add(CatalogApp(
      name: name,
      summary: plainText(_str(item, 'description')),
      repo: repo,
      license: shortLicense(_str(item, 'license')),
      categories: [
        for (final c in _elems((item as Map)['categories']))
          if (c is String && c.isNotEmpty) c
      ],
      source: CatalogSource.appImageHub,
    ));
  }
  return result;
}

/// Parses the app tables of pkgforge-dev's Anylinux-AppImages README:
/// one-cell rows of the form `| [Name](https://github.com/owner/repo) |`.
/// These AppImages bundle all their libraries (sharun + uruntime), so they
/// run on old, musl and non-FHS distros alike.
List<CatalogApp> parsePkgforge(String markdown) {
  final result = <CatalogApp>[];
  final seen = <String>{};
  for (final line in const LineSplitter().convert(markdown)) {
    final row = line.trim();
    if (!row.startsWith('| [') || !row.endsWith('|')) continue;
    final nameEnd = row.indexOf('](');
    if (nameEnd < 0) continue;
    final urlEnd = row.indexOf(')', nameEnd);
    if (urlEnd < 0 || row.substring(urlEnd + 1).trim() != '|') continue;
    final repo = normalizeRepo(row.substring(nameEnd + 2, urlEnd));
    if (repo.isEmpty || !seen.add(repo.toLowerCase())) continue;
    final name = row.substring(3, nameEnd).trim();
    result.add(CatalogApp(
      name: name.isNotEmpty ? name : repo.split('/')[1],
      summary: repo.toLowerCase().startsWith('pkgforge-dev/')
          ? 'Anylinux AppImage built by pkgforge-dev'
          : 'Publishes an Anylinux AppImage',
      repo: repo,
      categories: ['Anylinux'],
      source: CatalogSource.pkgforge,
    ));
  }
  return result;
}

/// Reads `full_name` -> `description` (keyed in lower case) from a GitHub
/// repository object or a list of them.
Map<String, String> parseRepoDescriptions(Object? node) {
  final result = <String, String>{};
  void add(Object? item) {
    final repo = _str(item, 'full_name');
    if (repo.isNotEmpty) result[repo.toLowerCase()] = plainText(_str(item, 'description')).trim();
  }

  if (node is List) {
    node.forEach(add);
  } else if (node is Map) {
    add(node);
  }
  return result;
}

/// Replaces summaries with the repositories' own GitHub descriptions.
void applyDescriptions(List<CatalogApp> apps, Map<String, String> descriptions) {
  for (final a in apps) {
    final d = descriptions[a.repo.toLowerCase()] ?? '';
    if (d.isNotEmpty) a.summary = d;
  }
}

/// The pkgforge-dev README lists names only, so entries carry a generic
/// placeholder summary. Borrows the real description from a described
/// catalog entry with the same name or repo.
void enrichPkgforge(List<CatalogApp> apps, List<CatalogApp> described) {
  String key(String s) => s.toLowerCase().replaceAll(RegExp(r'[-_ ]'), '');
  final byKey = <String, String>{};
  for (final d in described) {
    if (d.summary.isEmpty) continue;
    for (final k in [key(d.name), key(d.repo)]) {
      byKey.putIfAbsent(k, () => d.summary);
    }
  }
  for (final a in apps) {
    if (a.source != CatalogSource.pkgforge || !a.summary.contains('Anylinux AppImage')) continue;
    for (final k in [key(a.name), key(a.repo)]) {
      final s = byKey[k];
      if (s != null) {
        a.summary = s;
        break;
      }
    }
  }
}

/// Parses a downloaded catalog. Throws on malformed JSON.
List<CatalogApp> parseCatalog(CatalogSource source, String data) => switch (source) {
      CatalogSource.appImageHub => parseAppImageHub(jsonDecode(data)),
      CatalogSource.pkgforge => parsePkgforge(data),
      CatalogSource.gitHub => [],
    };

List<CatalogApp> parseGitHubSearch(Object? node) {
  final result = <CatalogApp>[];
  for (final item in _elems(node is Map ? node['items'] : null)) {
    final repo = _str(item, 'full_name');
    if (repo.isEmpty) continue;
    final license = _str((item as Map)['license'], 'spdx_id');
    result.add(CatalogApp(
      name: _str(item, 'name'),
      summary: plainText(_str(item, 'description')),
      repo: repo,
      stars: _int(item, 'stargazers_count'),
      license: license == 'NOASSERTION' ? '' : license,
      categories: [for (final t in _elems(item['topics'])) if (t is String) t],
      source: CatalogSource.gitHub,
    ));
  }
  return result;
}

/// Case-insensitive search: every word must occur in the name, summary,
/// categories or repo. Name matches rank first.
List<CatalogApp> searchCatalog(List<CatalogApp> apps, String query, [int limit = 200]) {
  final q = query.trim().toLowerCase();
  final words = q.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  final scored = <(int, CatalogApp)>[];
  for (final app in apps) {
    final name = app.name.toLowerCase();
    final hay = '$name\n${app.summary.toLowerCase()}\n'
        '${app.categories.join(' ').toLowerCase()}\n${app.repo.toLowerCase()}';
    if (!words.every(hay.contains)) continue;
    final score = q.isEmpty
        ? 0
        : name == q
            ? 100
            : name.startsWith(q)
                ? 50
                : name.contains(q)
                    ? 30
                    : app.repo.toLowerCase().contains(q)
                        ? 20
                        : 10;
    scored.add((score, app));
  }
  scored.sort((a, b) {
    var r = b.$1.compareTo(a.$1);
    if (r == 0) r = b.$2.stars.compareTo(a.$2.stars);
    if (r == 0) r = a.$2.name.toLowerCase().compareTo(b.$2.name.toLowerCase());
    return r;
  });
  return [for (final s in scored.take(limit)) s.$2];
}

// ---------------------------------------------------------------------------
// Picking a release asset

/// Shell-style match supporting `*` and `?`.
bool globMatch(String pattern, String s) {
  var pi = 0, i = 0, star = -1, mark = -1;
  while (i < s.length) {
    if (pi < pattern.length && (pattern[pi] == '?' || pattern[pi] == s[i])) {
      pi++;
      i++;
    } else if (pi < pattern.length && pattern[pi] == '*') {
      star = pi;
      mark = i;
      pi++;
    } else if (star >= 0) {
      pi = star + 1;
      mark++;
      i = mark;
    } else {
      return false;
    }
  }
  while (pi < pattern.length && pattern[pi] == '*') {
    pi++;
  }
  return pi == pattern.length;
}

const _archAliases = [
  ['x86_64', 'amd64', 'x64', 'x86-64'],
  ['aarch64', 'arm64'],
  ['armhf', 'armv7l', 'armv7', 'arm'],
  ['i386', 'i686', 'x86', 'ia32'],
];

List<String> hostArchTokens() {
  final abi = Abi.current();
  if (abi == Abi.linuxX64) return _archAliases[0];
  if (abi == Abi.linuxArm64) return _archAliases[1];
  if (abi == Abi.linuxArm) return _archAliases[2];
  if (abi == Abi.linuxIA32) return _archAliases[3];
  return [abi.toString().split('_').last];
}

/// 2 if the file name names our architecture, 1 if it names none, and -1 if
/// it is for another one.
int archScore(String name, [List<String>? arch]) {
  arch ??= hostArchTokens();
  final lower = name.toLowerCase();
  final tokens = [
    ...lower.split(RegExp(r'[-. +()\[\]]')),
    ...lower.split(RegExp(r'[-. +_]')), // "linux_x64"
  ];
  if (tokens.any(arch.contains)) return 2;
  for (final group in _archAliases) {
    if (tokens.any(group.contains)) return -1;
  }
  return 1;
}

/// A file name with its version numbers masked, used to find the same
/// flavour of an AppImage in a newer release.
String assetKey(String name) => name.toLowerCase().replaceAll(RegExp(r'[0-9]+'), '#');

bool _isAppImageName(String name) => name.toLowerCase().endsWith('.appimage');

/// Picks the AppImage to download from one GitHub release. Returns an asset
/// with an empty name when the release has none.
ReleaseAsset pickAsset(Object? release,
    {String pattern = '', String previous = '', List<String>? arch}) {
  arch ??= hostArchTokens();
  final zsyncPattern = pattern.toLowerCase().endsWith('.zsync');
  final byName = <(String, Object?)>[
    for (final asset in _elems(release is Map ? release['assets'] : null))
      (_str(asset, 'name'), asset)
  ];
  final candidates = <(int, Object?)>[];
  for (final (name, asset) in byName) {
    if (name.toLowerCase().endsWith('.zsync')) continue;
    if (pattern.isNotEmpty) {
      // A .zsync pattern names the file that sits next to the AppImage.
      if (!globMatch(pattern, zsyncPattern ? '$name.zsync' : name)) continue;
    } else if (!_isAppImageName(name)) {
      continue;
    }
    final a = archScore(name, arch);
    if (a < 0 && pattern.isEmpty) continue;
    var score = a * 10;
    if (previous.isNotEmpty && assetKey(name) == assetKey(previous)) score += 100;
    candidates.add((score, asset));
  }
  if (candidates.isEmpty) return ReleaseAsset();
  candidates.sort((a, b) {
    final r = b.$1.compareTo(a.$1);
    return r != 0 ? r : _str(a.$2, 'name').length.compareTo(_str(b.$2, 'name').length);
  });
  final best = candidates.first.$2;
  final result = ReleaseAsset(
    tag: _str(release, 'tag_name'),
    name: _str(best, 'name'),
    url: _str(best, 'browser_download_url'),
    size: _int(best, 'size'),
    id: _int(best, 'id'),
  );
  for (final (name, asset) in byName) {
    if (name == '${result.name}.zsync') result.zsyncUrl = _str(asset, 'browser_download_url');
  }
  return result;
}

/// Picks the release asset to install from the reply to `releasesUrl` (a
/// single release or a list). Unless `tag` is "latest-pre" or "latest-all",
/// stable releases are preferred over pre-releases.
ReleaseAsset pickRelease(Object? releases,
    {String tag = '', String pattern = '', String previous = '', List<String>? arch}) {
  if (releases is Map) {
    return pickAsset(releases, pattern: pattern, previous: previous, arch: arch);
  }
  if (releases is! List) return ReleaseAsset();
  final passes = (tag == 'latest-pre' || tag == 'latest-all')
      ? [
          {false, true}
        ]
      : [
          {false},
          {true}
        ];
  for (final allowed in passes) {
    for (final release in releases) {
      if (_bool(release, 'draft') || !allowed.contains(_bool(release, 'prerelease'))) continue;
      final asset = pickAsset(release, pattern: pattern, previous: previous, arch: arch);
      if (asset.name.isNotEmpty) return asset;
    }
  }
  return ReleaseAsset();
}

// ---------------------------------------------------------------------------
// Embedded update information

int _readLE(Uint8List data, int pos, int size) {
  var result = 0;
  for (var i = size - 1; i >= 0; i--) {
    result = (result << 8) | data[pos + i];
  }
  return result;
}

/// Returns the contents of the named section of a little-endian ELF file,
/// or empty bytes if there is no such section.
Uint8List readElfSection(String path, String section) {
  final empty = Uint8List(0);
  RandomAccessFile f;
  try {
    f = File(path).openSync();
  } on FileSystemException {
    return empty;
  }
  try {
    Uint8List readAt(int pos, int n) {
      f.setPositionSync(pos);
      return f.readSync(n);
    }

    final ident = readAt(0, 64);
    if (ident.length < 64 ||
        ident[0] != 0x7F ||
        ident[1] != 0x45 ||
        ident[2] != 0x4C ||
        ident[3] != 0x46 ||
        ident[5] != 1) {
      return empty;
    }
    final is64 = ident[4] == 2;
    final shoff = is64 ? _readLE(ident, 0x28, 8) : _readLE(ident, 0x20, 4);
    final shentsize = is64 ? _readLE(ident, 0x3A, 2) : _readLE(ident, 0x2E, 2);
    final shnum = is64 ? _readLE(ident, 0x3C, 2) : _readLE(ident, 0x30, 2);
    final shstrndx = is64 ? _readLE(ident, 0x3E, 2) : _readLE(ident, 0x32, 2);
    if (shoff <= 0 ||
        shnum <= 0 ||
        shnum > 4096 ||
        shstrndx >= shnum ||
        shentsize < (is64 ? 0x40 : 0x28)) {
      return empty;
    }
    final table = readAt(shoff, shentsize * shnum);
    if (table.length < shentsize * shnum) return empty;
    (int, int, int) header(int i) {
      final base = i * shentsize;
      return is64
          ? (_readLE(table, base, 4), _readLE(table, base + 0x18, 8), _readLE(table, base + 0x20, 8))
          : (_readLE(table, base, 4), _readLE(table, base + 0x10, 4), _readLE(table, base + 0x14, 4));
    }

    final (_, strOff, strSize) = header(shstrndx);
    if (strSize <= 0 || strSize > 1000000) return empty;
    final names = readAt(strOff, strSize);
    for (var i = 0; i < shnum; i++) {
      final (nameOff, off, size) = header(i);
      if (nameOff >= names.length) continue;
      var stop = names.indexOf(0, nameOff);
      if (stop < 0) stop = names.length;
      final name = latin1.decode(names.sublist(nameOff, stop));
      if (name == section) {
        if (size <= 0 || size > 1000000) return empty;
        return readAt(off, size);
      }
    }
    return empty;
  } on FileSystemException {
    return empty;
  } finally {
    f.closeSync();
  }
}

/// The update information embedded in an AppImage (its `.upd_info`
/// section), e.g. "gh-releases-zsync|owner|repo|latest|App-*.zsync".
String readUpdateInfo(String path) {
  final raw = readElfSection(path, '.upd_info');
  final stop = raw.indexOf(0);
  return latin1.decode(stop < 0 ? raw : raw.sublist(0, stop)).trim();
}

UpdateSource parseUpdateInfo(String info) {
  final parts = info.trim().split('|');
  switch (parts[0]) {
    case 'zsync':
      if (parts.length >= 2 && parts[1].isNotEmpty) {
        return UpdateSource.zsync(parts.sublist(1).join('|'));
      }
    case 'gh-releases-zsync' || 'gh-releases-direct':
      if (parts.length >= 5 && parts[1].isNotEmpty && parts[2].isNotEmpty) {
        return UpdateSource.gitHub(parts[1], parts[2],
            tag: parts[3].isNotEmpty ? parts[3] : 'latest', pattern: parts[4]);
      }
  }
  return const UpdateSource.none();
}

/// Parses what a user typed as an update source: a GitHub repo (or any URL
/// within it), a .zsync URL or a full update information string.
UpdateSource parseSourceSetting(String s) {
  s = s.trim();
  if (s.contains('|')) return parseUpdateInfo(s);
  if (s.toLowerCase().endsWith('.zsync') && s.contains('://')) return UpdateSource.zsync(s);
  final repo = normalizeRepo(s);
  if (repo.isNotEmpty) {
    final parts = repo.split('/');
    return UpdateSource.gitHub(parts[0], parts[1]);
  }
  return const UpdateSource.none();
}

/// Where to look for updates: the source the user set (or that the app was
/// installed from) wins over the information embedded in the AppImage.
UpdateSource updateSourceFor(InstallInfo info, String embedded) {
  if (info.source.isNotEmpty) {
    final src = parseSourceSetting(info.source);
    if (src.kind != UpdateKind.none) return src;
  }
  return parseUpdateInfo(embedded);
}

// ---------------------------------------------------------------------------
// zsync

String resolveUrl(String base, String rel) {
  if (rel.contains('://')) return rel;
  final schemeEnd = base.indexOf('://');
  if (rel.startsWith('/')) {
    final hostEnd = base.indexOf('/', schemeEnd + 3);
    return (hostEnd < 0 ? base : base.substring(0, hostEnd)) + rel;
  }
  final q = base.indexOf(RegExp(r'[?#]'));
  final path = q < 0 ? base : base.substring(0, q);
  return path.substring(0, path.lastIndexOf('/') + 1) + rel;
}

/// Parses the header of a .zsync file.
ZsyncInfo parseZsync(String data, String zsyncUrl) {
  final result = ZsyncInfo();
  for (final line in data.split('\n')) {
    final l = line.endsWith('\r') ? line.substring(0, line.length - 1) : line;
    if (l.isEmpty) break;
    final colon = l.indexOf(':');
    if (colon < 0) continue;
    final key = l.substring(0, colon).trim();
    final value = l.substring(colon + 1).trim();
    switch (key) {
      case 'Filename':
        result.filename = value;
      case 'URL':
        result.url = resolveUrl(zsyncUrl, value);
      case 'SHA-1':
        result.sha1 = value.toLowerCase();
      case 'Length':
        result.length = int.tryParse(value) ?? 0;
    }
  }
  if (result.url.isEmpty && result.filename.isNotEmpty) {
    result.url = resolveUrl(zsyncUrl, result.filename);
  }
  return result;
}

// ---------------------------------------------------------------------------
// Desktop integration

String applicationsDir() => p.join(dataHome(), 'applications');

/// The user's hicolor icon theme, where menu icons are installed.
String iconThemeDir() => p.join(dataHome(), 'icons', 'hicolor');

/// Where older versions put menu icons; cleaned up on (un)integrate.
String _legacyIconsDir() => p.join(dataHome(), 'appmanager', 'icons');

int _fnv1a(String s) {
  var h = 2166136261;
  for (final b in utf8.encode(s)) {
    h = ((h ^ b) * 16777619) & 0xFFFFFFFF;
  }
  return h;
}

/// A stable, unique file name stem for the menu entry of an AppImage.
String desktopId(String appPath) {
  final slug = StringBuffer();
  for (final c in stripAppImageExt(p.basename(appPath)).toLowerCase().split('')) {
    if (RegExp(r'[a-z0-9]').hasMatch(c)) {
      slug.write(c);
    } else if (slug.isNotEmpty && !slug.toString().endsWith('-')) {
      slug.write('-');
    }
  }
  var s = slug.toString().replaceAll(RegExp(r'^-+|-+$'), '');
  if (s.length > 40) s = s.substring(0, 40);
  return '$_desktopPrefix$s-${_fnv1a(appPath).toRadixString(16).padLeft(8, '0')}';
}

/// Quotes `path` for an Exec= key (desktop entry spec: reserved characters
/// need double quotes; `%` and the string escape `\` are doubled).
String desktopExecArg(String path) {
  const reserved = ' \t\n"\'\\><~|&;\$*?#()`';
  var arg = path;
  if (path.split('').any(reserved.contains)) {
    final b = StringBuffer('"');
    for (final c in path.split('')) {
      if ('"`\$\\'.contains(c)) b.write('\\');
      b.write(c);
    }
    b.write('"');
    arg = b.toString();
  }
  return arg.replaceAll('\\', '\\\\').replaceAll('%', '%%');
}

/// Replaces the program of an Exec= value, keeping its arguments.
String _replaceExec(String value, String exec) {
  var i = 0;
  if (value.startsWith('"')) {
    i = 1;
    while (i < value.length && value[i] != '"') {
      if (value[i] == '\\') i++;
      i++;
    }
    i++;
  } else {
    while (i < value.length && value[i] != ' ' && value[i] != '\t') {
      i++;
    }
  }
  return exec + (i < value.length ? value.substring(i) : '');
}

/// Adapts an AppImage's own .desktop file so the menu launches `appPath`
/// and shows `icon`. Builds a minimal entry when `content` is empty.
String rewriteDesktopEntry(String content, String appPath, String icon) {
  final exec = desktopExecArg(appPath);
  if (!content.contains('[Desktop Entry]')) {
    content = '[Desktop Entry]\nType=Application\nName='
        '${stripAppImageExt(p.basename(appPath))}\nExec=$exec\n'
        'Terminal=false\nCategories=Utility;\n';
  }
  var group = '';
  final lines = <String>[];
  void addMarkers() {
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    lines.add('$desktopMarkerKey=$appPath');
    lines.add('$desktopVersionKey=$desktopVersion');
    if (icon.isNotEmpty) lines.add('Icon=$icon');
  }

  for (final line in content.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
      if (group == '[Desktop Entry]') {
        addMarkers();
        lines.add('');
      }
      group = trimmed;
      lines.add(line);
      continue;
    }
    final eq = line.indexOf('=');
    final key = eq < 0 ? '' : line.substring(0, eq).trim();
    if (key == 'TryExec' || key == desktopMarkerKey || key == desktopVersionKey) continue;
    if (key == 'Icon' && icon.isNotEmpty && group == '[Desktop Entry]') continue;
    if (key == 'Exec' && group.startsWith('[Desktop')) {
      lines.add('Exec=${_replaceExec(line.substring(eq + 1).trim(), exec)}');
      continue;
    }
    lines.add(line);
  }
  if (group == '[Desktop Entry]') addMarkers();
  return '${lines.join('\n').trimRight()}\n';
}

/// The menu entry appmanager created for `appPath`, or "".
String desktopEntryFor(String appPath) {
  final path = p.join(applicationsDir(), '${desktopId(appPath)}.desktop');
  return fileExists(path) ? path : '';
}

bool isIntegrated(String appPath) => desktopEntryFor(appPath).isNotEmpty;

String readDesktopKey(String content, String key) {
  var inEntry = false;
  for (final line in content.split('\n')) {
    final t = line.trim();
    if (t.startsWith('[')) {
      inEntry = t == '[Desktop Entry]';
    } else if (inEntry && t.startsWith('$key=')) {
      return t.substring(key.length + 1).trim();
    }
  }
  return '';
}

/// Whether `appPath` has a menu entry written by an older, less capable
/// `integrate` (e.g. a stub that missed the AppImage's own .desktop file).
bool needsReintegration(String appPath) {
  final entry = desktopEntryFor(appPath);
  if (entry.isEmpty) return false;
  try {
    return readDesktopKey(File(entry).readAsStringSync(), desktopVersionKey) != desktopVersion;
  } on FileSystemException {
    return false;
  }
}

bool _startsWith(List<int> data, String prefix) {
  if (data.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (data[i] != prefix.codeUnitAt(i)) return false;
  }
  return true;
}

String _iconExt(List<int> data) {
  if (_startsWith(data, '\x89PNG')) return '.png';
  if (_startsWith(data, '/* XPM')) return '.xpm';
  final head = latin1.decode(data.sublist(0, data.length < 4096 ? data.length : 4096),
      allowInvalid: true);
  return head.contains('<svg') ? '.svg' : '';
}

const _hicolorSizes = [16, 22, 24, 32, 36, 48, 64, 72, 96, 128, 192, 256, 512];

/// The larger dimension of a PNG or XPM image, or 0 if unknown.
int iconSize(List<int> data) {
  if (_startsWith(data, '\x89PNG') &&
      data.length >= 24 &&
      latin1.decode(data.sublist(12, 16), allowInvalid: true) == 'IHDR') {
    var w = 0, h = 0;
    for (var i = 0; i < 4; i++) {
      w = (w << 8) | data[16 + i];
      h = (h << 8) | data[20 + i];
    }
    return w > h ? w : h;
  }
  if (_startsWith(data, '/* XPM')) {
    // The first string holds "<width> <height> <colors> <chars per pixel>".
    final text = latin1.decode(data, allowInvalid: true);
    final start = text.indexOf('"');
    if (start < 0) return 0;
    final stop = text.indexOf('"', start + 1);
    if (stop < 0) return 0;
    final fields =
        text.substring(start + 1, stop).split(RegExp(r'\s+')).where((f) => f.isNotEmpty).toList();
    if (fields.length >= 2) {
      final w = int.tryParse(fields[0]), h = int.tryParse(fields[1]);
      if (w != null && h != null) return w > h ? w : h;
    }
  }
  return 0;
}

/// The hicolor directory an icon belongs in: `scalable` for SVGs, else the
/// standard size closest to the image's (256x256 if it can't be read).
String iconSubdir(List<int> data) {
  if (_iconExt(data) == '.svg') return 'scalable';
  var size = iconSize(data);
  if (size <= 0) size = 256;
  var best = _hicolorSizes.first;
  for (final s in _hicolorSizes) {
    if ((s - size).abs() < (best - size).abs()) best = s;
  }
  return '${best}x$best';
}

/// Deletes every icon named `id` from the hicolor theme and the old folder.
void _removeIcons(String id) {
  if (dirExists(iconThemeDir())) {
    for (final dir in Directory(iconThemeDir()).listSync()) {
      if (dir is! Directory) continue;
      for (final ext in ['.png', '.svg', '.xpm']) {
        removeFile(p.join(dir.path, 'apps', '$id$ext'));
      }
    }
  }
  for (final ext in ['.png', '.svg', '.xpm']) {
    removeFile(p.join(_legacyIconsDir(), '$id$ext'));
  }
}

/// Bumps the theme folder's mtime so running apps rescan it and ignore a
/// stale icon cache.
void _touchIconTheme() {
  if (dirExists(iconThemeDir())) {
    Process.runSync('touch', ['-c', '--', iconThemeDir()]);
  }
}

enum RunResult { succeeded, failed, timedOut }

/// Process groups `runWithTimeout` is waiting on, killed by `killRunning`.
final _runningGroups = <int>{};

void _killGroup(int pid) {
  Process.runSync('kill', ['-KILL', '--', '-$pid']);
  Process.killPid(pid, ProcessSignal.sigkill);
}

/// Kills everything `runWithTimeout` is still running, so quitting doesn't
/// leave an app started by mistake behind.
void killRunning() {
  for (final pid in List.of(_runningGroups)) {
    _killGroup(pid);
  }
  _runningGroups.clear();
}

/// Runs `exe` with its output discarded, killing it and everything it
/// started after `timeout`.
Future<RunResult> runWithTimeout(String exe, List<String> args, String dir,
    {Duration timeout = const Duration(seconds: 15)}) async {
  Process proc;
  try {
    // Its own process group, so a runtime that starts the app instead of
    // extracting can be killed along with whatever it spawned.
    proc = await Process.start(
        '/bin/sh',
        [
          '-c',
          'exec >/dev/null 2>&1 </dev/null; '
              'command -v setsid >/dev/null && exec setsid "\$0" "\$@"; exec "\$0" "\$@"',
          exe,
          ...args
        ],
        workingDirectory: dir,
        environment: childEnvironment(),
        includeParentEnvironment: false);
  } on ProcessException {
    return RunResult.failed;
  }
  _runningGroups.add(proc.pid);
  try {
    final code = await proc.exitCode.timeout(timeout);
    return code == 0 ? RunResult.succeeded : RunResult.failed;
  } on TimeoutException {
    _killGroup(proc.pid);
    await proc.exitCode;
    return RunResult.timedOut;
  } finally {
    _runningGroups.remove(proc.pid);
  }
}

class ExtractTimeout implements Exception {
  final String message;
  ExtractTimeout(this.message);
  @override
  String toString() => message;
}

/// Extracts files matching `pattern` with the AppImage runtime's
/// `--appimage-extract` into `dir`/squashfs-root. Gives up after 15 s with
/// `ExtractTimeout`, in case an unusual runtime starts the app instead;
/// `integrate` then gives up rather than waiting that long for every file.
Future<bool> extractFromAppImage(String appPath, String pattern, String dir) async {
  switch (await runWithTimeout(appPath, ['--appimage-extract', pattern], dir)) {
    case RunResult.succeeded:
      return true;
    case RunResult.failed:
      return false;
    case RunResult.timedOut:
      throw ExtractTimeout(
          '${p.basename(appPath)} did not extract its files within 15 s; is it an AppImage?');
  }
}

/// Adds `appPath` to the application menu (like Gear Lever): copies its
/// .desktop file and icon out of the AppImage and points them at it.
/// Returns the path of the written .desktop file.
Future<String> integrate(String appPath) async {
  final tmp = Directory.systemTemp.createTempSync('appmanager-extract-');
  try {
    makeExecutable(appPath);
    final root = p.join(tmp.path, 'squashfs-root');

    /// Reads `want` out of the AppImage, following symlinks (linuxdeploy
    /// makes the top-level .desktop and .DirIcon links into usr/share), which
    /// `--appimage-extract` only extracts as links. Empty if missing.
    Future<List<int>> extractFile(String want) async {
      for (var i = 0; i < 4; i++) {
        if (!await extractFromAppImage(appPath, want, tmp.path)) return const [];
        final got = p.join(root, want);
        if (isSymlink(got)) {
          want = p.normalize(p.join(p.dirname(want), Link(got).targetSync()));
          if (want.startsWith('/') || want.startsWith('..')) return const [];
          continue;
        }
        if (fileExists(got)) {
          try {
            return File(got).readAsBytesSync();
          } on FileSystemException {
            return const [];
          }
        }
        return const [];
      }
      return const [];
    }

    var desktop = '';
    if (await extractFromAppImage(appPath, '*.desktop', tmp.path) && dirExists(root)) {
      // The entry the AppImage spec requires sits at the top level.
      for (final e in Directory(root).listSync(followLinks: false)) {
        if (e is Directory || !e.path.endsWith('.desktop')) continue;
        desktop = utf8.decode(await extractFile(p.basename(e.path)), allowMalformed: true);
        if (desktop.isNotEmpty) break;
      }
      if (desktop.isEmpty) {
        for (final e in Directory(root).listSync(recursive: true, followLinks: false)) {
          if (e is File && e.path.endsWith('.desktop')) {
            try {
              desktop = e.readAsStringSync();
            } on FileSystemException {
              // Unreadable; carry on without it.
            }
            break;
          }
        }
      }
    }
    var iconData = await extractFile('.DirIcon');
    if (iconData.isEmpty && desktop.isNotEmpty) {
      final name = readDesktopKey(desktop, 'Icon');
      if (name.isNotEmpty && !name.contains('/')) {
        for (final ext in ['.png', '.svg', '.xpm']) {
          iconData = await extractFile('$name$ext');
          if (iconData.isNotEmpty) break;
        }
      }
    }
    final id = desktopId(appPath);
    var icon = '';
    final ext = _iconExt(iconData);
    _removeIcons(id);
    if (ext.isNotEmpty) {
      final dir = p.join(iconThemeDir(), iconSubdir(iconData), 'apps');
      Directory(dir).createSync(recursive: true);
      File(p.join(dir, '$id$ext')).writeAsBytesSync(iconData);
      icon = id;
    }
    _touchIconTheme();
    Directory(applicationsDir()).createSync(recursive: true);
    final result = p.join(applicationsDir(), '$id.desktop');
    File(result).writeAsStringSync(rewriteDesktopEntry(desktop, appPath, icon));
    return result;
  } finally {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Leftovers in /tmp are harmless.
    }
  }
}

/// Removes the menu entry and icon `integrate` created. Returns whether
/// there was one.
bool unintegrate(String appPath) {
  final id = desktopId(appPath);
  final entry = p.join(applicationsDir(), '$id.desktop');
  final existed = fileExists(entry);
  removeFile(entry);
  _removeIcons(id);
  _touchIconTheme();
  return existed;
}

/// Asks the desktop (including KDE) to notice changed menu entries and
/// icons, if the tools exist. The icon cache is only rebuilt if the user
/// already has one, since a stale cache would hide new icons.
Future<void> refreshMenus() async {
  final tmp = Directory.systemTemp.path;
  final tool = findExe('update-desktop-database');
  if (tool.isNotEmpty) {
    await runWithTimeout(tool, ['-q', applicationsDir()], tmp, timeout: const Duration(seconds: 5));
  }
  if (fileExists(p.join(iconThemeDir(), 'icon-theme.cache'))) {
    for (final name in ['gtk-update-icon-cache', 'gtk4-update-icon-cache']) {
      final cacheTool = findExe(name);
      if (cacheTool.isNotEmpty) {
        await runWithTimeout(cacheTool, ['-q', '-t', '-f', iconThemeDir()], tmp);
        break;
      }
    }
  }
  // KDE reads menu entries from its own ksycoca cache, so without this Plasma
  // misses new entries and pins the AppImage's temporary mount instead.
  for (final name in ['kbuildsycoca6', 'kbuildsycoca5']) {
    final sycoca = findExe(name);
    if (sycoca.isNotEmpty) {
      await runWithTimeout(sycoca, [], tmp);
      break;
    }
  }
  // Running KDE apps (plasmashell's launchers) keep icons in memory until
  // told the theme changed.
  final dbusSend = findExe('dbus-send');
  if (dbusSend.isNotEmpty) {
    await runWithTimeout(
        dbusSend,
        [
          '--session',
          '--type=signal',
          '/KIconLoader',
          'org.kde.KIconLoader.iconChanged',
          'int32:0'
        ],
        tmp,
        timeout: const Duration(seconds: 5));
  }
}

// ---------------------------------------------------------------------------
// Opening AppImages from the file manager

const appImageMimeTypes = ['application/vnd.appimage', 'application/x-iso9660-appimage'];
const _selfMarkerKey = 'X-AppManager-Self';

/// The user's mimeapps.list files, highest precedence first (XDG MIME
/// Applications spec): desktop-specific ones, then the generic one, then the
/// deprecated copy in the applications folder.
List<String> mimeappsLists() => [
      for (final desktop in env('XDG_CURRENT_DESKTOP').toLowerCase().split(':'))
        if (desktop.isNotEmpty) p.join(configHome(), '$desktop-mimeapps.list'),
      p.join(configHome(), 'mimeapps.list'),
      p.join(applicationsDir(), 'mimeapps.list'),
    ];

List<String> _listValue(String value) =>
    [for (final id in value.split(';')) if (id.trim().isNotEmpty) id.trim()];

/// The first desktop file named for `mimeType` under [Default Applications]
/// in a mimeapps.list, or "".
String defaultFor(String content, String mimeType) {
  var group = '';
  for (final line in content.split('\n')) {
    final t = line.trim();
    if (t.startsWith('[')) {
      group = t;
    } else if (group == '[Default Applications]') {
      final eq = t.indexOf('=');
      if (eq > 0 && t.substring(0, eq).trim() == mimeType) {
        final ids = _listValue(t.substring(eq + 1));
        return ids.isNotEmpty ? ids.first : '';
      }
    }
  }
  return '';
}

/// Makes `desktopFile` the default for `mimeTypes` in a mimeapps.list and
/// lists it under [Added Associations], keeping everything else.
String setDefaultApp(String content, String desktopFile, List<String> mimeTypes) {
  final lines = <String>[];
  final seen = <String>{};
  var group = '';
  void closeGroup() {
    if (group != '[Default Applications]' && group != '[Added Associations]') return;
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    for (final mime in mimeTypes) {
      if (group == '[Default Applications]' || !seen.contains(group + mime)) {
        lines.add('$mime=$desktopFile;');
      }
    }
    lines.add('');
    seen.add(group);
  }

  for (final line in content.split('\n')) {
    final t = line.trim();
    if (t.startsWith('[') && t.endsWith(']')) {
      closeGroup();
      group = t;
      lines.add(line);
      continue;
    }
    final eq = t.indexOf('=');
    final key = eq > 0 ? t.substring(0, eq).trim() : '';
    if (mimeTypes.contains(key)) {
      if (group == '[Default Applications]') continue;
      if (group == '[Added Associations]') {
        final ids = _listValue(t.substring(eq + 1))..remove(desktopFile);
        lines.add('$key=${[desktopFile, ...ids].join(';')};');
        seen.add(group + key);
        continue;
      }
    }
    lines.add(line);
  }
  closeGroup();
  for (final g in ['[Default Applications]', '[Added Associations]']) {
    if (!seen.contains(g)) {
      while (lines.isNotEmpty && lines.last.trim().isEmpty) {
        lines.removeLast();
      }
      if (lines.isNotEmpty) lines.add('');
      lines.add(g);
      group = g;
      closeGroup();
    }
  }
  return '${lines.join('\n').trimRight()}\n';
}

/// How to start this program again: the AppImage it runs from, if any.
String selfExecutable() {
  final appImage = env('APPIMAGE');
  if (appImage.isNotEmpty && fileExists(appImage)) return appImage;
  return Platform.resolvedExecutable;
}

/// A menu entry for appmanager itself that opens AppImages with it.
String selfDesktopEntry(String appId, String exe) => '[Desktop Entry]\nType=Application\n'
    'Name=AppManager\nGenericName=AppImage Manager\n'
    'Comment=Find, install, update and alias AppImages\n'
    'Exec=${desktopExecArg(exe)} %F\nIcon=$appId\n'
    'Terminal=false\nCategories=Utility;\n'
    'MimeType=${appImageMimeTypes.join(';')};\n'
    'StartupWMClass=$appId\n$_selfMarkerKey=true\n';

/// The desktop file the user's mimeapps.list files pick for AppImages, or ""
/// when they don't name one (the desktop then picks any app that accepts
/// AppImages, e.g. Gear Lever).
String appImageHandler() {
  for (final list in mimeappsLists()) {
    if (!fileExists(list)) continue;
    String id;
    try {
      id = defaultFor(File(list).readAsStringSync(), appImageMimeTypes.first);
    } on FileSystemException {
      id = '';
    }
    if (id.isNotEmpty) return id;
  }
  return '';
}

/// Makes double-clicking an AppImage open appmanager: writes a menu entry for
/// it that accepts AppImages (unless another tool installed one) and makes
/// that the default in the user's mimeapps.list files.
void makeAppImageHandler(String appId, [String? exe]) {
  exe ??= selfExecutable();
  final desktopFile = '$appId.desktop';
  final entry = p.join(applicationsDir(), desktopFile);
  if (!fileExists(entry) || File(entry).readAsStringSync().contains('$_selfMarkerKey=true')) {
    Directory(applicationsDir()).createSync(recursive: true);
    File(entry).writeAsStringSync(selfDesktopEntry(appId, exe));
  }
  for (final list in mimeappsLists()) {
    // Always write the generic list; the others only matter if they exist,
    // since they would otherwise override it.
    if (list != p.join(configHome(), 'mimeapps.list') && !fileExists(list)) continue;
    final content = fileExists(list) ? File(list).readAsStringSync() : '';
    Directory(p.dirname(list)).createSync(recursive: true);
    File(list).writeAsStringSync(setDefaultApp(content, desktopFile, appImageMimeTypes));
  }
}

// ---------------------------------------------------------------------------
// Moving to a central folder

bool isInside(String path, String dir) => p.normalize(path).startsWith('${p.normalize(dir)}/');

/// Whether the AppImage at `path` lives outside `dir`. Symlinks are left
/// alone: they usually already point into it.
bool needsMove(String path, [String? dir]) =>
    fileExists(path) && !isSymlink(path) && !isInside(path, dir ?? defaultInstallDir());

/// Renames `src` to `dest`, copying across file systems when it must.
void moveFile(String src, String dest) {
  try {
    File(src).renameSync(dest);
  } on FileSystemException {
    final r = Process.runSync('mv', ['--', src, dest]);
    if (r.exitCode != 0) {
      throw FileSystemException('${r.stderr}'.trim(), src);
    }
  }
}

/// Moves the AppImage at `src` into `destDir` and points its alias, update
/// source and menu entry at the new path, which it returns. Throws
/// FileSystemException when the move fails or a file of that name is already
/// there. The caller must `apply` the config afterwards if `src` had an alias.
Future<String> relocate(Config cfg, String src, String destDir, List<String> notes) async {
  final result = p.join(destDir, p.basename(src));
  if (pathExists(result)) {
    throw FileSystemException('${tildify(result)} already exists', result);
  }
  final integrated = isIntegrated(src);
  Directory(destDir).createSync(recursive: true);
  moveFile(src, result);
  final alias = cfg.aliasFor(src);
  if (alias.isNotEmpty) cfg.aliases[alias] = result;
  final info = cfg.installs.remove(src);
  if (info != null) cfg.installs[result] = info;
  cfg.addScanDir(destDir);
  if (integrated) {
    unintegrate(src);
    try {
      await integrate(result);
    } on Exception catch (e) {
      notes.add('Could not re-add ${p.basename(result)} to the app menu: $e');
    }
  }
  return result;
}
