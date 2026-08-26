.pragma library

var allCountries = [
  { "code": "AD", "name": "Andorra", "flag": "🇦🇩", "popular": false },
  { "code": "AE", "name": "United Arab Emirates", "flag": "🇦🇪", "popular": false },
  { "code": "AL", "name": "Albania", "flag": "🇦🇱", "popular": false },
  { "code": "AM", "name": "Armenia", "flag": "🇦🇲", "popular": false },
  { "code": "AR", "name": "Argentina", "flag": "🇦🇷", "popular": false },
  { "code": "AT", "name": "Austria", "flag": "🇦🇹", "popular": false },
  { "code": "AU", "name": "Australia", "flag": "🇦🇺", "popular": false },
  { "code": "BA", "name": "Bosnia & Herzegovina", "flag": "🇧🇦", "popular": false },
  { "code": "BD", "name": "Bangladesh", "flag": "🇧🇩", "popular": false },
  { "code": "BE", "name": "Belgium", "flag": "🇧🇪", "popular": false },
  { "code": "BG", "name": "Bulgaria", "flag": "🇧🇬", "popular": false },
  { "code": "BO", "name": "Bolivia", "flag": "🇧🇴", "popular": false },
  { "code": "BR", "name": "Brazil", "flag": "🇧🇷", "popular": true },
  { "code": "BS", "name": "Bahamas", "flag": "🇧🇸", "popular": false },
  { "code": "BY", "name": "Belarus", "flag": "🇧🇾", "popular": false },
  { "code": "CA", "name": "Canada", "flag": "🇨🇦", "popular": true },
  { "code": "CH", "name": "Switzerland", "flag": "🇨🇭", "popular": true },
  { "code": "CL", "name": "Chile", "flag": "🇨🇱", "popular": false },
  { "code": "CN", "name": "China", "flag": "🇨🇳", "popular": false },
  { "code": "CO", "name": "Colombia", "flag": "🇨🇴", "popular": false },
  { "code": "CR", "name": "Costa Rica", "flag": "🇨🇷", "popular": false },
  { "code": "CY", "name": "Cyprus", "flag": "🇨🇾", "popular": false },
  { "code": "CZ", "name": "Czechia", "flag": "🇨🇿", "popular": false },
  { "code": "DE", "name": "Germany", "flag": "🇩🇪", "popular": true },
  { "code": "DK", "name": "Denmark", "flag": "🇩🇰", "popular": false },
  { "code": "DO", "name": "Dominican Republic", "flag": "🇩🇴", "popular": false },
  { "code": "DZ", "name": "Algeria", "flag": "🇩🇿", "popular": false },
  { "code": "EC", "name": "Ecuador", "flag": "🇪🇨", "popular": false },
  { "code": "EE", "name": "Estonia", "flag": "🇪🇪", "popular": false },
  { "code": "EG", "name": "Egypt", "flag": "🇪🇬", "popular": false },
  { "code": "ES", "name": "Spain", "flag": "🇪🇸", "popular": true },
  { "code": "FI", "name": "Finland", "flag": "🇫🇮", "popular": false },
  { "code": "FR", "name": "France", "flag": "🇫🇷", "popular": true },
  { "code": "GB", "name": "United Kingdom", "flag": "🇬🇧", "popular": true },
  { "code": "GE", "name": "Georgia", "flag": "🇬🇪", "popular": false },
  { "code": "GL", "name": "Greenland", "flag": "🇬🇱", "popular": false },
  { "code": "GR", "name": "Greece", "flag": "🇬🇷", "popular": false },
  { "code": "GT", "name": "Guatemala", "flag": "🇬🇹", "popular": false },
  { "code": "HK", "name": "Hong Kong", "flag": "🇭🇰", "popular": false },
  { "code": "HR", "name": "Croatia", "flag": "🇭🇷", "popular": false },
  { "code": "HU", "name": "Hungary", "flag": "🇭🇺", "popular": false },
  { "code": "ID", "name": "Indonesia", "flag": "🇮🇩", "popular": false },
  { "code": "IE", "name": "Ireland", "flag": "🇮🇪", "popular": false },
  { "code": "IL", "name": "Israel", "flag": "🇮🇱", "popular": false },
  { "code": "IM", "name": "Isle of Man", "flag": "🇮🇲", "popular": false },
  { "code": "IN", "name": "India", "flag": "🇮🇳", "popular": false },
  { "code": "IR", "name": "Iran", "flag": "🇮🇷", "popular": false },
  { "code": "IS", "name": "Iceland", "flag": "🇮🇸", "popular": false },
  { "code": "IT", "name": "Italy", "flag": "🇮🇹", "popular": true },
  { "code": "JP", "name": "Japan", "flag": "🇯🇵", "popular": true },
  { "code": "KE", "name": "Kenya", "flag": "🇰🇪", "popular": false },
  { "code": "KH", "name": "Cambodia", "flag": "🇰🇭", "popular": false },
  { "code": "KR", "name": "South Korea", "flag": "🇰🇷", "popular": false },
  { "code": "KZ", "name": "Kazakhstan", "flag": "🇰🇿", "popular": false },
  { "code": "LA", "name": "Laos", "flag": "🇱🇦", "popular": false },
  { "code": "LI", "name": "Liechtenstein", "flag": "🇱🇮", "popular": false },
  { "code": "LK", "name": "Sri Lanka", "flag": "🇱🇰", "popular": false },
  { "code": "LT", "name": "Lithuania", "flag": "🇱🇹", "popular": false },
  { "code": "LU", "name": "Luxembourg", "flag": "🇱🇺", "popular": false },
  { "code": "LV", "name": "Latvia", "flag": "🇱🇻", "popular": false },
  { "code": "MA", "name": "Morocco", "flag": "🇲🇦", "popular": false },
  { "code": "MC", "name": "Monaco", "flag": "🇲🇨", "popular": false },
  { "code": "MD", "name": "Moldova", "flag": "🇲🇩", "popular": false },
  { "code": "ME", "name": "Montenegro", "flag": "🇲🇪", "popular": false },
  { "code": "MK", "name": "North Macedonia", "flag": "🇲🇰", "popular": false },
  { "code": "MT", "name": "Malta", "flag": "🇲🇹", "popular": false },
  { "code": "MX", "name": "Mexico", "flag": "🇲🇽", "popular": false },
  { "code": "MY", "name": "Malaysia", "flag": "🇲🇾", "popular": false },
  { "code": "NG", "name": "Nigeria", "flag": "🇳🇬", "popular": false },
  { "code": "NL", "name": "Netherlands", "flag": "🇳🇱", "popular": true },
  { "code": "NO", "name": "Norway", "flag": "🇳🇴", "popular": false },
  { "code": "NZ", "name": "New Zealand", "flag": "🇳🇿", "popular": false },
  { "code": "PA", "name": "Panama", "flag": "🇵🇦", "popular": false },
  { "code": "PH", "name": "Philippines", "flag": "🇵🇭", "popular": false },
  { "code": "PK", "name": "Pakistan", "flag": "🇵🇰", "popular": false },
  { "code": "PL", "name": "Poland", "flag": "🇵🇱", "popular": false },
  { "code": "PT", "name": "Portugal", "flag": "🇵🇹", "popular": true },
  { "code": "QA", "name": "Qatar", "flag": "🇶🇦", "popular": false },
  { "code": "RO", "name": "Romania", "flag": "🇷🇴", "popular": false },
  { "code": "RS", "name": "Serbia", "flag": "🇷🇸", "popular": false },
  { "code": "SA", "name": "Saudi Arabia", "flag": "🇸🇦", "popular": false },
  { "code": "SE", "name": "Sweden", "flag": "🇸🇪", "popular": true },
  { "code": "SG", "name": "Singapore", "flag": "🇸🇬", "popular": false },
  { "code": "SI", "name": "Slovenia", "flag": "🇸🇮", "popular": false },
  { "code": "SK", "name": "Slovakia", "flag": "🇸🇰", "popular": false },
  { "code": "TH", "name": "Thailand", "flag": "🇹🇭", "popular": false },
  { "code": "TR", "name": "Turkey", "flag": "🇹🇷", "popular": false },
  { "code": "TW", "name": "Taiwan", "flag": "🇹🇼", "popular": false },
  { "code": "UA", "name": "Ukraine", "flag": "🇺🇦", "popular": false },
  { "code": "US", "name": "United States", "flag": "🇺🇸", "popular": true },
  { "code": "UY", "name": "Uruguay", "flag": "🇺🇾", "popular": false },
  { "code": "VE", "name": "Venezuela", "flag": "🇻🇪", "popular": false },
  { "code": "VN", "name": "Vietnam", "flag": "🇻🇳", "popular": false },
  { "code": "ZA", "name": "South Africa", "flag": "🇿🇦", "popular": false }
];

