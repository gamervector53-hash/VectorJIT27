//
//  PairingFileStore.swift
//  StikDebug
//
//  VectorJIT27 keeps the imported MobileDevice pairing record separate from the
//  RPPairing identity used by the iOS 17.4+ tunnel protocol.
//

import Foundation
import UniformTypeIdentifiers
import idevice

enum PairingRecordKind: Equatable {
    case remote
    case classic
}

enum PairingFileStore {
    static let remoteHostName = "StikDebug"
    static let supportedContentTypes: [UTType] = [
        UTType(filenameExtension: "mobiledevicepairing", conformingTo: .data)!,
        UTType(filenameExtension: "mobiledevicepair", conformingTo: .data)!,
        .propertyList
    ]

    private static let remoteFileName = "rp_pairing_file.plist"
    private static let classicFileName = "pairingFile.plist"
    private static let archivedClassicFileName = "classic_pairing_file.plist"

    static var url: URL {
        directoryURL.appendingPathComponent(remoteFileName)
    }

    static var classicPairingURL: URL {
        directoryURL.appendingPathComponent(archivedClassicFileName)
    }

    @discardableResult
    static func prepareURL(fileManager: FileManager = .default) -> URL {
        let destination = url
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        if isRemotePairingRecord(at: destination, fileManager: fileManager) {
            protectPairingFile(at: destination, fileManager: fileManager)
            return destination
        }

        for candidate in migrationCandidates where
            candidate.standardizedFileURL != destination.standardizedFileURL &&
            fileManager.fileExists(atPath: candidate.path)
        {
            if isRemotePairingRecord(at: candidate, fileManager: fileManager) {
                try? replaceItem(at: destination, with: candidate, fileManager: fileManager)
                protectPairingFile(at: destination, fileManager: fileManager)
                return destination
            }
            archiveClassicCandidate(candidate, fileManager: fileManager)
        }

        return destination
    }

    static func ensureRemotePairingRecord(
        hostname: String = remoteHostName,
        fileManager: FileManager = .default
    ) throws -> URL {
        let destination = prepareURL(fileManager: fileManager)
        if isRemotePairingRecord(at: destination, fileManager: fileManager) {
            return destination
        }

        if fileManager.fileExists(atPath: destination.path) {
            quarantineInvalidRemoteRecord(at: destination, fileManager: fileManager)
        }

        return try generateRemotePairingRecord(hostname: hostname, fileManager: fileManager)
    }

    @discardableResult
    static func regenerateRemotePairingRecord(
        hostname: String = remoteHostName,
        fileManager: FileManager = .default
    ) throws -> URL {
        let destination = prepareURL(fileManager: fileManager)
        if fileManager.fileExists(atPath: destination.path) {
            quarantineInvalidRemoteRecord(at: destination, fileManager: fileManager)
        }
        return try generateRemotePairingRecord(hostname: hostname, fileManager: fileManager)
    }

    static func persistRemotePairingFile(
        _ pairingFile: OpaquePointer,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let temporary = directoryURL.appendingPathComponent(".remote-pairing-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }

        let writeError = temporary.path.withCString {
            rp_pairing_file_write(pairingFile, $0)
        }
        if let writeError {
            throw consumeFFIError(writeError, fallback: "Failed to persist the remote pairing identity.")
        }

        guard isRemotePairingRecord(at: temporary, fileManager: fileManager) else {
            throw storeError(
                code: 1003,
                message: "The remote pairing identity produced by idevice was incomplete."
            )
        }

        try replaceItem(at: url, with: temporary, fileManager: fileManager)
        protectPairingFile(at: url, fileManager: fileManager)
    }

    static func isRemotePairingRecord(
        at candidateURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard fileManager.fileExists(atPath: candidateURL.path),
              let data = try? Data(contentsOf: candidateURL) else {
            return false
        }
        return isRemotePairingRecord(data: data)
    }

    static func isRemotePairingRecord(data: Data) -> Bool {
        guard
            let object = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ),
            let dictionary = object as? [String: Any],
            let publicKey = dictionary["public_key"] as? Data,
            publicKey.count == 32,
            let privateKey = dictionary["private_key"] as? Data,
            privateKey.count == 32,
            let identifier = dictionary["identifier"] as? String,
            !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }

        if let altIRK = dictionary["alt_irk"] as? Data, altIRK.count != 16 {
            return false
        }
        return true
    }

    @discardableResult
    static func replace(
        with sourceURL: URL,
        fileManager: FileManager = .default
    ) throws -> PairingRecordKind {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try Data(contentsOf: sourceURL)

        if isRemotePairingRecord(data: data) {
            try replaceItem(at: url, with: sourceURL, fileManager: fileManager)
            protectPairingFile(at: url, fileManager: fileManager)

            if sourceURL.standardizedFileURL != documentsRemoteURL.standardizedFileURL {
                try? replaceItem(at: documentsRemoteURL, with: sourceURL, fileManager: fileManager)
                protectPairingFile(at: documentsRemoteURL, fileManager: fileManager)
            }
            return .remote
        }

        try replaceItem(at: classicPairingURL, with: sourceURL, fileManager: fileManager)
        protectPairingFile(at: classicPairingURL, fileManager: fileManager)

        if sourceURL.standardizedFileURL != documentsClassicURL.standardizedFileURL {
            try? replaceItem(at: documentsClassicURL, with: sourceURL, fileManager: fileManager)
            protectPairingFile(at: documentsClassicURL, fileManager: fileManager)
        }

        _ = try ensureRemotePairingRecord(hostname: remoteHostName, fileManager: fileManager)
        return .classic
    }

    @discardableResult
    static func importFromPicker(
        _ sourceURL: URL,
        fileManager: FileManager = .default
    ) throws -> PairingRecordKind {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        return try replace(with: sourceURL, fileManager: fileManager)
    }

    static func remove(fileManager: FileManager = .default) throws {
        for candidate in [
            url,
            classicPairingURL,
            documentsRemoteURL,
            documentsClassicURL,
            legacyApplicationSupportURL
        ] where fileManager.fileExists(atPath: candidate.path) {
            try fileManager.removeItem(at: candidate)
        }
    }

    private static func generateRemotePairingRecord(
        hostname: String,
        fileManager: FileManager
    ) throws -> URL {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var pairingFile: OpaquePointer?
        let generationError = hostname.withCString {
            rp_pairing_file_generate($0, &pairingFile)
        }
        if let generationError {
            throw consumeFFIError(generationError, fallback: "Failed to generate a remote pairing identity.")
        }

        guard let pairingFile else {
            throw storeError(code: 1001, message: "idevice did not return a remote pairing identity.")
        }
        defer { rp_pairing_file_free(pairingFile) }

        try persistRemotePairingFile(pairingFile, fileManager: fileManager)
        return url
    }

    private static var directoryURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pairing", isDirectory: true)
    }

    private static var documentsClassicURL: URL {
        URL.documentsDirectory.appendingPathComponent(classicFileName)
    }

    private static var documentsRemoteURL: URL {
        URL.documentsDirectory.appendingPathComponent(remoteFileName)
    }

    private static var legacyApplicationSupportURL: URL {
        directoryURL.appendingPathComponent(classicFileName)
    }

    private static var migrationCandidates: [URL] {
        [
            documentsRemoteURL,
            legacyApplicationSupportURL,
            documentsClassicURL
        ]
    }

    private static func archiveClassicCandidate(
        _ candidate: URL,
        fileManager: FileManager
    ) {
        guard candidate.standardizedFileURL != classicPairingURL.standardizedFileURL,
              !fileManager.fileExists(atPath: classicPairingURL.path) else {
            return
        }

        try? replaceItem(at: classicPairingURL, with: candidate, fileManager: fileManager)
        protectPairingFile(at: classicPairingURL, fileManager: fileManager)
    }

    private static func quarantineInvalidRemoteRecord(
        at candidate: URL,
        fileManager: FileManager
    ) {
        guard fileManager.fileExists(atPath: candidate.path) else { return }

        let quarantineDirectory = directoryURL.appendingPathComponent("Invalid", isDirectory: true)
        try? fileManager.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let destination = quarantineDirectory
            .appendingPathComponent("rp_pairing_file-\(stamp)-\(UUID().uuidString).plist")

        do {
            try fileManager.moveItem(at: candidate, to: destination)
            protectPairingFile(at: destination, fileManager: fileManager)
        } catch {
            try? fileManager.removeItem(at: candidate)
        }
    }

    private static func replaceItem(
        at destination: URL,
        with source: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if source.standardizedFileURL == destination.standardizedFileURL {
            return
        }

        let temporary = destination
            .deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + ".tmp")
        try? fileManager.removeItem(at: temporary)
        try fileManager.copyItem(at: source, to: temporary)
        defer { try? fileManager.removeItem(at: temporary) }

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    private static func protectPairingFile(
        at candidate: URL,
        fileManager: FileManager
    ) {
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: candidate.path)
    }

    private static func consumeFFIError(
        _ ffiError: UnsafeMutablePointer<IdeviceFfiError>,
        fallback: String
    ) -> NSError {
        let message: String
        if let pointer = ffiError.pointee.message,
           let decoded = String(validatingUTF8: pointer) {
            message = decoded
        } else {
            message = fallback
        }
        let code = Int(ffiError.pointee.code)
        idevice_error_free(ffiError)
        return storeError(code: code, message: message)
    }

    private static func storeError(code: Int, message: String) -> NSError {
        NSError(
            domain: "VectorJIT27.PairingFileStore",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
