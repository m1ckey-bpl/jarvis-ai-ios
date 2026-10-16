import Foundation
import SwiftUI

/// Composition root: builds every engine once, wires them together, and exposes
/// the honest capability state of each subsystem to the UI.
///
/// Failure policy: if persistent storage cannot be opened, the app does NOT run on
/// stubbed data — it surfaces a recovery screen with the real error.
@MainActor
public final class AppEnvironment: ObservableObject {

    // Published surfaces used by the UI
    @Published public private(set) var startupError: JarvisError?
    @Published public private(set) var capabilities: [Capability] = []
    @Published public private(set) var providerState: CapabilityState = .requiresConfiguration(detail: "No AI provider configured yet.")

    // Engines
    public private(set) var memory: MemoryEngine?
    public private(set) var conversations: ConversationStore?
    public private(set) var context: ContextManager?
    public private(set) var reminderEngine: ReminderEngine?
    public private(set) var reminderStore: ReminderStore?
    public private(set) var toolLog: ToolExecutionLog?
    public private(set) var toolRegistry = ToolRegistry()
    public private(set) var toolExecutor: ToolExecutor?
    public private(set) var orchestrator: AgentOrchestrator?
    public private(set) var integrations: IntegrationHub?
    public private(set) var providerRegistry: ProviderRegistry?

    /// One shared HTTP client for every outbound call, so timeouts and retry policy are
    /// identical everywhere — and so Settings can run a live model listing against the
    /// same transport the assistant uses.
    public let httpTransport: HTTPTransport = URLSessionTransport()
    public let secrets: KeychainSecretStore
    public let providerSettings: ProviderSettingsStore
    public let capabilityRegistry = CapabilityRegistry()
    public let notifications = NotificationScheduler()
    public let calendar = EventKitCalendarBridge()
    public let speechRecognizer: SpeechRecognizerService
    public let speechSynthesizer = SpeechSynthesizerService()

    public init() {
        self.secrets = KeychainSecretStore()
        self.providerSettings = ProviderSettingsStore()
        let locale = Locale.current.identifier
        self.speechRecognizer = SpeechRecognizerService(localeIdentifier: locale)

        JarvisLog.shared.sink = OSLogSink()
        JarvisLog.shared.minimumLevel = .info

        do {
            try bootstrap()
        } catch let error as JarvisError {
            startupError = error
            JarvisLog.shared.error("startup", "bootstrap failed: \(error.userMessage)")
        } catch {
            startupError = .unexpected(error.localizedDescription)
        }
    }

    // MARK: Bootstrap

    private func bootstrap() throws {
        let directory = try Self.applicationSupportDirectory()
        let memoryPath = directory.appendingPathComponent("memory.sqlite3").path
        let conversationPath = directory.appendingPathComponent("conversations.sqlite3").path
        let remindersPath = directory.appendingPathComponent("reminders.sqlite3").path
        let toolLogPath = directory.appendingPathComponent("toollog.sqlite3").path

        let memoryStore = try SQLiteMemoryStore(path: memoryPath)
        let memory = MemoryEngine(store: memoryStore, clock: SystemClock(), embedder: HashingEmbedder())
        try memory.expireStale()

        let conversations = try ConversationStore(path: conversationPath)
        let summarizer = ConversationSummarizer(store: memoryStore)
        let context = ContextManager(memory: memory, conversations: conversations, summarizer: summarizer)

        let reminderStore = try ReminderStore(path: remindersPath)
        let reminderEngine = ReminderEngine(store: reminderStore, scheduler: notifications)

        let toolLog = try ToolExecutionLog(path: toolLogPath)
        let registry = ToolRegistry(capabilities: capabilityRegistry)
        let executor = ToolExecutor(registry: registry, log: toolLog)

        let integrations = IntegrationHub(secrets: secrets, capabilities: capabilityRegistry, calendar: calendar)
        let providerRegistry = ProviderRegistry(secrets: secrets, transport: httpTransport,
                                                settingsStore: providerSettings)

        let orchestrator = AgentOrchestrator(
            memory: memory, conversations: conversations, contextManager: context,
            registry: registry, executor: executor, providerRegistry: providerRegistry,
            settingsStore: providerSettings, capabilities: capabilityRegistry,
            integrations: integrations, transport: httpTransport, secrets: secrets
        )
        orchestrator.reminderEngine = reminderEngine

        registerTools(in: registry)

        // Assign stored properties only after every dependency succeeded, so a
        // partially-initialised environment can never reach the UI.
        self.memory = memory
        self.conversations = conversations
        self.context = context
        self.reminderStore = reminderStore
        self.reminderEngine = reminderEngine
        self.toolLog = toolLog
        self.toolRegistry = registry
        self.toolExecutor = executor
        self.integrations = integrations
        self.providerRegistry = providerRegistry
        self.orchestrator = orchestrator

        registerCapabilities()
    }

