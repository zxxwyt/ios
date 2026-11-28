// SPDX-FileCopyrightText: Nextcloud GmbH
// SPDX-FileCopyrightText: 2018 Marino Faggiana
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import FileProvider
import RealmSwift
import NextcloudKit

class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    var enumeratedItemIdentifier: NSFileProviderItemIdentifier
    private let session: NCSession.Session
    var serverUrl: String?
    var anchor: UInt64 = 0
    var readCapabilities: Bool = false

    // X-NC-PAGINATE
#if DEBUG
    var paginateCount: Int = 50
#else
    var paginateCount: Int = 200
#endif
    // X-NC-PAGINATE

    var paginateToken: String?
    var paginatedTotal: Int = 0

    struct PageInfo {
        let page: Int
        let items: Int
    }
    var paginateItems: [PageInfo] = []

    init(enumeratedItemIdentifier: NSFileProviderItemIdentifier, session: NCSession.Session) {
        self.enumeratedItemIdentifier = enumeratedItemIdentifier
        self.session = session
        super.init()

        if enumeratedItemIdentifier == .rootContainer {
            self.serverUrl = NCUtilityFileSystem().getHomeServer(session: session)
        } else {
            if let metadata = fileProviderUtility().getTableMetadataFromItemIdentifier(enumeratedItemIdentifier),
               metadata.account == session.account,
               let directorySource = NCManageDatabase.shared.getTableDirectory(predicate: NSPredicate(format: "account == %@ AND serverUrl == %@", metadata.account, metadata.serverUrl)) {
                serverUrl = NCUtilityFileSystem().createServerUrl(serverUrl: directorySource.serverUrl, fileName: metadata.fileName)
            }
        }
    }

    func invalidate() { }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        Task {
            var items: [NSFileProviderItemProtocol] = []

            // WorkingSet
            if enumeratedItemIdentifier == .workingSet {
                var itemIdentifierMetadata: [NSFileProviderItemIdentifier: tableMetadata] = [:]

                // Tags
                if let tags = await NCManageDatabase.shared.getTagsAsync(predicate: NSPredicate(format: "account == %@", session.account)) {
                    for tag in tags {
                        guard let metadata = await NCManageDatabase.shared.getMetadataFromOcIdAsync(tag.ocId), metadata.account == session.account else {
                            continue
                        }
                        itemIdentifierMetadata[fileProviderUtility().getItemIdentifier(metadata: metadata)] = metadata
                    }
                }

                // Favorite
                let predicate = NSPredicate(format: "account == %@ AND directory == true AND favorite == true", session.account)
                guard let favorites = await NCManageDatabase.shared.getMetadatasAsync(predicate: predicate, limit: nil) else {
                    observer.finishEnumeratingWithError(NSFileProviderError(.serverUnreachable))
                    return
                }
                for metadata in favorites {
                    itemIdentifierMetadata[fileProviderUtility().getItemIdentifier(metadata: metadata)] = metadata
                }

                // Create items
                for (_, metadata) in itemIdentifierMetadata {
                    if let parentItemIdentifier = await fileProviderUtility().getParentItemIdentifierAsync(metadata: metadata) {
                        let item = FileProviderItem(metadata: metadata, parentItemIdentifier: parentItemIdentifier)
                        items.append(item)
                    }
                }
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)

            } else {
                guard let serverUrl = serverUrl else {
                    observer.finishEnumerating(upTo: nil)
                    return
                }
                var pageNumber = 0
                if let stringPage = String(data: page.rawValue, encoding: .utf8),
                   let intPage = Int(stringPage) {
                    pageNumber = intPage
                }

                let (items, ncPaginated) = await fetchItemsForPage(session: session,
                                                                   serverUrl: serverUrl,
                                                                   pageNumber: pageNumber)
                observer.didEnumerate(items)

                if !items.isEmpty,
                   ncPaginated {
                    pageNumber += 1
                    observer.finishEnumerating(upTo: NSFileProviderPage(Data("\(pageNumber)".utf8)))
                } else {
                    observer.finishEnumerating(upTo: nil)
                }
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        var itemsDelete: [NSFileProviderItemIdentifier] = []
        var itemsUpdate: [FileProviderItem] = []

        if enumeratedItemIdentifier == .workingSet {
            let batch = FileProviderData.shared.withWorkingSet(account: session.account) { $0.changes(from: anchor) }
            guard let batch else {
                observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                return
            }
            observer.didDeleteItems(withIdentifiers: batch.deletions)
            observer.didUpdate(batch.updates)
            observer.finishEnumeratingChanges(upTo: batch.anchor, moreComing: false)
            return
        }

        for (itemIdentifier, _) in FileProviderData.shared.fileProviderSignalDeleteContainerItemIdentifier {
            itemsDelete.append(itemIdentifier)
        }
        FileProviderData.shared.fileProviderSignalDeleteContainerItemIdentifier.removeAll()
        for (_, item) in FileProviderData.shared.fileProviderSignalUpdateContainerItem {
            itemsUpdate.append(item)
        }
        FileProviderData.shared.fileProviderSignalUpdateContainerItem.removeAll()

        observer.didDeleteItems(withIdentifiers: itemsDelete)
        observer.didUpdate(itemsUpdate)

        let data = Data("\(self.anchor)".utf8)
        observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(data), moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        if enumeratedItemIdentifier == .workingSet {
            completionHandler(FileProviderData.shared.withWorkingSet(account: session.account) { $0.currentSyncAnchor() })
            return
        }
        let data = Data("\(self.anchor)".utf8)
        completionHandler(NSFileProviderSyncAnchor(data))
    }

    func fetchItemsForPage(session: NCSession.Session, serverUrl: String, pageNumber: Int) async -> (items: [NSFileProviderItem], ncPaginate: Bool) {
        let fileProviderUtility = fileProviderUtility()
        let createMetadata = NCManageDatabaseCreateMetadata()

        func getItemsFrom(metadatas: [tableMetadata], addOnDB: Bool) async -> [NSFileProviderItem] {
            var items: [NSFileProviderItem] = []

            // Get parentItemIdentifier
            guard let directory = await NCManageDatabase.shared.getTableDirectoryAsync(predicate: NSPredicate(format: "account == %@ AND serverUrl == %@", session.account, serverUrl)),
                  let parentItemIdentifier = await fileProviderUtility.getParentItemIdentifierAsync(
                    session: session,
                    directory: directory
                  ) else {
                return ([])
            }

            // make items
            for metadata in metadatas {
                // NO E2EE OR NO VIDEO PART OF LIVE PHOTO
                if metadata.e2eEncrypted || (metadata.classFile == NKTypeClassFile.video.rawValue && !metadata.livePhotoFile.isEmpty) {
                    continue
                }

                if addOnDB {
                    if metadata.directory {
                        await NCManageDatabase.shared.createDirectory(metadata: metadata)
                    }
                    await NCManageDatabase.shared.addMetadataAsync(metadata)
                }

                autoreleasepool {
                    let item = FileProviderItem(metadata: metadata, parentItemIdentifier: parentItemIdentifier)
                    items.append(item)
                }
            }
            return items
        }

        // Request pagination
        //
        let showHiddenFiles = NCPreferences().getShowHiddenFiles(account: session.account)
        var paginateOffset = 0
        if pageNumber > 0 {
           paginateOffset = getOffset(for: pageNumber)
        } else {
            // A listing restarting at page 0 must not reuse the cached result or the page counts of an earlier one.
            paginateToken = nil
            paginatedTotal = 0
            paginateItems.removeAll()
        }
        let optionsPaginate = await FileProviderData.shared.isPaginatedAvailabile(serverUrl: serverUrl, session: session)
        let options = NKRequestOptions(paginate: optionsPaginate,
                                       paginateToken: self.paginateToken,
                                       paginateOffset: paginateOffset,
                                       paginateCount: paginateCount)

        // Read folder metadata
        //
        let resultsRead = await NextcloudKit.shared.readFileOrFolderAsync(
            serverUrlFileName: serverUrl,
            depth: "1",
            showHiddenFiles: showHiddenFiles,
            account: session.account,
            options: options
        )

        print("PAGINATE OFFSET: \(paginateOffset) COUNT: \(resultsRead.files?.count ?? 0) PAGE NUMBER: \(pageNumber) TOTAL: \(self.paginatedTotal) SERVERURL: \(serverUrl)")

        // Header for paginate
        //
        var ncPaginate: Bool = false
        if let headers = resultsRead.responseData?.response?.allHeaderFields as? [String: String] {
            let normalizedHeaders = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
            ncPaginate = Bool(normalizedHeaders["x-nc-paginate"] ?? "false") ?? false
            // Pages served from the server's cache may omit the token; it stays valid for the whole listing.
            self.paginateToken = normalizedHeaders["x-nc-paginate-token"] ?? self.paginateToken
            if let totalString = normalizedHeaders["x-nc-paginate-total"],
               let total = Int(totalString) {
                self.paginatedTotal = total
            }
        }

        if resultsRead.error == .success, let files = resultsRead.files {
            let (metadataFolder, metadatas) = await createMetadata.convertFilesToMetadatasAsync(files, serverUrlMetadataFolder: pageNumber == 0 ? serverUrl : nil)
            self.paginateItems.append(PageInfo(page: pageNumber, items: metadatas.count))

            if pageNumber == 0 {
                await NCManageDatabase.shared.deleteMetadataAsync(predicate: NSPredicate(format: "account == %@ AND serverUrl == %@ AND status == %d", session.account, serverUrl, NCGlobal.shared.metadataStatusNormal))
                await NCManageDatabase.shared.createDirectory(metadata: metadataFolder)
            }

            let items = await getItemsFrom(metadatas: Array(metadatas), addOnDB: true)
            if self.totalItems() >= self.paginatedTotal {
                ncPaginate = false
            }
            return (items, ncPaginate)
        } else {
            let predicate = NSPredicate(
                format: """
                account == %@ AND
                serverUrl == %@ AND
                status == %d AND
                (
                    classFile != 'video' OR
                    (classFile == 'video' AND livePhotoFile == '')
                )
                """,
                session.account,
                serverUrl,
                NCGlobal.shared.metadataStatusNormal
            )

            guard let metadatas = await NCManageDatabase.shared.getResultsMetadatasAsync(predicate: predicate) else {
                return ([], false)
            }
            let items = await getItemsFrom(metadatas: Array(metadatas), addOnDB: false)
            return (items, false)
        }
    }

    func getOffset(for page: Int) -> Int {
        let items = paginateItems
                .filter { $0.page < page }
                .map { $0.items }
                .reduce(0, +)
        // + 1 for the next
        return items == 0 ? 0 : items + 1
    }

    func totalItems() -> Int {
        let total = paginateItems.map { $0.items }.reduce(0, +)
        // + 1 for the first "root directory"
        return total == 0 ? 0 : total + 1
    }
}
