//
//  StartSessionIntent.swift
//  ChromaVue
//
//  Created by Mohamed Elbashir on 11/2/25.
//


import AppIntents

@available(iOS 26, *)
struct StartSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Start ChromaVue Session"
    static var description = IntentDescription("Starts a new ChromaVue session and camera if needed.")

    func perform() async -> some IntentResult {
        await MainActor.run {
            if DataExportManager.shared.sessionFolder == nil {
                DataExportManager.shared.beginNewSession()
            }
            if !ChromaCameraManager.shared.isSessionRunning {
                ChromaCameraManager.shared.startSession()
            }
        }
        return .result(value: "ChromaVue session started")
    }
}

@available(iOS 26, *)
struct EndSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "End ChromaVue Session"
    static var description = IntentDescription("Ends the current ChromaVue session and stops the camera.")

    func perform() async -> some IntentResult {
        await MainActor.run {
            DataExportManager.shared.endSession()
            ChromaCameraManager.shared.setFlash(false)
            if ChromaCameraManager.shared.isSessionRunning {
                ChromaCameraManager.shared.stopSession()
            }
        }
        return .result(value: "ChromaVue session ended")
    }
}

@available(iOS 26, *)
struct MarkEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Mark Event in ChromaVue"
    static var description = IntentDescription("Adds an event with an optional note to the current session.")

    @Parameter(title: "Note")
    var note: String?

    func perform() async -> some IntentResult {
        await MainActor.run {
            DataExportManager.shared.appendEvent(name: "Manual Event", note: note)
        }
        return .result(value: "Event marked\(note?.isEmpty == false ? ": \(note!)" : "")")
    }
}

@available(iOS 26, *)
struct ChromaVueShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartSessionIntent(),
            phrases: [
                "Start a session in \(.applicationName)",
                "Begin a session in \(.applicationName)",
                "Start my session in \(.applicationName)"
            ],
            shortTitle: "Start Session",
            systemImageName: "play.circle"
        )
        
        AppShortcut(
            intent: EndSessionIntent(),
            phrases: [
                "End my session in \(.applicationName)",
                "Stop the session in \(.applicationName)",
                "Finish my session in \(.applicationName)"
            ],
            shortTitle: "End Session",
            systemImageName: "stop.circle"
        )
        
        AppShortcut(
            intent: MarkEventIntent(),
            phrases: [
                "Mark event in \(.applicationName)",
                "Add note in \(.applicationName)",
                "Record event in \(.applicationName)"
            ],
            shortTitle: "Mark Event",
            systemImageName: "bookmark.circle"
        )
    }
}
