import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "NotificationLogic.js" as NotificationLogic

BarWidget {
  id: root
  moduleName: "omacom.notification-center"


  property bool popupOpen: false
  function close() { popupOpen = false }

  // The list is read from disk each time the popup opens rather than kept in
  // sync, so it costs nothing while closed and can never show a stale row.
  onPopupOpenChanged: if (popupOpen) root.refreshRecent()

  // Where the notifications actually are.
  //
  // Omarchy 4.0.4 stopped handing third-party bar widgets the notification
  // service itself: firstPartyServiceFor() now returns a narrow proxy
  // (PluginFirstPartyServiceApi) carrying doNotDisturb and setDoNotDisturb and
  // nothing else, so the pendingModel/pastModel this popup was built on no
  // longer exist and every row silently vanished. The notifications are still
  // right there on disk though -- one JSON object per file, which is where the
  // service keeps them and what its own showHistory replays -- so the list
  // reads them directly. The service trims that directory to its own limit, so
  // this shows exactly what it has kept.
  readonly property string historyDir:
    Quickshell.env("HOME") + "/.local/state/omarchy/notifications/history/"

  ListModel { id: recentModel }

  function refreshRecent() {
    if (readRecent.running) return
    readRecent.running = true
  }

  function loadRecent(raw) {
    // Urgency 1 is Normal, and only covers a file that somehow carries no
    // urgency of its own. Spelled out rather than imported so this widget does
    // not depend on Quickshell.Services.Notifications just for the enum.
    var rows = NotificationLogic.recentFromFiles(raw, 1)
    recentModel.clear()
    for (var i = 0; i < rows.length; i++) recentModel.append(rows[i])
  }

  Process {
    id: readRecent
    // One line per notification: its file path, a tab, then the file's JSON on
    // a single line. Reading the whole directory in one subprocess keeps this
    // to a single spawn per popup open.
    command: ["bash", "-c",
      'for f in "$1"*.json; do [ -f "$f" ] || continue; printf "%s\\t" "$f"; tr -d "\\n" < "$f"; printf "\\n"; done',
      "--", root.historyDir]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadRecent(text)
    }
  }

  // Look up the long-running notifications service through the shell host.
  readonly property var hostShell: bar && bar.shell ? bar.shell : null
  readonly property var notificationService: hostShell?.firstPartyServiceFor("omarchy.notifications")

  function isChromiumDerived(app, appIcon) {
    return NotificationLogic.isChromiumDerived(app, appIcon)
  }

  function sanitizeBody(s, app, appIcon) {
    return NotificationLogic.sanitizeBody(s, app, appIcon)
  }

  function styledBody(s, app, appIcon) {
    return NotificationLogic.styledBody(s, app, appIcon)
  }

  // What clicking a row does.
  //
  // Not the libnotify "default" action: that only lives as long as the sender's
  // notification does, and every row here is one the server has already closed.
  // The shell's own service refuses to invoke it for restored rows for exactly
  // that reason -- the id belongs to a past generation and could fire an
  // unrelated live notification's action.
  //
  // What does survive is the two things the service falls back to. Omarchy's
  // own toasts carry their action as an argv vector that the history file
  // preserves verbatim ("Screenshot saved", "Screen recording saved"), so that
  // runs. Everything else -- a chat message, a VPN state change -- gets the
  // sender's window focused, which is what clicking those is for anyway.
  function activate(execArgv, app) {
    var argv = NotificationLogic.parseExecArgv(execArgv)
    if (argv) {
      // Detached, so the action outlives the shell: some Omarchy toasts
      // restart it.
      Util.execArgv(argv)
    } else if (String(app || "").length > 0) {
      focusApp.appName = String(app)
      focusApp.retried = false
      focusApp.command = [root.focusAppBin, focusApp.appName]
      focusApp.running = true
    }
    root.close()
  }

  readonly property string focusAppBin:
    Quickshell.env("OMARCHY_PATH") + "/bin/omarchy-hyprland-focus-app"

  // Focusing the sender is best-effort, and the helper matches its argument as
  // a regex against the window class. Plenty of apps notify under a display
  // name that is not their class -- "Telegram Desktop" against
  // org.telegram.desktop -- so a miss is retried with the spaces turned into
  // wildcards. That bridges exactly this gap without loosening the match into
  // "any one word wins", which would let "Package Manager" grab a window that
  // merely has "package" in its class.
  Process {
    id: focusApp
    running: false
    property string appName: ""
    property bool retried: false

    onExited: function(exitCode) {
      if (exitCode === 0 || focusApp.retried) return
      var pattern = focusApp.appName.replace(/\s+/g, ".*")
      if (pattern === focusApp.appName) return
      focusApp.retried = true
      focusApp.command = [root.focusAppBin, pattern]
      focusApp.running = true
    }
  }

  function notificationIconSource(icon) {
    var value = String(icon || "")
    if (value.length === 0) return ""
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    return Quickshell.iconPath(value, true)
  }

  readonly property bool dnd: notificationService ? notificationService.doNotDisturb : false

  readonly property string icon: dnd ? "󰂛" : "󰂚"

  // Theme palette (mirrors HistoryPanel's tokens so the popup matches the
  // rest of the notification stack).
  readonly property color colForeground: Color.foreground
  readonly property color colDim: Qt.darker(Color.foreground, 1.4)
  readonly property color colBorder: Style.normalBorderFor(Color.foreground, Color.accent)
  readonly property color colSurface: Style.normalFillFor(Color.foreground, Color.accent)
  readonly property color colAccent: Color.accent
  readonly property int cardRadius: Style.cornerRadius

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // BarIconButton centres the glyph on its painted shape, not its advance
  // box, so the bell sits in line with the other bar icons.
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    tooltipText: root.dnd ? "Do Not Disturb" : "Recent notifications"

    onPressed: function(b) {
      if (b === Qt.RightButton) {
        if (root.notificationService) {
          root.notificationService.setDoNotDisturb(!root.notificationService.doNotDisturb)
        }
      } else {
        root.popupOpen = !root.popupOpen
      }
    }
  }

  PopupCard {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(440))
    contentHeight: popup.cappedContentHeight(Style.space(540))

    ColumnLayout {
      anchors.fill: parent
      spacing: Style.space(10)

      // ----------------------------------------- header
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Text {
          text: "Notifications"
          font.family: root.bar ? root.bar.fontFamily : ""
          color: root.colForeground
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Item { Layout.fillWidth: true }

        BorderSurface {
          id: dndPill
          Layout.preferredHeight: Math.max(Style.space(24), Style.font.bodySmall + Style.spacing.controlPaddingY * 2)
          Layout.preferredWidth: dndLabel.implicitWidth + dndGlyph.implicitWidth + Style.space(18)
          radius: Math.min(Style.space(12), root.cardRadius + Style.space(6))
          color: dndOn ? root.colAccent : root.colSurface
          borderSpec: Border.flat(dndOn ? root.colAccent : root.colBorder, Style.normalBorderWidth)

          readonly property bool dndOn: !!root.notificationService && root.notificationService.doNotDisturb

          Row {
            anchors.centerIn: parent
            spacing: Style.space(4)

            Text {
              id: dndGlyph
              text: dndPill.dndOn ? "󰂛" : "󰂚"
              font.family: root.bar ? root.bar.fontFamily : ""
              color: dndPill.dndOn ? Color.background : root.colDim
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: dndLabel
              text: dndPill.dndOn ? "DND on" : "DND off"
              font.family: root.bar ? root.bar.fontFamily : ""
              color: dndPill.dndOn ? Color.background : root.colDim
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (root.notificationService) root.notificationService.setDoNotDisturb(!dndPill.dndOn)
          }
        }
      }

      // A single list, so no tabs. The two the popup used to have -- pending
      // and past -- were the service's two models, and "pending" meant a toast
      // still on screen, which the screen is already showing. What is left is
      // the history, which is what "recent notifications" means here.
      // ----------------------------------------- list
      ListView {
        id: listView
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        spacing: Style.space(8)

        model: recentModel
        visible: count > 0

        delegate: BorderSurface {
          id: rowCard
          required property int index
          required property string app
          required property string appIcon
          required property string summary
          required property string body
          required property string image
          required property string execArgv
          required property int urgency
          required property double timestamp

          readonly property bool hasMedia: image.length > 0 && (
            image.indexOf("image://icon//") === 0 || image.indexOf("file://") === 0)
          readonly property string smallIconSource: image.length > 0 ? image : root.notificationIconSource(appIcon)
          readonly property bool hasIcon: !hasMedia && smallIconSource.length > 0
          readonly property string sanitizedBody: root.sanitizeBody(body, app, appIcon)
          readonly property string styledMarkup: root.styledBody(body, app, appIcon)

          width: listView.width
          implicitHeight: rowContent.implicitHeight + Style.spacing.panelGap
          radius: root.cardRadius
          // Lit on hover, so it reads as something you can click.
          color: rowArea.containsMouse ? root.colSurface : "transparent"
          borderSpec: Border.flat(root.colBorder, Style.normalBorderWidth)

          MouseArea {
            id: rowArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.activate(rowCard.execArgv, rowCard.app)
          }

          RowLayout {
            id: rowContent
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: rowCard.borderLeft + Style.space(12)
            anchors.rightMargin: rowCard.borderRight + Style.space(12)
            spacing: Style.space(10)

            Item {
              id: imageSlot
              Layout.preferredWidth: Style.space(32)
              Layout.preferredHeight: Style.space(32)
              Layout.alignment: Qt.AlignVCenter
              // Hide on icon load failure so unresolved themed-icon names
              // don't render Qt's broken-image placeholder.
              visible: (rowCard.hasIcon || rowCard.hasMedia) && rowIconImage.status !== Image.Error

              Image {
                id: rowIconImage
                anchors.fill: parent
                source: rowCard.hasMedia ? rowCard.image : rowCard.smallIconSource
                fillMode: rowCard.hasMedia ? Image.PreserveAspectCrop : Image.PreserveAspectFit
                sourceSize.width: imageSlot.width * Screen.devicePixelRatio
                sourceSize.height: imageSlot.height * Screen.devicePixelRatio
                asynchronous: true
                smooth: true
              }
            }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(2)

              Text {
                Layout.fillWidth: true
                visible: rowCard.summary.length > 0
                text: rowCard.summary
                font.family: root.bar ? root.bar.fontFamily : ""
                color: root.colForeground
                font.pixelSize: Style.font.subtitle
                font.bold: true
                wrapMode: Text.WordWrap
                elide: Text.ElideRight
                maximumLineCount: 1
              }

              Text {
                Layout.fillWidth: true
                visible: rowCard.sanitizedBody.length > 0
                text: rowCard.styledMarkup
                font.family: root.bar ? root.bar.fontFamily : ""
                textFormat: Text.StyledText
                color: root.colDim
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
                elide: Text.ElideRight
                maximumLineCount: 2
              }
            }

            // No per-row dismiss: the proxy has no way to remove one, and the
            // service trims the directory itself as new notifications arrive.
            Text {
              Layout.alignment: Qt.AlignVCenter
              text: Qt.formatDateTime(new Date(rowCard.timestamp), "HH:mm")
              font.family: root.bar ? root.bar.fontFamily : ""
              color: root.colDim
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      // ----------------------------------------- empty state
      Item {
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: listView.count === 0

        ColumnLayout {
          anchors.centerIn: parent
          spacing: Style.space(6)

          Text {
            Layout.alignment: Qt.AlignHCenter
            text: "󰂚"
            font.family: root.bar ? root.bar.fontFamily : ""
            color: root.colBorder
            font.pixelSize: Style.font.displayLarge
          }

          Text {
            Layout.alignment: Qt.AlignHCenter
            text: "Nothing recent"
            font.family: root.bar ? root.bar.fontFamily : ""
            color: root.colDim
            font.pixelSize: Style.font.body
          }
        }
      }
    }
  }
}
