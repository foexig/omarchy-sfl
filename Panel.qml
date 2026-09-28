import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "fabio.crypto"
  ipcTarget: "fabio.crypto"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string script: Qt.resolvedUrl("crypto.sh").toString().replace(/^file:\/\//, "")
  readonly property var modes: [
    { value: "vault", label: "Vault" },
    { value: "hash", label: "Hash" },
    { value: "password", label: "Password" },
    { value: "keys", label: "Keys" },
    { value: "uuid", label: "UUID" },
    { value: "ssh", label: "SSH" }
  ]
  property string mode: "vault"
  property string input: ""
  // [{ label, value, secret }]
  property var results: []
  property string error: ""
  property string copiedLabel: ""
  property bool pending: false
  readonly property color dim: root.bar ? Qt.darker(root.bar.foreground, 1.5) : "gray"

  // ---- Vault state. The master password never stays in memory: vault.py
  // turns it into a key (Argon2id), and only that key is held while unlocked.
  readonly property string vaultScript: Qt.resolvedUrl("vault.py").toString().replace(/^file:\/\//, "")
  property string vaultState: "unknown" // unknown | missing (create form) | locked | unlocked
  // One file per vault, each with its own master password
  property var vaultNames: []
  property string vaultName: ""
  property string vaultKey: ""
  // [{ id, title, username, password, url, notes, updated }]
  property var entries: []
  property string vaultFilter: ""
  property var editing: null // entry being edited; {} for a new one
  property bool deleteArmed: false
  property bool lockedDelete: false // locked screen: delete-vault confirm shown
  property bool rekeying: false // settings view: username presets + master password
  property bool showPass: false
  property string pwMode: "random" // entry form: random | own
  // Username presets, most recently used first; the first is the default
  property var usernames: []
  property var emails: []
  // Entry form fill orders: 6 slots of "username" | "email" | "password" | ""
  readonly property int slotCount: 6
  property var fillSignup: []
  property var fillSignin: []
  property string fillTarget: "signup" // which order the digit keys fill
  property string hoveredElement: ""   // chip under the mouse
  property string hoveredSlotKind: ""  // slot under the mouse
  property int hoveredSlot: -1

  // Window that was focused when the panel opened: auto-type target
  property string targetWindow: ""
  property string targetTitle: ""
  readonly property string autotypeScript: Qt.resolvedUrl("autotype.sh").toString().replace(/^file:\/\//, "")
  readonly property var filteredEntries: {
    var q = root.vaultFilter.toLowerCase()
    var list = root.entries.filter(function(e) {
      return q === "" || (e.title + " " + (e.username || "") + " " + (e.email || "") + " " + (e.url || "")).toLowerCase().indexOf(q) !== -1
    })
    // Entries matching the page you came from go first
    var hits = list.filter(matchesTarget)
    return hits.concat(list.filter(function(e) { return !matchesTarget(e) }))
  }
  readonly property Item focusItem: {
    if (mode === "hash") return inputField
    if (mode !== "vault" || vaultState === "unknown") return keyCatcher
    if (vaultState === "missing") return vaultNameField
    if (vaultState !== "unlocked") return masterField
    if (rekeying) return userPresets.addField
    return editing ? titleField : searchField
  }

  function open() { openFromHotkey() }

  function openFromHotkey() {
    if (!root.opened) {
      targetWindow = ""
      targetTitle = ""
      winProc.running = true
    }
    root.controller.show()
    if (mode !== "hash" && (mode === "vault" || results.length === 0)) generate()
    Qt.callLater(focusMode)
  }

  function close() { root.controller.hide() }

  // Don't leave a half-typed master password behind in a closed panel
  onOpenedChanged: if (!opened) {
    masterField.text = ""
    confirmField.text = ""
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function focusMode() {
    focusItem.forceActiveFocus()
  }

  function setMode(m) {
    if (m === mode) return
    mode = m
    results = []
    error = ""
    copiedLabel = ""
    generate()
    Qt.callLater(focusMode)
  }

  function cycleMode(step) {
    var i = modes.findIndex(function(o) { return o.value === mode })
    setMode(modes[(i + step + modes.length) % modes.length].value)
  }

  function generate() {
    if (mode === "vault") {
      if (vaultState !== "unlocked") vaultStatus()
      return
    }
    if (genProc.running) { pending = true; return }
    error = ""
    copiedLabel = ""
    genProc.command = ["bash", root.script, root.mode]
    genProc.environment = { CRYPTO_INPUT: root.input }
    genProc.running = true
  }

  function copy(row) {
    if (copyProc.running) return
    copyProc.label = row.label
    copyProc.value = row.secret ? row.value : ""
    // --sensitive keeps secrets out of the clipboard history
    copyProc.command = ["sh", "-c", "printf %s \"$CRYPTO_COPY\" | wl-copy" + (row.secret ? " --sensitive" : "") + " >/dev/null 2>&1"]
    copyProc.environment = { CRYPTO_COPY: row.value }
    copyProc.running = true
  }

  // ---- Vault

  // Runs vault.py with the request on stdin (never argv/env: those are
  // visible in /proc). cb gets the parsed reply unless it has an error.
  function vaultCall(req, cb) {
    if (vaultProc.running) return
    error = ""
    vaultProc.callback = cb || null
    if (req.op !== "status" && req.vault === undefined) req.vault = vaultName
    vaultProc.payload = JSON.stringify(req)
    vaultProc.running = true
    if (vaultKey !== "") autoLock.restart()
  }

  function vaultStatus() {
    vaultCall({ op: "status" }, function(r) {
      vaultNames = r.vaults
      if (vaultNames.indexOf(vaultName) === -1) vaultName = vaultNames.length > 0 ? vaultNames[0] : ""
      vaultState = vaultName === "" ? "missing" : "locked"
      Qt.callLater(focusMode)
    })
  }

  // "__new__" opens the create form; any other value locks and switches
  function switchVault(name) {
    lockVault()
    lockedDelete = false
    lockedDeleteField.text = ""
    if (name === "__new__") {
      vaultState = "missing"
    } else {
      vaultName = name
      vaultState = "locked"
    }
    Qt.callLater(focusMode)
  }

  function cancelCreate() {
    vaultNameField.text = ""
    masterField.text = ""
    confirmField.text = ""
    vaultState = vaultName === "" ? "missing" : "locked"
    Qt.callLater(focusMode)
  }

  // From settings (unlocked) or from the locked screen (no password needed)
  function deleteVault() {
    var req = { op: "delete", confirm: vaultState === "unlocked" ? deleteField.text : lockedDeleteField.text }
    if (vaultState === "unlocked") req.key = vaultKey
    vaultCall(req, function() {
      var gone = vaultName
      lockVault()
      lockedDelete = false
      lockedDeleteField.text = ""
      vaultName = ""
      copiedLabel = "vault " + gone + " deleted"
      vaultStatus()
    })
  }

  function unlocked(r) {
    vaultKey = r.key
    entries = r.entries
    usernames = r.usernames || []
    emails = r.emails || []
    masterField.text = ""
    confirmField.text = ""
    vaultNameField.text = ""
    vaultState = "unlocked"
    autoLock.restart()
    Qt.callLater(focusMode)
  }

  function vaultSubmit() {
    if (vaultState === "missing") {
      if (masterField.text !== confirmField.text) { error = "Passwords don't match"; return }
      var name = vaultNameField.text.trim()
      if (vaultNames.indexOf(name) !== -1) { error = "A vault named " + name + " already exists"; return }
      vaultCall({ op: "create", vault: name, password: masterField.text }, function(r) {
        vaultName = name
        vaultNames = vaultNames.concat([name]).sort(function(a, b) { return a.localeCompare(b) })
        unlocked(r)
      })
    } else if (vaultState === "locked") {
      vaultCall({ op: "unlock", password: masterField.text }, unlocked)
    }
  }

  function lockVault() {
    autoLock.stop()
    vaultKey = ""
    entries = []
    usernames = []
    emails = []
    vaultFilter = ""
    searchField.text = ""
    closeEdit()
    closeRekey()
    if (vaultState === "unlocked") vaultState = "locked"
    Qt.callLater(focusMode)
  }

  function startEdit(e) {
    editing = e
    deleteArmed = false
    showPass = false
    titleField.text = e.title || ""
    userPick.text = e.id ? (e.username || "") : (usernames[0] || "")
    emailPick.text = e.id ? (e.email || "") : (emails[0] || "")
    var fill = e.id ? fillOf(e) : { signup: padSlots([]), signin: padSlots([]) }
    fillSignup = fill.signup
    fillSignin = fill.signin
    fillTarget = e.id ? "signin" : "signup"
    passField.text = e.password || ""
    pwMode = e.id ? "own" : "random"
    if (!e.id) pwGenProc.running = true
    urlField.text = e.url || ""
    notesField.text = e.notes || ""
    Qt.callLater(focusMode)
  }

  function closeEdit() {
    editing = null
    deleteArmed = false
    var fields = [titleField, userPick.field, emailPick.field, passField, urlField, notesField]
    fields.forEach(function(f) { f.text = "" })
    Qt.callLater(focusMode)
  }

  function saveVault(list, names, mails, after) {
    vaultCall({ op: "save", key: vaultKey, entries: list, usernames: names, emails: mails }, function() {
      entries = list
      usernames = names
      emails = mails
      if (after) after()
    })
  }

  // presets with name moved to the front (it becomes the default), or appended
  function withPreset(presets, name, toFront) {
    var rest = presets.filter(function(u) { return u !== name })
    if (name === "") return rest
    return toFront ? [name].concat(rest) : rest.concat([name])
  }

  // kind: "usernames" | "emails"
  function setPresets(kind, list, after) {
    saveVault(entries, kind === "usernames" ? list : usernames, kind === "emails" ? list : emails, after)
  }

  function validEmail(s) {
    return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(s)
  }

  function setPwMode(m) {
    pwMode = m
    if (m === "random") {
      pwGenProc.running = true
    } else {
      passField.text = ""
      showPass = true
      passField.forceActiveFocus()
    }
  }

  function matchesTarget(e) {
    var t = targetTitle.toLowerCase()
    if (t === "") return false
    var host = (e.url || "").toLowerCase().replace(/^[a-z]+:\/\//, "").replace(/^www\./, "").split(/[\/:]/)[0]
    var name = (e.title || "").toLowerCase()
    return (name.length > 2 && t.indexOf(name) !== -1) || (host !== "" && t.indexOf(host.split(".")[0]) !== -1)
  }

  function padSlots(list) {
    var out = list.slice(0, slotCount)
    while (out.length < slotCount) out.push("")
    return out
  }

  // A login's fill orders; v1.1 logins had checkboxes (use), v1.0 loginWith
  function fillOf(e) {
    if (e.fill) return { signup: padSlots(e.fill.signup || []), signin: padSlots(e.fill.signin || []) }
    var use = e.use || { username: e.loginWith !== "email" && !!e.username, email: e.loginWith === "email" || !e.username }
    var seq = []
    if (use.username && e.username) seq.push("username")
    if (use.email && e.email) seq.push("email")
    seq.push("password")
    return { signup: padSlots(seq), signin: padSlots(seq) }
  }

  function setSlot(kind, i, element) {
    var list = (kind === "signup" ? fillSignup : fillSignin).slice()
    list[i] = element
    if (kind === "signup") fillSignup = list
    else fillSignin = list
  }

  // Clicking a Username/Email/Password chip appends it to the active order
  function appendSlot(element) {
    var list = fillTarget === "signup" ? fillSignup : fillSignin
    var i = list.indexOf("")
    if (i === -1) { error = "That order is full: click a slot to remove it first"; return }
    setSlot(fillTarget, i, element)
  }

  function clearSlots(kind) {
    if (kind === "signup") fillSignup = padSlots([])
    else fillSignin = padSlots([])
  }

  // Hover a Username/Email/Password chip and press 1-6 to put it in that
  // slot; hover a slot and press 0/Backspace/Delete to clear it.
  function handleFillKey(event) {
    if (!editing) return false
    var n = event.key - Qt.Key_0
    if (hoveredElement !== "" && n >= 1 && n <= slotCount) {
      setSlot(fillTarget, n - 1, hoveredElement)
      return true
    }
    if (hoveredSlot >= 0 && (event.key === Qt.Key_0 || event.key === Qt.Key_Backspace || event.key === Qt.Key_Delete)) {
      setSlot(hoveredSlotKind, hoveredSlot, "")
      return true
    }
    return false
  }

  function signIn(e) { autoType(e, "signin") }

  // Types the login's sign-up or sign-in order, Tab between values, then
  // Enter, into the window you came from. autotype.sh refuses if another
  // window has focus by then.
  function autoType(e, kind) {
    if (autotypeProc.running) return
    if (targetWindow === "") { error = "No window to type into: focus the first field on the page, then open the vault"; return }
    var seq = fillOf(e)[kind].filter(Boolean).map(function(el) { return e[el] || "" })
    if (seq.length === 0) { error = "The " + (kind === "signup" ? "sign-up" : "sign-in") + " order is empty: edit the login (pencil) to set it"; return }
    autotypeProc.payload = JSON.stringify({ seq: seq, win: targetWindow })
    close()
    autotypeProc.running = true
    autoLock.restart()
  }

  // andSignIn: auto-type afterwards (sign-up for a new login)
  function commitEdit(andSignIn) {
    var isNew = !editing.id
    var title = titleField.text.trim()
    if (title === "") { error = "Title is required"; return }
    var e = {
      id: editing.id || (Date.now().toString(36) + Math.random().toString(36).slice(2, 8)),
      title: title,
      username: userPick.text.trim(),
      email: emailPick.text.trim(),
      fill: { signup: fillSignup.slice(), signin: fillSignin.slice() },
      password: passField.text,
      url: urlField.text.trim(),
      notes: notesField.text,
      updated: new Date().toISOString()
    }
    if (e.password === "") { error = "Password is empty"; return }
    if (e.email !== "" && !validEmail(e.email)) { error = "That email address doesn't look right"; return }
    var names = { username: "Username", email: "Email", password: "Password" }
    var kinds = [["signup", "Sign-up"], ["signin", "Sign-in"]]
    for (var k = 0; k < kinds.length; k++) {
      var slots = e.fill[kinds[k][0]]
      for (var i = 0; i < slots.length; i++) {
        if (slots[i] !== "" && e[slots[i]] === "") { error = kinds[k][1] + " slot " + (i + 1) + " uses " + names[slots[i]] + ", which is empty"; return }
      }
    }
    var typeKind = isNew ? "signup" : "signin"
    if (andSignIn && e.fill[typeKind].filter(Boolean).length === 0) {
      error = "Set the " + (isNew ? "sign-up" : "sign-in") + " order first: click the fields in the order the page asks for them"
      return
    }
    var list = entries.filter(function(x) { return x.id !== e.id })
    list.push(e)
    list.sort(function(a, b) { return a.title.localeCompare(b.title) })
    // A username/email typed on the fly becomes a preset; using one makes it the default
    saveVault(list, withPreset(usernames, e.username, true), withPreset(emails, e.email, true), function() {
      closeEdit()
      if (andSignIn) autoType(e, typeKind)
    })
  }

  function deleteEditing() {
    if (!deleteArmed) { deleteArmed = true; return }
    var id = editing.id
    saveVault(entries.filter(function(x) { return x.id !== id }), usernames, emails, closeEdit)
  }

  function closeRekey() {
    rekeying = false
    userPresets.addField.text = ""
    emailPresets.addField.text = ""
    deleteField.text = ""
    newMasterField.text = ""
    newMasterField2.text = ""
    Qt.callLater(focusMode)
  }

  function commitRekey() {
    if (newMasterField.text !== newMasterField2.text) { error = "Passwords don't match"; return }
    vaultCall({ op: "rekey", key: vaultKey, password: newMasterField.text }, function(r) {
      vaultKey = r.key
      closeRekey()
      copiedLabel = "master password changed"
    })
  }

  function vaultEscape() {
    if (editing) closeEdit()
    else if (rekeying) closeRekey()
    else if (searchField.text !== "") searchField.text = ""
    else close()
  }

  function copyEntry(e, field) {
    if (!e[field]) return
    copy({ label: e.title + " " + field, value: e[field], secret: field === "password" })
    autoLock.restart()
  }

  // Lock after 5 idle minutes; the key is wiped from memory.
  Timer {
    id: autoLock
    interval: 5 * 60 * 1000
    onTriggered: root.lockVault()
  }

  // Wipe a copied secret from the clipboard after 30 s, unless something
  // else has been copied since.
  Timer {
    id: clipClear
    interval: 30 * 1000
    property string value: ""
    onTriggered: {
      clearProc.environment = { CRYPTO_COPY: value }
      value = ""
      clearProc.running = true
    }
  }

  Process {
    id: clearProc
    command: ["sh", "-c", "[ \"$(wl-paste -n 2>/dev/null)\" != \"$CRYPTO_COPY\" ] || wl-copy --clear"]
    onExited: environment = {}
  }

  Process {
    id: vaultProc
    property string payload: ""
    property var callback: null
    command: ["python3", root.vaultScript]
    stdinEnabled: true
    onStarted: {
      write(payload + "\n")
      payload = ""
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var cb = vaultProc.callback
        vaultProc.callback = null
        if (text.trim() === "") return // stderr handler reports it
        try {
          var r = JSON.parse(text)
          if (r.error) root.error = r.error
          else if (cb) cb(r)
        } catch (e) {
          root.error = "Bad output from vault.py: " + e
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") root.error = text.trim()
    }
  }

  Process {
    id: winProc
    command: ["hyprctl", "activewindow", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var w = JSON.parse(text)
          root.targetWindow = w.address || ""
          root.targetTitle = w.title || ""
        } catch (e) {
          root.targetWindow = ""
        }
      }
    }
  }

  Process {
    id: autotypeProc
    property string payload: ""
    command: ["bash", root.autotypeScript]
    stdinEnabled: true
    onStarted: {
      write(payload + "\n")
      payload = ""
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") root.error = text.trim()
    }
  }

  // Fills the entry form's password with crypto.sh's strong password
  Process {
    id: pwGenProc
    command: ["bash", root.script, "password"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { passField.text = JSON.parse(text)[0].value }
        catch (e) { root.error = "Password generator failed: " + e }
      }
    }
  }

  // Debounce hashing while typing (bcrypt is deliberately slow)
  Timer {
    id: hashDebounce
    interval: 250
    onTriggered: root.generate()
  }

  Process {
    id: genProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text.trim() || "[]")
          root.results = Array.isArray(parsed) ? parsed : []
        } catch (e) {
          root.results = []
          root.error = "Bad output from crypto.sh: " + e
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") root.error = text.trim()
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.error === "") root.error = "crypto.sh failed (exit " + exitCode + ")"
      if (root.pending) {
        root.pending = false
        Qt.callLater(root.generate)
      }
    }
  }

  Process {
    id: copyProc
    property string label: ""
    property string value: ""
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.copiedLabel = label
        if (value !== "") { clipClear.value = value; clipClear.restart() }
      } else {
        root.error = "wl-copy failed (exit " + exitCode + ")"
      }
      value = ""
      environment = {}
    }
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function mode(name: string): void { root.openFromHotkey(); root.setMode(name) }
  }

  // Text field for the vault forms: Esc backs out, Enter submits
  component VaultField: TextField {
    signal submit()
    width: parent ? parent.width : 0
    foreground: root.bar.foreground
    font.family: root.bar.fontFamily
    Keys.onPressed: function(event) {
      if (root.handleFillKey(event)) event.accepted = true
      else if (event.key === Qt.Key_Escape) root.vaultEscape()
      else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) submit()
      else return
      event.accepted = true
    }
  }

  // Hover target for the fill-order keys, in front of each form field
  component ElementChip: Rectangle {
    id: chip
    property string element: ""
    property string label: ""
    readonly property bool hot: chipHover.hovered
    width: Style.space(78)
    height: chipText.implicitHeight + Style.space(8)
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    radius: Style.cornerRadius
    color: hot ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"
    border.width: 1
    border.color: hot ? Color.accent : root.dim
    HoverHandler {
      id: chipHover
      cursorShape: Qt.PointingHandCursor
      onHoveredChanged: {
        if (hovered) root.hoveredElement = chip.element
        else if (root.hoveredElement === chip.element) root.hoveredElement = ""
      }
    }
    TapHandler { onTapped: root.appendSlot(chip.element) }
    PanelToolTip {
      visible: chip.hot
      text: "Click to add " + chip.label + " to the " + (root.fillTarget === "signup" ? "sign-up" : "sign-in") + " order (or press 1-" + root.slotCount + " for a specific slot)"
    }
    Text {
      id: chipText
      anchors.centerIn: parent
      text: chip.hot ? "+ " + chip.label : chip.label
      color: chip.hot ? Color.accent : root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  // One fill order: a label plus numbered slots
  component FillRow: Row {
    id: fillRow
    property string kind: ""
    property string label: ""
    readonly property var slots: kind === "signup" ? root.fillSignup : root.fillSignin
    readonly property bool active: root.fillTarget === kind
    width: parent ? parent.width : 0
    spacing: Style.space(4)
    Text {
      id: fillLabel
      width: Style.space(78)
      anchors.verticalCenter: parent.verticalCenter
      text: fillRow.label
      color: fillRow.active ? Color.accent : root.dim
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: fillRow.active
      MouseArea {
        id: labelMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.fillTarget = fillRow.kind
      }
      PanelToolTip {
        visible: labelMouse.containsMouse
        text: fillRow.kind === "signup" ? "Typed by the sign-up button, for registration forms. Click to edit this order." : "Typed by the sign-in button and by Enter in search. Click to edit this order."
      }
    }
    Repeater {
      model: root.slotCount
      delegate: Rectangle {
        id: slot
        required property int index
        readonly property string element: fillRow.slots[index] || ""
        // the slot the next click on a field fills
        readonly property bool next: fillRow.active && index === fillRow.slots.indexOf("")
        width: (fillRow.width - fillLabel.width - clearButton.width - (root.slotCount + 1) * fillRow.spacing) / root.slotCount
        height: slotText.implicitHeight + Style.space(10)
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        radius: Style.cornerRadius
        color: slotHover.hovered ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"
        border.width: next ? 2 : 1
        border.color: fillRow.active ? Color.accent : root.dim
        opacity: element === "" && !next ? 0.55 : 1
        Behavior on opacity { NumberAnimation { duration: 120 } }
        PanelToolTip {
          visible: slotHover.hovered
          text: slot.element !== "" ? "Click to remove" : (slot.next ? "Next: click Username, Email or Password to fill it" : "Empty")
        }
        HoverHandler {
          id: slotHover
          onHoveredChanged: {
            if (hovered) { root.hoveredSlotKind = fillRow.kind; root.hoveredSlot = slot.index }
            else if (root.hoveredSlotKind === fillRow.kind && root.hoveredSlot === slot.index) root.hoveredSlot = -1
          }
        }
        Text {
          id: slotText
          anchors.centerIn: parent
          text: slot.element === "" ? String(slot.index + 1) : { username: "User", email: "Mail", password: "Pass" }[slot.element]
          color: slot.element === "" ? root.dim : root.bar.foreground
          font.bold: slot.element !== ""
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        // Click: make this order the active one; click a filled slot again to clear it
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            if (slot.element !== "") root.setSlot(fillRow.kind, slot.index, "")
            root.fillTarget = fillRow.kind
          }
        }
      }
    }
    VaultButton {
      id: clearButton
      anchors.verticalCenter: parent.verticalCenter
      iconText: String.fromCodePoint(0xF0156) // nf-md-close
      tooltipText: "Clear this order"
      enabled: fillRow.slots.some(Boolean)
      onClicked: { root.clearSlots(fillRow.kind); root.fillTarget = fillRow.kind }
    }
  }

  // Entry form field with a "Saved" dropdown of presets
  component PresetPicker: Row {
    id: picker
    property var presets: []
    property string element: ""
    property string label: ""
    property alias text: pickerField.text
    property alias field: pickerField
    property alias placeholderText: pickerField.placeholderText
    width: parent ? parent.width : 0
    spacing: Style.space(6)
    ElementChip { id: box; element: picker.element; label: picker.label }
    VaultField {
      id: pickerField
      width: picker.width - box.width - picker.spacing - (picker.presets.length > 0 ? pick.width + picker.spacing : 0)
      onSubmit: root.commitEdit(true)
    }
    Dropdown {
      id: pick
      visible: picker.presets.length > 0
      width: Style.space(130)
      showLabel: false
      options: picker.presets
      // Not an option, so the trigger always reads "Saved"
      value: "Saved"
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
      onChanged: function(v) { pickerField.text = v; pick.value = "Saved" }
    }
  }

  // Settings list of presets: star makes one the default, x removes it
  component PresetList: Column {
    id: plist
    property string kind: "" // "usernames" | "emails"
    property string title: ""
    property alias addText: addField.placeholderText
    property alias addField: addField
    readonly property var items: root.rekeying ? root[kind] : []
    width: parent ? parent.width : 0
    spacing: Style.space(6)

    Text {
      text: plist.title
      color: root.dim
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Repeater {
      model: plist.items
      delegate: Rectangle {
        id: presetRow
        required property string modelData
        required property int index
        width: plist.width
        height: presetName.implicitHeight + Style.space(8)
        radius: Style.cornerRadius
        color: presetHover.hovered ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"
        HoverHandler { id: presetHover }
        Text {
          id: presetName
          anchors.left: parent.left
          anchors.leftMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: presetRow.modelData + (presetRow.index === 0 ? "  (default)" : "")
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
        }
        Row {
          anchors.right: parent.right
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(10)
          opacity: presetHover.hovered ? 1 : 0.35
          Text {
            visible: presetRow.index > 0
            text: String.fromCodePoint(0xF04CE) // nf-md-star
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.setPresets(plist.kind, root.withPreset(plist.items, presetRow.modelData, true))
            }
          }
          Text {
            text: String.fromCodePoint(0xF0156) // nf-md-close
            color: Color.urgent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.setPresets(plist.kind, plist.items.filter(function(u) { return u !== presetRow.modelData }))
            }
          }
        }
      }
    }
    VaultField {
      id: addField
      onSubmit: {
        var name = text.trim()
        if (name === "") return
        if (plist.kind === "emails" && !root.validEmail(name)) { root.error = "That email address doesn't look right"; return }
        root.setPresets(plist.kind, root.withPreset(plist.items, name, false), function() { addField.text = "" })
      }
    }
  }

  component VaultButton: Button {
    enabled: !vaultProc.running
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: root.focusItem
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    Item {
      id: keyCatcher
      focus: true
      Keys.onPressed: function(event) {
        if (root.handleFillKey(event)) {
          // placed or cleared a fill slot
        } else if (event.key === Qt.Key_Escape) {
          root.close()
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_R) {
          root.generate()
        } else if (event.key === Qt.Key_Left || event.key === Qt.Key_H) {
          root.cycleMode(-1)
        } else if (event.key === Qt.Key_Right || event.key === Qt.Key_L) {
          root.cycleMode(1)
        } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
          root.switchPanel((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1)
        } else {
          return
        }
        event.accepted = true
      }
    }

    Flickable {
      id: scroll
      anchors.fill: parent
      contentWidth: width
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height

      Column {
        id: column
        width: scroll.width
        spacing: Style.space(10)

        // ---- Header
        Item {
          width: parent.width
          height: headerText.implicitHeight

          Text {
            id: headerText
            anchors.left: parent.left
            text: "CRYPTO"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            font.letterSpacing: 1
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: headerText.verticalCenter
            textFormat: Text.PlainText
            text: root.copiedLabel !== "" ? ("Copied " + root.copiedLabel) : (vaultProc.running ? (root.vaultState === "locked" ? "Unlocking…" : "Working…") : genProc.running ? "Working…" : root.mode === "vault" ? (root.vaultState === "unlocked" ? "Auto-locks after 5 min idle" : "") : "Click a value to copy")
            color: root.copiedLabel !== "" ? Color.accent : root.dim
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        ButtonGroup {
          options: root.modes
          value: root.mode
          focusable: false
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          onChanged: function(v) { root.setMode(v) }
        }

        // ---- Input (hash mode)
        TextField {
          id: inputField
          visible: root.mode === "hash"
          width: parent.width
          placeholderText: "Text to hash / encode…"
          foreground: root.bar.foreground
          font.family: root.bar.fontFamily

          onTextChanged: {
            root.input = text
            hashDebounce.restart()
          }

          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              if (inputField.text !== "") inputField.text = ""
              else root.close()
              event.accepted = true
            } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
              root.switchPanel((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1)
              event.accepted = true
            }
          }
        }

        Button {
          visible: root.mode !== "hash" && root.mode !== "vault"
          text: "Regenerate"
          iconText: String.fromCodePoint(0xF0450) // nf-md-refresh
          bordered: true
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          onClicked: root.generate()
        }

        Text {
          visible: root.error !== ""
          width: parent.width
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
          text: root.error
          color: Color.urgent
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        // ---- Vault
        Column {
          id: vaultColumn
          visible: root.mode === "vault"
          width: parent.width
          spacing: Style.space(8)

          readonly property bool isMissing: root.vaultState === "missing"
          readonly property bool isLocked: root.vaultState === "locked"
          readonly property bool listing: root.vaultState === "unlocked" && !root.editing && !root.rekeying

          // Vault picker; switching locks the open vault
          Dropdown {
            visible: root.vaultNames.length > 0 && !root.editing && !root.rekeying
            width: parent.width
            showLabel: false
            enabled: !vaultProc.running
            options: root.vaultNames.map(function(n) {
              return { value: n, label: String.fromCodePoint(root.vaultState === "unlocked" && n === root.vaultName ? 0xF033F : 0xF033E) + "  " + n }
            }).concat([{ value: "__new__", label: "+  New vault…" }])
            value: vaultColumn.isMissing ? "__new__" : root.vaultName
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            onChanged: function(v) { root.switchVault(v) }
          }

          VaultField {
            id: vaultNameField
            visible: vaultColumn.isMissing
            placeholderText: "Vault name (e.g. Personal, Work)"
            onSubmit: masterField.forceActiveFocus()
          }

          Text {
            visible: vaultColumn.isMissing
            width: parent.width
            wrapMode: Text.Wrap
            text: "Create a vault. Pick a long master password (12+ characters, a passphrase is best). Each vault has its own password, and it can't be recovered: forget it and that vault is gone."
            color: root.dim
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          VaultField {
            id: masterField
            visible: vaultColumn.isMissing || vaultColumn.isLocked
            password: true
            placeholderText: vaultColumn.isMissing ? "New master password" : "Master password"
            onSubmit: vaultColumn.isMissing ? confirmField.forceActiveFocus() : root.vaultSubmit()
          }

          VaultField {
            id: confirmField
            visible: vaultColumn.isMissing
            password: true
            placeholderText: "Repeat master password"
            onSubmit: root.vaultSubmit()
          }

          Row {
            visible: vaultColumn.isMissing || vaultColumn.isLocked
            spacing: Style.space(6)
            VaultButton {
              text: vaultColumn.isMissing ? "Create vault" : "Unlock"
              iconText: String.fromCodePoint(0xF033F) // nf-md-lock_open
              bordered: true
              onClicked: root.vaultSubmit()
            }
            VaultButton {
              visible: vaultColumn.isMissing && root.vaultName !== ""
              text: "Cancel"
              onClicked: root.cancelCreate()
            }
            VaultButton {
              visible: vaultColumn.isLocked
              text: root.lockedDelete ? "Keep vault" : "Delete vault…"
              iconText: String.fromCodePoint(0xF0A7A) // nf-md-trash_can_outline
              foreground: root.lockedDelete ? root.bar.foreground : Color.urgent
              onClicked: {
                root.lockedDelete = !root.lockedDelete
                lockedDeleteField.text = ""
                if (root.lockedDelete) lockedDeleteField.forceActiveFocus()
                else masterField.forceActiveFocus()
              }
            }
          }

          // Delete a locked vault, e.g. when its password is forgotten
          Column {
            visible: vaultColumn.isLocked && root.lockedDelete
            width: parent.width
            spacing: Style.space(6)
            Text {
              width: parent.width
              wrapMode: Text.Wrap
              text: "Delete vault \"" + root.vaultName + "\" without unlocking it. All its logins are gone for good."
              color: Color.urgent
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Row {
              id: lockedDeleteRow
              spacing: Style.space(6)
              VaultField {
                id: lockedDeleteField
                width: vaultColumn.width - lockedDeleteButton.width - lockedDeleteRow.spacing
                placeholderText: "Type " + root.vaultName + " to confirm"
                onSubmit: if (text === root.vaultName) root.deleteVault()
              }
              VaultButton {
                id: lockedDeleteButton
                text: "Delete"
                foreground: Color.urgent
                bordered: true
                enabled: !vaultProc.running && lockedDeleteField.text === root.vaultName
                onClicked: root.deleteVault()
              }
            }
          }

          // Toolbar
          Row {
            id: toolbar
            visible: vaultColumn.listing
            spacing: Style.space(6)

            VaultField {
              id: searchField
              width: vaultColumn.width - newButton.width - rekeyButton.width - lockButton.width - 3 * toolbar.spacing
              placeholderText: "Search… (Enter signs in with the top entry)"
              onTextChanged: root.vaultFilter = text
              onSubmit: if (root.filteredEntries.length > 0) root.signIn(root.filteredEntries[0])
            }
            VaultButton {
              id: newButton
              text: "Sign up"
              iconText: String.fromCodePoint(0xF0415) // nf-md-plus
              tooltipText: "New login: pick username, email and password, then set the typing order"
              bordered: true
              onClicked: root.startEdit({})
            }
            VaultButton {
              id: rekeyButton
              iconText: String.fromCodePoint(0xF0493) // nf-md-cog
              tooltipText: "Usernames & master password"
              bordered: true
              onClicked: { root.rekeying = true; Qt.callLater(root.focusMode) }
            }
            VaultButton {
              id: lockButton
              iconText: String.fromCodePoint(0xF033E) // nf-md-lock
              tooltipText: "Lock now"
              bordered: true
              onClicked: root.lockVault()
            }
          }

          Text {
            visible: vaultColumn.listing && root.filteredEntries.length === 0
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            topPadding: Style.space(6)
            text: root.entries.length === 0 ? "No entries yet. Click New to add one." : "No matches."
            color: root.dim
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
          }

          // Entries
          Column {
            visible: vaultColumn.listing
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: vaultColumn.listing ? root.filteredEntries : []

              delegate: Rectangle {
                id: entryRow
                required property var modelData

                width: parent ? parent.width : 0
                height: Math.max(entryText.implicitHeight, entryActions.implicitHeight) + Style.space(10)
                radius: Style.cornerRadius
                color: entryHover.hovered ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

                HoverHandler { id: entryHover }

                // Clicking the row copies the password
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.copyEntry(entryRow.modelData, "password")
                }

                Column {
                  id: entryText
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(6)
                  anchors.right: entryActions.left
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    text: entryRow.modelData.title
                    color: root.matchesTarget(entryRow.modelData) ? Color.accent : root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }

                  Text {
                    visible: text !== ""
                    width: parent.width
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    text: [entryRow.modelData.username, entryRow.modelData.email, entryRow.modelData.url].filter(Boolean).join("  ·  ")
                    color: root.dim
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                Row {
                  id: entryActions
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(3)

                  Repeater {
                    // nf-md-account_plus / nf-md-login / nf-md-account / nf-md-email / nf-md-key / nf-md-pencil
                    model: [
                      { icon: 0xF0014, action: "signup", tip: "Sign up: types the sign-up order into the page you came from" },
                      { icon: 0xF0342, action: "signin", tip: "Sign in: types the sign-in order, then Enter" },
                      { icon: 0xF0004, action: "username", tip: "Copy username" },
                      { icon: 0xF01EE, action: "email", tip: "Copy email" },
                      { icon: 0xF0306, action: "password", tip: "Copy password (wiped from the clipboard after 30 s)" },
                      { icon: 0xF03EB, action: "edit", tip: "Edit this login and its typing orders" }
                    ]

                    delegate: VaultButton {
                      required property var modelData
                      readonly property string copyLabel: entryRow.modelData.title + " " + modelData.action
                      readonly property bool copied: root.copiedLabel === copyLabel
                      readonly property bool typing: modelData.action === "signin" || modelData.action === "signup"
                      visible: modelData.action === "edit" || typing || !!entryRow.modelData[modelData.action]
                      iconText: String.fromCodePoint(copied ? 0xF012C : modelData.icon)
                      iconSize: Style.font.icon * 1.2
                      bordered: typing
                      selected: copied
                      tooltipText: modelData.tip
                      onClicked: {
                        var a = modelData.action
                        if (a === "edit") root.startEdit(entryRow.modelData)
                        else if (typing) root.autoType(entryRow.modelData, a)
                        else root.copyEntry(entryRow.modelData, a)
                      }
                    }
                  }
                }
              }
            }
          }

          // Entry form
          Column {
            visible: root.vaultState === "unlocked" && !!root.editing && !root.rekeying
            width: parent.width
            spacing: Style.space(6)

            Text {
              text: root.editing && root.editing.id ? "Edit entry" : "New login: fill in the fields, set the typing order, then Save & sign up"
              color: root.dim
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            VaultField { id: titleField; placeholderText: "Site (e.g. GitHub)"; onSubmit: root.commitEdit(true) }
            PresetPicker {
              id: userPick
              presets: root.usernames
              element: "username"
              label: "Username"
              placeholderText: "Username (typed ones are remembered)"
            }
            PresetPicker {
              id: emailPick
              presets: root.emails
              element: "email"
              label: "Email"
              placeholderText: "Email (typed ones are remembered)"
            }
            ButtonGroup {
              options: [{ value: "random", label: "Random password" }, { value: "own", label: "Own password" }]
              value: root.pwMode
              focusable: false
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onChanged: function(v) { root.setPwMode(v) }
            }
            Row {
              id: passRow
              spacing: Style.space(6)
              ElementChip { id: passChip; element: "password"; label: "Password" }
              VaultField {
                id: passField
                width: vaultColumn.width - passChip.width - showButton.width - genButton.width - 3 * passRow.spacing
                password: !root.showPass
                placeholderText: "Password"
                onSubmit: root.commitEdit(true)
              }
              VaultButton {
                id: showButton
                iconText: String.fromCodePoint(root.showPass ? 0xF0209 : 0xF0208) // nf-md-eye_off / eye
                tooltipText: root.showPass ? "Hide" : "Show"
                bordered: true
                onClicked: root.showPass = !root.showPass
              }
              VaultButton {
                id: genButton
                iconText: String.fromCodePoint(0xF0450) // nf-md-refresh
                tooltipText: "Generate a strong password"
                bordered: true
                enabled: !pwGenProc.running
                onClicked: root.setPwMode("random")
              }
            }

            // Fill orders: what auto-type types, Tab-separated, then Enter
            Text {
              topPadding: Style.space(4)
              width: parent.width
              wrapMode: Text.Wrap
              text: "Typing order: click Username, Email or Password in the order the page asks for them. They go into the highlighted row, Tab between each, Enter at the end."
              color: root.dim
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            FillRow { kind: "signup"; label: "Sign-up" }
            FillRow { kind: "signin"; label: "Sign-in" }
            VaultField { id: urlField; placeholderText: "URL (optional, helps match the page)"; onSubmit: root.commitEdit(true) }
            VaultField { id: notesField; placeholderText: "Notes"; onSubmit: root.commitEdit(true) }
            Row {
              spacing: Style.space(6)
              VaultButton {
                text: root.editing && root.editing.id ? "Save & sign in" : "Save & sign up"
                tooltipText: "Save, close the panel and type the " + (root.editing && root.editing.id ? "sign-in" : "sign-up") + " order into the page"
                iconText: String.fromCodePoint(root.editing && root.editing.id ? 0xF0342 : 0xF0014) // nf-md-login / account_plus
                bordered: true
                onClicked: root.commitEdit(true)
              }
              VaultButton { text: "Save"; bordered: true; tooltipText: "Save without typing anything"; onClicked: root.commitEdit(false) }
              VaultButton { text: "Cancel"; tooltipText: "Discard changes (Esc)"; onClicked: root.closeEdit() }
              VaultButton {
                visible: !!(root.editing && root.editing.id)
                tooltipText: "Delete this login (click twice)"
                text: root.deleteArmed ? "Click again to delete" : "Delete"
                foreground: Color.urgent
                onClicked: root.deleteEditing()
              }
            }
          }

          // Settings: presets, master password, delete vault
          Column {
            visible: root.vaultState === "unlocked" && root.rekeying
            width: parent.width
            spacing: Style.space(6)

            VaultButton {
              text: "Back to logins"
              iconText: String.fromCodePoint(0xF004D) // nf-md-arrow_left
              onClicked: root.closeRekey()
            }

            PresetList { id: userPresets; kind: "usernames"; title: "Usernames (first one is the default for new logins)"; addText: "Add a username (Enter)" }
            PresetList { id: emailPresets; kind: "emails"; title: "Emails (first one is the default for new logins)"; addText: "Add an email (Enter)" }

            Text {
              topPadding: Style.space(6)
              text: "Change master password"
              color: root.dim
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            VaultField { id: newMasterField; password: true; placeholderText: "New master password (12+ characters)"; onSubmit: newMasterField2.forceActiveFocus() }
            VaultField { id: newMasterField2; password: true; placeholderText: "Repeat new master password"; onSubmit: root.commitRekey() }
            Row {
              spacing: Style.space(6)
              VaultButton { text: "Change password"; bordered: true; onClicked: root.commitRekey() }
              VaultButton { text: "Done"; onClicked: root.closeRekey() }
            }

            Text {
              topPadding: Style.space(6)
              width: parent.width
              wrapMode: Text.Wrap
              text: "Delete vault \"" + root.vaultName + "\": all its logins are gone for good."
              color: Color.urgent
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Row {
              id: deleteRow
              spacing: Style.space(6)
              VaultField {
                id: deleteField
                width: vaultColumn.width - deleteVaultButton.width - deleteRow.spacing
                placeholderText: "Type " + root.vaultName + " to confirm"
                onSubmit: root.deleteVault()
              }
              VaultButton {
                id: deleteVaultButton
                text: "Delete vault"
                foreground: Color.urgent
                bordered: true
                enabled: !vaultProc.running && deleteField.text === root.vaultName
                onClicked: root.deleteVault()
              }
            }
          }
        }

        Text {
          visible: root.mode === "hash" && root.input === ""
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          topPadding: Style.space(6)
          bottomPadding: Style.space(6)
          text: "Type something to see its hashes and encodings."
          color: root.dim
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
        }

        // ---- Results
        Column {
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: root.results

            delegate: Rectangle {
              id: row
              required property var modelData

              width: parent ? parent.width : 0
              height: rowColumn.implicitHeight + Style.space(10)
              radius: Style.cornerRadius
              color: rowHover.hovered ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

              HoverHandler { id: rowHover }

              Column {
                id: rowColumn
                anchors.left: parent.left
                anchors.leftMargin: Style.space(6)
                anchors.right: copyIcon.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: row.modelData.label + (row.modelData.secret ? "  " + String.fromCodePoint(0xF033E) : "") // nf-md-lock
                  color: root.dim
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  wrapMode: Text.WrapAnywhere
                  maximumLineCount: 4
                  elide: Text.ElideRight
                  text: row.modelData.value
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                }
              }

              Text {
                id: copyIcon
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                readonly property bool copied: root.copiedLabel === row.modelData.label
                opacity: rowHover.hovered || copied ? 1 : 0
                // nf-md-check / nf-md-content_copy
                text: copied ? String.fromCodePoint(0xF012C) : String.fromCodePoint(0xF018F)
                color: copied ? Color.accent : root.dim
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.copy(row.modelData)
              }
            }
          }
        }
      }
    }
  }
}
