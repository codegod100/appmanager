import 'dart:io';

import 'package:appmanager/src/core.dart';
import 'package:appmanager/src/env.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Minimal file with the AppImage type-2 ELF magic.
void fakeAppImage(String path) {
  Directory(p.dirname(path)).createSync(recursive: true);
  File(path).writeAsBytesSync([0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0, 0x41, 0x49, 2, ...List.filled(32, 0)]);
}

String run(String exe, List<String> args) =>
    (Process.runSync(exe, args, environment: childEnvironment(), includeParentEnvironment: false)
            .stdout as String)
        .trim();

void main() {
  late String home;
  setUp(() {
    home = Directory.systemTemp.createTempSync('appmanager-home').path;
    envOverrides
      ..clear()
      ..['HOME'] = home
      ..['XDG_CONFIG_HOME'] = '' // empty must behave like unset
      ..['XDG_DATA_HOME'] = null;
  });
  tearDown(() {
    Directory(home).deleteSync(recursive: true);
    envOverrides.clear();
  });

  test('suggestAlias strips versions and architectures', () {
    expect(suggestAlias('Krita-5.2.2-x86_64.appimage'), 'krita');
    expect(suggestAlias('LM-Studio-0.3.1.AppImage'), 'lm-studio');
    expect(suggestAlias('nvim.appimage'), 'nvim');
    expect(suggestAlias('Obsidian-v1.5.3.AppImage'), 'obsidian');
    expect(suggestAlias('1234.AppImage'), '');
  });

  test('isValidAlias', () {
    expect(isValidAlias('code'), isTrue);
    expect(isValidAlias('my-app_2.0+'), isTrue);
    expect(isValidAlias(''), isFalse);
    expect(isValidAlias('-rf'), isFalse);
    expect(isValidAlias('a/b'), isFalse);
    expect(isValidAlias('has space'), isFalse);
  });

  test('finds AppImages by extension and by magic', () {
    fakeAppImage('$home/Applications/Foo-1.0.AppImage');
    fakeAppImage('$home/Applications/nested/bar');
    File('$home/Applications/notes.txt').writeAsStringSync('hi');
    final apps = findAppImages(Config.defaults());
    expect(apps.length, 2);
    expect(apps[0].name, 'bar');
    expect(apps[1].name, 'Foo-1.0');
  });

  test('setAlias rejects duplicates and replaces old alias', () {
    final cfg = Config.defaults();
    cfg.setAlias('/a.AppImage', 'a');
    expect(() => cfg.setAlias('/b.AppImage', 'a'), throwsA(isA<AliasError>()));
    expect(() => cfg.setAlias('/b.AppImage', 'bad name'), throwsA(isA<AliasError>()));
    cfg.setAlias('/a.AppImage', 'aa');
    expect(cfg.aliases.length, 1);
    expect(cfg.aliasFor('/a.AppImage'), 'aa');
    cfg.setAlias('/a.AppImage', '');
    expect(cfg.aliases, isEmpty);
  });

  test('config round-trips', () {
    final cfg = Config.defaults();
    cfg.setAlias('/x/y.AppImage', 'y');
    saveConfig(cfg);
    final loaded = loadConfig();
    expect(loaded.aliases['y'], '/x/y.AppImage');
    expect(loaded.binDir, cfg.binDir);
    expect(loaded.scanDirs, cfg.scanDirs);
    expect(fileExists('$home/.config/appmanager/config.json'), isTrue);
  });

  test('apply writes runnable shims and PATH snippet', () {
    final target = '$home/Applications/Echo Tool.AppImage';
    Directory(p.dirname(target)).createSync(recursive: true);
    File(target).writeAsStringSync('#!/bin/sh\necho "hello \$1"\n'); // not yet executable
    File('$home/.bashrc').writeAsStringSync("alias ll='ls -l'");
    final cfg = Config.defaults();
    cfg.setAlias(target, 'echotool');
    apply(cfg);

    final shim = p.join(cfg.binDir, 'echotool');
    expect(isManagedShim(shim), isTrue);
    expect(isExecutable(target), isTrue);
    expect(run(shim, ['world']), 'hello world');

    final bashrc = File('$home/.bashrc').readAsStringSync();
    expect(bashrc.startsWith("alias ll='ls -l'\n"), isTrue);
    expect(pathBlockStart.allMatches(bashrc).length, 1);
    expect(fileExists('$home/.profile'), isTrue);

    // Sourcing the snippet puts the bin dir on PATH, and applying again
    // doesn't duplicate it.
    apply(cfg);
    expect(pathBlockStart.allMatches(File('$home/.bashrc').readAsStringSync()).length, 1);
    expect(run('/bin/sh', ['-c', '. "\$HOME/.profile"; command -v echotool']), shim);
  });

  test('removing an alias removes only managed shims', () {
    final target = '$home/t.AppImage';
    File(target).writeAsStringSync('#!/bin/sh\n');
    final cfg = Config.defaults();
    cfg.setAlias(target, 't');
    apply(cfg);
    File(p.join(cfg.binDir, 'foreign')).writeAsStringSync('#!/bin/sh\n');
    cfg.setAlias(target, '');
    apply(cfg);
    expect(fileExists(p.join(cfg.binDir, 't')), isFalse);
    expect(fileExists(p.join(cfg.binDir, 'foreign')), isTrue);
  });

  test('does not overwrite files it did not create', () {
    final target = '$home/t.AppImage';
    File(target).writeAsStringSync('#!/bin/sh\n');
    final cfg = Config.defaults();
    Directory(cfg.binDir).createSync(recursive: true);
    File(p.join(cfg.binDir, 't')).writeAsStringSync('mine');
    cfg.setAlias(target, 't');
    final notes = apply(cfg);
    expect(File(p.join(cfg.binDir, 't')).readAsStringSync(), 'mine');
    expect(notes, isNotEmpty);
    expect(notes[0], contains('Skipped'));
  });

  test('replaceBlock updates an existing block in place', () {
    final old = 'a\n${posixPathBlock('/old')}b\n';
    expect(replaceBlock(old, posixPathBlock('/new')), 'a\n${posixPathBlock('/new')}b\n');
  });

  test('tildify', () {
    expect(tildify('$home/Applications'), '~/Applications');
    expect(tildify('/opt/x'), '/opt/x');
  });
}
