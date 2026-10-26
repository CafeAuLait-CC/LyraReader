import Foundation
import LyraReaderBindings

/// Thin Swift handle for one `lyra-reader-edit::DocumentTransaction`.
///
/// The Rust object owns the revision chain, the page map, the undo/redo snapshots and
/// `session.json`; this type only turns the app's model into the FFI records and runs the one
/// call that writes a PDF (`apply`) off the main thread. The shell keeps rendering the revision
/// and keeps its annotation model.
package final class DocumentTransactionSession: @unchecked Sendable {
    /// Page writes are PDFium work. The app already serialises page commands with
    /// `pageEditBusy`; a dedicated queue keeps the transaction's file write off the main thread,
    /// as the engine's `rasterQueue` did before the move.
    private static let queue = DispatchQueue(
        label: "com.lyrareader.document-transaction", qos: .userInitiated)

    package let handle: LyraReaderDocumentTransaction
    package private(set) var canUndo: Bool
    package private(set) var canRedo: Bool

    private init(
        handle: LyraReaderDocumentTransaction,
        state: DocumentTransactionStateRecord
    ) {
        self.handle = handle
        canUndo = state.canUndo
        canRedo = state.canRedo
    }

    /// Starts or restores a session. The Rust side has already written (or read) `session.json`.
    package static func start(
        _ request: DocumentTransactionStartRecord
    ) throws -> (DocumentTransactionSession, DocumentTransactionStateRecord) {
        let handle = try startDocumentTransaction(request: request)
        let state = try handle.snapshot()
        return (DocumentTransactionSession(handle: handle, state: state), state)
    }

    package func snapshot() throws -> DocumentTransactionStateRecord {
        try handle.snapshot()
    }

    /// Captures the state that an undo of the next operation must restore, before the caller
    /// materialises annotations for it.
    @discardableResult
    package func prepare(
        label: String,
        input: DocumentTransactionInputRecord
    ) throws -> DocumentTransactionStateRecord {
        try handle.beginApply(label: label, input: input)
    }

    package func cancelPrepared() {
        try? handle.cancelApply()
    }

    /// Writes `rev-N.pdf` and adopts it. Runs on the transaction queue; the PDF stage call and
    /// the state adoption happen in one Rust call, in that order.
    package func apply(
        _ operation: PageEditOperation
    ) async throws -> DocumentTransactionApplyRecord {
        let handle = self.handle
        let record = Self.record(operation)
        return try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do {
                    continuation.resume(returning: try handle.apply(operation: record))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @discardableResult
    package func undo(input: DocumentTransactionInputRecord) throws -> DocumentTransactionStateRecord? {
        let state = try handle.undo(input: input)
        if let state {
            canUndo = state.canUndo
            canRedo = state.canRedo
        }
        return state
    }

    @discardableResult
    package func redo(input: DocumentTransactionInputRecord) throws -> DocumentTransactionStateRecord? {
        let state = try handle.redo(input: input)
        if let state {
            canUndo = state.canUndo
            canRedo = state.canRedo
        }
        return state
    }

    @discardableResult
    package func persist(
        input: DocumentTransactionInputRecord,
        revisionURL: URL,
        revisionNumber: Int,
        recoveryPath: URL
    ) throws -> DocumentTransactionStateRecord {
        let state = try handle.persist(
            input: input,
            revisionUrl: revisionURL.absoluteString,
            revisionNumber: UInt32(clamping: max(0, revisionNumber)),
            recoveryPath: recoveryPath.path)
        canUndo = state.canUndo
        canRedo = state.canRedo
        return state
    }

    /// Adopts a revision written by the content-edit path. The snapshot captured by `prepare`
    /// remains the undo entry; the content edit itself does not change the reader's marks.
    @discardableResult
    package func commitRevision(
        url: URL,
        revisionNumber: Int,
        label: String,
        input: DocumentTransactionInputRecord
    ) throws -> DocumentTransactionStateRecord {
        let state = try handle.commitRevision(
            revisionUrl: url.absoluteString,
            revisionNumber: UInt32(clamping: max(0, revisionNumber)),
            label: label,
            input: input)
        canUndo = state.canUndo
        canRedo = state.canRedo
        return state
    }

    package func close(deleteFiles: Bool) {
        try? handle.close(deleteFiles: deleteFiles)
    }

    private static func record(_ operation: PageEditOperation) -> PageOperationRecord {
        switch operation {
        case .rotate(let pages, let quarterTurns):
            return .rotate(
                pages: pages.map { UInt32(clamping: max(0, $0)) },
                quarterTurns: Int32(clamping: quarterTurns))
        case .setRotation(let pages, let quarterTurns):
            return .setRotation(
                pages: pages.map { UInt32(clamping: max(0, $0)) },
                quarterTurns: quarterTurns.map { UInt32(clamping: max(0, $0)) })
        case .delete(let pages):
            return .delete(pages: pages.map { UInt32(clamping: max(0, $0)) })
        case .move(let pages, let destination):
            return .move(
                pages: pages.map { UInt32(clamping: max(0, $0)) },
                destination: UInt32(clamping: max(0, destination)))
        case .insertBlank(let index):
            return .insertBlank(index: UInt32(clamping: max(0, index)))
        }
    }
}

/// The JSON fragments the transaction stores are the app's own model encoding: the transaction
/// never invents a field or reinterprets a kind. Encoding and decoding therefore use the shell's
/// `Codable` types unchanged.
package enum DocumentTransactionJSON {
    package static func string<T: Encodable>(_ value: T) throws -> String {
        // The app's model is always encodable (it is how the annotation cache is written); a
        // failure is still propagated instead of dropping the reader's marks into an empty
        // snapshot.
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    package static func value<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(string.utf8))
    }
}
