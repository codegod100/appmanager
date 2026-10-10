/// Environment lookups that tests can override (Dart can't change its own
/// process environment).
library;

import 'dart:io';

/// Values here take precedence over the real environment; a `null` value
/// means "unset".
final Map<String, String?> envOverrides = {};

String env(String name) {
  if (envOverrides.containsKey(name)) return envOverrides[name] ?? '';
  return Platform.environment[name] ?? '';
}

/// The environment to hand to child processes, with overrides applied.
Map<String, String> childEnvironment() {
  final result = Map<String, String>.of(Platform.environment);
  envOverrides.forEach((k, v) {
    if (v == null) {
      result.remove(k);
    } else {
      result[k] = v;
    }
  });
  return result;
}

String homeDir() {
  final home = env('HOME');
  return home.isNotEmpty ? home : '/';
}

/// Like `$XDG_*_HOME`, but also treats an empty variable as unset, as the
/// XDG spec requires.
String xdgDir(String envVar, String fallback) {
  final dir = env(envVar);
  return dir.isNotEmpty ? dir : '${homeDir()}/$fallback';
}

String cacheDir() => '${xdgDir('XDG_CACHE_HOME', '.cache')}/appmanager';

String dataHome() => xdgDir('XDG_DATA_HOME', '.local/share');

String configHome() => xdgDir('XDG_CONFIG_HOME', '.config');

/// Looks `name` up on PATH, like `command -v`; "" if not found.
String findExe(String name) {
  for (final dir in env('PATH').split(':')) {
    if (dir.isEmpty) continue;
    final candidate = '$dir/$name';
    if (isExecutable(candidate)) return candidate;
  }
  return '';
}

bool isExecutable(String path) {
  try {
    final st = FileStat.statSync(path);
    return st.type == FileSystemEntityType.file && st.mode & 0x40 != 0;
  } on FileSystemException {
    return false;
  }
}

int fileMode(String path) => FileStat.statSync(path).mode & 0xfff;

/// Sets the permission bits of `path` (via chmod, which dart:io lacks).
void chmod(String path, int mode) {
  final r = Process.runSync('chmod', [mode.toRadixString(8), '--', path]);
  if (r.exitCode != 0) {
    throw FileSystemException('chmod failed: ${r.stderr}'.trim(), path);
  }
}

void makeExecutable(String path) {
  final mode = fileMode(path);
  if (mode & 0x40 == 0) chmod(path, mode | 0x40);
}

bool isSymlink(String path) =>
    FileSystemEntity.isLinkSync(path);

bool fileExists(String path) =>
    FileSystemEntity.typeSync(path) == FileSystemEntityType.file;

bool dirExists(String path) =>
    FileSystemEntity.typeSync(path) == FileSystemEntityType.directory;

/// Whether anything (a file, a directory or a link, even a dangling one)
/// is at `path`.
bool pathExists(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) !=
    FileSystemEntityType.notFound;

void removeFile(String path) {
  try {
    File(path).deleteSync();
  } on FileSystemException {
    // Already gone.
  }
}

String expandTilde(String path) {
  if (path == '~') return homeDir();
  if (path.startsWith('~/')) return homeDir() + path.substring(1);
  return path;
}

/// Abbreviates the home directory to "~" for display.
String tildify(String path) {
  var home = homeDir();
  while (home.length > 1 && home.endsWith('/')) {
    home = home.substring(0, home.length - 1);
  }
  if (path == home || path.startsWith('$home/')) {
    return '~${path.substring(home.length)}';
  }
  return path;
}

/// Quotes `s` for a POSIX shell.
String quoteShell(String s) {
  if (s.isNotEmpty && RegExp(r'^[A-Za-z0-9_\-./=+:,@%]+$').hasMatch(s)) return s;
  return "'${s.replaceAll("'", "'\"'\"'")}'";
}
