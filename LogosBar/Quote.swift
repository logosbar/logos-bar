// Turns a passage copied from Logos, with the citation Logos adds after it, into Markdown for
// Obsidian: the passage in quotation marks, its footnotes as Markdown footnotes, then
// “**Source:** citation”, either as it is or inside a quote callout.
//
// Logos's citation runs “Author, Title, ed. …, Series (City: Publisher, Year), page.” with the
// title linked back to the copied spot. It's kept whole, with the title as a link and the page
// given the same link. Italics become _…_, bold **…**, and a superscript footnote number whose note was copied
// too becomes [^n], with the note as [^n]: ….

import Cocoa

/// The rich text on the clipboard, from its RTF or HTML.
func copiedRichText(on pasteboard: NSPasteboard) -> NSAttributedString? {
    if let rtf = pasteboard.data(forType: .rtf),
       let text = NSAttributedString(rtf: rtf, documentAttributes: nil) {
        return text
    }
    guard let html = pasteboard.data(forType: .html) else { return nil }
    // Reading HTML uses WebKit, which wants the main thread.
    let read = { try? NSAttributedString(data: html, options: [.documentType: NSAttributedString.DocumentType.html,
                                                               .characterEncoding: String.Encoding.utf8.rawValue],
                                         documentAttributes: nil) }
    return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
}

/// A passage copied from Logos, in Markdown, split from its footnotes and the citation Logos adds after it.
struct LogosQuote {
    var paragraphs: [String]   // the passage
    var footnotes: [String]    // “[^9]: The article …”
    var source: String         // the whole citation, title and page linked

    private var lines: [String] {
        var blocks = ["\"\(paragraphs.joined(separator: "\n\n"))\""]
        blocks += footnotes
        blocks.append("**Source:** \(source)")
        return blocks.joined(separator: "\n\n").components(separatedBy: "\n")
    }

    /// The passage in quotation marks, its footnotes, then the source.
    var simplified: String {
        lines.joined(separator: "\n") + "\n"
    }

    /// The same inside an Obsidian quote callout, with a blank line after so whatever comes next
    /// starts outside it.
    var callout: String {
        ([">[!quote] Quotation"] + lines.map { ">" + $0 }).joined(separator: "\n") + "\n\n"
    }
}

/// The copied passage and its Logos citation, or nil when it has no Logos citation.
func logosQuote(from copied: NSAttributedString) -> LogosQuote? {
    let text = copied.string as NSString
    // The citation's title is its last link back into Logos.
    var titleRange: NSRange?
    var link: String?
    copied.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length), options: .reverse) { value, range, stop in
        let url = (value as? URL)?.absoluteString ?? value as? String
        if let url, url.contains("ref.ly/") {
            titleRange = range
            link = url
            stop.pointee = true
        }
    }
    guard let titleRange, let link else { return nil }
    let url = markdownURL(link)

    // The passage, with superscripts marked until we know which are footnote numbers.
    let citation = text.paragraphRange(for: titleRange)
    var paragraphs = markdown(copied, in: NSRange(location: 0, length: citation.location))
        .components(separatedBy: .newlines)
        .map { $0.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ") }
        .filter { !$0.isEmpty }

    // A footnote is a paragraph starting with a number that's superscript in the passage
    // (“⁹ The article …” or “9 The article …”).
    let marked = try! NSRegularExpression(pattern: "\(supOpen)([^\(supClose)]+)\(supClose)")
    let superscripts = Set(paragraphs.flatMap { paragraph in
        marked.matches(in: paragraph, range: NSRange(paragraph.startIndex..., in: paragraph))
            .map { String(paragraph[Range($0.range(at: 1), in: paragraph)!]) }
    })
    var footnoteMarks = Set<String>()
    var footnotes: [String] = []
    paragraphs.removeAll { paragraph in
        let start = try! NSRegularExpression(pattern: "^(?:\(supOpen)([^\(supClose)]+)\(supClose)|([0-9]+)\\s)\\s*")
        guard let match = start.firstMatch(in: paragraph, range: NSRange(paragraph.startIndex..., in: paragraph)) else { return false }
        let mark = [1, 2].compactMap { Range(match.range(at: $0), in: paragraph).map { String(paragraph[$0]) } }.first ?? ""
        guard superscripts.contains(mark) else { return false }
        footnoteMarks.insert(mark)
        footnotes.append("[^\(mark)]: " + paragraph[Range(match.range, in: paragraph)!.upperBound...])
        return true
    }
    guard !paragraphs.isEmpty else { return nil }
    // Footnote numbers become [^n]; other superscripts (verse numbers) stay as they are.
    let resolve = { (line: String) -> String in
        let range = NSRange(line.startIndex..., in: line)
        var out = line
        for match in marked.matches(in: line, range: range).reversed() {
            let mark = String(line[Range(match.range(at: 1), in: line)!])
            out.replaceSubrange(Range(match.range, in: out)!, with: footnoteMarks.contains(mark) ? "[^\(mark)]" : mark)
        }
        return out
    }
    paragraphs = paragraphs.map(resolve)
    footnotes = footnotes.map(resolve)

    // The citation, whole, with the title linked and the page that ends it linked too.
    let author = text.substring(with: NSRange(location: citation.location, length: titleRange.location - citation.location))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let title = text.substring(with: titleRange).trimmingCharacters(in: .whitespacesAndNewlines)
    let afterRange = NSRange(location: titleRange.upperBound, length: citation.upperBound - titleRange.upperBound)
    var after = resolve(markdown(copied, in: afterRange)).trimmingCharacters(in: .whitespacesAndNewlines)
    if let page = page(endingCitation: text.substring(with: afterRange)),
       let at = after.range(of: page, options: .backwards) {
        after.replaceSubrange(at, with: "[\(page)](\(url))")
    }
    let source = (author.isEmpty ? "" : author + " ") + "[_\(title)_](\(url))" + after
    return LogosQuote(paragraphs: paragraphs, footnotes: footnotes, source: source)
}

