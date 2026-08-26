.pragma library

var serverSelectorPattern = /^[a-z0-9]+(?:-[a-z0-9]+)*-s\d+-i\d+$/

function isValidServerSelector(value) {
  return value === "fastest" || serverSelectorPattern.test(value)
}

function appendBounded(existing, line, maxChars) {
  var current = String(existing || "")
  if (current.indexOf("[output truncated]") !== -1) return current
  var addition = String(line || "")
  var combined = current === "" ? addition : current + "\n" + addition
  if (combined.length <= maxChars) return combined
  return combined.substring(0, maxChars) + "\n[output truncated]"
}

function cleanProcessError(text, fallback) {
  var lines = String(text || "").substring(0, 1024).split("\n")
  for (var i = lines.length - 1; i >= 0; i--) {
    var clean = lines[i].trim()
    if (!clean || clean.indexOf("Traceback") === 0 || clean.indexOf("File \"") === 0 || clean.indexOf("[Previous line repeated") === 0) continue
    if (clean.indexOf("Error:") === 0) clean = clean.substring(6).trim()
    if (clean !== "") return clean.substring(0, 160)
  }
  return fallback
}

function parseActionResult(output) {
  var lines = String(output || "").split("\n")
  for (var i = lines.length - 1; i >= 0; i--) {
    var line = lines[i].trim()
    if (!line) continue
    try {
      var result = JSON.parse(line)
      if (result && typeof result.ok === "boolean" && (result.action === "connect" || result.action === "disconnect")) return result
    } catch (e) {
      // Ignore non-JSON lines from compatibility helpers.
    }
  }
  return null
}
