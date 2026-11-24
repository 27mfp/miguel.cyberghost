.pragma library

.import "Countries.js" as Countries

// Persisted lists are short, canonical CSVs of actual supported country codes.
// Do not accept the legacy UK alias: the stored representation is always GB.
function normalizeCode(value) {
  if (typeof value !== "string")
    return ""
  if (/[\x00-\x1f\x7f]/.test(value))
    return ""
  const trimmed = value.trim()
  if (!/^[A-Za-z]{2}$/.test(trimmed))
    return ""
  const code = trimmed.toUpperCase()
  const country = Countries.countryByCode(code)
  return Countries.isSupportedCountry(code) && country.code === code ? code : ""
}

function normalizeList(values, limit) {
  if (!Array.isArray(values))
    return []
  const result = []
  const maximum = Math.max(0, Math.min(8, Number(limit) || 0))
  for (let i = 0; i < values.length && result.length < maximum; i++) {
    const code = normalizeCode(values[i])
    if (code !== "" && result.indexOf(code) === -1)
      result.push(code)
  }
  return result
}

function fromCsv(value, limit) {
  if (typeof value !== "string" || value.length > 1024)
    return []
  return normalizeList(value.split(","), limit)
}

function toCsv(values, limit) {
  return normalizeList(values, limit).join(",")
}

function addRecent(values, countryCode) {
  const code = normalizeCode(countryCode)
  const existing = normalizeList(values, 5)
  if (!code)
    return existing
  return [code].concat(existing.filter(function(item) { return item !== code })).slice(0, 5)
}
