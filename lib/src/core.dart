/// Core logic for appmanager: discovering AppImages, persisting aliases,
/// writing launcher shims and making sure the shim directory is on PATH.
///
/// Kept free of any GUI code so it can be unit tested and reused.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'env.dart';

const shimMarker = '# managed-by: appmanager';
const pathBlockStart = '# >>> appmanager >>>';
const pathBlockEnd = '# <<< appmanager <<<';
const _maxScanDepth = 2;

class AppImage {
  /// Absolute path to the AppImage file.
  final String path;

  /// File name without the .AppImage extension.
  final String name;

  const AppImage(this.path, this.name);
}

/// Where an AppImage's updates come from and which build is installed.
class InstallInfo {
  /// "owner/repo" on GitHub or a .zsync URL; "" means use the update
  /// information embedded in the file.
  String source;

  /// Release tag of the installed build.
  String tag;

  /// Release asset name of the installed build.
  String asset;

  /// GitHub asset id of the installed build (0 = unknown).
  int assetId;

  InstallInfo({this.source = '', this.tag = '', this.asset = '', this.assetId = 0});

  InstallInfo copy() =>
      InstallInfo(source: source, tag: tag, asset: asset, assetId: assetId);
}

class AliasError implements Exception {
  final String message;
  AliasError(this.message);
  @override
  String toString() => message;
}

class Config {
  /// Directories searched for AppImages.
  List<String> scanDirs;

  /// Where alias shims are written.
  String binDir;

  /// alias -> AppImage path (insertion ordered).
  Map<String, String> aliases;

  /// AppImage path -> install info.
  Map<String, InstallInfo> installs;

  /// Offer to move stray AppImages to ~/Applications.
  bool offerMove;

  Config({
    required this.scanDirs,
    required this.binDir,
    Map<String, String>? aliases,
    Map<String, InstallInfo>? installs,
    this.offerMove = true,
  })  : aliases = aliases ?? {},
        installs = installs ?? {};

  factory Config.defaults() =>
      Config(scanDirs: defaultScanDirs(), binDir: defaultBinDir());

  Map<String, Object?> toJson() => {
        'scanDirs': scanDirs,
        'binDir': binDir,
        'aliases': aliases,
        'installs': {
          for (final e in installs.entries)
            e.key: {
              'source': e.value.source,
              'tag': e.value.tag,
              'asset': e.value.asset,
              'assetId': e.value.assetId,
            }
        },
        'offerMove': offerMove,
      };

  factory Config.fromJson(Object? node) {
    final cfg = Config.defaults();
    if (node is! Map) return cfg;
    final dirs = node['scanDirs'];
    if (dirs is List) cfg.scanDirs = [for (final d in dirs) if (d is String) d];
    final bin = node['binDir'];
    if (bin is String && bin.isNotEmpty) cfg.binDir = bin;
    final aliases = node['aliases'];
    if (aliases is Map) {
      aliases.forEach((k, v) {
        if (k is String && v is String) cfg.aliases[k] = v;
      });
    }
    final offer = node['offerMove'];
    if (offer is bool) cfg.offerMove = offer;
    final installs = node['installs'];
    if (installs is Map) {
      installs.forEach((path, info) {
        if (path is! String || info is! Map) return;
        String str(String k) => info[k] is String ? info[k] as String : '';
        final id = info['assetId'];
        cfg.installs[path] = InstallInfo(
            source: str('source'),
            tag: str('tag'),
            asset: str('asset'),
            assetId: id is int ? id : (id is num ? id.toInt() : 0));
      });
    }
    return cfg;
  }

  InstallInfo installFor(String path) => installs[path]?.copy() ?? InstallInfo();

  String aliasFor(String target) {
    for (final e in aliases.entries) {
      if (e.value == target) return e.key;
    }
    return '';
  }

  /// Assigns `alias` to the AppImage at `target`, replacing any previous
  /// alias of that AppImage. An empty alias removes it.
  void setAlias(String target, String alias) {
    alias = alias.trim();
    if (alias.isNotEmpty) {
      if (!isValidAlias(alias)) {
        throw AliasError("Invalid alias '$alias': use letters, digits, '-', '_', '.' or '+'");
      }
      final other = aliases[alias];
      if (other != null && other != target) {
        throw AliasError("Alias '$alias' is already used by ${p.basename(other)}");
      }
    }
    final old = aliasFor(target);
    if (old.isNotEmpty) aliases.remove(old);
    if (alias.isNotEmpty) aliases[alias] = target;
  }

  /// Returns the path of an existing command (outside our bin dir) that has
  /// the same name as `alias`, or "" if none.
  String shadowedCommand(String alias) {
    for (final dir in env('PATH').split(':')) {
      if (dir.isEmpty || p.normalize(dir) == p.normalize(binDir)) continue;
      final candidate = p.join(dir, alias);
      if (isExecutable(candidate)) return candidate;
    }
    return '';
  }

  bool get binDirOnPath {
    final wanted = p.normalize(binDir);
    return env('PATH').split(':').any((d) => d.isNotEmpty && p.normalize(d) == wanted);
  }

