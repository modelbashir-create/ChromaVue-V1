//
//  SessionEntity.swift
//  ChromaVue
//
//  Created by Mohamed Elbashir on 11/2/25.
//


import SwiftData
import Foundation

@Model final class SessionEntity {
    @Attribute(.unique) var id: String
    var startedAt: Date
    var endedAt: Date?
    var folderPath: String
    var frameCount: Int = 0
    var eventCount: Int = 0
    var note: String?
    
    @Relationship(deleteRule: .cascade, inverse: \EventEntity.session) var events: [EventEntity] = []
    
    init(id: String, startedAt: Date, folderPath: String) {
        self.id = id
        self.startedAt = startedAt
        self.folderPath = folderPath
    }
}
