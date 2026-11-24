import QtQuick
import QtTest
import "../.." as Plugin
import "../../CountryRecents.js" as CountryRecents

// Service processes use the test double; no real VPN, subprocess or network.
TestCase {
  id: testCase
  name: "QuickDestinationsBehavior"
  visible: true
  when: windowShown
  width: 410
  height: 720

  Component {
    id: serviceFactory
    Plugin.Service {}
  }

  QtObject {
    id: fakeService
    property bool setupDone: true
    property bool busy: false
    property string country: "PT"
    property var favoriteCountries: ["PT", "ES"]
    property var recentCountries: ["ES", "FR", "US"]
    property int chooseCalls: 0
    property int favoriteCalls: 0
    property int connectCalls: 0
    property int chosenSignals: 0
    property int favoriteSignals: 0
    function setCountry(value) {
      chooseCalls++
      country = value
      return true
    }
    function toggleFavorite(value) {
      favoriteCalls++
      const current = favoriteCountries.slice()
      const index = current.indexOf(value)
      if (index >= 0) current.splice(index, 1)
      else current.push(value)
      favoriteCountries = current
      return true
    }
  }

  Component {
    id: quickFactory
    Plugin.QuickDestinations {
      service: fakeService
      width: 360
      language: "pt-PT"
      onChosen: fakeService.chosenSignals++
      onFavoriteToggle: fakeService.favoriteSignals++
    }
  }

  function serviceWith(settings) {
    const service = createTemporaryObject(serviceFactory, this, {settings: settings})
    verify(service !== null)
    return service
  }

  function init() {
    fakeService.setupDone = true
    fakeService.busy = false
    fakeService.country = "PT"
    fakeService.favoriteCountries = ["PT", "ES"]
    fakeService.recentCountries = ["ES", "FR", "US"]
    fakeService.chooseCalls = 0
    fakeService.favoriteCalls = 0
    fakeService.connectCalls = 0
    fakeService.chosenSignals = 0
    fakeService.favoriteSignals = 0
  }

  function test_csvNormalizationStrictLimitsAndCanonicalSupport() {
    compare(CountryRecents.normalizeCode(" es "), "ES")
    compare(CountryRecents.normalizeCode("GB"), "GB")
    compare(CountryRecents.normalizeCode("UK"), "")
    compare(CountryRecents.normalizeCode("1A"), "")
    compare(CountryRecents.normalizeCode("ZZ"), "")
    compare(CountryRecents.normalizeCode("KR"), "")
    compare(CountryRecents.normalizeCode("FR\n"), "")
    compare(CountryRecents.normalizeCode("FR,PT"), "")
    compare(CountryRecents.normalizeCode(42), "")
    compare(CountryRecents.fromCsv(" pt,ES,xx,ES,UK,GB,DE ", 5).join(","), "PT,ES,GB,DE")
    compare(CountryRecents.fromCsv("PT,ES,FR,DE,US,GB,IT,NL,SE", 8).join(","), "PT,ES,FR,DE,US,GB,IT,NL")
    compare(CountryRecents.fromCsv(["PT", "ES"], 8).join(","), "")
    compare(CountryRecents.fromCsv("PT,FR\n,ES", 8).join(","), "PT,ES")
    compare(CountryRecents.addRecent(["ES", "PT", "FR", "DE", "US"], "FR").join(","), "FR,ES,PT,DE,US")
  }

  function test_restoreReadsValidCsvWithoutWriting() {
    const service = serviceWith({})
    const writes = []
    service.settingChanged.connect(function(key) { writes.push(key) })
    service.settings = {
      favoriteCountries: " es, PT,xx,PT,UK,GB,DE,FR,IT,NL,US ",
      recentCountries: "IT,FR,IT,PT,GB,DE,ES",
      defaultCountry: "ES"
    }
    compare(service.favoriteCountries.join(","), "ES,PT,GB,DE,FR,IT,NL,US")
    compare(service.recentCountries.join(","), "IT,FR,PT,GB,DE")
    compare(service.country, "ES")
    compare(writes.length, 0)
  }

  function test_favoritesAreExplicitBoundedAndNeverConnect() {
    const service = serviceWith({})
    const writes = []
    service.settingChanged.connect(function(key, value) { writes.push([key, value]) })
    verify(!service.toggleFavorite("UK"))
    verify(!service.toggleFavorite("ZZ"))
    compare(writes.length, 0)
    verify(service.toggleFavorite("PT"))
    compare(service.favoriteCountries.join(","), "PT")
    compare(writes[0][0], "favoriteCountries")
    compare(writes[0][1], "PT")
    verify(service.toggleFavorite("PT"))
    compare(service.favoriteCountries.length, 0)
    service.settings = {favoriteCountries: "PT,ES,FR,DE,GB,US,IT,NL"}
    const count = writes.length
    verify(!service.toggleFavorite("SE"))
    compare(service.favoriteCountries.length, 8)
    compare(writes.length, count)
    verify(service.toggleFavorite("FR"))
    verify(service.toggleFavorite("SE"))
    compare(service.favoriteCountries.join(","), "PT,ES,DE,GB,US,IT,NL,SE")
    compare(service.recentCountries.length, 0)
  }

  function test_recentOnlyAfterObservedActiveNetworkManagerAndOnlyOnce() {
    const service = serviceWith({recentCountries: "FR,PT"})
    const writes = []
    service.settingChanged.connect(function(key, value) {
      if (key === "recentCountries") writes.push(value)
    })
    service.setCountry("ES")
    compare(service.recentCountries.join(","), "FR,PT")
    compare(writes.length, 0)
    service.activeCountry = "ES"
    service.parseStatus('{"connected":true,"backend":"networkmanager","state":"activating"}')
    compare(writes.length, 0)
    service.parseStatus('{"connected":true,"backend":"legacy","state":"activated"}')
    compare(writes.length, 0)
    service.parseStatus('{"connected":true,"backend":"networkmanager","state":"activated"}')
    compare(service.recentCountries.join(","), "ES,FR,PT")
    compare(writes.length, 1)
    compare(writes[0], "ES,FR,PT")
    verify(service.statusObservedAt > 0)
    service.parseStatus('{"connected":true,"backend":"networkmanager","state":"activated"}')
    compare(writes.length, 1)
    service.parseStatus("{}")
    verify(service.statusUnknown)
    compare(service.statusObservedAt, 0)
    compare(writes.length, 1)
    service.parseStatus('{"connected":true,"backend":"networkmanager","state":"activated"}')
    compare(writes.length, 1)
    service.parseStatus('{"connected":false,"backend":null,"state":""}')
    compare(service.activeCountry, "")
    service.setCountry("FR")
    compare(writes.length, 1)
  }

  function test_successfulActionDoesNotRecordUntilObservedStatus() {
    const service = serviceWith({recentCountries: "FR"})
    const writes = []
    service.settingChanged.connect(function(key, value) {
      if (key === "recentCountries") writes.push(value)
    })
    service.readyNm = true
    service.nmPermission = "yes"
    service.readyRequests = true
    service.readyCreds = true
    service.connectTo("ES", "wireguard", "traffic", "", "fastest")
    let action = null
    const pending = [service]
    while (pending.length > 0) {
      const node = pending.pop()
      if (node.objectName === "actionProcess") action = node
      const children = node.children || []
      for (let i = 0; i < children.length; i++) pending.push(children[i])
    }
    verify(action !== null)
    action.stdout.read('{"ok":true,"action":"connect","backend":"networkmanager","country":"ES"}')
    action.running = false
    action.exited(0)
    compare(service.connected, true)
    compare(service.activeCountry, "ES")
    compare(service.recentCountries.join(","), "FR")
    compare(writes.length, 0)
    service.parseStatus('{"connected":true,"backend":"networkmanager","state":"activated"}')
    compare(service.recentCountries.join(","), "ES,FR")
    compare(writes.length, 1)
  }

  function test_onlyVerifiedCountryIsRecordedAndFiveKept() {
    const service = serviceWith({recentCountries: "PT,ES,FR,DE,GB"})
    const writes = []
    service.settingChanged.connect(function(key, value) {
      if (key === "recentCountries") writes.push(value)
    })
    service.activeCountry = "ZZ"
    service.parseStatus('{"connected":true,"backend":"networkmanager","state":"activated"}')
    compare(writes.length, 0)
    service.activeCountry = "IT"
    service.parseStatus('{"connected":true,"backend":"networkmanager","state":"activated"}')
    compare(service.recentCountries.join(","), "IT,PT,ES,FR,DE")
    compare(writes.length, 1)
    service.activeCountry = "ES"
    service.parseStatus('{"connected":true,"backend":"networkmanager","state":"activated"}')
    compare(service.recentCountries.join(","), "ES,IT,PT,FR,DE")
    compare(writes.length, 2)
    service.parseStatus('{"connected":true,"backend":"networkmanager","state":"activated"}')
    compare(writes.length, 2)
  }

  function test_oldStatusCompletionDoesNotChangeObservationTime() {
    const service = serviceWith({})
    service.parseStatus('{"connected":false,"backend":null,"state":""}')
    const observed = service.statusObservedAt
    verify(observed > 0)
    service.refresh()
    const status = findChild(service, "statusProcess")
    verify(status !== null)
    service.statusGeneration++
    service.statusOutput = '{"connected":true,"backend":"networkmanager","state":"activated"}'
    status.running = false
    status.exited(0)
    compare(service.statusObservedAt, observed)

    service.refresh()
    status.running = false
    status.stderr.read("status unavailable")
    status.exited(1)
    compare(service.statusObservedAt, 0)
    verify(service.statusUnknown)
  }

  function test_quickChipsChangeSelectionAndFavoriteOnly() {
    const quick = createTemporaryObject(quickFactory, this)
    verify(quick !== null)
    verify(quick.implicitHeight > 0)
    compare(quick.favoriteCodes.join(","), "PT,ES")
    compare(quick.recentCodes.join(","), "FR,US")
    compare(quick.selectedCode, "PT")
    const recent = findChild(quick, "quickChooseRecent_FR")
    const favorite = findChild(quick, "quickAddFavorite_FR")
    verify(recent !== null && favorite !== null)
    recent.clicked()
    compare(fakeService.country, "FR")
    compare(fakeService.chooseCalls, 1)
    compare(fakeService.chosenSignals, 1)
    compare(fakeService.connectCalls, 0)
    favorite.clicked()
    compare(fakeService.favoriteCalls, 1)
    compare(fakeService.favoriteSignals, 1)
    compare(fakeService.favoriteCountries.join(","), "PT,ES,FR")
    compare(quick.recentCodes.join(","), "US")
    verify(quick.selectedFavorite)
    fakeService.setupDone = false
    verify(!quick.visible)
  }

  function test_maxFavoritesStayInOneCompactRowAndDisableMore() {
    fakeService.country = "SE"
    fakeService.favoriteCountries = ["PT", "ES", "FR", "DE", "GB", "US", "IT", "NL"]
    fakeService.recentCountries = ["SE"]
    const quick = createTemporaryObject(quickFactory, this)
    verify(quick !== null)
    quick.width = 320
    compare(quick.favoriteCodes.length, 8)
    verify(quick.implicitHeight > 0 && quick.implicitHeight < 210)
    verify(!findChild(quick, "quickAddFavorite_SE").enabled)
    compare(fakeService.favoriteCalls, 0)
    compare(fakeService.connectCalls, 0)
  }

  function test_emptyShortcutsAreHidden() {
    fakeService.favoriteCountries = []
    fakeService.recentCountries = []
    const quick = createTemporaryObject(quickFactory, this)
    verify(!quick.visible)
    fakeService.recentCountries = ["PT"]
    verify(quick.visible)
  }
}
