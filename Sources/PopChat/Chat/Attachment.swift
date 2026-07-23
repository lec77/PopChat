import AppKit
import PDFKit
import CoreXLSX
import UniformTypeIdentifiers

/// A file attached to a draft message. Text-type content is inlined into the user
/// message; images become image_url content parts.
struct Attachment: Identifiable, Equatable, Codable {
    enum Content: Equatable, Codable {
        case text(String)
        case image(dataURL: String)
        /// A PDF keeps BOTH forms: capability is a property of the provider+model
        /// picked at SEND time (the user can switch after dropping the file), so
        /// the choice between the raw bytes and the extracted text has to wait
        /// until `ChatStore.wireContent`. Raw retention is capped
        /// (`AttachmentLoader.maxDirectPDFBytes`) so conversation JSON can't
        /// balloon to the 25 MB file limit; over the cap it degrades to `.text`
        /// with a visible note.
        case pdf(dataURL: String, extractedText: String)
    }

    enum NoteKind: Equatable, Codable {
        /// Routine processing info (e.g. image downscaling) — shown quietly, never alarming.
        case info
        /// Lossy or suspicious extraction ("truncated at 200 rows", "likely scanned") —
        /// shown prominently and passed to the model with the file.
        case warning
    }

    var id = UUID()
    let filename: String
    let content: Content
    let note: String?
    var noteKind: NoteKind = .warning
}

struct AttachError: Error {
    let message: String
}

