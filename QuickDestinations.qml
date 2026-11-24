pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Countries.js" as Countries
import "CountryRecents.js" as CountryRecents

// Compact destination shortcuts. Picking a country updates the next
// destination only; connection remains an explicit dashboard action.
Column {
  id: root
  objectName: "quickDestinations"
  required property var service
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  property string language: "en"

  signal chosen(string code)
  signal favoriteToggle(string code)

  readonly property bool isPortuguese: language.toLowerCase().indexOf("pt") === 0
  readonly property var favoriteCodes: CountryRecents.normalizeList(service.favoriteCountries, 8)
  // Keep the two rows concise; an item already in Favorites needn't repeat.
  readonly property var recentCodes: CountryRecents.normalizeList(service.recentCountries, 5).filter(function(code) {
    return root.favoriteCodes.indexOf(code) < 0
  })
  readonly property string selectedCode: CountryRecents.normalizeCode(service.country)
  readonly property bool selectedFavorite: favoriteCodes.indexOf(selectedCode) >= 0

  function choose(code) {
    const normalized = CountryRecents.normalizeCode(code)
    if (normalized && typeof service.setCountry === "function" && service.setCountry(normalized))
      chosen(normalized)
  }

  function toggle(code) {
    const normalized = CountryRecents.normalizeCode(code)
    if (normalized && typeof service.toggleFavorite === "function" && service.toggleFavorite(normalized))
      favoriteToggle(normalized)
  }

  visible: !!service.setupDone && (favoriteCodes.length > 0 || recentCodes.length > 0)
  spacing: Style.space(8)
  width: parent ? parent.width : Style.space(340)

  Column {
    width: parent.width
    visible: root.favoriteCodes.length > 0
    spacing: Style.space(4)

    Text {
      text: root.isPortuguese ? "Favoritos" : "Favorites"
      textFormat: Text.PlainText
      color: root.foreground
      opacity: 0.58
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Flickable {
      id: favoritesStrip
      width: parent.width
      height: favoritesRow.implicitHeight
      contentWidth: favoritesRow.implicitWidth
      contentHeight: height
      clip: true
      flickableDirection: Flickable.HorizontalFlick
      boundsBehavior: Flickable.StopAtBounds

      Row {
        id: favoritesRow
        spacing: Style.space(5)
        Repeater {
          model: root.favoriteCodes
          delegate: Row {
            required property string modelData
            readonly property string code: modelData
            objectName: "quickFavoriteRow_" + code
            spacing: Style.space(2)

            Button {
              objectName: "quickChooseFavorite_" + parent.code
              text: Countries.countryFlag(parent.code) + " " + Countries.countryName(parent.code)
              tooltipText: root.isPortuguese ? "Selecionar " + Countries.countryName(parent.code) : "Select " + Countries.countryName(parent.code)
              Accessible.name: tooltipText
              width: Math.min(implicitWidth, Math.max(60, root.width - Style.space(55)))
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              foreground: root.foreground
              selected: root.selectedCode === parent.code
              bordered: selected
              focusable: true
              onClicked: root.choose(parent.code)
            }

            Button {
              objectName: "quickRemoveFavorite_" + parent.code
              text: "★"
              tooltipText: root.isPortuguese ? "Remover dos favoritos" : "Remove from favorites"
              Accessible.name: tooltipText + ": " + Countries.countryName(parent.code)
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              foreground: root.foreground
              focusable: true
              onClicked: root.toggle(parent.code)
            }
          }
        }
      }
    }
  }

  Column {
    width: parent.width
    visible: root.recentCodes.length > 0
    spacing: Style.space(4)

    Text {
      text: root.isPortuguese ? "Recentes" : "Recent"
      textFormat: Text.PlainText
      color: root.foreground
      opacity: 0.58
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Flickable {
      id: recentsStrip
      width: parent.width
      height: recentsRow.implicitHeight
      contentWidth: recentsRow.implicitWidth
      contentHeight: height
      clip: true
      flickableDirection: Flickable.HorizontalFlick
      boundsBehavior: Flickable.StopAtBounds

      Row {
        id: recentsRow
        spacing: Style.space(5)
        Repeater {
          model: root.recentCodes
          delegate: Row {
            required property string modelData
            readonly property string code: modelData
            objectName: "quickRecentRow_" + code
            spacing: Style.space(2)

            Button {
              objectName: "quickChooseRecent_" + parent.code
              text: Countries.countryFlag(parent.code) + " " + Countries.countryName(parent.code)
              tooltipText: root.isPortuguese ? "Selecionar " + Countries.countryName(parent.code) : "Select " + Countries.countryName(parent.code)
              Accessible.name: tooltipText
              width: Math.min(implicitWidth, Math.max(60, root.width - Style.space(55)))
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              foreground: root.foreground
              selected: root.selectedCode === parent.code
              bordered: selected
              focusable: true
              onClicked: root.choose(parent.code)
            }

            Button {
              objectName: "quickAddFavorite_" + parent.code
              enabled: root.favoriteCodes.length < 8 && !root.service.busy
              text: "☆"
              tooltipText: root.isPortuguese ? "Adicionar aos favoritos" : "Add to favorites"
              Accessible.name: tooltipText + ": " + Countries.countryName(parent.code)
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              foreground: root.foreground
              focusable: true
              onClicked: root.toggle(parent.code)
            }
          }
        }
      }
    }
  }
}
