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

function finiteNonNegative(value) {
  return typeof value === "number" && isFinite(value) && value >= 0 ? value : -1
}

function emptyTransferSample() {
  return {
    endpoint: "",
    transferText: "",
    rxBytes: -1,
    rxChangedAt: 0,
    rxIdleSec: 0,
    txBytes: -1,
    rxRate: -1,
    txRate: -1,
    counterSampleAt: 0,
    sampleRx: -1,
    sampleTx: -1
  }
}

// Pure `status --json` transfer sampling. `previous` is the previous sample
// object; callers assign the result back. Rates need two samples of the same
// session at least one second apart, and a missing or reset counter restarts
// sampling instead of producing a bogus rate.
function statusSample(data, previous, now) {
  var prev = previous || {}
  var connected = !!(data && data.connected === true) && data.backend !== "legacy"
  if (!connected) return emptyTransferSample()
  var rx = finiteNonNegative(data.rx_bytes)
  var tx = finiteNonNegative(data.tx_bytes)
  var sample = emptyTransferSample()
  sample.endpoint = String(data.endpoint || "").substring(0, 64).trim()
  sample.transferText = String(data.transfer || "").substring(0, 64).trim()
  sample.rxBytes = finiteNonNegative(prev.rxBytes)
  sample.rxChangedAt = Number(prev.rxChangedAt) || 0
  sample.txBytes = tx
  sample.counterSampleAt = Number(prev.counterSampleAt) || 0
  sample.sampleRx = typeof prev.sampleRx === "number" ? prev.sampleRx : -1
  sample.sampleTx = typeof prev.sampleTx === "number" ? prev.sampleTx : -1
  sample.rxRate = typeof prev.rxRate === "number" ? prev.rxRate : -1
  sample.txRate = typeof prev.txRate === "number" ? prev.txRate : -1

  var elapsed = (now - sample.counterSampleAt) / 1000
  if (rx < 0 || tx < 0 || rx < sample.sampleRx || tx < sample.sampleTx) {
    sample.rxRate = -1
    sample.txRate = -1
    sample.counterSampleAt = rx >= 0 && tx >= 0 ? now : 0
    sample.sampleRx = rx
    sample.sampleTx = tx
  } else if (sample.counterSampleAt === 0 || elapsed >= 1) {
    if (sample.counterSampleAt > 0) {
      sample.rxRate = (rx - sample.sampleRx) / elapsed
      sample.txRate = (tx - sample.sampleTx) / elapsed
    }
    sample.counterSampleAt = now
    sample.sampleRx = rx
    sample.sampleTx = tx
  }
  if (rx < 0 || rx !== sample.rxBytes || sample.rxChangedAt === 0) {
    sample.rxBytes = rx
    sample.rxChangedAt = now
  }
  sample.rxIdleSec = rx < 0 ? 0 : Math.floor((now - sample.rxChangedAt) / 1000)
  return sample
}

// GeoIP payload -> display fields, or null when the body is not usable.
// Validation lives here so a malformed or spoofed answer cannot reach the UI.
function ipInfo(jsonStr) {
  if (!jsonStr || String(jsonStr).trim() === "") return null
  var data = null
  try {
    data = JSON.parse(String(jsonStr).substring(0, 4096))
  } catch (e) {
    return null
  }
  if (!data || data.success === false || !data.ip) return null
  var ip = String(data.ip || "").substring(0, 45).trim()
  if (!/^[0-9A-Fa-f:.]+$/.test(ip)) return null
  var country = String(data.country_code || data.country || "").substring(0, 2).trim().toUpperCase()
  var connection = data.connection || {}
  return {
    ip: ip,
    city: String(data.city || "").substring(0, 64).trim(),
    country: /^[A-Z]{2}$/.test(country) ? country : "",
    org: String(data.org || connection.org || connection.isp || "").substring(0, 128).trim()
  }
}

// A connect result may name the country and the concrete server. Keep both
// validated; the UI never trusts the process output verbatim.
function connectResult(data, fallbackCountry) {
  var source = data || {}
  var country = typeof source.country === "string" && /^[A-Z]{2}$/.test(source.country) ? source.country : String(fallbackCountry || "")
  var raw = typeof source.server === "string" ? source.server.replace(/\.cg-dialup\.net$/, "").toLowerCase() : ""
  return {
    country: country,
    server: isValidServerSelector(raw) && raw !== "fastest" ? raw : ""
  }
}

// Tooltip shown by the bar icon. State is passed explicitly so the contract
// can be exercised without instantiating the statically registered bar host.
function barTooltip(state) {
  var s = state || {}
  if (!s.setupDone) return "CyberGhost VPN: setup incomplete — click for steps"
  if (s.statusUnknown) return "CyberGhost VPN: status unavailable — click to reconcile"
  if (s.legacyTunnel) return "CyberGhost VPN: previous helper tunnel active — click to disconnect"
  if (s.connecting) return "CyberGhost VPN: Connecting to " + String(s.countryName || "") + " (" + String(s.country || "") + ")…"
  if (s.disconnecting) return "CyberGhost VPN: Disconnecting…"
  if (s.connected) {
    var ipPart = (!s.hideDetails && s.publicIp !== undefined && s.publicIp !== "") ? (" • " + s.publicIp) : ""
    return "CyberGhost VPN: Connected" + ipPart
  }
  return "CyberGhost VPN: Disconnected (Click to open)"
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