  bool get pathSnippetInstalled {
    final profile = p.join(homeDir(), '.profile');
    return fileExists(profile) &&
        File(profile).readAsStringSync().contains(posixPathBlock(binDir));
  }

  /// Drops everything the config knows about `appPath`.
  void forget(String appPath) {
    final alias = aliasFor(appPath);
    if (alias.isNotEmpty) aliases.remove(alias);
    installs.remove(appPath);
  }

  void addScanDir(String dir) {
    if (!scanDirs.any((d) => p.normalize(expandTilde(d)) == p.normalize(dir))) {
      scanDirs.add(dir);
    }
  }
}

// ---------------------------------------------------------------------------
// Paths & config

String configDir() => p.join(configHome(), 'appmanager');

String configPath() => p.join(configDir(), 'config.json');

String defaultBinDir() => p.join(dataHome(), 'appmanager', 'bin');

List<String> defaultScanDirs() {
  final home = homeDir();
  return [
    p.join(home, 'Applications'),
    p.join(home, 'AppImages'),
    p.join(home, '.local', 'bin'),
    p.join(home, 'bin'),
    p.join(home, 'Downloads'),
    '/opt',
  ];
}

Config loadConfig([String? path]) {
  path ??= configPath();
  if (!fileExists(path)) return Config.defaults();
  try {
    return Config.fromJson(jsonDecode(File(path).readAsStringSync()));
  } on Exception {
    return Config.defaults();
  }
}

void saveConfig(Config cfg, [String? path]) {
  path ??= configPath();
  Directory(p.dirname(path)).createSync(recursive: true);
  final tmp = '$path.tmp';
  File(tmp).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(cfg.toJson())}\n');
  File(tmp).renameSync(path);
}

// ---------------------------------------------------------------------------
// Discovery

/// AppImages are ELF files with "AI" followed by the type byte (1 or 2) at
/// offset 8.
bool hasAppImageMagic(String path) {
  RandomAccessFile? f;
  try {
    f = File(path).openSync();
    final buf = f.readSync(11);
    if (buf.length != 11) return false;
    return buf[0] == 0x7F &&
        buf[1] == 0x45 &&
        buf[2] == 0x4C &&
        buf[3] == 0x46 &&
        buf[8] == 0x41 &&
        buf[9] == 0x49 &&
        (buf[10] == 1 || buf[10] == 2);
  } on FileSystemException {
    return false;
  } finally {
    f?.closeSync();
  }
}

bool _hasAppImageExt(String path) => path.toLowerCase().endsWith('.appimage');

String stripAppImageExt(String filename) => _hasAppImageExt(filename)
    ? filename.substring(0, filename.length - '.appimage'.length)
    : filename;

bool isAppImage(String path) =>
    fileExists(path) && (_hasAppImageExt(path) || hasAppImageMagic(path));

String _realPath(String path) {
  try {
    return File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return path;
  }
}

void _scan(String dir, int depth, Set<String> skip, Set<String> seen, List<AppImage> found) {
  if (depth > _maxScanDepth || !dirExists(dir)) return;
  List<FileSystemEntity> entries;
  try {
    entries = Directory(dir).listSync(followLinks: false);
  } on FileSystemException {
    return;
  }
  for (final entry in entries) {
    final path = entry.path;
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.file) {
      if (!isAppImage(path)) continue;
      final real = _realPath(path);
      if (!seen.add(real)) continue;
      found.add(AppImage(path, stripAppImageExt(p.basename(path))));
    } else if (type == FileSystemEntityType.directory && entry is! Link) {
      final name = p.basename(path);
      if (name.startsWith('.') || skip.contains(path)) continue;
      _scan(path, depth + 1, skip, seen, found);
    }
  }
}

/// Finds AppImages in the configured scan directories (searching up to two
/// levels deep), plus any AppImage already referenced by an alias.
List<AppImage> findAppImages(Config cfg) {
  final seen = <String>{};
  final found = <AppImage>[];
  final skip = {cfg.binDir};
  for (final dir in cfg.scanDirs) {
    _scan(expandTilde(dir), 0, skip, seen, found);
  }
  for (final target in cfg.aliases.values) {
    if (seen.add(_realPath(target))) {
      found.add(AppImage(target, stripAppImageExt(p.basename(target))));
    }
  }
  found.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return found;
}

// ---------------------------------------------------------------------------
// Aliases

final _aliasChars = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_\-.+]*$');

bool isValidAlias(String alias) =>
    alias.isNotEmpty && alias.length <= 64 && _aliasChars.hasMatch(alias);

/// Turns e.g. "Krita-5.2.2-x86_64.AppImage" into "krita" and
/// "LM-Studio-0.3.1.AppImage" into "lm-studio".
String suggestAlias(String filename) {
  const archTokens = {
    'x86', 'x86_64', 'amd64', 'aarch64', 'arm64', 'armhf', 'i386', 'i686', //
    'linux', 'appimage',
  };
  final parts = <String>[];
  for (final token in stripAppImageExt(filename).split(RegExp(r'[-_ .]'))) {
    if (token.isEmpty) continue;
    final lower = token.toLowerCase();
    bool isDigit(int i) => i < lower.length && '0123456789'.contains(lower[i]);
    if (isDigit(0) || (lower[0] == 'v' && isDigit(1)) || archTokens.contains(lower)) {
      break;
    }
    parts.add(lower);
  }
  final result = parts.join('-');
  return isValidAlias(result) ? result : '';
}

