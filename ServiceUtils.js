.pragma library

var serverSelectorPattern = /^[a-z0-9]+(?:-[a-z0-9]+)*-s\d+-i\d+$/

function isValidServerSelector(value) {
  return value === "fastest" || serverSelectorPattern.test(value)
}

function preferences(settings) {
  var saved = settings || {}
  return {
    country: String(saved.defaultCountry || "PT").trim().toUpperCase(),
    // Migrate earlier experimental selections to the supported release path.
    protocol: "wireguard",
    serverType: "traffic",
    serverSelection: "fastest",
    hideDetails: saved.hideDetails === true
  }
}

function setupState(network, requests, credentials) {
  return network && requests && credentials ? "ready" : "first-run"
}

function inventoryMatches(key, country, protocol, mode) {
  return key === country + "|" + protocol + "|" + mode
}

function serverOptions(rows, countryName) {
  var options = [{value: "fastest", label: "Automatic · " + countryName,
    description: "Lowest reported load when inventory is available; otherwise automatic fallback"}]
  var seen = {}
  if (!Array.isArray(rows)) return options
  for (var i = 0; i < rows.length && options.length < 65; i++) {
    var item = rows[i] || {}
    var value = String(item.server || item.instance || "").toLowerCase()
    var load = Number(item.load)
    if (!serverSelectorPattern.test(value) || seen[value] || !isFinite(load) || load < 0 || load > 100) continue
    seen[value] = true
    var city = String(item.city || countryName).substring(0, 48).replace(/</g, "[").replace(/>/g, "]")
    options.push({value: value, label: city + " · " + value + " · " + load + "% load", description: "Exact server"})
  }
  return options
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
      if (result && typeof result.ok === "boolean" && ["connect", "disconnect", "logout"].indexOf(result.action) >= 0) return result
    } catch (e) {
      // Ignore non-JSON lines from compatibility helpers.
    }
  }
  return null
}

// Same units and precision as Omarchy's network panel, so identical numbers
// read identically across both panels. Negative means "no sample yet".
function formatBytes(bytes) {
  var n = Number(bytes)
  if (!isFinite(n) || n < 0) return "--"
  if (n < 1024) return Math.round(n) + " B"
  if (n < 1024 * 1024) return (n / 1024).toFixed(1) + " KB"
  if (n < 1024 * 1024 * 1024) return (n / (1024 * 1024)).toFixed(1) + " MB"
  return (n / (1024 * 1024 * 1024)).toFixed(2) + " GB"
}

function formatRate(bytesPerSec) {
  var text = formatBytes(bytesPerSec)
  return text === "--" ? text : text + "/s"
}
