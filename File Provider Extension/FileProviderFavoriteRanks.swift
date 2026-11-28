// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 zouxianxian
// SPDX-License-Identifier: GPL-3.0-or-later

import FileProvider
import Foundation

struct FileProviderFavoriteRanks {
    static let shared = Self(defaults: UserDefaults(suiteName: NCBrandOptions.shared.capabilitiesGroup) ?? .standard)

    let defaults: UserDefaults

    func rank(for metadata: tableMetadata) -> NSNumber? {
        guard metadata.directory, metadata.favorite else { return nil }
        if let stored = defaults.string(forKey: key(for: metadata)), let rank = UInt64(stored) {
            return NSNumber(value: rank)
        }
        return NSNumber(value: NSFileProviderFavoriteRankUnranked)
    }

    func set(_ rank: NSNumber?, for metadata: tableMetadata) {
        if let rank {
            defaults.set(String(rank.uint64Value), forKey: key(for: metadata))
        } else {
            defaults.removeObject(forKey: key(for: metadata))
        }
    }

    private func key(for metadata: tableMetadata) -> String {
        "FileProviderFavoriteRank.\(metadata.account.utf8.count).\(metadata.account).\(metadata.ocId)"
    }
}
