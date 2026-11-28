// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 zouxianxian
// SPDX-License-Identifier: GPL-3.0-or-later

import FileProvider
import Testing
@testable import Nextcloud

@Suite("Files working-set changes")
struct FileProviderWorkingSetChangesTests {
    @Test("Cold starts and other accounts require a full enumeration")
    func unknownAnchor() {
        var old = FileProviderWorkingSetChanges<String>()
        var fresh = FileProviderWorkingSetChanges<String>()
        let initial = old.currentSyncAnchor()
        #expect(fresh.changes(from: initial) == nil)
        #expect(old.changes(from: initial)?.updates.isEmpty == true)
    }

    @Test("Full enumeration establishes a new baseline after pending changes")
    func fullEnumerationBaseline() throws {
        var buffer = FileProviderWorkingSetChanges<String>()
        let previous = buffer.currentSyncAnchor()
        let folder = NSFileProviderItemIdentifier("folder")
        buffer.record("favorite", for: folder)
        let baseline = buffer.currentSyncAnchor()
        #expect(previous != baseline)
        buffer.record("reordered", for: folder)
        let changed = buffer.changes(from: baseline)
        let batch = try #require(changed)
        #expect(batch.updates == ["reordered"])
        #expect(batch.deletions.isEmpty)
    }

    @Test("The latest operation per item is delivered, then acknowledged by a new anchor")
    func coalescedChanges() throws {
        let first = NSFileProviderItemIdentifier("first")
        let second = NSFileProviderItemIdentifier("second")
        var buffer = FileProviderWorkingSetChanges<String>()
        let initial = buffer.currentSyncAnchor()
        buffer.record("old", for: first)
        buffer.record(nil, for: first)
        buffer.record("new", for: second)
        buffer.record("newer", for: second)
        let changes = buffer.changes(from: initial)
        let batch = try #require(changes)
        #expect(batch.updates == ["newer"])
        #expect(batch.deletions == [first])
        #expect(batch.anchor != initial)
        #expect(buffer.changes(from: initial) == nil)
        let unchanged = buffer.changes(from: batch.anchor)
        let empty = try #require(unchanged)
        #expect(empty.updates.isEmpty && empty.deletions.isEmpty)

        buffer.record(nil, for: second)
        buffer.record("restored", for: second)
        let changed = buffer.changes(from: batch.anchor)
        let next = try #require(changed)
        #expect(next.updates == ["restored"])
        #expect(next.deletions.isEmpty)
    }
}
