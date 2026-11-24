pragma Singleton
import QtQuick

QtObject {
  function flat(color, width) { return ({ color: color, width: width }) }
}
