import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// MyIP — public IP + country/flag bar widget.
//
// The bar shows the custom MyIP icon, the widget name and the live public IP
// with its flag emoji: `[icon] MyIP 203.0.113.7 🇳🇱`. Hovering gives a calm
// tooltip (status + country + ISP + last check). Left/right click toggles the
// details panel; middle click forces an immediate check.
//
// Config: an optional, key-less `~/.config/myip/config.json` tunes the
// poll interval (min 30 s), timeout, change alerts and country/flag display.
// Missing/empty file = defaults; a valid file is applied live; a broken file
// never crashes the widget and never leaks content — the widget keeps
// running with defaults while the panel offers a calm "reset to defaults".
// Copying always uses Omarchy's fixed clipboard IPC (no copyCommand config,
// no shell interpolation).
//
// Address-change detection: every successful check feeds a tiny
// persistent tracker (state file + short history). The first sighting after
// a state reset is a silent baseline — a fresh install or a shell restart
// with an unchanged address never rings. When the public IP really changes,
// the widget sends exactly one quiet Omarchy notification
// ("IP changed: OLD → NEW", country included when known), deduped across
// twin bar instances with a flock gate.
//
// Quiet by design:
//   * one heartbeat Timer and at most one fetch Process in flight, at most
//     one per poll interval (default 60 s); every poll runs on a *fresh*
//     Process object (created per request, destroyed on exit), never a
//     long-lived one — a Quickshell Process reused many times can lose an
//     exit event and then report running forever, silently stopping the
//     widget (MI-5). The extra Processes only run when an address change
//     happens (state write + notification), never on the polling cadence;
//   * _dueAt is a `double` epoch (Date.now() ~1.7e12) — an `int` would wrap
//     at 2^31 and turn the dueAt guard into polling-spam;
//   * after every attempt (success OR failure) the next poll is scheduled a
//     full interval away, so offline never spams retries;
//   * a poll result that belongs to an older run (stale-result guard, epoch
//     check) is dropped; the Model reducer additionally drops out-of-order
//     events.
//
// Poll self-heal (watchdog): a healthy poll is bounded by curl's own
// --max-time. The 1 s heartbeat checks that a running poll never exceeds
// Model.fetchDeadlineMs() (timeout + 5 s, floor 10 s). If it does, the exit
// event was lost or the child hung: the watchdog SIGKILLs the child, and if
// the Process still does not report an exit shortly after, the wedged
// Process object is dropped and the next poll starts on a fresh one — so a
// single lost exit can never stall the widget again.
//
// Polling lives here (never in the panel) so every bar instance and the
// panel share one source of truth.
BarWidget {
  id: root
  moduleName: "io.github.shirak-semonian.myip"

  // ---- config / state ----------------------------------------------------
  // Optional key-less config (~/.config/myip/config.json). A missing/empty
  // file means defaults; a valid file tunes interval/display/alert prefs; a
  // broken file shows a calm config-attention state and keeps running with
  // defaults (reset action in the panel repairs it). FileView watchers are
  // active, so an external edit or a reset is picked up live.
  property var config: Model.defaults()
  property var view: Model.initialView()
  // Millisecond epoch (Date.now() ~1.7e12): must be double, never int.
  property double _dueAt: 0
  property int _epoch: 0
  property string _logKey: ""
  // Active poll (a fresh Process object per request) + poll watchdog state.
  // When a poll overruns Model.fetchDeadlineMs() the watchdog kills it; if
  // the Process still never exits, the object is dropped and the next poll
  // starts on a fresh one (see startFetch/checkPollWatchdog/releasePoll).
  property var _activePoll: null
  property double _pollDeadlineAt: 0
  property bool _pollKillSent: false
  property int _pollRecoveries: 0

  readonly property string configPath: {
    var base = Quickshell.env("XDG_CONFIG_HOME")
    if (!base) base = (Quickshell.env("HOME") || "") + "/.config"
    return base + "/myip/config.json"
  }
  readonly property string configDir: {
    var idx = root.configPath.lastIndexOf("/")
    return idx > 0 ? root.configPath.substring(0, idx) : root.configPath
  }
  property string configErrorKind: ""
  property var _configProblem: null
  property var _lastConfigRaw: null
  property bool _configSeen: false
  property bool _configLoadFailed: false
  property double _configRetryAt: 0

  // Calm human-readable config problem (static text; never file content).
  readonly property string configError: root.configErrorKind !== ""
    ? Model.configProblemText(root._configProblem) : ""

  // True while the config file is broken: the widget runs on defaults and
  // the panel shows a "reset to defaults" action.
  readonly property bool configAttention: root.configErrorKind !== ""

  readonly property bool alertOnChange: !root.config
    || root.config.alertOnChange !== false
  readonly property bool showCountry: !root.config
    || root.config.showCountry !== false
  readonly property bool showFlag: !root.config
    || root.config.showFlag !== false

  // ---- Address-change tracker + notifications ----------------------------
  // The tracker (last known address + short history) lives in a tiny JSON
  // state file so a restart can never re-announce an unchanged address and
  // the panel can show the history. Loaded once at startup; observations
  // that arrive before the file resolves are queued and drained after.
  property var tracker: Model.emptyTracker()
  property bool _trackerLoaded: false
  property var _pendingObservations: []
  property string _trackerWriteText: ""
  property var _notifQueue: []
  property var _notifPending: null
  property bool _notifGateMode: false
  property string _notifOut: ""

  readonly property string stateFile: {
    var base = Quickshell.env("XDG_STATE_HOME")
    if (!base) base = (Quickshell.env("HOME") || "") + "/.local/state"
    return base + "/myip/state.json"
  }
  readonly property string notifGateFile: {
    var base = Quickshell.env("XDG_STATE_HOME")
    if (!base) base = (Quickshell.env("HOME") || "") + "/.local/state"
    return base + "/myip/notifications.gate"
  }

  // ---- display helpers ---------------------------------------------------
  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color warn: "#ebcb8b"
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool hasOk: Model.isOk(root.view)
  readonly property bool loading: Model.isLoading(root.view)
  readonly property bool offline: Model.isOffline(root.view)
  readonly property bool dimmed: Model.isDimmed(root.view)

  readonly property string valueText: Model.barValueText(root.view)
  // Flag only when the user enables it AND the state is fresh enough.
  readonly property string flagText: Model.barFlag(root.view, root.config)
  readonly property string widgetTooltip: {
    var base = Model.tooltipText(root.view, root.config)
    if (root.configAttention) {
      return "MyIP \u2014 config file needs attention \u00b7 using defaults \u00b7 "
        + root.configError + " \u00b7 click for reset"
    }
    return base
  }

  // ---- panel popup. Shape contract for shell summon/hide/toggle routing:
  //      Bar.findPanelWidget requires open/close/opened on the bar-widget
  //      root, so those are forwarded to the loaded Panel.qml.
  readonly property bool opened: panelLoader.item
    ? panelLoader.item.opened === true
    : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function handlePressed(buttonCode) {
    if (buttonCode === Qt.MiddleButton) root.refreshNow()
    else root.togglePanel()
  }

  // Manual refresh (middle click / panel button). Forces a fetch on the next
  // heartbeat when the process is idle; a busy process keeps its single
  // in-flight request and fetches right after it finishes.
  function refreshNow() {
    root._dueAt = 0
    root.tick()
  }

  // Copy the current public IPv4 to the clipboard. Exposed so the shell IPC
  // (`omarchy-shell shell <id> copy`) and the panel share one path.
  function copyIp() {
    var target = panelLoader.item
    if (target && typeof target.copyIp === "function") target.copyIp()
  }

  // ---- Config file ------------------------------------------------------
  // Apply one raw config file read. A missing/empty file = defaults; a
  // broken file keeps the defaults and records a calm attention state; a
  // valid file replaces root.config. Identical reloads are ignored so a
  // FileView watch event never resets the poll timer needlessly.
  function applyConfig(raw) {
    if (raw === root._lastConfigRaw) return
    root._lastConfigRaw = raw
    root._configSeen = true
    var parsed = Model.parseConfig(raw)
    if (!parsed.ok) {
      // Broken file: run with defaults, keep the widget calm and let
      // the panel offer "reset to defaults". Raw content is never logged.
      root.configErrorKind = parsed.kind
      root._configProblem = parsed
      root.config = Model.defaults()
      console.warn("MyIP: " + Model.configProblemText(parsed))
      return
    }
    var intervalChanged = parsed.config.pollIntervalSeconds
      !== root.config.pollIntervalSeconds
    root.configErrorKind = ""
    root._configProblem = null
    root.config = parsed.config
    root._logKey = ""
    if (intervalChanged && !root._configLoadFailed) {
      // Apply the new cadence from now: never poll sooner than the current
      // dueAt, but do not wait longer than one fresh interval either.
      var fresh = Date.now() + parsed.config.pollIntervalSeconds * 1000
      root._dueAt = Math.min(root._dueAt, fresh)
    }
    // Journal transparency: static summary only, never config contents.
    console.log("MyIP: config loaded — poll every "
      + parsed.config.pollIntervalSeconds + " s, alert "
      + (parsed.config.alertOnChange ? "on" : "off")
      + ", country " + (parsed.config.showCountry ? "on" : "off")
      + ", flag " + (parsed.config.showFlag ? "on" : "off"))
    Qt.callLater(root.tick)
  }

  function refreshConfig() {
    configFile.reload()
  }

  // Panel action: back up the broken file and write the defaults template.
  function resetConfigFile() {
    if (configWriteProc.running) return
    configWriteProc.command = Model.resetConfigCommandArgs(
      root.configDir, Model.templateConfigText())
    configWriteProc.running = true
  }

  // Panel action: open the config in the user's editor (fixed Omarchy
  // launcher; path travels as argv, never through a shell).
  function openConfigFile() {
    var omarchyPath = Quickshell.env("OMARCHY_PATH")
    var launcher = omarchyPath
      ? omarchyPath + "/bin/omarchy-launch-config-editor"
      : "/usr/bin/omarchy-launch-config-editor"
    Quickshell.execDetached([launcher, root.configPath])
  }

  // One heartbeat tick. Starts a fetch only when no poll is in flight AND
  // the poll interval has elapsed — the actual polling cadence.
  function tick() {
    if (root._activePoll) return
    if (Date.now() < root._dueAt) return
    root.startFetch()
  }

  // Start one poll on a brand-new Process object. A single long-lived
  // Process reused for many requests can lose an exit event in Quickshell
  // and then report running forever (MI-5 poll-stop); a fresh object per
  // request keeps the failure surface to one poll and lets the watchdog
  // rebuild cleanly when an exit really is lost.
  function startFetch() {
    if (root._activePoll) return
    var cmd = Model.buildFetchCommand(root.config)
    if (!cmd || cmd.length === 0) return
    root.view = Model.reduce(root.view, { type: "fetchStart" })
    var poll = fetchProcessComponent.createObject(root, {
      command: cmd,
      runEpoch: ++root._epoch
    })
    if (!poll) {
      console.warn("MyIP: could not create the poll process")
      return
    }
    root._activePoll = poll
    root._pollKillSent = false
    root._pollDeadlineAt = Date.now()
      + Model.fetchDeadlineMs(root.config)
    poll.running = true
  }

  // Drop a poll Process object exactly once (createObject/destroy pair).
  function releasePoll(poll) {
    if (!poll || poll.released) return
    poll.released = true
    if (root._activePoll === poll) root._activePoll = null
    poll.destroy()
  }

  // Poll watchdog (called from the 1 s heartbeat). A healthy fetch is
  // bounded by curl's --max-time, so a poll still "running" past its
  // deadline has lost its exit event or its child hung. First strike:
  // SIGKILL the child and wait briefly for the exit event. Second strike:
  // the Process object itself is wedged — drop it and schedule a recovery
  // poll on a fresh object. Repeated recoveries back off to the normal
  // interval so a pathological environment can never turn into a retry loop.
  function checkPollWatchdog() {
    var poll = root._activePoll
    if (!poll) return
    if (Date.now() < root._pollDeadlineAt) return
    var intervalMs = (root.config ? root.config.pollIntervalSeconds
      : Model.DEFAULT_POLL_INTERVAL_SECONDS) * 1000
    if (!root._pollKillSent) {
      root._pollKillSent = true
      console.warn("MyIP: poll watchdog — fetch did not finish within "
        + Math.round(Model.fetchDeadlineMs(root.config) / 1000)
        + " s; killing the poll process")
      // Any late result from this run is now stale.
      ++root._epoch
      poll.runEpoch = -1
      try { poll.signal(9) } catch (error) { /* object may be gone */ }
      try { poll.running = false } catch (error) { /* ditto */ }
      root._pollDeadlineAt = Date.now() + 3000
      return
    }
    console.warn("MyIP: poll watchdog — poll process did not recover; "
      + "rebuilding the poll process")
    ++root._epoch
    root._pollRecoveries++
    root.releasePoll(poll)
    root._dueAt = Date.now()
      + (root._pollRecoveries >= 3 ? intervalMs : 3000)
  }

  function handleFetchExited(poll, exitCode) {
    if (!poll) return
    var intervalMs = (root.config ? root.config.pollIntervalSeconds
      : Model.DEFAULT_POLL_INTERVAL_SECONDS) * 1000
    var killed = root._pollKillSent
    if (root._activePoll !== poll || poll.runEpoch !== root._epoch) {
      // Stale result: the watchdog already took over this run (killed +
      // epoch bumped), or a newer poll replaced it. Drop it; after a
      // watchdog kill the next attempt comes soon (bounded recovery), never
      // as a tight retry loop.
      root.releasePoll(poll)
      if (killed && root._activePoll === null) {
        root._pollRecoveries++
        root._dueAt = Date.now()
          + (root._pollRecoveries >= 3 ? intervalMs : 10000)
      }
      return
    }
    root._pollRecoveries = 0
    root.releasePoll(poll)
    // Whatever the outcome, the next poll is a full interval away: a failing
    // endpoint never turns this into a retry loop.
    root._dueAt = Date.now() + intervalMs
    var output = String(poll.pollOutput || "")
    var result = Model.parseFetchResult(exitCode, output)
    var at = Date.now()
    var next = result.ok
      ? Model.reduce(root.view, {
          type: "fetchSuccess", data: result.data, at: at
        })
      : Model.reduce(root.view, {
          type: "fetchFail", kind: result.kind, message: result.message, at: at
        })
    var key = next.status + "|" + (next.message || "")
    if (key !== root._logKey) {
      root._logKey = key
      console.log("MyIP: " + Model.statusLine(next))
    }
    root.view = next
    // A fresh successful check feeds the address-change tracker (baseline,
    // history, one notification per real change). Failed checks never touch
    // the tracker: they cannot erase or re-announce anything.
    if (result.ok) root.observeAddress(result.data, at)
  }

  // ---- Address-change tracking -------------------------------------------
  // Feeds one fresh observation into the pure Model reducer, persists the
  // tracker when it moved (baseline or change) and queues a notification for
  // every real change event. The reducer emits at most one event per
  // transition, so a poll that re-observes the same address stays silent.
  function observeAddress(data, at) {
    if (!data || !data.ip) return
    if (!root._trackerLoaded) {
      root._pendingObservations.push({ data: data, at: at })
      return
    }
    var res = Model.trackObservation(root.tracker, {
      ip: data.ip, country: data.country,
      countryCode: data.countryCode, at: at
    })
    if (!Model.sameTracker(root.tracker, res.state)) {
      root.tracker = res.state
      root._trackerWriteText = Model.trackerToText(root.tracker)
      root.kickTrackerWrite()
    }
    for (var i = 0; i < res.events.length; i++) {
      root.enqueueChangeNotification(res.events[i])
    }
  }

  function loadTracker(raw) {
    var text = String(raw == null ? "" : raw)
    root.tracker = text.trim() === ""
      ? Model.emptyTracker()
      : Model.trackerFromText(text)
    root._trackerLoaded = true
    var pending = root._pendingObservations
    root._pendingObservations = []
    for (var i = 0; i < pending.length; i++) {
      root.observeAddress(pending[i].data, pending[i].at)
    }
  }

  function drainPendingTrackerLoad() {
    if (root._trackerLoaded) return
    trackerFile.reload()
  }

  // Atomic state-file writer with coalescing: at most one write in flight,
  // the latest tracker text wins. A write that fails is simply retried on
  // the next state change (the in-memory tracker stays authoritative).
  function kickTrackerWrite() {
    if (trackerWriteProc.running) return
    if (root._trackerWriteText === "") return
    var text = root._trackerWriteText
    root._trackerWriteText = ""
    trackerWriteProc.command = Model.writeFileCommandArgs(root.stateFile, text)
    trackerWriteProc.running = true
  }

  // One Omarchy notification per real IP change, deduped across twin bar
  // instances through the flock gate (Model.notifGateCommandArgs): the first
  // instance to reach the gate sends; twins that observed the same change
  // skip. Gate failures degrade to "skip" — never to a duplicate.
  // alertOnChange=false in the config silences change alerts entirely (the
  // tracker still records history; only the popup is suppressed).
  function enqueueChangeNotification(event) {
    if (!root.alertOnChange) return
    var parts = Model.changeNotificationParts(event, root.config)
    if (!parts || !parts.summary) return
    var args = []
    var omarchyPath = Quickshell.env("OMARCHY_PATH")
    if (omarchyPath) args.push(omarchyPath + "/bin/omarchy-notification-send")
    else args.push("/usr/bin/omarchy-notification-send")
    args = args.concat(["--app-name", "MyIP", "-u", parts.urgency,
      "-g", parts.glyph, parts.summary, parts.body])
    root._notifQueue.push({ event: event, args: args })
    root.runNextChangeNotification()
  }

  function runNextChangeNotification() {
    if (notifProc.running) return
    if (root._notifQueue.length === 0) return
    var entry = root._notifQueue[0]
    root._notifQueue = root._notifQueue.slice(1)
    root._notifPending = entry
    root._notifGateMode = true
    root._notifOut = ""
    notifProc.command = Model.notifGateCommandArgs(root.notifGateFile,
      Model.changeGateKey(entry.event), Model.CHANGE_GATE_TTL_SECONDS)
    notifProc.running = true
  }

  function finishChangeNotification(exitCode, output) {
    if (root._notifGateMode) {
      root._notifGateMode = false
      var gate = String(output == null ? "" : output).trim()
      var entry = root._notifPending
      root._notifPending = null
      if (gate === "send" && entry && entry.args) {
        var parts = Model.changeNotificationParts(entry.event, root.config)
        console.log("MyIP: notification — "
          + (parts && parts.body ? parts.body : "IP changed"))
        notifProc.command = entry.args
        notifProc.running = true
        return
      }
      Qt.callLater(root.runNextChangeNotification)
      return
    }
    root._notifPending = null
    Qt.callLater(root.runNextChangeNotification)
  }

  // Reserve the natural width of the composed label so the bar slot matches
  // the visible content (value + optional flag). Local patch: the icon and the
  // "MyIP" name were removed from the bar label on purpose.
  implicitWidth: valueText.implicitWidth
    + (flagTextItem.visible ? Style.space(5) + flagTextItem.implicitWidth : 0)
    + Style.space(16)
  implicitHeight: root.barSize

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  // Heartbeat. Runs the tick gate once per second; tick() itself decides
  // when a request may actually start (idle process + interval elapsed).
  // Before the tracker file has been resolved (or confirmed missing) the
  // tick is paused so the first observation can never race the baseline.
  // The optional config file is read at startup (and re-checked whenever a
  // previous read failed, e.g. the file did not exist yet).
  Timer {
    id: pollTimer
    interval: 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: {
      // Poll self-heal first: a poll that overruns its deadline is killed /
      // rebuilt regardless of the tracker/config gates below.
      root.checkPollWatchdog()
      if (!root._trackerLoaded) {
        root.drainPendingTrackerLoad()
        return
      }
      if (!root._configSeen) {
        configFile.reload()
        return
      }
      if (root._configLoadFailed && Date.now() >= root._configRetryAt) {
        root._configRetryAt = Date.now() + 10000
        configFile.reload()
      }
      root.tick()
    }
  }

  // The optional config file (~/.config/myip/config.json). Watch is on so a
  // manual edit or a panel "reset to defaults" is applied live. A missing
  // file is not an error: the widget simply keeps the defaults.
  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root._configLoadFailed = false
      root.applyConfig(text())
    }
    onFileChanged: reload()
    onLoadFailed: {
      // A missing config file is not an error — the widget keeps the
      // defaults. This fires on the first load attempt (no file yet) and
      // again when an existing file disappears; both mean "use defaults".
      root._lastConfigRaw = null
      root._configSeen = true
      root._configLoadFailed = true
      root._configRetryAt = Date.now() + 10000
      root.configErrorKind = ""
      root._configProblem = null
      root.config = Model.defaults()
    }
  }

  // Panel "reset to defaults": atomic backup + write, see resetConfigFile().
  Process {
    id: configWriteProc
    command: []
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        console.warn("MyIP: could not reset the config file")
        return
      }
      root._lastConfigRaw = null
      Qt.callLater(root.refreshConfig)
    }
  }

  // The persisted address-change tracker (last known IP + short history).
  // watchChanges is off on purpose: the file is only read once at startup;
  // every write goes through the coalescing writer below, never through
  // this view. A missing file resolves immediately to the silent-baseline
  // empty tracker.
  FileView {
    id: trackerFile
    path: root.stateFile
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadTracker(text())
    onLoadFailed: root.loadTracker("")
  }

  // Fetch Process factory. Every poll runs on a fresh Process object so a
  // wedged Process (lost exit event, MI-5) can never stall polling forever:
  // the object is created per request and destroyed on exit / watchdog
  // recovery. See startFetch()/handleFetchExited()/checkPollWatchdog().
  Component {
    id: fetchProcessComponent
    Process {
      id: fetchPoll
      property int runEpoch: 0
      property string pollOutput: ""
      property bool released: false
      command: []
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: fetchPoll.pollOutput = text
      }
      onExited: function(exitCode) {
        root.handleFetchExited(fetchPoll, exitCode)
      }
    }
  }

  // State-file writer (coalesced, atomic). See kickTrackerWrite().
  Process {
    id: trackerWriteProc
    command: []
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        console.warn("MyIP: could not write the address state file")
      }
      root.kickTrackerWrite()
    }
  }

  // Change-notification dispatcher: first the cross-instance flock gate
  // (prints "send"/"skip"), then — only on "send" — the real
  // omarchy-notification-send call. See runNextChangeNotification().
  Process {
    id: notifProc
    command: []
    stdout: StdioCollector {
      id: notifStdout
      waitForEnd: true
      onStreamFinished: root._notifOut = text
    }
    onExited: function(exitCode) {
      var output = String(notifStdout.text || root._notifOut || "")
      root._notifOut = ""
      root.finishChangeNotification(exitCode, output)
    }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // Shell IPC: `omarchy-shell shell summon|hide|toggle <id>` routes here.
  IpcHandler {
    target: root.moduleName
    function refresh(): void { root.refreshNow() }
    function copy(): void { root.copyIp() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function reset(): void { root.resetConfigFile() }
  }

  // Full-size interaction layer. Its own label is hidden; the composed
  // content below (plain visuals — they do not consume mouse events) sits on
  // top, so hover/press/tooltip all still land on this button.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: " "
    labelVisible: false
    tooltipText: root.widgetTooltip
    onPressed: function(buttonCode) {
      root.handlePressed(buttonCode)
    }
  }

  Item {
    id: contentRow
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: Style.space(8)
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    opacity: root.dimmed ? 0.6 : 1.0

    Behavior on opacity {
      NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
    }

    // Local patch: no icon and no "MyIP" name here — the bar shows only the
    // address and the country flag. The icon still ships in assets/ for the
    // panel and the marketplace listing.
    Text {
      id: valueText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: root.valueText
      color: root.hasOk ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      verticalAlignment: Text.AlignVCenter

      Behavior on color {
        enabled: !root.bar || root.bar.foregroundAnimationEnabled
        ColorAnimation { duration: 160 }
      }
    }

    // Flag emoji (regional indicators, e.g. 🇳🇱). Rendered by the Qt color
    // emoji font fallback; empty while there is no fresh country to show.
    Text {
      id: flagTextItem
      anchors.left: valueText.right
      anchors.leftMargin: Style.space(5)
      anchors.verticalCenter: parent.verticalCenter
      text: root.flagText
      visible: text !== ""
      font.pixelSize: Style.font.body
      verticalAlignment: Text.AlignVCenter
    }
  }
}
