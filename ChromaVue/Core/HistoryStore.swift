//
//  HistoryStore.swift
//  ChromaVue
//
//  Clean version — single HistoryStore + SwiftData models with unique names.
//  Drop this into ChromaVue/ChromaVue/Core/ and remove any duplicates of this file.
//
//  Requires: iOS 17+ (SwiftData)
//
import Foundation
import SwiftData
import Combine

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    private(set) var context: ModelContext?

    func configure(with container: ModelContainer) {
        self.context = container.mainContext
    }

    func beginSession(id: String, folderPath: String) {
        guard let context = context else { return }

        let session = HistorySessionEntity(id: id, folderPath: folderPath)
        session.startedAt = Date()
        session.frameCount = 0
        session.eventCount = 0

        context.insert(session)
        try? context.save()
    }

    func endSession(id: String) {
        guard let context = context else { return }

        let request = FetchDescriptor<HistorySessionEntity>(predicate: #Predicate { $0.id == id })
        guard let session = try? context.fetch(request).first else { return }

        session.endedAt = Date()
        try? context.save()
    }

    func appendEvent(sessionID: String, timestampMS: Int64, name: String, note: String?) {
        guard let context = context else { return }

        let request = FetchDescriptor<HistorySessionEntity>(predicate: #Predicate { $0.id == sessionID })
        guard let session = try? context.fetch(request).first else { return }

        let event = HistoryEventEntity()
        event.timestampMS = timestampMS
        event.name = name
        event.note = note
        event.session = session

        context.insert(event)

        session.eventCount += 1

        try? context.save()
    }
}

// MARK: - Model Entities (renamed to avoid conflicts elsewhere)

@Model
final class HistorySessionEntity {
    @Attribute(.unique) var id: String
    var folderPath: String

    var startedAt: Date?
    var endedAt: Date?

    var frameCount: Int
    var eventCount: Int

    @Relationship(deleteRule: .cascade) var events: [HistoryEventEntity]

    init(id: String, folderPath: String) {
        self.id = id
        self.folderPath = folderPath
        self.frameCount = 0
        self.eventCount = 0
        self.events = []
    }
}

@Model
final class HistoryEventEntity {
    var timestampMS: Int64 = 0
    var name: String = ""
    var note: String?

    @Relationship(inverse: \HistorySessionEntity.events) var session: HistorySessionEntity?

    init() {}
}
