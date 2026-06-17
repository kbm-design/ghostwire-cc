//
//  Constants.swift
//  Ghostwire
//
//

import SwiftUI
import Defaults

private let availableDirectories = FileManager
    .default
    .urls(for: .documentDirectory, in: .userDomainMask)
let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
let bundleIdentifier = Bundle.main.bundleIdentifier!
let appVersion = "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))"

let temporaryDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
let spacing: CGFloat = 16

struct CustomVisualizer: Codable, Hashable, Equatable, Defaults.Serializable {
    let UUID: UUID
    var name: String
    var url: URL
    var speed: CGFloat = 1.0
}

enum CalendarSelectionState: Codable, Defaults.Serializable {
    case all
    case selected(Set<String>)
}

enum HideNotchOption: String, Defaults.Serializable {
    case always
    case nowPlayingOnly
    case never
}

// Define notification names at file scope
extension Notification.Name {
    static let mediaControllerChanged = Notification.Name("mediaControllerChanged")
}

// Media controller types for selection in settings
enum MediaControllerType: String, CaseIterable, Identifiable, Defaults.Serializable {
    case nowPlaying = "Now Playing"
    case appleMusic = "Apple Music"
    case spotify = "Spotify"
    case youtubeMusic = "YouTube Music"
    
    var id: String { self.rawValue }
}

// Sneak peek styles for selection in settings
enum SneakPeekStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case standard = "Default"
    case inline = "Inline"
    
    var id: String { self.rawValue }
}

// Action to perform when Option (⌥) is held while pressing media keys
enum OptionKeyAction: String, CaseIterable, Identifiable, Defaults.Serializable {
    case openSettings = "Open System Settings"
    case showHUD = "Show HUD"
    case none = "No Action"

    var id: String { self.rawValue }
}

// Message display in agent chat (GW-144). Full raw pairs with GW-139's
// security rule: prompts shown verbatim — no markdown rendering, and the
// view layer must never truncate.
enum MessageDisplayMode: String, CaseIterable, Identifiable, Defaults.Serializable {
    case inline = "Inline"
    case fullRaw = "Full raw"

    var id: String { rawValue }
}

// When to auto-open the notch for a new pending permission (GW-209).
// Smart  = open only when the triggering session's own pane isn't focused
//          (so a hidden lane pings you even with other terminals on screen).
// Always = open on every new permission (still requires the notch closed).
// Never  = never auto-open; the glow/haptic/record still follow the Smart
//          visibility rule — Never only suppresses the OPEN.
enum PermissionAutoOpenMode: String, CaseIterable, Identifiable, Defaults.Serializable {
    case smart = "Smart"
    case always = "Always"
    case never = "Never"

    var id: String { rawValue }
}

// Ambient context retention (GW-172). How long frontmost-app activity shards
// are kept on disk. session-only = RAM only, nothing is ever written (and
// switching to it wipes existing shards). `forever` keeps everything.
enum AmbientRetention: String, CaseIterable, Identifiable, Defaults.Serializable {
    case days7 = "7 days"
    case days30 = "30 days"
    case days90 = "90 days"
    case forever = "Forever"
    case sessionOnly = "Session only"

    var id: String { rawValue }

    /// Max age to keep, or nil for `forever`. `sessionOnly` also returns nil
    /// here but is special-cased upstream (nothing is persisted at all).
    var maxAge: TimeInterval? {
        switch self {
        case .days7: return 7 * 86_400
        case .days30: return 30 * 86_400
        case .days90: return 90 * 86_400
        case .forever, .sessionOnly: return nil
        }
    }
}

extension Defaults.Keys {
    // MARK: General
    static let menubarIcon = Key<Bool>("menubarIcon", default: true)
    static let showOnAllDisplays = Key<Bool>("showOnAllDisplays", default: false)
    static let automaticallySwitchDisplay = Key<Bool>("automaticallySwitchDisplay", default: true)

    // MARK: Behavior
    static let minimumHoverDuration = Key<TimeInterval>("minimumHoverDuration", default: 0.3)
    static let enableHaptics = Key<Bool>("enableHaptics", default: true)
    static let openNotchOnHover = Key<Bool>("openNotchOnHover", default: true)
    static let extendHoverArea = Key<Bool>("extendHoverArea", default: false)
    static let notchHeightMode = Key<WindowHeightMode>(
        "notchHeightMode",
        default: WindowHeightMode.matchRealNotchSize
    )
    static let nonNotchHeightMode = Key<WindowHeightMode>(
        "nonNotchHeightMode",
        default: WindowHeightMode.matchMenuBar
    )
    static let nonNotchHeight = Key<CGFloat>("nonNotchHeight", default: 32)
    static let notchHeight = Key<CGFloat>("notchHeight", default: 32)
    //static let openLastTabByDefault = Key<Bool>("openLastTabByDefault", default: false)
    static let showOnLockScreen = Key<Bool>("showOnLockScreen", default: false)
    static let hideFromScreenRecording = Key<Bool>("hideFromScreenRecording", default: false)
    
