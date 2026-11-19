import Foundation
import SwiftSoup

// 优先识别 EPUB 注释语义，也兼容仅使用简短「注」字样的旧书。
enum EPUBNoteReference {
    static func link(in markup: String) throws -> Element? {
        let document = try SwiftSoup.parseBodyFragment(markup)
        guard let link = try document.select("a[href]").first() else { return nil }
        let roles = try link.attr("role").split(whereSeparator: \.isWhitespace)
        let types = try link.attr("epub:type").split(whereSeparator: \.isWhitespace)
        guard !roles.contains("doc-backlink"), !types.contains("backlink") else { return nil }
        if types.contains("noteref") || roles.contains("doc-noteref") { return link }

        // 忽略「[注]」「〔注 12〕」「［註二］」等短标记外的括号与空白。
        let brackets = CharacterSet(charactersIn: "[]()［］（）【】〔〕〈〉《》「」﹝﹞〖〗<>")
        let text = try link.text()
        // 有些书把注释标记绘成图标，沿用其可访问名称识别。
        let labels = text.isEmpty
            ? [try link.attr("aria-label"), try link.select("img[alt]").first()?.attr("alt") ?? "", try link.attr("title")]
            : [text]
        let marker = labels.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .filter { !$0.isWhitespace }.trimmingCharacters(in: brackets) ?? ""
        return marker.range(of: #"^[注註](?:释|釋)?[0-9０-９〇零一二三四五六七八九十百千]*$"#,
                            options: .regularExpression) != nil ? link : nil
    }

    // 相对跨页链接与页内片段都以点击的正文文件作为基准。
    static func destination(in markup: String, from source: URL) throws -> (Element, URL)? {
        guard let link = try link(in: markup) else { return nil }
        let address = try link.attr("href").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, let url = URL(string: address, relativeTo: source)?.absoluteURL else { return nil }
        return (link, url)
    }

    // 按字面查找 ID 或旧书的命名锚点。行内标号使用所在段落的完整文字。
    static func content(in markup: String, fragment: String?) throws -> String? {
        let document = try SwiftSoup.parse(markup)
        guard let fragment else { return try document.body()?.html() }
        guard let target = try document.getElementById(fragment) ?? document.select("a[name]").first(where: {
            try $0.attr("name") == fragment
        }) else { return nil }
        var container = target
        while !container.isBlock(), let parent = container.parent(), parent.tagName() != "body" {
            container = parent
        }

        // 有些旧书将空锚点单独放在注释段落前面。
        if container === target, target.tagName() == "a", !target.hasAttr("href"),
           try target.text().isEmpty, let following = try target.nextElementSibling(), following.isBlock()
        {
            container = following
        }
        return try container.html()
    }
}