    private func registerTools(in registry: ToolRegistry) {
        registry.register(contentsOf: [
            CurrentTimeTool(),
            DeviceInfoTool(provider: { AppEnvironment.staticDeviceInfo() }),
            MemoryRememberTool(),
            MemorySearchTool(),
            MemoryForgetTool(),
            MemoryExportTool(),
            ReminderCreateTool(),
            ReminderListTool(),
            ReminderCancelTool(),
            ReminderCompleteTool(),
            WebFetchTool(),
            WebSearchTool(secrets: secrets),
            GitHubReposTool(),
            GitHubIssuesTool(),
            GitHubReadFileTool(),
            GitHubCreateIssueTool(),
            GmailSearchTool(),
            GmailReadTool(),
            GmailDraftTool(),
            GmailSendTool(),
            WhatsAppComposeTool(),
            InstagramProfileTool(),
            CalendarUpcomingTool(),
            CalendarCreateEventTool()
        ])
    }

    private func registerCapabilities() {
        capabilityRegistry.register(Capability(id: CapabilityID.assistant, name: "Assistant", summary: "Conversational AI", state: .requiresConfiguration(detail: "Choose a provider to start a conversation.")))
        capabilityRegistry.register(Capability(id: CapabilityID.memory, name: "Memory", summary: "Durable, on-device memory", state: .ready))
        capabilityRegistry.register(Capability(id: CapabilityID.reminders, name: "Reminders", summary: "Local notifications, time-zone aware", state: .ready))
        capabilityRegistry.register(Capability(id: CapabilityID.voiceInput, name: "Voice input", summary: "Speech recognition", state: .requiresPermission(detail: "Needs microphone and speech recognition permission.")))
        capabilityRegistry.register(Capability(id: CapabilityID.voiceOutput, name: "Spoken replies", summary: "On-device speech synthesis", state: .ready))
        capabilityRegistry.register(Capability(id: CapabilityID.whatsapp, name: "WhatsApp", summary: "Compose messages for you to send", state: .ready))
        capabilityRegistry.register(Capability(id: CapabilityID.github, name: "GitHub", summary: "Repositories, issues and files", state: .requiresConfiguration(detail: "Connect with a personal access token or device flow.")))
        capabilityRegistry.register(Capability(id: CapabilityID.gmail, name: "Gmail", summary: "Search, read, draft and send (read-only by default)", state: .requiresConfiguration(detail: "Connect with Google OAuth.")))
        capabilityRegistry.register(Capability(id: CapabilityID.instagram, name: "Instagram", summary: "Professional accounts only, via the Graph API", state: .requiresConfiguration(detail: "Requires a Meta app and a professional account; personal-account automation is not possible through official APIs.")))
        capabilityRegistry.register(Capability(id: CapabilityID.appleCalendar, name: "Apple Calendar", summary: "Read your schedule, create events", state: .requiresPermission(detail: "Grant calendar access to enable.")))
        capabilityRegistry.register(Capability(id: CapabilityID.webSearch, name: "Web search", summary: "Search the web through your own provider key", state: .requiresConfiguration(detail: "Add a free search API key (for example Brave Search).")))
        capabilityRegistry.register(Capability(id: CapabilityID.backend, name: "Companion backend", summary: "Optional server for secrets and scheduling", requiresBackend: true, state: .requiresConfiguration(detail: "Optional. Only needed for server-side OAuth exchange, background schedules and webhooks.")))
        capabilities = capabilityRegistry.all
    }

