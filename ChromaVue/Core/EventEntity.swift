//
//  EventEntity.swift
//  ChromaVue
//
//  Created by Mohamed Elbashir on 11/2/25.
//


import SwiftData
import Foundation

@Model final class EventEntity {
    var timestampMS: Int64
    var name: String
    var note: String?
    @Relationship var session: SessionEntity?
    
    init(timestampMS: Int64, name: String, note: String? = nil) {
        self.timestampMS = timestampMS
        self.name = name
        self.note = note
    }
}