/// Converts files/images into Attachments. SIMPLE handling only — complicated cases
/// produce explicit errors or warning notes, never silent degradation.
enum AttachmentLoader {
    static let maxFileBytes = 25 * 1024 * 1024
    static let maxTextChars = 100_000
    static let maxRowsPerSheet = 200
    static let maxPDFPages = 100
    static let maxImageEdge = 2048.0
    /// Raw-PDF retention cap for direct pass-through — parity with the image
    /// cap, and the ceiling on what one attachment adds to a conversation file.
    static let maxDirectPDFBytes = 10 * 1024 * 1024

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "bmp"]
    private static let wordExtensions: Set<String> = ["docx", "doc", "rtf", "rtfd", "odt"]
    private static let sheetExtensions: Set<String> = ["xlsx", "xlsm"]

    // MARK: - Entry points

    static func load(url: URL) async -> Result<Attachment, AttachError> {
        let filename = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return .failure(AttachError(message: "\(filename): couldn't read file."))
        }
        guard size <= maxFileBytes else {
            return .failure(AttachError(message: "\(filename): too large (\(size / 1_048_576) MB — limit is \(maxFileBytes / 1_048_576) MB)."))
        }

        do {
            if imageExtensions.contains(ext) {
                guard let image = NSImage(contentsOf: url) else {
                    throw AttachError(message: "\(filename): couldn't decode image.")
                }
                return .success(try encode(image: image, filename: filename))
            }
            if ext == "pdf" {
                return .success(try loadPDF(url: url, filename: filename))
            }
            if wordExtensions.contains(ext) {
                return .success(try loadWordDocument(url: url, filename: filename))
            }
            if sheetExtensions.contains(ext) {
                return .success(try loadSpreadsheet(url: url, filename: filename))
            }
            return .success(try loadPlainText(url: url, filename: filename, ext: ext))
        } catch let error as AttachError {
            return .failure(error)
        } catch {
            return .failure(AttachError(message: "\(filename): \(error.localizedDescription)"))
        }
    }

    static func load(image: NSImage, suggestedName: String) -> Result<Attachment, AttachError> {
        do {
            return .success(try encode(image: image, filename: suggestedName))
        } catch let error as AttachError {
            return .failure(error)
        } catch {
            return .failure(AttachError(message: "\(suggestedName): \(error.localizedDescription)"))
        }
    }

    // MARK: - Images

    private static func encode(image: NSImage, filename: String) throws -> Attachment {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            throw AttachError(message: "\(filename): couldn't read image data.")
        }
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        let scale = min(1.0, maxImageEdge / Double(max(width, height, 1)))
        var finalRep = rep
        var note: String?

        if scale < 1.0 {
            let targetSize = NSSize(width: Double(width) * scale, height: Double(height) * scale)
            let resized = NSImage(size: targetSize)
            resized.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: NSRect(origin: .zero, size: targetSize))
            resized.unlockFocus()
            guard let resizedTiff = resized.tiffRepresentation,
                  let resizedRep = NSBitmapImageRep(data: resizedTiff) else {
                throw AttachError(message: "\(filename): couldn't downscale image.")
            }
            finalRep = resizedRep
            note = "downscaled to \(Int(targetSize.width))×\(Int(targetSize.height))"
        }

        guard let jpeg = finalRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw AttachError(message: "\(filename): couldn't encode image as JPEG.")
        }
        guard jpeg.count <= 10 * 1024 * 1024 else {
            throw AttachError(message: "\(filename): image still exceeds 10 MB after downscaling.")
        }
        let dataURL = "data:image/jpeg;base64," + jpeg.base64EncodedString()
        return Attachment(filename: filename, content: .image(dataURL: dataURL), note: note, noteKind: .info)
    }

    // MARK: - PDF

    private static func loadPDF(url: URL, filename: String) throws -> Attachment {
        guard let document = PDFDocument(url: url) else {
            throw AttachError(message: "\(filename): couldn't open PDF.")
        }
        guard !document.isLocked else {
            throw AttachError(message: "\(filename): PDF is password-protected.")
        }
        let pageCount = document.pageCount
        let usedPages = min(pageCount, maxPDFPages)
        var text = (0..<usedPages)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Small enough to keep the original alongside the extraction: a provider
        // that accepts PDF input gets the real file at send time.
        let raw = try? Data(contentsOf: url)
        let keepsRaw = (raw?.count ?? .max) <= maxDirectPDFBytes

        var notes: [String] = []
        if pageCount > maxPDFPages {
            notes.append("first \(maxPDFPages) of \(pageCount) pages when sent as text")
        }
        // Heuristic: a text PDF averages far more than 80 chars/page. Below that it's
        // likely scanned images — warn instead of silently sending near-empty text.
        if text.count < usedPages * 80 {
            notes.append(keepsRaw
                ? "very little extractable text — likely scanned; needs a model that accepts PDFs directly"
                : "very little extractable text — likely a scanned PDF; content may be missing")
        }
        if text.count > maxTextChars {
            text = String(text.prefix(maxTextChars))
            notes.append("truncated at \(maxTextChars) characters when sent as text")
        }
        if text.isEmpty, !keepsRaw {
            throw AttachError(message: "\(filename): no extractable text (scanned PDF?), and too large to send as a PDF file. Attach page screenshots instead for vision models.")
        }
        if let raw, keepsRaw {
            let dataURL = "data:application/pdf;base64," + raw.base64EncodedString()
            return Attachment(
                filename: filename,
                content: .pdf(dataURL: dataURL, extractedText: text),
                note: notes.isEmpty ? nil : notes.joined(separator: "; ")
            )
        }
        notes.append("over \(maxDirectPDFBytes / 1_048_576) MB — sent as extracted text, not the original PDF")
        return Attachment(filename: filename, content: .text(text), note: notes.joined(separator: "; "))
    }

    // MARK: - Word / RTF

    private static func loadWordDocument(url: URL, filename: String) throws -> Attachment {
        let attributed: NSAttributedString
        do {
            attributed = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        } catch {
            throw AttachError(message: "\(filename): couldn't extract text (\(error.localizedDescription)).")
        }
        var text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AttachError(message: "\(filename): document contains no text.")
        }
        var note: String?
        if text.count > maxTextChars {
            text = String(text.prefix(maxTextChars))
            note = "truncated at \(maxTextChars) characters"
        }
        return Attachment(filename: filename, content: .text(text), note: note)
    }

    // MARK: - Spreadsheets

    private static func loadSpreadsheet(url: URL, filename: String) throws -> Attachment {
        guard let file = XLSXFile(filepath: url.path) else {
            throw AttachError(message: "\(filename): couldn't open spreadsheet.")
        }
        do {
            let sharedStrings = try? file.parseSharedStrings()
            var sections: [String] = []
            var notes: [String] = []

            let workbook = try file.parseWorkbooks().first
            let sheets: [(name: String?, path: String)]
            if let workbook {
                sheets = try file.parseWorksheetPathsAndNames(workbook: workbook)
            } else {
                sheets = try file.parseWorksheetPaths().map { (name: nil, path: $0) }
            }

            for (index, sheet) in sheets.enumerated() {
                let worksheet = try file.parseWorksheet(at: sheet.path)
                let rows = worksheet.data?.rows ?? []
                let usedRows = rows.prefix(maxRowsPerSheet)
                let csv = usedRows.map { row in
                    row.cells.map { escapeCSV(cellText($0, sharedStrings: sharedStrings)) }.joined(separator: ",")
                }.joined(separator: "\n")
                let sheetName = sheet.name ?? "Sheet \(index + 1)"
                sections.append("--- \(sheetName) (\(rows.count) rows) ---\n\(csv)")
                if rows.count > maxRowsPerSheet {
                    notes.append("\(sheetName): first \(maxRowsPerSheet) of \(rows.count) rows")
                }
            }

            var text = sections.joined(separator: "\n\n")
            guard !text.isEmpty else {
                throw AttachError(message: "\(filename): spreadsheet contains no data.")
            }
            if text.count > maxTextChars {
                text = String(text.prefix(maxTextChars))
                notes.append("truncated at \(maxTextChars) characters")
            }
            return Attachment(
                filename: filename,
                content: .text(text),
                note: notes.isEmpty ? nil : notes.joined(separator: "; ")
            )
        } catch let error as AttachError {
            throw error
        } catch {
            throw AttachError(message: "\(filename): couldn't parse spreadsheet (\(error.localizedDescription)).")
        }
    }

    private static func cellText(_ cell: Cell, sharedStrings: SharedStrings?) -> String {
        if let sharedStrings, let value = cell.stringValue(sharedStrings) {
            return value
        }
        if let inline = cell.inlineString?.text {
            return inline
        }
        // Only cells explicitly typed as dates — dateValue would misread any plain
        // number as an Excel date serial.
        if cell.type == .date, let date = cell.dateValue {
            return ISO8601DateFormatter().string(from: date)
        }
        return cell.value ?? ""
    }

    private static func escapeCSV(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    // MARK: - Plain text & everything else

    private static func loadPlainText(url: URL, filename: String, ext: String) throws -> Attachment {
        let data = try Data(contentsOf: url)
        guard !data.contains(0) else {
            throw AttachError(message: "\(filename): unsupported binary format (.\(ext)). Supported: images, PDF, docx/rtf, xlsx, and text files.")
        }
        var text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AttachError(message: "\(filename): file is empty.")
        }
        var note: String?
        if text.count > maxTextChars {
            text = String(text.prefix(maxTextChars))
            note = "truncated at \(maxTextChars) characters"
        }
        return Attachment(filename: filename, content: .text(text), note: note)
    }
}
