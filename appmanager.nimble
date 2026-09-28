# Package

version       = "0.1.0"
author        = "codegod100"
description   = "GTK4 GUI to find, install, update and alias AppImages"
license       = "MIT"
srcDir        = "src"
installExt    = @["nim"]
bin           = @["appmanager"]

# Dependencies

requires "nim >= 2.0.0"
requires "owlkettle >= 3.0.0"

task test, "Run the core and store tests":
  exec "nim c -r --hints:off --path:src tests/tcore.nim"
  exec "nim c -r --hints:off --path:src tests/tstore.nim"
