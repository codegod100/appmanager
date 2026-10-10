import 'dart:convert';
import 'dart:io';

import 'package:appmanager/src/core.dart';
import 'package:appmanager/src/env.dart';
import 'package:appmanager/src/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

List<int> le(int v, int size) => [for (var i = 0; i < size; i++) (v >> (8 * i)) & 0xFF];

/// A minimal 64-bit little-endian ELF with the given sections (plus the null
/// section and .shstrtab).
List<int> fakeElf(List<(String, List<int>)> sections) {
  final names = <int>[0];
  final nameOffs = <int>[];
  for (final (name, _) in sections) {
    nameOffs.add(names.length);
    names.addAll([...latin1.encode(name), 0]);
  }
  final shstrName = names.length;
  names.addAll([...latin1.encode('.shstrtab'), 0]);
  final body = <int>[];
  final offs = <int>[];
  for (final (_, data) in sections) {
    offs.add(64 + body.length);
    body.addAll(data);
  }
  final strOff = 64 + body.length;
  body.addAll(names);
  final shoff = 64 + body.length;
  final shnum = sections.length + 2;
  final header = <int>[0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0, 0x41, 0x49, 2, 0, 0, 0, 0, 0];
  header
    ..addAll([...le(2, 2), ...le(0x3E, 2), ...le(1, 4), ...le(0, 8), ...le(0, 8), ...le(shoff, 8)])
    ..addAll([...le(0, 4), ...le(64, 2), ...le(0, 2), ...le(0, 2), ...le(64, 2)])
    ..addAll([...le(shnum, 2), ...le(shnum - 1, 2)]);
  assert(header.length == 64);
  List<int> sh(int name, int off, int size) => [
        ...le(name, 4), ...le(1, 4), ...le(0, 8), ...le(0, 8), ...le(off, 8), ...le(size, 8), //
        ...le(0, 4), ...le(0, 4), ...le(1, 8), ...le(0, 8),
      ];
  final table = List.filled(64, 0, growable: true);
  for (final (i, (_, data)) in sections.indexed) {
    table.addAll(sh(nameOffs[i], offs[i], data.length));
  }
  table.addAll(sh(shstrName, strOff, names.length));
  return [...header, ...body, ...table];
}

Map<String, Object?> release(String tag, List<String> assets,
        {bool pre = false, bool draft = false}) =>
    {
      'tag_name': tag,
      'prerelease': pre,
      'draft': draft,
      'assets': [
        for (final (i, name) in assets.indexed)
          {
            'id': 100 + i,
            'name': name,
            'size': 1000 + i,
            'browser_download_url': 'https://github.com/o/r/releases/download/$tag/$name',
          }
      ],
    };

/// A stand-in AppImage whose runtime supports --appimage-extract. Like
/// linuxdeploy's, its top-level .desktop is a link into usr/share, and
/// patterns only match whole paths, so the link comes out on its own.
void writeFakeRuntime(String path) {
  Directory(p.dirname(path)).createSync(recursive: true);
  File(path).writeAsStringSync(r'''#!/bin/sh
[ "$1" = --appimage-extract ] || exit 1
mkdir -p squashfs-root
case "$2" in
  '*.desktop'|foo.desktop) ln -sf usr/share/applications/foo.desktop squashfs-root/foo.desktop ;;
  usr/share/applications/foo.desktop)
    mkdir -p squashfs-root/usr/share/applications
    printf '[Desktop Entry]\nType=Application\nName=Foo\nExec=AppRun %%F\nIcon=foo\n' > squashfs-root/usr/share/applications/foo.desktop ;;
  .DirIcon) ln -sf foo.png squashfs-root/.DirIcon ;;
  foo.png) printf '\211PNG\r\n\032\n\0\0\0\rIHDR\0\0\0\100\0\0\0\100' > squashfs-root/foo.png ;;
esac
''');
  chmod(path, 0x1c0); // 0700
}

