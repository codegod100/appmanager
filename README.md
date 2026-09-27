# appmanager

A small GTK4 GUI written in Nim ([owlkettle](https://github.com/can-lehmann/owlkettle))
that finds the AppImages you have installed, lets you give each one a short
command-line alias, and puts those aliases on your `PATH`.

![screenshot](docs/screenshot.png)

## Features

- Scans `~/Applications`, `~/AppImages`, `~/.local/bin`, `~/bin`, `~/Downloads`
  and `/opt` (up to two levels deep) for AppImages. Files are recognised by a
  `.AppImage` extension or by the AppImage ELF magic, so renamed AppImages are
  found too. Use the folder button in the header bar to add or remove folders.
- Suggests an alias from the file name (`Krita-5.2.2-x86_64.appimage` → `krita`).
  To accept it, press the ✓ button or Enter. You can also type your own.
- For each alias it writes a small launcher script to
  `~/.local/share/appmanager/bin/<alias>` (use **Change…** next to the folder
  shown at the top of the window to pick a different one):

  ```sh
  #!/bin/sh
  # managed-by: appmanager
  exec '/home/you/Applications/Krita-5.2.2-x86_64.appimage' "$@"
  ```

  It also marks the AppImage executable if it isn't already.
- Adds that folder to `PATH` by writing a marked block to `~/.profile`, to
  `~/.bashrc` and `~/.zshrc` if they exist, and to
  `~/.config/fish/conf.d/appmanager.fish` if you use fish. Open a new terminal
  afterwards to use the aliases.
- Warns if an alias would shadow an existing command. It refuses duplicate
  aliases and never overwrites or deletes files it didn't create.

Aliases and scan folders are stored in `~/.config/appmanager/config.json`.

## Building

You need Nim ≥ 2.0 and the GTK 4 development files (`libgtk-4-dev` on
Debian/Ubuntu, `gtk4-devel` on Fedora, `gtk4` on Arch).

```sh
nimble build      # produces ./appmanager
nimble test       # runs the core tests (no GTK needed)
./appmanager
```

## AppImage

Every push to `main` builds `appmanager-<version>-x86_64.AppImage` in CI
([`.github/workflows/appimage.yml`](.github/workflows/appimage.yml)) and
publishes it, with a matching `.zsync` file, to the single rolling GitHub
release tagged [`release`](https://github.com/codegod100/appmanager/releases/tag/release).
Each build replaces the previous one; there are no versioned releases.

The AppImage embeds this update information:

```
gh-releases-zsync|codegod100|appmanager|release|appmanager-*-x86_64.AppImage.zsync
```

This lets [AppImageUpdate](https://github.com/AppImageCommunity/AppImageUpdate),
Gear Lever, AppImageLauncher and similar tools update it in place. They only
download the blocks that changed.

To build one locally (needs `zsync` for the `.zsync` file):

```sh
packaging/build-appimage.sh          # -> dist/appmanager-<version>-x86_64.AppImage
```

The icon source is [`data/icons/hicolor/scalable/apps/dev.appmanager.AppManager.svg`](data/icons/hicolor/scalable/apps/dev.appmanager.AppManager.svg).
