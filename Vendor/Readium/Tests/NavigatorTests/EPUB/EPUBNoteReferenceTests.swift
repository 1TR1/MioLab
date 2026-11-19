import Foundation
@testable import ReadiumNavigator
import Testing

// 注释识别同时覆盖 EPUB 标准语义和旧书「注」标记。
struct EPUBNoteReferenceTests {
    @Test(arguments: [
        ##"<a href="#fn" epub:type="annotation noteref">1</a>"##,
        ##"<a href="../Notes/notes.xhtml#fn" role="doc-noteref">1</a>"##,
        ##"<a href="#fn"><sup>〔注 12〕</sup></a>"##,
        ##"<a href="#fn">［註二］</a>"##,
        ##"<a href="#fn"><img alt="注"></a>"##,
        ##"<a href="#fn" title="注释"></a>"##,
    ])
    func recognizesNoteReferences(markup: String) throws {
        let link = try EPUBNoteReference.link(in: markup)
        #expect(link != nil)
    }

    // 普通章节链接和显式返回链接保留原导航行为。
    @Test(arguments: [
        ##"<a href="#chapter">第二章</a>"##,
        ##"<a href="#source" role="doc-backlink">注</a>"##,
        ##"<a href="#source" epub:type="backlink">注</a>"##,
        ##"<a href="#chapter">注释说明</a>"##,
    ])
    func leavesOtherLinksAlone(markup: String) throws {
        let link = try EPUBNoteReference.link(in: markup)
        #expect(link == nil)
    }

    // 使用正文文件的目录解析跨页注释，中文片段按实际 ID 读取。
    @Test func resolvesCrossPageReferenceAgainstTheSourceFile() throws {
        let source = try #require(URL(string: "readium://test/OEBPS/Text/chapter.xhtml"))
        let markup = ##"<a href="../Notes/notes.xhtml#%E6%B3%A8.1">注</a>"##
        let (_, url) = try #require(try EPUBNoteReference.destination(in: markup, from: source))
        #expect(url.path == "/OEBPS/Notes/notes.xhtml")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: true)?.fragment == "注.1")
    }

    // 片段是字面 ID；编号上的锚点应带出同段的注释正文。
    @Test func readsNoteAtInlineAnchor() throws {
        let markup = #"<p>前一条</p><p><a id="注.1:甲"></a>注释 &amp; 正文<br />第二行</p><p>下一条</p>"#
        let content = try EPUBNoteReference.content(in: markup, fragment: "注.1:甲")
        let note = try #require(content)
        #expect(note.contains("注释 &amp; 正文"))
        #expect(note.contains("第二行"))
        #expect(!note.contains("前一条"))
        #expect(!note.contains("下一条"))
    }

    // 独立锚点与指向整页尾注的链接都能读取内容。
    @Test func resolvesStandaloneAnchorAndWholePage() throws {
        let markup = #"<a id="n"></a><p>跨章尾注</p>"#
        #expect(try EPUBNoteReference.content(in: markup, fragment: "n") == "跨章尾注")
        #expect(try EPUBNoteReference.content(in: markup, fragment: nil)?.contains("跨章尾注") == true)
        #expect(try EPUBNoteReference.content(in: markup, fragment: "missing") == nil)
    }

    // 命名锚点使用原始字符匹配，独立标记取它后面的注释段落。
    @Test func resolvesLegacyNamedAnchorsWithoutASelector() throws {
        let markup = #"<p>上一段</p><a name="注.1%甲"></a><p>尾注文字</p><p>后文</p>"#
        #expect(try EPUBNoteReference.content(in: markup, fragment: "注.1%甲") == "尾注文字")
        #expect(try EPUBNoteReference.content(in: markup, fragment: "注.1%乙") == nil)
    }
}
