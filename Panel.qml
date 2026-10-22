import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import qs.Ui
import qs.Commons
import "Model.js" as Model

// SiriusXM bar widget + popup. All SiriusXM work happens in the `sxm`
// helper next to this file; the panel only runs its subcommands and renders
// the three JSON files it maintains (status, channel lineup, user state).
Panel {
  id: root
  moduleName: "sastr.siriusxm"
  ipcTarget: "sastr.siriusxm"
  manageIpc: false

  readonly property string sxmPath: Qt.resolvedUrl("sxm").toString().replace(/^file:\/\//, "")
  readonly property string home: Quickshell.env("HOME")
  readonly property string runtimeDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omarchy-siriusxm"
  readonly property string cacheDir: (Quickshell.env("XDG_CACHE_HOME") || home + "/.cache") + "/omarchy-siriusxm"
  readonly property string dataDir: (Quickshell.env("XDG_DATA_HOME") || home + "/.local/share") + "/omarchy-siriusxm"

  property var status: Model.parseStatus("")
  property var channels: []
  property var favorites: []
  property bool statusChecked: false

  property string searchText: ""
  property string filterMode: "all"     // "all" | "favorites"
  property string genre: ""
  property int selectedIndex: -1
  property bool cursorActive: false
  property string actionError: ""
  property bool busy: false
  property bool signingIn: false
  property string loginError: ""
  // The volume the user asked for, held until the status file reports it so
  // the slider never snaps back to a stale value mid-change.
  property int pendingVolume: -1
  property int sentVolume: -1
  property bool volumeInFlight: false
  // While playing, volume is set straight on mpv's PipeWire stream (named
  // "SiriusXM" via --audio-client-name), exactly as Omarchy's audio panel
  // does: no process per slider step, and both panels show the same number.
  // The sxm CLI path only covers the moments before the stream exists.
  readonly property var pwNodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property var streamNode: {
    for (var i = 0; i < pwNodes.length; i++) {
      var n = pwNodes[i]
      if (n && n.isStream && n.isSink && String(n.name) === "SiriusXM") return n
    }
    return null
  }
  readonly property bool hasStreamVolume: !!(streamNode && streamNode.audio)
  readonly property int shownVolume: hasStreamVolume
    ? Math.max(0, Math.min(100, Math.round(streamNode.audio.volume * 100)))
    : (pendingVolume >= 0 ? pendingVolume : status.volume)

  readonly property bool loggedIn: status.loggedIn
  readonly property var channel: status.channel
  readonly property var track: status.track
  readonly property bool playing: status.state === "playing"
  readonly property var genres: Model.genres(channels)
  readonly property var filtered: Model.filter(channels, searchText, filterMode, genre, favorites)
  readonly property string errorText: actionError || status.error

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: Style.hoverFillFor(fg, Color.accent)
  readonly property color selectedFill: Style.selectedFillFor(fg, Color.accent)

  readonly property string icon: "󰐹"

  // ---- actions ---------------------------------------------------------

  function run(args, onDone) {
    var proc = processComponent.createObject(root, { command: [root.sxmPath].concat(args), onDone: onDone || null })
    proc.running = true
  }

  function play(channelId) {
    if (!channelId) return
    actionError = ""
    run(["play", channelId])
  }

  function toggleFavorite(channelId) {
    if (!channelId) return
    // Optimistic: the state file watch confirms it a moment later.
    var next = favorites.slice()
    var at = next.indexOf(channelId)
    if (at >= 0) next.splice(at, 1)
    else next.push(channelId)
    favorites = next
    run(["fav", channelId])
  }

  function setVolume(value) {
    var level = Math.max(0, Math.min(100, Math.round(value)))
    if (hasStreamVolume) {
      streamNode.audio.volume = level / 100   // sxm picks the change up and saves it
      return
    }
    pendingVolume = level
    volumeSettle.restart()
    if (!volumeTimer.running) volumeTimer.start()  // throttle, not debounce: audio follows the drag
  }

  function refreshChannels(force) {
    if (!loggedIn) return
    busy = true
    run(force ? ["channels", "--refresh", "--json"] : ["channels", "--json"], function() { root.busy = false })
  }

  function checkStatus() {
    run(["status", "--json"], function(code) {
      root.statusChecked = true
      if (code === 0 && root.loggedIn && root.channels.length === 0) root.refreshChannels(false)
    })
  }

  function signIn(email, password) {
    if (signingIn) return
    if (!email || !password) { loginError = "Enter your email and password"; return }
    signingIn = true
    loginError = ""
    loginProc.secret = JSON.stringify({ username: email, password: password })
    loginProc.running = true
  }

  function signOut() {
    run(["logout"], function() { root.channels = [] })
  }

  function open() {
    root.controller.show()
    checkStatus()
  }

  function moveCursor(dy) {
    if (filtered.length === 0) return
    if (!cursorActive || selectedIndex < 0) { cursorActive = true; selectedIndex = 0; return }
    selectedIndex = Math.max(0, Math.min(filtered.length - 1, selectedIndex + dy))
  }

  function activateCursor() {
    if (selectedIndex >= 0 && selectedIndex < filtered.length) play(filtered[selectedIndex].id)
  }

  onFilteredChanged: if (selectedIndex >= filtered.length) selectedIndex = filtered.length - 1

  // ---- data ------------------------------------------------------------

  // Paths stay empty until the first `sxm status` has created the files:
  // a watch set on a missing file never fires. The reload timer covers
  // watches lost to atomic replaces.
  FileView {
    id: statusFile
    path: root.statusChecked ? root.runtimeDir + "/status.json" : ""
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.status = Model.parseStatus(text())
      if (root.pendingVolume >= 0 && !root.volumeInFlight && !volumeSlider.dragging
          && root.status.volume === root.pendingVolume) root.pendingVolume = -1
    }
  }

  FileView {
    id: lineupFile
    path: root.statusChecked ? root.cacheDir + "/channels.json" : ""
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.channels = Model.parseLineup(text())
  }

  FileView {
    id: userFile
    path: root.statusChecked ? root.dataDir + "/state.json" : ""
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.favorites = Model.parseFavorites(text())
  }

  PwObjectTracker { objects: root.streamNode ? [root.streamNode] : [] }

  Component {
    id: processComponent
    Process {
      property var onDone: null
      stderr: StdioCollector { id: errors; waitForEnd: true }
      onExited: function(code) {
        if (code !== 0) root.actionError = Model.cleanError(errors.text) || "sxm exited with " + code
        else if (command[1] === "play" || command[1] === "toggle") root.actionError = ""
        statusFile.reload()
        if (command[1] === "fav") userFile.reload()
        if (command[1] === "channels") lineupFile.reload()
        if (onDone) onDone(code)
        destroy()
      }
    }
  }

  // The password travels over stdin, never argv.
  Process {
    id: loginProc
    property string secret: ""
    command: [root.sxmPath, "login", "--stdin"]
    stdinEnabled: true
    stderr: StdioCollector { id: loginErrors; waitForEnd: true }
    onStarted: {
      write(secret + "\n")
      secret = ""
    }
    onExited: function(code) {
      root.signingIn = false
      statusFile.reload()
      if (code === 0) {
        passwordField.text = ""
        root.loginError = ""
        root.checkStatus()
        root.refreshChannels(false)
      } else {
        root.loginError = Model.cleanError(loginErrors.text) || "Sign-in failed"
      }
    }
  }

  Timer {
    interval: root.opened || root.status.running ? 2000 : 15000
    running: root.statusChecked
    repeat: true
    onTriggered: statusFile.reload()
  }

  // Safety net: drop the override if the status never confirms it.
  Timer {
    id: volumeSettle
    interval: 3000
    onTriggered: if (!volumeSlider.dragging && !root.volumeInFlight) { root.pendingVolume = -1; root.sentVolume = -1 }
  }

  Timer {
    id: volumeTimer
    interval: 120
    onTriggered: {
      if (root.pendingVolume < 0 || root.volumeInFlight || root.pendingVolume === root.sentVolume) return
      var value = root.pendingVolume
      root.volumeInFlight = true
      root.sentVolume = value
      root.run(["volume", String(value)], function() {
        root.volumeInFlight = false
        // The drag moved on while this was in flight: send the latest value.
        if (root.pendingVolume >= 0 && root.pendingVolume !== value) volumeTimer.start()
      })
    }
  }

  Component.onCompleted: {
    run(["status", "--json"], function() { root.statusChecked = true })
    run(["widget", "alive"])
  }
  // Disabling the plugin destroys this widget; tell the player so it stops
  // instead of playing on unseen. A hot reload re-creates the widget (and
  // says "alive") well inside the player's grace period.
  Component.onDestruction: {
    Quickshell.execDetached([root.sxmPath, "widget", "gone"])
  }

  IpcHandler {
    target: "sastr.siriusxm"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.opened ? root.close() : root.open() }
    function playPause(): void { root.run(["toggle"]) }
    function next(): void { root.run(["next"]) }
    function prev(): void { root.run(["prev"]) }
    function stop(): void { root.run(["stop"]) }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---- bar button ------------------------------------------------------

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    active: root.playing
    tooltipText: root.opened ? "" : Model.tooltip(root.status)
    onPressed: function(b) {
      if (b === Qt.RightButton) root.run(["stop"])
      else if (b === Qt.MiddleButton) root.run(["toggle"])
      else root.opened ? root.close() : root.open()
    }
    onWheelMoved: function(delta) {
      if (root.hasStreamVolume) root.setVolume(root.shownVolume + (delta > 0 ? 5 : -5))
      else root.run(["volume", delta > 0 ? "+5" : "-5"])
    }
  }

  // ---- popup -----------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus || emailField.activeFocus || passwordField.activeFocus
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()
      onReturnRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (!root.loggedIn) return
        if (t === " ") root.run(["toggle"])
        else if (t === "/") searchField.forceActiveFocus()
        else if (t === "f" && root.cursorActive && root.selectedIndex >= 0) root.toggleFavorite(root.filtered[root.selectedIndex].id)
        else if (t === "n") root.run(["next"])
        else if (t === "p") root.run(["prev"])
        else if (t === "s") root.run(["stop"])
      }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.space(12)

        // ---------- Hero: art · now playing · favorite ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(art.height, heroLabels.implicitHeight)

          Rectangle {
            id: art
            width: Style.space(64)
            height: width
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            radius: Style.cornerRadius
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)
            clip: true

            Text {
              anchors.centerIn: parent
              visible: artImage.status !== Image.Ready
              text: root.icon
              color: root.fg
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }

            Image {
              id: artImage
              anchors.fill: parent
              source: root.loggedIn ? (root.track.art || (root.channel ? root.channel.logo : "")) : ""
              sourceSize.width: 192
              sourceSize.height: 192
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              cache: true
            }
          }

          Column {
            id: heroLabels
            anchors.left: art.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroFav.visible ? heroFav.left : parent.right
            anchors.rightMargin: heroFav.visible ? Style.space(8) : 0
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: Model.heroTitle(root.status)
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              visible: text !== ""
              text: Model.heroSubtitle(root.status)
              color: root.fg
              opacity: 0.85
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: Model.heroCaption(root.status).toUpperCase()
              color: Qt.darker(root.fg, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
            }
          }

          PanelActionButton {
            id: heroFav
            visible: root.loggedIn && !!root.channel
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.channel && root.favorites.indexOf(root.channel.id) >= 0 ? "󰓎" : "󰓒"
            tooltipText: "Favorite"
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: root.toggleFavorite(root.channel.id)
          }
        }

        // ---------- Transport + volume ----------
        Item {
          visible: root.loggedIn
          width: parent.width
          implicitHeight: Math.max(transport.implicitHeight, volumeSlider.implicitHeight)

          Row {
            id: transport
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            PanelActionButton {
              iconText: "󰒮"; tooltipText: "Previous channel"
              foreground: root.fg; fontFamily: root.fontFamily
              onClicked: root.run(["prev"])
            }
            PanelActionButton {
              iconText: root.playing ? "󰏤" : "󰐊"
              tooltipText: root.playing ? "Pause" : "Play"
              foreground: root.fg; fontFamily: root.fontFamily
              onClicked: root.run(["toggle"])
            }
            PanelActionButton {
              iconText: "󰓛"; tooltipText: "Stop"
              foreground: root.fg; fontFamily: root.fontFamily
              onClicked: root.run(["stop"])
            }
            PanelActionButton {
              iconText: "󰒭"; tooltipText: "Next channel"
              foreground: root.fg; fontFamily: root.fontFamily
              onClicked: root.run(["next"])
            }
          }

          Text {
            id: volumeIcon
            anchors.left: transport.right
            anchors.leftMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            text: volumeSlider.liveValue <= 0 ? "󰝟" : (volumeSlider.liveValue < 50 ? "󰖀" : "󰕾")
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.icon
          }

          PanelSlider {
            id: volumeSlider
            bar: root.bar
            anchors.left: volumeIcon.right
            anchors.leftMargin: Style.space(8)
            anchors.right: volumeText.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            minimum: 0
            maximum: 100
            step: 5
            integer: true
            value: root.shownVolume
            onMoved: function(v) { root.setVolume(v) }
            onReleased: function(v) { root.setVolume(v) }
          }

          Text {
            id: volumeText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(30)
            horizontalAlignment: Text.AlignRight
            text: Math.round(volumeSlider.liveValue) + "%"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        PanelSeparator { foreground: root.fg }

        // ---------- Sign in ----------
        Column {
          visible: root.statusChecked && !root.loggedIn
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "SIGN IN TO SIRIUSXM"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          TextField {
            id: emailField
            width: parent.width
            placeholderText: "Email or username"
            foreground: root.fg
            inputMethodHints: Qt.ImhEmailCharactersOnly | Qt.ImhNoAutoUppercase
            onAccepted: passwordField.forceActiveFocus()
            Keys.onEscapePressed: keyCatcher.forceActiveFocus()
          }

          TextField {
            id: passwordField
            width: parent.width
            placeholderText: "Password"
            password: true
            foreground: root.fg
            onAccepted: root.signIn(emailField.text.trim(), passwordField.text)
            Keys.onEscapePressed: keyCatcher.forceActiveFocus()
          }

          Item {
            width: parent.width
            implicitHeight: signInButton.implicitHeight

            Text {
              anchors.left: parent.left
              anchors.right: signInButton.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: root.loginError || "Stored in your keyring. Requires a SiriusXM streaming subscription."
              color: root.loginError ? Color.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Button {
              id: signInButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.signingIn ? "Signing in…" : "Sign in"
              bordered: true
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: root.signIn(emailField.text.trim(), passwordField.text)
            }
          }
        }

        // ---------- Search + filters ----------
        Item {
          visible: root.loggedIn
          width: parent.width
          implicitHeight: Math.max(searchField.implicitHeight, filterRow.implicitHeight)

          TextField {
            id: searchField
            anchors.left: parent.left
            anchors.right: filterRow.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            placeholderText: "Search " + root.channels.length + " channels…"
            foreground: root.fg
            onTextChanged: { root.searchText = text; root.selectedIndex = text ? 0 : -1; root.cursorActive = text !== "" }
            onAccepted: root.activateCursor()
            Keys.onEscapePressed: {
              if (text !== "") text = ""
              else keyCatcher.forceActiveFocus()
            }
            Keys.onDownPressed: { keyCatcher.forceActiveFocus(); root.moveCursor(1) }
          }

          Row {
            id: filterRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Button {
              text: "All"
              selected: root.filterMode === "all" && root.genre === ""
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: { root.filterMode = "all"; root.genre = "" }
            }
            Button {
              iconText: "󰓎"
              tooltipText: "Favorites"
              selected: root.filterMode === "favorites"
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: root.filterMode = root.filterMode === "favorites" ? "all" : "favorites"
            }
            Dropdown {
              width: Style.space(130)
              showLabel: false
              value: root.genre
              options: [{ value: "", label: "All genres" }].concat(root.genres)
              foreground: root.fg
              fontFamily: root.fontFamily
              onChanged: function(v) { root.genre = v }
            }
          }
        }

        // ---------- Channel list ----------
        ListView {
          id: channelList
          visible: root.loggedIn
          width: parent.width
          height: Math.min(contentHeight, Style.space(360))
          spacing: Style.space(2)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          model: root.filtered
          currentIndex: root.selectedIndex
          onCurrentIndexChanged: if (currentIndex >= 0) Qt.callLater(function() { channelList.positionViewAtIndex(channelList.currentIndex, ListView.Contain) })
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          delegate: ChannelRow {
            required property var modelData
            required property int index
            width: channelList.width - (channelList.contentHeight > channelList.height ? Style.space(8) : 0)
            entry: modelData
            rowIndex: index
          }
        }

        Text {
          visible: root.loggedIn && root.filtered.length === 0
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: root.busy || root.channels.length === 0 ? "Loading channels…"
            : (root.filterMode === "favorites" && root.favorites.length === 0
              ? "No favorites yet. Right-click a channel or press f."
              : "No channels match")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        // ---------- Footer ----------
        Item {
          visible: root.loggedIn
          width: parent.width
          implicitHeight: Math.max(footerText.implicitHeight, footerButtons.implicitHeight)

          Text {
            id: footerText
            anchors.left: parent.left
            anchors.right: footerButtons.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: root.errorText || "Click to play · right-click to favorite · / to search"
            color: root.errorText ? Color.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            maximumLineCount: 2
            wrapMode: Text.WordWrap
          }

          Row {
            id: footerButtons
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            PanelActionButton {
              iconText: "󰑐"; tooltipText: "Refresh channel lineup"
              foreground: root.fg; fontFamily: root.fontFamily
              onClicked: root.refreshChannels(true)
            }
            PanelActionButton {
              iconText: "󰍃"; tooltipText: "Sign out"
              foreground: root.fg; fontFamily: root.fontFamily
              onClicked: root.signOut()
            }
          }
        }
      }
    }
  }

  component ChannelRow: CursorSurface {
    id: row
    required property var entry
    required property int rowIndex

    readonly property bool isCurrent: !!root.channel && root.channel.id === entry.id && root.status.running
    readonly property bool isFavorite: root.favorites.indexOf(entry.id) >= 0

    hasCursor: root.cursorActive && root.selectedIndex === rowIndex
    current: isCurrent
    foreground: root.fg
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: Style.space(36)
    opacity: entry.locked ? 0.55 : 1.0

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) { root.cursorActive = true; root.selectedIndex = row.rowIndex }
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) root.toggleFavorite(row.entry.id)
        else root.play(row.entry.id)
      }
    }

    PanelToolTip {
      visible: rowMouse.containsMouse && (row.entry.description !== "" || row.entry.locked)
      text: row.entry.locked ? "Not included in your subscription" : row.entry.description
      fontFamily: root.fontFamily
    }

    Image {
      id: logo
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(26)
      height: width
      source: row.entry.logo
      sourceSize.width: 78
      sourceSize.height: 78
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      cache: true
    }

    Text {
      id: number
      anchors.left: logo.right
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(28)
      text: row.entry.number !== null ? row.entry.number : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignRight
    }

    Column {
      anchors.left: number.right
      anchors.leftMargin: Style.space(10)
      anchors.right: star.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter

      Text {
        width: parent.width
        text: (row.isCurrent ? "󰐊 " : "") + row.entry.name
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: row.isCurrent
        elide: Text.ElideRight
      }
      Text {
        width: parent.width
        visible: text !== ""
        text: row.entry.category
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Text {
      id: star
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: row.isFavorite ? "󰓎" : (rowMouse.containsMouse ? "󰓒" : "")
      color: root.fg
      opacity: row.isFavorite ? 1.0 : 0.5
      font.family: root.fontFamily
      font.pixelSize: Style.font.body

      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.space(4)
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggleFavorite(row.entry.id)
      }
    }
  }
}
