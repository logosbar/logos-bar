// Turns a passage copied from Logos, with the citation Logos adds after it, into a short quote:
// "text" (Author, [_Title_](link), [page](link)).
//
// Logos's citation runs “Author, Title, ed. …, Series (City: Publisher, Year), page.” with the
// title linked back to the copied spot. Only the author, title, series and page are kept, and
// the page gets the same link.

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

/// The copied passage as a short Markdown quote, or nil when it has no Logos citation.
func shortQuote(from copied: NSAttributedString) -> String? {
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

    let citation = text.paragraphRange(for: titleRange)
    let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
    let author = text.substring(with: NSRange(location: citation.location, length: titleRange.location - citation.location))
        .trimmingCharacters(in: trim)
    let title = text.substring(with: titleRange).trimmingCharacters(in: .whitespacesAndNewlines)
    let afterTitle = text.substring(with: NSRange(location: titleRange.upperBound, length: citation.upperBound - titleRange.upperBound))
    let quote = text.substring(to: citation.location)
        .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    guard !quote.isEmpty else { return nil }

    let url = markdownURL(link)
    var parts = author.isEmpty ? [] : [author]
    parts.append("[_\(title)_](\(url))")
    if let series = series(inCitation: afterTitle) { parts.append(series) }
    if let page = page(endingCitation: afterTitle) { parts.append("[\(page)](\(url))") }
    return "\"\(quote)\" (\(parts.joined(separator: ", ")))."
}

/// The series, the last part before the publication details (“…, ed. Clinton E. Arnold, Zondervan
/// Exegetical Commentary on the New Testament (Grand Rapids…”), or nil when the book has none.
func series(inCitation citation: String) -> String? {
    guard let publication = citation.range(of: " (") else { return nil }
    let last = citation[..<publication.lowerBound].components(separatedBy: ",").last?
        .trimmingCharacters(in: .whitespaces) ?? ""
    // Without a series, the last part is an editor, translator, volume or edition.
    let notSeries = #"^(and |ed\.|eds\.|trans\.|vol\.|rev\.|repr\.)|\bed\.$|edition$"#
    guard !last.isEmpty, last.range(of: notSeries, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
    return last
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
