// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 zouxianxian
// SPDX-License-Identifier: GPL-3.0-or-later

import FileProvider
import Foundation

struct FileProviderWorkingSetChanges<Item> {
    typealias Batch = (updates: [Item], deletions: [NSFileProviderItemIdentifier], anchor: NSFileProviderSyncAnchor)

    private var anchor = NSFileProviderSyncAnchor(Data(UUID().uuidString.utf8))
    private var previousAnchor: NSFileProviderSyncAnchor
    private var updates: [NSFileProviderItemIdentifier: Item] = [:]
    private var deletions: Set<NSFileProviderItemIdentifier> = []

    init() {
        previousAnchor = anchor
    }

    // A full enumeration already includes all changes through this anchor.
    mutating func currentSyncAnchor() -> NSFileProviderSyncAnchor {
        updates.removeAll()
        deletions.removeAll()
        previousAnchor = anchor
        return anchor
    }

    mutating func record(_ item: Item?, for identifier: NSFileProviderItemIdentifier) {
        if let item {
            updates[identifier] = item
            deletions.remove(identifier)
        } else {
            updates.removeValue(forKey: identifier)
            deletions.insert(identifier)
        }
        anchor = NSFileProviderSyncAnchor(Data(UUID().uuidString.utf8))
    }

    mutating func changes(from known: NSFileProviderSyncAnchor) -> Batch? {
        if known == anchor { return ([], [], currentSyncAnchor()) }
        guard known == previousAnchor else { return nil }

        let updatedItems = Array(updates.values)
        let deletedItems = Array(deletions)
        return (updatedItems, deletedItems, currentSyncAnchor())
    }
}
