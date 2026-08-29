//
//  BackupFileDocument.swift
//  Kue
//
//  Kue 2.0 Phase 12 — docs/28. The `.fileExporter`/`.fileImporter` glue `SettingsView`'s
//  Backup & Restore section uses. `.fileExporter` does the atomic write itself (a native
//  platform guarantee, not hand-rolled temp-file-then-rename logic) and presents the system
//  share/save sheet; `.kueBackup`'s `UTTypeTagSpecification` (Kue/Info.plist) is what makes
//  Restore's `.fileImporter` filter to `.kuebackup` files and lets Files/AirDrop offer
//  "Open in Kue" for one.
//

import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static var kueBackup: UTType {
        UTType(exportedAs: "com.kanishkgandecha.Kue.backup", conformingTo: .json)
    }
}

struct BackupFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.kueBackup] }
    static var writableContentTypes: [UTType] { [.kueBackup] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