void main() {
  late String home;
  setUp(() {
    home = Directory.systemTemp.createTempSync('appmanager-home').path;
    envOverrides
      ..clear()
      ..['HOME'] = home
      ..['XDG_DATA_HOME'] = null
      ..['XDG_CONFIG_HOME'] = null
      ..['XDG_CURRENT_DESKTOP'] = null;
  });
  tearDown(() {
    Directory(home).deleteSync(recursive: true);
    envOverrides.clear();
  });

  test('normalizeRepo', () {
    expect(normalizeRepo('owner/repo'), 'owner/repo');
    expect(normalizeRepo('https://github.com/owner/repo.git'), 'owner/repo');
    expect(normalizeRepo('github.com/owner/repo/releases/latest'), 'owner/repo');
    expect(normalizeRepo('https://gitlab.com/owner/repo'), '');
    expect(normalizeRepo('krita'), '');
    expect(normalizeRepo('a b/c'), '');
  });

  test('parses and searches the AppImageHub feed', () {
    final feed = {
      'items': [
        {
          'name': 'Kdenlive',
          'description': 'Video editor',
          'categories': ['AudioVideo'],
          'links': [
            {'type': 'GitHub', 'url': 'KDE/kdenlive'}
          ]
        },
        {'name': 'No_Source', 'links': []},
        {
          'name': 'Video_Tool',
          'description': 'Converts files',
          'links': [
            {'type': 'GitHub', 'url': 'someone/videotool'}
          ]
        },
        {
          'name': 'Editor',
          'description': 'A video thing',
          'links': [
            {'type': 'GitHub', 'url': 'x/editor'}
          ]
        },
      ]
    };
    final apps = parseAppImageHub(feed);
    expect(apps.length, 3);
    expect(apps[1].name, 'Video Tool');
    expect(apps[0].repo, 'KDE/kdenlive');
    final hits = searchCatalog(apps, 'video');
    expect(hits.length, 3);
    expect(hits[0].name, 'Video Tool'); // name match beats description match
    expect(searchCatalog(apps, 'video editor').length, 2);
    expect(searchCatalog(apps, 'audiovideo')[0].name, 'Kdenlive');
    expect(searchCatalog(apps, 'zzz'), isEmpty);
  });

  test('parses the pkgforge-dev app list', () {
    const md = '''
Intro with a [link](https://github.com/pkgforge-dev/sharun) inline.
<!-- APPS_LIST_START -->
| Applications |
| --- |
| [86Box](https://github.com/pkgforge-dev/86box-AppImage-Enhanced) |
| [Android Tools](https://github.com/pkgforge-dev/android-tools-AppImage) |
| [Dupe](https://github.com/pkgforge-dev/86box-AppImage-Enhanced) |
| [Elsewhere](https://gitlab.com/x/y) |
| [Two](https://github.com/a/b) | extra cell |
<!-- APPS_LIST_END -->

| Projects with Anylinux AppImages |
| --- |
| [AM-GUI](https://github.com/Shikakiben/AM-GUI) |
''';
    final apps = parsePkgforge(md);
    expect(apps.length, 3);
    expect(apps[0].name, '86Box');
    expect(apps[0].repo, 'pkgforge-dev/86box-AppImage-Enhanced');
    expect(apps[0].source, CatalogSource.pkgforge);
    expect(apps[1].name, 'Android Tools');
    expect(apps[2].repo, 'Shikakiben/AM-GUI');
    expect(apps[0].summary, contains('pkgforge-dev'));
    expect(searchCatalog(apps, 'android')[0].name, 'Android Tools');
    expect(parseCatalog(CatalogSource.pkgforge, md).length, 3);
    expect(CatalogSource.pkgforge.cachePath, isNot(CatalogSource.appImageHub.cachePath));
    expect(CatalogSource.pkgforge.isCatalog && !CatalogSource.gitHub.isCatalog, isTrue);

    final enriched = [for (final a in apps) a.copy()];
    enrichPkgforge(enriched, [
      CatalogApp(
          name: 'Android_Tools',
          summary: 'ADB and fastboot',
          repo: 'x/android-tools',
          source: CatalogSource.appImageHub)
    ]);
    expect(enriched[1].summary, 'ADB and fastboot');
    expect(enriched[0].summary, apps[0].summary);

    final descs = parseRepoDescriptions(jsonDecode('''[
      {"full_name": "pkgforge-dev/86box-AppImage-Enhanced", "description": "86Box <b>emulator</b>"},
      {"full_name": "a/none", "description": null}]'''));
    expect(descs['pkgforge-dev/86box-appimage-enhanced'], '86Box emulator');
    expect(parseRepoDescriptions(jsonDecode('{"full_name": "A/B", "description": "x"}')).length, 1);
    final described = [for (final a in apps) a.copy()];
    applyDescriptions(described, descs);
    expect(described[0].summary, '86Box emulator');
    expect(described[1].summary, apps[1].summary);
  });

  test('cleans up catalog text', () {
    expect(plainText('<p>Audio &amp; video</p>\n<ul>\n  <li>Cut</li></ul>'), 'Audio & video Cut');
    expect(shortLicense('LicenseRef-proprietary=https://x/LICENSE'), 'proprietary');
    expect(shortLicense('MIT'), 'MIT');
  });

  test('parses GitHub search results', () {
    final apps = parseGitHubSearch({
      'items': [
        {
          'full_name': 'a/b',
          'name': 'b',
          'description': 'd',
          'stargazers_count': 42,
          'license': {'spdx_id': 'MIT'},
          'topics': ['appimage']
        }
      ]
    });
    expect(apps.length, 1);
    expect(apps[0].stars, 42);
    expect(apps[0].license, 'MIT');
    expect(githubSearchUrl('my app'), contains('appimage'));
    expect(githubSearchUrl('my app'), contains('q=my+app+appimage'));
  });

  test('globMatch', () {
    expect(
        globMatch('appmanager-*-x86_64.AppImage.zsync', 'appmanager-0.1.5-x86_64.AppImage.zsync'),
        isTrue);
    expect(
        globMatch('appmanager-*-x86_64.AppImage.zsync', 'appmanager-0.1.5-aarch64.AppImage.zsync'),
        isFalse);
    expect(globMatch('a?c*', 'abcdef'), isTrue);
    expect(globMatch('*', ''), isTrue);
    expect(globMatch('a*b', 'acd'), isFalse);
  });

  test('picks the AppImage for this architecture', () {
    const x64 = ['x86_64', 'amd64', 'x64', 'x86-64'];
    final rel = release('v2', [
      'App-2.0-aarch64.AppImage',
      'App-2.0-x86_64.AppImage',
      'App-2.0-x86_64.AppImage.zsync',
      'App-2.0.tar.gz'
    ]);
    final asset = pickAsset(rel, arch: x64);
    expect(asset.name, 'App-2.0-x86_64.AppImage');
    expect(asset.tag, 'v2');
    expect(asset.zsyncUrl, endsWith('App-2.0-x86_64.AppImage.zsync'));
    expect(pickAsset(release('v1', ['App.tar.gz']), arch: x64).name, '');
    // A glob for the .zsync file selects the AppImage next to it.
    expect(pickAsset(rel, pattern: 'App-*-aarch64.AppImage.zsync', arch: x64).name,
        'App-2.0-aarch64.AppImage');
    // The same flavour as before wins.
    final flavours = release('v3', ['App-3.0-x86_64.AppImage', 'App-Qt6-3.0-x86_64.AppImage']);
    expect(pickAsset(flavours, previous: 'App-Qt6-2.0-x86_64.AppImage', arch: x64).name,
        'App-Qt6-3.0-x86_64.AppImage');
    expect(pickAsset(flavours, arch: x64).name, 'App-3.0-x86_64.AppImage');
  });

  test('prefers stable releases', () {
    const x64 = ['x86_64'];
    final list = [
      release('nightly', ['A-n.AppImage'], pre: true),
      release('v3', ['A-3.AppImage'], draft: true),
      release('v2', ['notes.txt']),
      release('v1', ['A-1.AppImage']),
    ];
    expect(pickRelease(list, arch: x64).tag, 'v1');
    expect(pickRelease(list, tag: 'latest-pre', arch: x64).tag, 'nightly');
    expect(
        pickRelease([
          release('nightly', ['A-n.AppImage'], pre: true)
        ], arch: x64)
            .tag,
        'nightly');
    expect(pickRelease(release('v9', ['A-9.AppImage']), arch: x64).tag, 'v9');
  });

  test('reads embedded update information', () {
    const info = 'gh-releases-zsync|codegod100|appmanager|release|appmanager-*-x86_64.AppImage.zsync';
    final path = '$home/a.AppImage';
    File(path).writeAsBytesSync(fakeElf([
      ('.text', latin1.encode('code')),
      ('.upd_info', [...latin1.encode(info), ...List.filled(100, 0)]),
      ('.sha256_sig', latin1.encode('sig')),
    ]));
    expect(readUpdateInfo(path), info);
    final src = parseUpdateInfo(readUpdateInfo(path));
    expect(src.kind, UpdateKind.gitHubReleases);
    expect(src.owner, 'codegod100');
    expect(src.repo, 'appmanager');
    expect(src.tag, 'release');
    File(path).writeAsBytesSync(fakeElf([('.text', latin1.encode('code'))]));
    expect(readUpdateInfo(path), '');
    File(path).writeAsStringSync('not an elf');
    expect(readUpdateInfo(path), '');
    expect(parseUpdateInfo('zsync|https://x/y.zsync').url, 'https://x/y.zsync');
    expect(parseUpdateInfo('pling-v1-zsync|123').kind, UpdateKind.none);
  });

  test('update source precedence', () {
    const embedded = 'zsync|https://example.com/a.zsync';
    expect(updateSourceFor(InstallInfo(), embedded).kind, UpdateKind.zsyncUrl);
    final src = updateSourceFor(InstallInfo(source: 'https://github.com/o/r'), embedded);
    expect(src.kind, UpdateKind.gitHubReleases);
    expect('${src.owner}/${src.repo}', 'o/r');
    expect(updateSourceFor(InstallInfo(), '').kind, UpdateKind.none);
    expect(parseSourceSetting('nonsense').kind, UpdateKind.none);
  });

  test('parses zsync headers', () {
    final z = parseZsync(
        'zsync: 0.6.2\nFilename: App-2.AppImage\nMTime: x\n'
        'Length: 12345\nURL: App-2.AppImage\nSHA-1: ABCDEF\n\n\x00\x01binary',
        'https://example.com/dl/App.zsync?x=1');
    expect(z.url, 'https://example.com/dl/App-2.AppImage');
    expect(z.sha1, 'abcdef');
    expect(z.length, 12345);
    expect(resolveUrl('https://h.com/a/b.zsync', '/c'), 'https://h.com/c');
    expect(resolveUrl('https://h.com/a/b.zsync', 'https://o/x'), 'https://o/x');
  });

  test('desktop entries launch the AppImage', () {
    expect(desktopExecArg('/opt/app.AppImage'), '/opt/app.AppImage');
    expect(desktopExecArg(r'/home/me/My Apps/a$b.AppImage'), r'"/home/me/My Apps/a\\$b.AppImage"');
    expect(desktopExecArg('/x/100%.AppImage'), '/x/100%%.AppImage');
    final entry = rewriteDesktopEntry(
        '[Desktop Entry]\nName=Foo\nExec=foo %U\nTryExec=foo\nIcon=foo\n\n'
        '[Desktop Action new]\nExec="foo bar" --new\n',
        '/apps/Foo.AppImage',
        '/icons/foo.png');
    expect(entry, contains('Exec=/apps/Foo.AppImage %U'));
    expect(entry, contains('Exec=/apps/Foo.AppImage --new'));
    expect(entry, isNot(contains('TryExec')));
    expect(entry, contains('Icon=/icons/foo.png'));
    expect(entry, isNot(contains('Icon=foo\n')));
    expect(desktopMarkerKey.allMatches(entry).length, 1);
    expect(entry.indexOf(desktopMarkerKey), lessThan(entry.indexOf('[Desktop Action new]')));
    expect('$desktopVersionKey=$desktopVersion\n'.allMatches(entry).length, 1);
    expect(rewriteDesktopEntry(entry, '/apps/Foo.AppImage', '/icons/foo.png'), entry);
    final generated = rewriteDesktopEntry('', '/apps/Bar-1.0.AppImage', '');
    expect(generated, contains('Name=Bar-1.0'));
    expect(generated, contains('Exec=/apps/Bar-1.0.AppImage'));
  });

  test('picks a hicolor folder for icons', () {
    List<int> png(int w, int h) => [
          ...latin1.encode('\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR'),
          for (final v in [w, h]) for (final shift in [24, 16, 8, 0]) (v >> shift) & 0xff,
        ];
    expect(iconSize(png(48, 48)), 48);
    expect(iconSubdir(png(48, 48)), '48x48');
    expect(iconSubdir(png(200, 180)), '192x192');
    expect(iconSubdir(png(1024, 1024)), '512x512');
    expect(iconSubdir(latin1.encode('\x89PNGdata')), '256x256');
    expect(iconSubdir(latin1.encode("<?xml?><svg xmlns='x'/>")), 'scalable');
    expect(iconSubdir(latin1.encode('/* XPM */\nstatic char *x[] = {\n"32 32 2 1",')), '32x32');
  });

  test('integrates an AppImage into the menu and removes it again', () async {
    // A stand-in AppImage whose runtime supports --appimage-extract.
    final app = '$home/Applications/Foo-1.0.AppImage';
    writeFakeRuntime(app);
    final entry = await integrate(app);
    expect(entry, desktopEntryFor(app));
    expect(isIntegrated(app), isTrue);
    expect(entry, startsWith('$home/.local/share/applications/appmanager-foo-1-0-'));
    final content = File(entry).readAsStringSync();
    expect(content, contains('Name=Foo\n'));
    expect(content, contains('Exec=$app %F'));
    final icon = '$home/.local/share/icons/hicolor/64x64/apps/${desktopId(app)}.png';
    expect(content, contains('Icon=${desktopId(app)}\n'));
    expect(File(icon).readAsBytesSync().take(4), [0x89, 0x50, 0x4E, 0x47]);
    expect(needsReintegration(app), isFalse);
    // Entries from before the version key get redone.
    File(entry).writeAsStringSync('[Desktop Entry]\nName=Foo-1.0\n$desktopMarkerKey=$app\n');
    expect(needsReintegration(app), isTrue);
    await integrate(app);
    expect(needsReintegration(app), isFalse);
    expect(File(entry).readAsStringSync(), contains('Name=Foo\n'));
    expect(unintegrate(app), isTrue);
    expect(isIntegrated(app), isFalse);
    expect(needsReintegration(app), isFalse);
    expect(fileExists(icon), isFalse);
    expect(unintegrate(app), isFalse);
  });

  test('sets the default app for AppImages in mimeapps.list', () {
    const before = '[Default Applications]\ntext/plain=gedit.desktop;\n'
        'application/vnd.appimage=it.mijorus.gearlever.desktop;\n\n'
        '[Added Associations]\napplication/vnd.appimage=it.mijorus.gearlever.desktop;\n';
    final after = setDefaultApp(before, 'am.desktop', appImageMimeTypes);
    expect(defaultFor(after, 'application/vnd.appimage'), 'am.desktop');
    expect(defaultFor(after, 'application/x-iso9660-appimage'), 'am.desktop');
    expect(defaultFor(after, 'text/plain'), 'gedit.desktop');
    expect(after, contains('application/vnd.appimage=am.desktop;it.mijorus.gearlever.desktop;'));
    expect(after, contains('application/x-iso9660-appimage=am.desktop;'));
    expect('[Default Applications]'.allMatches(after).length, 1);
    expect('application/vnd.appimage='.allMatches(after).length, 2);
    expect(setDefaultApp(after, 'am.desktop', appImageMimeTypes), after);
    final fresh = setDefaultApp('', 'am.desktop', appImageMimeTypes);
    expect(fresh, startsWith('[Default Applications]\n'));
    expect(defaultFor(fresh, 'application/vnd.appimage'), 'am.desktop');
    expect(fresh, contains('[Added Associations]\napplication/vnd.appimage=am.desktop;'));
  });

  test('registers itself as the AppImage handler', () {
    envOverrides['XDG_CURRENT_DESKTOP'] = 'GNOME';
    final gnomeList = '$home/.config/gnome-mimeapps.list';
    Directory(p.dirname(gnomeList)).createSync(recursive: true);
    File(gnomeList)
        .writeAsStringSync('[Default Applications]\napplication/vnd.appimage=gearlever.desktop;\n');
    expect(appImageHandler(), 'gearlever.desktop');
    makeAppImageHandler('dev.x.Am', '/opt/My Apps/am.AppImage');
    expect(appImageHandler(), 'dev.x.Am.desktop');
    expect(defaultFor(File('$home/.config/mimeapps.list').readAsStringSync(), 'application/vnd.appimage'),
        'dev.x.Am.desktop');
    final entryPath = '$home/.local/share/applications/dev.x.Am.desktop';
    final entry = File(entryPath).readAsStringSync();
    expect(entry, contains('Exec="/opt/My Apps/am.AppImage" %F'));
    expect(entry, contains('MimeType=application/vnd.appimage;application/x-iso9660-appimage;'));
    // An entry some other tool installed is left alone.
    File(entryPath).writeAsStringSync('[Desktop Entry]\nName=Pkg\n');
    makeAppImageHandler('dev.x.Am', '/elsewhere/am');
    expect(File(entryPath).readAsStringSync(), '[Desktop Entry]\nName=Pkg\n');
  });

  test('relocate moves an AppImage with its alias, source and menu entry', () async {
    final src = '$home/Downloads/Foo-1.0.AppImage';
    writeFakeRuntime(src);
    final cfg = Config.defaults();
    cfg.setAlias(src, 'foo');
    cfg.installs[src] = InstallInfo(source: 'o/r', tag: 'v1');
    await integrate(src);
    expect(needsMove(src), isTrue);
    expect(needsMove('$home/Applications/x.AppImage'), isFalse); // missing
    final notes = <String>[];
    final dest = await relocate(cfg, src, defaultInstallDir(), notes);
    expect(notes, isEmpty);
    expect(dest, '$home/Applications/Foo-1.0.AppImage');
    expect(fileExists(dest) && !fileExists(src), isTrue);
    expect(isExecutable(dest), isTrue);
    expect(needsMove(dest), isFalse);
    expect(cfg.aliases['foo'], dest);
    expect(cfg.installFor(dest).source, 'o/r');
    expect(cfg.installs.containsKey(src), isFalse);
    expect(isIntegrated(src), isFalse);
    expect(isIntegrated(dest), isTrue);
    expect(File(desktopEntryFor(dest)).readAsStringSync(), contains('Exec=$dest %F'));
    // A symlink into the central folder isn't offered for moving.
    Link('$home/bin-foo.AppImage').createSync(dest);
    expect(needsMove('$home/bin-foo.AppImage'), isFalse);
    // Never overwrites a file that's already there.
    writeFakeRuntime(src);
    await expectLater(relocate(cfg, src, defaultInstallDir(), notes),
        throwsA(isA<FileSystemException>()));
    expect(fileExists(src), isTrue);
  });

  test('forget removes aliases and install records', () {
    final cfg = Config.defaults();
    cfg.setAlias('/a.AppImage', 'a');
    cfg.installs['/a.AppImage'] = InstallInfo(source: 'o/r', tag: 'v1');
    cfg.forget('/a.AppImage');
    expect(cfg.aliases, isEmpty);
    expect(cfg.installs, isEmpty);
  });

  test('install records round-trip through the config', () {
    final cfg = Config.defaults();
    cfg.installs['/x/A.AppImage'] =
        InstallInfo(source: 'o/r', tag: 'v1', asset: 'A.AppImage', assetId: 1234567890123);
    expect(cfg.offerMove, isTrue);
    cfg.offerMove = false;
    saveConfig(cfg);
    final loaded = loadConfig();
    expect(loaded.offerMove, isFalse);
    expect(loaded.installFor('/x/A.AppImage').assetId, 1234567890123);
    expect(loaded.installFor('/x/A.AppImage').source, 'o/r');
    expect(loaded.installFor('/nope').tag, '');
  });
}
