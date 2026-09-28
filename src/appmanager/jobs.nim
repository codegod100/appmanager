## Runs curl and other helpers in the background, polled from the GTK main
## loop, so downloads never freeze the window.

import std/[os, osproc, streams, strutils, json]
import owlkettle
import store

const PollMs = 100

type
  DoneProc* = proc(code: int, output: string)
  ProgressProc* = proc(fraction: float)
  BytesProc* = proc(bytes: BiggestInt)

var tempCounter = 0

proc tempFile*(ext: string): string =
  inc tempCounter
  getTempDir() / "appmanager-" & $getCurrentProcessId() & "-" & $tempCounter & ext

proc runAsync*(exe: string, args: seq[string], onDone: DoneProc,
               poll: proc() = nil) =
  ## Starts `exe` and calls `onDone` with its exit code and output (stdout
  ## and stderr, which must stay small) once it exits. `poll` runs on every
  ## tick while it is running.
  var p: Process
  try:
    p = startProcess(exe, args = args, options = {poUsePath, poStdErrToStdOut})
  except OSError:
    onDone(127, exe & " is not installed")
    return
  proc tick(): bool =
    if p.running:
      if poll != nil: poll()
      return true
    let code = p.peekExitCode
    var output = ""
    try: output = p.outputStream.readAll()
    except IOError, OSError: discard
    p.close()
    onDone(code, output.strip)
    false
  discard addGlobalTimeout(PollMs, tick)

proc curlError(url: string, code: int, output: string): string =
  result = if output.len > 0: output.replace("curl: ", "") else: "curl exited with " & $code
  if code == 127:
    result = "curl is needed to download AppImages; please install it"
  elif url.startsWith(GitHubApi) and ("403" in output or "429" in output):
    result.add(" (GitHub rate limit? Set GITHUB_TOKEN to raise it)")

proc download*(url, dest: string, onDone: proc(error: string),
               range = "", expected: BiggestInt = 0, onProgress: ProgressProc = nil,
               onBytes: BytesProc = nil) =
  ## Downloads `url` to `dest`; `onDone` gets "" on success or an error.
  ## `onProgress` reports the fraction done when `expected` is known;
  ## `onBytes` reports how much has arrived so far either way.
  if not (url.startsWith("https://") or url.startsWith("http://")):
    onDone("not a web address: " & url)
    return
  proc poll() =
    if onProgress == nil and onBytes == nil: return
    var size: BiggestInt
    try: size = getFileSize(dest)
    except OSError: return
    if onBytes != nil: onBytes(size)
    if onProgress != nil and expected > 0:
      onProgress(min(1.0, size.float / expected.float))
  runAsync("curl", curlArgs(url, dest, range),
    proc(code: int, output: string) =
      if code == 0: onDone("")
      else:
        removeFile(dest)
        onDone(curlError(url, code, output)),
    poll)

proc fetchJson*(url: string, onDone: proc(node: JsonNode, error: string)) =
  let dest = tempFile(".json")
  download(url, dest, proc(error: string) =
    if error.len > 0:
      onDone(nil, error)
      return
    var node: JsonNode
    try:
      node = parseFile(dest)
    except JsonParsingError, IOError, ValueError:
      removeFile(dest)
      onDone(nil, "Unexpected reply from " & url)
      return
    removeFile(dest)
    onDone(node, ""))

proc fetchText*(url: string, onDone: proc(text, error: string), range = "") =
  let dest = tempFile(".txt")
  download(url, dest, proc(error: string) =
    var text = ""
    if error.len == 0:
      try: text = readFile(dest)
      except IOError: discard
    removeFile(dest)
    onDone(text, error), range)

proc sha1Async*(path: string, onDone: proc(sha1, error: string)) =
  runAsync("sha1sum", @["--", path], proc(code: int, output: string) =
    # Names with odd characters get a leading backslash.
    let output = if output.startsWith("\\"): output[1 .. ^1] else: output
    if code == 0 and output.len >= 40:
      onDone(output[0 ..< 40].toLowerAscii, "")
    else:
      onDone("", "Could not hash " & path.extractFilename & ": " & output))
