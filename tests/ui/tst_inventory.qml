import QtQuick
import QtTest
import "../.." as Plugin

TestCase {
  name: "InventoryRequestLifecycle"
  Component {
    id: factory
    Plugin.ServerInventory {
      cliAvailable: true
      runnerPath: "/unused/test-runner"
    }
  }

  function test_countryChangeRejectsOldResultAndRequestsCurrentCountry() {
    var inventory = createTemporaryObject(factory, this)
    verify(inventory !== null)
    inventory.refresh()
    var process = inventory.children[0]
    compare(process.running, true)
    process.stdout.read('[{"server":"lisbon-s405-i19","city":"Lisbon","load":18}]')
    inventory.country = "ES"
    inventory.countryName = "Spain"
    inventory.refresh()
    process.running = false
    process.exited(0)
    compare(inventory.options.length, 1)
    compare(process.running, true)
    verify(process.command.indexOf("ES") >= 0)
    process.stdout.read('[{"server":"madrid-s10-i2","city":"Madrid","load":20}]')
    process.running = false
    process.exited(0)
    compare(inventory.options.length, 2)
    compare(inventory.options[1].value, "madrid-s10-i2")
  }

  function test_refreshWhileRunningDoesNotDestroyPartialOutput() {
    var inventory = createTemporaryObject(factory, this)
    inventory.refresh()
    var process = inventory.children[0]
    process.stdout.read('[{"server":"lisbon-s405-i19","city":"Lisbon","load":18}]')
    inventory.refresh()
    process.running = false
    process.exited(0)
    compare(inventory.options.length, 2)
  }

  function test_cliFailureKeepsAutomaticFallbackAndUsefulError() {
    var inventory = createTemporaryObject(factory, this)
    inventory.refresh()
    var process = inventory.children[0]
    process.stderr.read("CLI authentication expired. Run setup again.")
    process.running = false
    process.exited(1)
    compare(inventory.options.length, 1)
    verify(inventory.error.indexOf("authentication expired") >= 0)
  }
}