    /// Recomputes live capability states (permissions, credentials, provider).
    public func refreshCapabilities() async {
        capabilityRegistry.update(id: CapabilityID.voiceInput, state: speechRecognizer.state)

        if let reminderEngine {
            let state = await reminderEngine.authorizationState()
            capabilityRegistry.update(id: CapabilityID.reminders, state: state)
            toolRegistry.permissionStates["notifications"] = state
        }
        let calendarState = await calendar.state()
        capabilityRegistry.update(id: CapabilityID.appleCalendar, state: calendarState)

        if let integrations { await integrations.refreshCapabilities() }
        if let webSearch = toolRegistry.tool(named: "web.search") as? WebSearchTool {
            capabilityRegistry.update(id: CapabilityID.webSearch, state: webSearch.state())
        }
        if let orchestrator {
            orchestrator.registry.permissionStates["notifications"] = capabilityRegistry.capability(id: CapabilityID.reminders)?.state ?? .requiresPermission(detail: "Notification permission unknown.")
        }

        // Provider state drives the "can I actually talk?" indicator.
        if let registry = providerRegistry {
            if let provider = try? registry.activeProvider() {
                let state = await provider.state()
                providerState = state
                capabilityRegistry.update(id: CapabilityID.assistant, state: state)
            } else {
                providerState = .requiresConfiguration(detail: "Add a free provider key (Groq or Google AI Studio) in Settings ▸ AI Providers.")
                capabilityRegistry.update(id: CapabilityID.assistant, state: providerState)
            }
        }
        capabilities = capabilityRegistry.all
    }

    public func capability(_ id: String) -> CapabilityState {
        capabilityRegistry.capability(id: id)?.state ?? .unavailable(reason: "Not configured")
    }

    // MARK: Helpers

    public func deviceInfo() -> [String: String] { Self.staticDeviceInfo() }

    /// Device facts as plain values. Deliberately `nonisolated` and UIKit-free so
    /// the `device.info` tool can be handed a closure that is safe to call from
    /// any isolation domain (Swift 6 strict concurrency).
    public nonisolated static func staticDeviceInfo() -> [String: String] {
        let info = Bundle.main.infoDictionary ?? [:]
        return [
            "appVersion": info["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": info["CFBundleVersion"] as? String ?? "unknown",
            "systemName": "iOS",
            "systemVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "locale": Locale.current.identifier,
            "timeZone": TimeZone.current.identifier
        ]
    }

    /// Reads the OS version without importing UIKit in this file.
    public var systemVersion: String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }

    public var systemName: String {
        #if canImport(UIKit)
        return UIDevice.current.systemName
        #else
        return "iOS"
        #endif
    }

    /// Deletes every user-visible store (Settings ▸ Privacy ▸ Erase all data).
    public func eraseAllLocalData() async throws {
        try memory?.forgetAll()
        try conversations?.deleteAll()
        try toolLog?.deleteAll()
        if let reminderStore {
            for reminder in try reminderStore.all(includeClosed: true) {
                if let identifier = reminder.notificationIdentifier {
                    try? await notifications.cancel(identifier: identifier)
                }
            }
            try reminderStore.deleteAll()
        }
        try secrets.removeAll()
        providerSettings.clear()
    }

    static func applicationSupportDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("Jarvis", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