// ---------------------------------------------------------------------------
// Shims

String shimContent(String target) =>
    '#!/bin/sh\n$shimMarker\nexec ${quoteShell(target)} "\$@"\n';

bool isManagedShim(String path) {
  if (!fileExists(path) || isSymlink(path)) return false;
  try {
    final lines = File(path).readAsLinesSync();
    return lines.take(3).contains(shimMarker);
  } on FileSystemException {
    return false;
  } on FormatException {
    return false;
  }
}

/// Writes one launcher script per alias into `cfg.binDir` and removes
/// launchers for aliases that no longer exist. Files in the bin dir not
/// created by appmanager are never touched. Returns warnings.
List<String> syncShims(Config cfg) {
  final notes = <String>[];
  Directory(cfg.binDir).createSync(recursive: true);
  for (final entry in Directory(cfg.binDir).listSync(followLinks: false)) {
    final name = p.basename(entry.path);
    if (!cfg.aliases.containsKey(name) && isManagedShim(entry.path)) {
      removeFile(entry.path);
    }
  }
  cfg.aliases.forEach((alias, target) {
    final shim = p.join(cfg.binDir, alias);
    if (pathExists(shim) && !isManagedShim(shim)) {
      notes.add("Skipped '$alias': $shim exists and was not created by appmanager");
      return;
    }
    File(shim).writeAsStringSync(shimContent(target));
    chmod(shim, 0x1ed); // 0755
    if (fileExists(target)) {
      try {
        makeExecutable(target);
      } on FileSystemException {
        notes.add('Could not make $target executable');
      }
    } else {
      notes.add("'$alias' points to a missing file: $target");
    }
  });
  return notes;
}

// ---------------------------------------------------------------------------
// PATH

/// Escapes `s` for use inside a double-quoted POSIX shell string.
String _dquote(String s) => s.replaceAllMapped(RegExp(r'["\\$`]'), (m) => '\\${m[0]}');

String posixPathBlock(String binDir) {
  final dir = _dquote(binDir);
  return '$pathBlockStart\n'
      'case ":\$PATH:" in\n'
      '  *":$dir:"*) ;;\n'
      '  *) export PATH="$dir:\$PATH" ;;\n'
      'esac\n'
      '$pathBlockEnd\n';
}

String fishPathBlock(String binDir) =>
    '$pathBlockStart\nfish_add_path --global ${quoteShell(binDir)}\n$pathBlockEnd\n';

/// Replaces an existing appmanager block in `content` with `blk`, or appends
/// `blk` if there is none.
String replaceBlock(String content, String blk) {
  final start = content.indexOf(pathBlockStart);
  if (start >= 0) {
    final stop = content.indexOf(pathBlockEnd, start);
    if (stop >= 0) {
      var after = stop + pathBlockEnd.length;
      if (after < content.length && content[after] == '\n') after++;
      return content.substring(0, start) + blk + content.substring(after);
    }
  }
  final out = StringBuffer(content);
  if (content.isNotEmpty && !content.endsWith('\n')) out.write('\n');
  if (content.isNotEmpty) out.write('\n');
  out.write(blk);
  return out.toString();
}

/// Startup files that get the PATH snippet: ~/.profile always, plus the rc
/// files of any shells the user appears to use.
List<({String path, bool fish})> shellRcFiles() {
  final home = homeDir();
  final result = [(path: p.join(home, '.profile'), fish: false)];
  for (final rc in ['.bashrc', '.zshrc']) {
    if (fileExists(p.join(home, rc))) result.add((path: p.join(home, rc), fish: false));
  }
  final fishDir = p.join(configHome(), 'fish');
  if (dirExists(fishDir)) {
    result.add((path: p.join(fishDir, 'conf.d', 'appmanager.fish'), fish: true));
  }
  return result;
}

/// Adds (or updates) the snippet that puts `cfg.binDir` on PATH in the
/// user's shell startup files. Returns the files that were changed.
List<String> installPathSnippet(Config cfg) {
  final changed = <String>[];
  for (final rc in shellRcFiles()) {
    final blk = rc.fish ? fishPathBlock(cfg.binDir) : posixPathBlock(cfg.binDir);
    final old = fileExists(rc.path) ? File(rc.path).readAsStringSync() : '';
    final updated = replaceBlock(old, blk);
    if (updated != old) {
      Directory(p.dirname(rc.path)).createSync(recursive: true);
      File(rc.path).writeAsStringSync(updated);
      changed.add(rc.path);
    }
  }
  return changed;
}

/// Persists the config, writes shims and makes sure they're on PATH.
/// Returns human readable notes/warnings.
List<String> apply(Config cfg) {
  saveConfig(cfg);
  final notes = syncShims(cfg);
  for (final file in installPathSnippet(cfg)) {
    notes.add('Added ${cfg.binDir} to PATH in $file');
  }
  return notes;
}