    // MARK: Appearance
    //static let alwaysShowTabs = Key<Bool>("alwaysShowTabs", default: true)
    static let showMirror = Key<Bool>("showMirror", default: false)
    static let mirrorShape = Key<MirrorShapeEnum>("mirrorShape", default: MirrorShapeEnum.rectangle)
    static let settingsIconInNotch = Key<Bool>("settingsIconInNotch", default: true)
    static let lightingEffect = Key<Bool>("lightingEffect", default: true)
    static let enableShadow = Key<Bool>("enableShadow", default: true)
    static let cornerRadiusScaling = Key<Bool>("cornerRadiusScaling", default: true)

    static let showNotHumanFace = Key<Bool>("showNotHumanFace", default: false)
    static let showCalendar = Key<Bool>("showCalendar", default: false)
    static let hideCompletedReminders = Key<Bool>("hideCompletedReminders", default: true)
    static let sliderColor = Key<SliderColorEnum>(
        "sliderUseAlbumArtColor",
        default: SliderColorEnum.white
    )
    static let playerColorTinting = Key<Bool>("playerColorTinting", default: true)
    // GW-195: the settings toggle for these was removed with the coming-soon
    // Lottie section (it was already disabled, so no UI path ever set
    // useMusicVisualizer false in this app). ContentView still reads it;
    // when custom visualizers ship for real, the controls come back with them.
    static let useMusicVisualizer = Key<Bool>("useMusicVisualizer", default: true)
    static let customVisualizers = Key<[CustomVisualizer]>("customVisualizers", default: [])
    static let selectedVisualizer = Key<CustomVisualizer?>("selectedVisualizer", default: nil)
    
    // MARK: Gestures
    static let enableGestures = Key<Bool>("enableGestures", default: true)
    static let closeGestureEnabled = Key<Bool>("closeGestureEnabled", default: true)
    static let gestureSensitivity = Key<CGFloat>("gestureSensitivity", default: 200.0)
    
    // MARK: Media playback
    static let coloredSpectrogram = Key<Bool>("coloredSpectrogram", default: true)
    static let enableSneakPeek = Key<Bool>("enableSneakPeek", default: false)
    static let sneakPeekStyles = Key<SneakPeekStyle>("sneakPeekStyles", default: .standard)
    static let waitInterval = Key<Double>("waitInterval", default: 3)
    static let enableLyrics = Key<Bool>("enableLyrics", default: false)
    static let musicControlSlots = Key<[MusicControlButton]>(
        "musicControlSlots",
        default: MusicControlButton.defaultLayout
    )
    static let musicControlSlotLimit = Key<Int>(
        "musicControlSlotLimit",
        default: MusicControlButton.defaultLayout.count
    )
    
    // MARK: Battery
    static let showPowerStatusNotifications = Key<Bool>("showPowerStatusNotifications", default: true)
    static let showBatteryIndicator = Key<Bool>("showBatteryIndicator", default: true)
    static let showBatteryPercentage = Key<Bool>("showBatteryPercentage", default: true)
    static let showPowerStatusIcons = Key<Bool>("showPowerStatusIcons", default: true)
    
    // MARK: HUD
    static let hudReplacement = Key<Bool>("hudReplacement", default: false)
    static let inlineHUD = Key<Bool>("inlineHUD", default: false)
    static let enableGradient = Key<Bool>("enableGradient", default: false)
    static let systemEventIndicatorShadow = Key<Bool>("systemEventIndicatorShadow", default: false)
    static let systemEventIndicatorUseAccent = Key<Bool>("systemEventIndicatorUseAccent", default: false)
    static let showOpenNotchHUD = Key<Bool>("showOpenNotchHUD", default: true)
    static let showOpenNotchHUDPercentage = Key<Bool>("showOpenNotchHUDPercentage", default: true)
    static let showClosedNotchHUDPercentage = Key<Bool>("showClosedNotchHUDPercentage", default: false)
    // Option key modifier behaviour for media keys
    static let optionKeyAction = Key<OptionKeyAction>("optionKeyAction", default: OptionKeyAction.openSettings)
    
    // MARK: Shelf
    static let shelf = Key<Bool>("shelf", default: true)
    // GW-226: `openShelfByDefault` retired — the default-open tab is now the last
    // tab you selected (with an approval→Agents override + one-shot Shelf reveal),
    // not "Shelf whenever it has items." See GhostwireViewCoordinator.defaultViewOnOpen.
    static let quickShareProvider = Key<String>("quickShareProvider", default: QuickShareProvider.defaultProvider.id)
    static let copyOnDrag = Key<Bool>("copyOnDrag", default: false)
    static let autoRemoveShelfItems = Key<Bool>("autoRemoveShelfItems", default: false)
    static let expandedDragDetection = Key<Bool>("expandedDragDetection", default: true)
    
    // MARK: Calendar
    static let calendarSelectionState = Key<CalendarSelectionState>("calendarSelectionState", default: .all)
    static let hideAllDayEvents = Key<Bool>("hideAllDayEvents", default: false)
    static let showFullEventTitles = Key<Bool>("showFullEventTitles", default: false)
    static let autoScrollToNextEvent = Key<Bool>("autoScrollToNextEvent", default: true)
    
