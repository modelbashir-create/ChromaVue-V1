//
//  NotificationExtensions.swift
//  ChromaVue
//
//  Notification name extensions for app-wide communication
//

import Foundation

extension Notification.Name {
    /// Posted when camera permission is denied
    static let cameraPermissionDenied = Notification.Name("cameraPermissionDenied")
    
    /// Posted when camera session starts successfully
    static let cameraSessionStarted = Notification.Name("cameraSessionStarted")
    
    /// Posted when camera session stops
    static let cameraSessionStopped = Notification.Name("cameraSessionStopped")
    
    /// Posted when torch alternation state changes
    static let torchAlternationChanged = Notification.Name("torchAlternationChanged")
    
    /// Posted when new analysis data is available
    static let analysisDataUpdated = Notification.Name("analysisDataUpdated")
    
    /// Posted when export session begins
    static let exportSessionBegan = Notification.Name("exportSessionBegan")
    
    /// Posted when export session ends
    static let exportSessionEnded = Notification.Name("exportSessionEnded")
}