// Keep the quick-connect area to two rows; the searchable dropdown still
// exposes every supported country without making the panel taller.
var popularCodes = ["PT", "ES", "GB", "US", "DE", "FR", "NL", "CH"];

function normalizeCountryCode(code) {
  var upper = String(code).toUpperCase().trim();
  return upper === "UK" ? "GB" : upper;
}

function countryByCode(code) {
  if (!code) return { code: "PT", name: "Portugal", flag: "🇵🇹" };
  var upper = normalizeCountryCode(code);
  for (var i = 0; i < allCountries.length; i++) {
    if (allCountries[i].code === upper) return allCountries[i];
  }
  return { code: upper, name: upper, flag: "🌐" };
}

var popularCountries = popularCodes.map(function(code) {
  return countryByCode(code);
});

function isSupportedCountry(code) {
  if (!code) return false;
  var upper = normalizeCountryCode(code);
  for (var i = 0; i < allCountries.length; i++) {
    if (allCountries[i].code === upper) return true;
  }
  return false;
}

function countryFlag(code) {
  return countryByCode(code).flag;
}

function countryName(code) {
  return countryByCode(code).name;
}

function dropdownOptions() {
  return allCountries.map(function(c) {
    return {
      value: c.code,
      label: c.flag + "  " + c.name + " (" + c.code + ")"
    };
  });
}