// Private-use characters around a superscript while the passage is read.
private let supOpen = "\u{E000}", supClose = "\u{E001}"

/// The text in `range` with italics as _…_, bold as **…** and superscripts marked with supOpen…supClose.
func markdown(_ text: NSAttributedString, in range: NSRange) -> String {
    // Runs split wherever any attribute changes; join neighbours that look the same in Markdown.
    var pieces: [(text: String, italic: Bool, bold: Bool, superscript: Bool)] = []
    text.enumerateAttributes(in: range) { attrs, run, _ in
        let piece = (text.string as NSString).substring(with: run)
        let font = attrs[.font] as? NSFont
        let italic = font?.fontDescriptor.symbolicTraits.contains(.italic) ?? false
        let bold = font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
        let superscript = (attrs[.superscript] as? Int ?? 0) > 0 || (attrs[.baselineOffset] as? CGFloat ?? 0) > 0
        if let last = pieces.last, last.italic == italic, last.bold == bold, last.superscript == superscript {
            pieces[pieces.count - 1].text += piece
        } else {
            pieces.append((piece, italic, bold, superscript))
        }
    }
    return pieces.map { piece in
        let core = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty else { return piece.text }
        var wrapped = core
        if piece.superscript {
            wrapped = supOpen + core + supClose
        } else {
            if piece.italic { wrapped = "_\(wrapped)_" }
            if piece.bold { wrapped = "**\(wrapped)**" }
        }
        guard wrapped != core else { return piece.text }
        // Keep the spaces around it outside the markers.
        let lead = piece.text.prefix { $0.isWhitespace || $0.isNewline }
        let trail = String(piece.text.reversed().prefix { $0.isWhitespace || $0.isNewline }.reversed())
        return lead + wrapped + trail
    }.joined()
}

/// The page that ends a citation (“…, 2024), 421.”), or nil when it ends some other way.
func page(endingCitation citation: String) -> String? {
    let last = citation.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        .components(separatedBy: ",").last?
        .trimmingCharacters(in: .whitespaces) ?? ""
    let pages = #"^(pp?\. ?)?[0-9ivxlcdm]+([–-][0-9ivxlcdm]+)?$"#
    return last.range(of: pages, options: [.regularExpression, .caseInsensitive]) != nil ? last : nil
}

/// A link safe inside Markdown's (…), which ends at a space or an unmatched parenthesis.
func markdownURL(_ link: String) -> String {
    link.replacingOccurrences(of: " ", with: "%20")
        .replacingOccurrences(of: "(", with: "%28")
        .replacingOccurrences(of: ")", with: "%29")
}
