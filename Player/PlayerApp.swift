//
//  PlayerApp.swift
//  Player
//
//  Created by Simon Loffler on 30/10/2025.
//

import SwiftUI
import CoreData

@main
struct PlayerApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
