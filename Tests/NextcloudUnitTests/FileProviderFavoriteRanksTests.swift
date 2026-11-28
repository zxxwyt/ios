// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 zouxianxian
// SPDX-License-Identifier: GPL-3.0-or-later

import FileProvider
import Foundation
import Testing
@testable import Nextcloud

@Suite("Files favorite ranks")
struct FileProviderFavoriteRanksTests {
    private func folder(account: String) -> tableMetadata {
        let folder = tableMetadata()
        folder.account = account
        folder.ocId = "12345oc"
        folder.directory = true
        folder.favorite = true
        return folder
    }

    @Test("Existing Nextcloud favorites are visible before a working-set enumeration")
    func unrankedFavorites() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ranks = FileProviderFavoriteRanks(defaults: defaults)
        let item = folder(account: "first")

        #expect(ranks.rank(for: item)?.uint64Value == NSFileProviderFavoriteRankUnranked)
        item.directory = false
        #expect(ranks.rank(for: item) == nil)
        item.directory = true
        item.favorite = false
        #expect(ranks.rank(for: item) == nil)
    }

    @Test("The Files order survives reopening and reordering, and belongs to one account")
    func persistedOrder() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ranks = FileProviderFavoriteRanks(defaults: defaults)
        let first = folder(account: "first")
        let second = folder(account: "second")
        let large = NSNumber(value: UInt64.max - 1)
        ranks.set(large, for: first)
        let reopened = FileProviderFavoriteRanks(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(reopened.rank(for: first) == large)
        #expect(reopened.rank(for: second)?.uint64Value == NSFileProviderFavoriteRankUnranked)

        reopened.set(12, for: first)
        #expect(ranks.rank(for: first) == 12)
        first.favorite = false
        #expect(ranks.rank(for: first) == nil)
        ranks.set(nil, for: first)
        first.favorite = true
        #expect(reopened.rank(for: first)?.uint64Value == NSFileProviderFavoriteRankUnranked)
    }
}
