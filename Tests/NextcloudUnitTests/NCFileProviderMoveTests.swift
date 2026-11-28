// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2026 zouxianxian
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import RealmSwift
import Testing
@testable import Nextcloud

@Suite("Moving folders in Files")
struct NCFileProviderMoveTests {
    private func item(_ name: String, parent: String, directory: Bool = false, account: String = "alice") -> tableMetadata {
        let item = tableMetadata()
        item.ocId = UUID().uuidString
        item.account = account
        item.fileName = name
        item.fileNameView = name
        item.serverUrl = parent
        item.serverUrlFileName = parent + "/" + name
        item.directory = directory
        return item
    }

    private func folderRecord(_ item: tableMetadata) -> tableDirectory {
        let record = tableDirectory()
        record.ocId = item.ocId
        record.account = item.account
        record.serverUrl = item.serverUrlFileName
        record.offline = true
        return record
    }

    @Test("Only an unlocked non-root folder with move permission can be reparented")
    func folderPermissions() {
        let folder = item("Trip", parent: "/alice", directory: true)
        folder.permissions = "RGDNVCK"
        #expect(NCMetadataPermissions.canReparentDirectory(folder, isRoot: false))
        #expect(!NCMetadataPermissions.canReparentDirectory(folder, isRoot: true))
        folder.lock = true
        #expect(!NCMetadataPermissions.canReparentDirectory(folder, isRoot: false))
        folder.lock = false
        folder.permissions = "RG"
        #expect(!NCMetadataPermissions.canReparentDirectory(folder, isRoot: false))
    }

    @Test("Reparenting updates the moved subtree and preserves other cached items", arguments: ["Trip", "New trip"])
    func moveSubtree(destinationName: String) throws {
        let realm = try Realm(configuration: .init(inMemoryIdentifier: UUID().uuidString,
                                                  objectTypes: [tableDirectory.self, tableMetadata.self, tableMetadataTag.self, NCKeyValue.self]))
        let home = "https://example.com/dav/files/alice"
        let source = item("Trip", parent: home, directory: true)
        source.path = "/dav/files/alice/"
        let nested = item("Day 1", parent: source.serverUrlFileName, directory: true)
        let photo = item("photo.jpg", parent: nested.serverUrlFileName)
        photo.path = "/dav/files/alice/Trip/Day 1/"
        photo.fileNameView = "pending name.jpg"
        let sibling = item("Trip 2", parent: home, directory: true)
        let neighbor = item("other.jpg", parent: sibling.serverUrlFileName)
        let otherAccount = item("other.jpg", parent: nested.serverUrlFileName, account: "bob")
        let sourceFolder = folderRecord(source)
        let nestedFolder = folderRecord(nested)
        let siblingFolder = folderRecord(sibling)
        let destination = home + "/Archive"
        let newPath = destination + "/" + destinationName
        try realm.write {
            realm.add([source, nested, photo, sibling, neighbor, otherAccount])
            realm.add([sourceFolder, nestedFolder, siblingFolder])
        }
        try realm.write {
            NCManageDatabase.moveDirectory(in: realm, metadata: source, toParentURL: destination, newName: destinationName)
        }

        #expect(source.serverUrl == destination)
        #expect(source.fileName == destinationName)
        #expect(source.fileNameView == destinationName)
        #expect(source.serverUrlFileName == newPath)
        #expect(source.path == "/dav/files/alice/Archive/")
        #expect(sourceFolder.serverUrl == newPath)
        #expect(nested.serverUrl == newPath)
        #expect(nested.serverUrlFileName == newPath + "/Day 1")
        #expect(nestedFolder.serverUrl == newPath + "/Day 1")
        #expect(nestedFolder.offline)
        #expect(photo.serverUrl == newPath + "/Day 1")
        #expect(photo.serverUrlFileName == newPath + "/Day 1/photo.jpg")
        #expect(photo.fileNameView == "pending name.jpg")
        #expect(photo.path == "/dav/files/alice/Archive/" + destinationName + "/Day 1/")
        #expect(siblingFolder.serverUrl == home + "/Trip 2")
        #expect(neighbor.serverUrl == home + "/Trip 2")
        #expect(otherAccount.serverUrl == home + "/Trip/Day 1")
    }
}