    // MARK: Fullscreen Media Detection
    static let hideNotchOption = Key<HideNotchOption>("hideNotchOption", default: .nowPlayingOnly)
    
    // MARK: Media Controller
    static let mediaController = Key<MediaControllerType>("mediaController", default: defaultMediaController)
    
    // MARK: Advanced Settings
    static let useCustomAccentColor = Key<Bool>("useCustomAccentColor", default: false)
    static let customAccentColorData = Key<Data?>("customAccentColorData", default: nil)
    // Show or hide the title bar
    static let hideTitleBar = Key<Bool>("hideTitleBar", default: true)
    
    // Helper to determine the default media controller based on NowPlaying deprecation status
    static var defaultMediaController: MediaControllerType {
        if MusicManager.shared.isNowPlayingDeprecated {
            return .appleMusic
        } else {
            return .nowPlaying
        }
    }

    static let didClearLegacyURLCacheV1 = Key<Bool>("didClearLegacyURLCache_v1", default: false)

    static let notificationSound = Key<String>("notificationSound", default: "Pop")

    // MARK: Agents (GW-144)
    // Gate the silent launch-time hook auto-install per agent so an
    // uninstall from the Agents tab sticks across relaunches.
    static let claudeHooksEnabled = Key<Bool>("claudeHooksEnabled", default: true)
    static let codexHooksEnabled = Key<Bool>("codexHooksEnabled", default: true)
    // Pending Codex re-trust map (GW-196): `[hooks.state]` position key ->
    // the stale `trusted_hash` that was in config.toml when we changed that
    // hook's command in place (e.g. buddi -> ghostwire). The installer records
    // it on rewrite; the detector reports `.retrustRequired` while the config
    // still carries that exact stale hash, and clears the entry once Codex
    // rewrites the hash (user re-trusted via `/hooks`). Catches the in-place
    // command change that coverage detection can't see (same key, stale hash).
    static let codexPendingRetrust = Key<[String: String]>("codexPendingRetrust", default: [:])
    static let messageDisplayMode = Key<MessageDisplayMode>("messageDisplayMode", default: .inline)
    // GW-209: when to auto-open the notch for a new pending permission.
    static let permissionAutoOpenMode = Key<PermissionAutoOpenMode>(
        "permissionAutoOpenMode",
        default: .smart
    )
    // Alert-history cap (GW-139 spec: 100 entries / 7 days, configurable)
    static let alertHistoryMaxEntries = Key<Int>("alertHistoryMaxEntries", default: 100)
    static let alertHistoryMaxAgeDays = Key<Int>("alertHistoryMaxAgeDays", default: 7)

    // MARK: Clipboard history (GW-210)
    // Master switch. Default OFF: clipboard capture is privacy-sensitive, so
    // the first ship is opt-in — the user enables it from the Shelf section
    // header or the Settings row. (Capture honors concealed/transient markers
    // and skips our own writes; see ClipboardHistoryService.)
    static let clipboardHistoryEnabled = Key<Bool>("clipboardHistoryEnabled", default: false)
    // Cap mirrors the alert-history pattern: 100 entries / 7 days, configurable.
    static let clipboardHistoryMaxEntries = Key<Int>("clipboardHistoryMaxEntries", default: 100)
    static let clipboardHistoryMaxAgeDays = Key<Int>("clipboardHistoryMaxAgeDays", default: 7)
    // GW-218: what a double-click on a unified card does. Default: copy.
    static let cardDoubleClickAction = Key<CardDoubleClickAction>("cardDoubleClickAction", default: .copy)

    // MARK: Modules + notch tabs (GW-144)
    // Media's toggle only hides its settings pane (the player is core);
    // the other modules reuse their feature master keys (see SettingsModule).
    static let mediaModuleEnabled = Key<Bool>("mediaModuleEnabled", default: true)
    static let notchTabOrder = Key<[String]>("notchTabOrder", default: ["agents", "dashboard", "shelf"])
    static let hiddenNotchTabs = Key<Set<String>>("hiddenNotchTabs", default: [])

    // MARK: Ambient context (GW-172) — Tier-0 frontmost-app spine.
    // SILENT: collects + persists which app is frontmost (identity only — no
    // window titles or content) for Ghostwire's OWN future surfacing (ranking
    // GW-182, display GW-214). Local-only — never narrated to a cloud agent.
    //
    // Master toggle, default ON (Tier 0 is free, zero-TCC). AmbientContextService
    // follows this key live; SettingsModule.ambient exposes it as the sidebar
    // module toggle.
    static let ambientCaptureEnabled = Key<Bool>("ambientCaptureEnabled", default: true)
    static let ambientRetention = Key<AmbientRetention>("ambientRetention", default: .days30)
    // Apps whose activity is never recorded (capture-suppressing). Empty by
    // default: the spine records app identity only (no window titles, no
    // content), so there's little to protect yet — users add their own apps in
    // Settings → Activity. (Revisit the seed when Tier-1 window titles land in
    // GW-182+, where the privacy stakes are higher.)
    static let ambientAppDenylist = Key<[String]>("ambientAppDenylist", default: [])
}
