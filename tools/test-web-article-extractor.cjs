// 验证真实 Readability 与应用提取脚本；依赖只安装到忽略的 output 目录。
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const { JSDOM } = require('../output/web-reader-validation/node_modules/jsdom');
const root = path.resolve(__dirname, '..');
const readability = readFileSync(path.join(root, 'Sources/MioLib/Resources/Readability.js'), 'utf8');
const extractor = readFileSync(path.join(root, 'Sources/MioLib/Resources/WebArticleExtractor.js'), 'utf8');
const navigation = readFileSync(path.join(root, 'Sources/MioLib/Resources/WebChapterNavigation.js'), 'utf8');
const readerImageMenu = readFileSync(path.join(root, 'Sources/MioLib/Resources/ReaderImageMenu.js'), 'utf8');
const readerFootnotes = readFileSync(path.join(root,
  'Vendor/Readium/Sources/Navigator/EPUB/Assets/Static/scripts/readium-footnote-links.js'), 'utf8');
const prose = '城市图书馆的窗边，读者正在阅读一本介绍星空的书。正文记录观察的方法，也描述不同季节的星座，让每一个段落都有完整的信息。'.repeat(6);

// 每次使用独立 DOM，模拟实际网页地址、元数据和周边导航，不发出网络请求。
function capture(body, extra = '') {
  const dom = new JSDOM(`<!doctype html><html lang="zh-Hans"><head><title>星空阅读</title>
    <meta name="author" content="测试作者"></head><body><nav>导航栏目</nav><aside>广告推荐</aside>
    <article><h1>星空阅读</h1>${body}</article><footer>页脚导航</footer>${extra}</body></html>`,
    { url: 'https://example.com/reading/chapter', runScripts: 'outside-only' });
  try {
    const original = dom.window.document.body.innerHTML;
    const result = JSON.parse(dom.window.eval(`${navigation}\n${readability}\n(function () {\n${extractor}\n})()`));
    assert.equal(dom.window.document.body.innerHTML, original, '不能修改浏览器正在显示的页面');
    return result;
  } finally { dom.window.close(); }
}

// 保留中文正文和章节标题，去掉网站导航、推荐、脚本与交互表单。
test('提取正文、作者和目录标题并排除交互区', () => {
  const result = capture(`<p>${prose}</p><h2>观察方法</h2><p>${prose}</p>
    <script>window.tracker = '恶意脚本';</script><form><input/><button>提交广告</button></form>`);
  assert.equal(result.title, '星空阅读');
  assert.equal(result.byline, '测试作者');
  assert.equal(result.language, 'zh-Hans');
  assert.ok(result.blocks.some(block => block.kind === 'heading' && block.text === '观察方法'));
  const text = result.blocks.map(block => block.text).join('\n');
  assert.ok(text.includes(prose));
  assert.doesNotMatch(text, /导航栏目|广告推荐|页脚导航|恶意脚本|提交广告/);
});

// 行内强调和链接保留文字，连续 span 不会被拆成多段或重复输出。
test('行内文字和换行保持阅读顺序', () => {
  const result = capture(`<p>${prose}</p><div>这一段正文介绍如何阅读星图，并在连续的行内文字中包含<span>开始</span><strong>加粗</strong><a href="/next">链接</a><span>结束</span>，随后继续解释观测记录。</div><p>前行<br/>后行</p>`);
  const text = result.blocks.map(block => block.text);
  assert.ok(text.some(value => value.includes('开始加粗链接结束')), JSON.stringify(text));
  assert.ok(text.includes('前行\n后行'));
  assert.equal(text.filter(value => value.includes('开始')).length, 1);
});

// 嵌套列表、引用、代码与表格均保留语义，不让列表子项重复进入父项。
test('列表引用代码和表格可阅读', () => {
  const result = capture(`<p>${prose}</p><ol start="3"><li>第三项<ul><li>子项</li></ul></li><li>第四项</li></ol>
    <blockquote>引文内容</blockquote><pre>if (a &lt; 2) {\n  return a;\n}</pre>
    <table><tr><th>名称</th><th>数值</th></tr><tr><td>甲</td><td>42</td></tr></table><p>${prose}</p>`);
  assert.ok(result.blocks.some(block => block.kind === 'listItem' && block.text === '3. 第三项'));
  assert.ok(result.blocks.some(block => block.kind === 'listItem' && block.text === '• 子项'));
  assert.ok(result.blocks.some(block => block.kind === 'quote' && block.text === '引文内容'));
  assert.ok(result.blocks.some(block => block.kind === 'code' && block.text.includes('\n  return a;')));
  assert.ok(result.blocks.some(block => block.text === '甲 | 42'));
});

// 图片相对路径基于原网页解析，危险协议和追踪像素不进入阅读副本。
test('图片规范化与危险来源过滤', () => {
  const result = capture(`<p>${prose}</p><figure><img src="../images/sky.jpg" alt="星空图片"/><figcaption>图一</figcaption></figure>
    <img src="javascript:alert(1)" alt="危险图片"/><img src="/pixel.png" width="1" height="1"/>
    <svg><text>不应包含的 SVG</text></svg><p>${prose}</p>`);
  const images = result.blocks.filter(block => block.kind === 'image');
  assert.ok(images.some(block => block.url === 'https://example.com/images/sky.jpg' && block.text === '星空图片'));
  assert.ok(images.every(block => /^https?:/.test(block.url)));
  assert.ok(images.every(block => !block.url.includes('pixel.png')));
  assert.ok(result.blocks.every(block => !block.text.includes('不应包含的 SVG')));
});

// 无正文的交互页返回可显示的错误，用户仍可留在原网页。
test('无正文页面明确失败', () => {
  assert.throws(() => capture('<p>请登录</p><button>继续</button>'), /未找到适合阅读模式的正文/);
});

// 折叠空白和处理非 BMP 字符后，脚注范围仍精确覆盖链接文字。
test('只保留指向同页注释的内联链接', () => {
  const result = capture('<p>' + prose + '</p><p>正文 😀   <a href="#n.1">〔注 1〕</a> 紧接' +
    '<sup><a href="/reading/chapter#n2" role="doc-noteref">2</a></sup>、' +
    '<a href="/other#n.1">注</a>、<a href="#missing">注</a>、' +
    '<a href="#n3">〔注 3〕</a>、<a href="#hidden">注</a>。</p>' +
    '<ol><li id="n.1">第一条 &amp; 说明<br>续行<a href="#source" role="doc-backlink">返回标记</a></li>' +
    '<li id="n2"><p>另一条注释</p></li></ol>',
    '<footer><p id="n3">页脚中的注释<script>未载入的内容</script></p><p id="hidden" hidden>隐藏内容</p></footer>');
  const paragraph = result.blocks.find(block => block.noteReferences);
  assert.ok(paragraph);
  const notes = new Map(result.blocks.filter(block => block.kind === 'footnote').map(block => [block.noteID, block.text]));
  assert.deepEqual(paragraph.noteReferences.map(({ offset, length, noteID }) =>
    [paragraph.text.slice(offset, offset + length), notes.get(noteID)]),
    [['〔注 1〕', '第一条 & 说明\n续行'], ['2', '另一条注释'], ['〔注 3〕', '页脚中的注释']]);
  assert.equal(result.blocks.filter(block => block.text.includes('第一条 & 说明')).length, 1);
  assert.doesNotMatch(JSON.stringify(result), /返回标记|未载入的内容|隐藏内容|\/other#n/);
});

// 自写页面仅保留实际站点的 DOM 结构，不在测试中分发第三方小说正文。
function wenkuCapture(markup, filename = '2.htm', articleMode = true) {
  const dom = new JSDOM(`<!doctype html><html><head><title>章节测试</title></head><body>${markup}</body></html>`,
    { url: `https://www.wenku8.net/novel/0/1/${filename}`, runScripts: 'outside-only' });
  try {
    const script = articleMode ? `${navigation}\n${readability}\n(function () {\n${extractor}\n})()`
      : `${navigation}\nJSON.stringify(mioLibChapterNavigation())`;
    return JSON.parse(dom.window.eval(script));
  } finally { dom.window.close(); }
}

// 文库正文可能直接使用纯行内节点和命名锚点。
test('文库页内注释与独立命名锚点', () => {
  const result = wenkuCapture('<div id="content">' + prose + '<br><a href="#note1">注</a>' +
    '<p>中间的正文</p><a name="note1"></a><p>可离线打开的注释</p></div>');
  const reference = result.blocks.flatMap(block => block.noteReferences || []);
  assert.equal(reference.length, 1);
  assert.equal(result.blocks.find(block => block.noteID === reference[0].noteID).text, '可离线打开的注释');
});

// Wenku8 实际使用“下一页”，首章的上一页指向目录；章节 ID 不能用自增猜测。
test('Wenku8 下一页识别为下一章且排除目录边界', () => {
  const result = wenkuCapture(`<div id="title">第一章</div><div id="content">${prose}<br/>换行正文</div>
    <div id="foottext"><a href="index.htm">上一页</a><a href="37.htm">下一页</a></div>
    <script>var preview_page='index.htm';var next_page='37.htm';var index_page='index.htm';</script>`);
  assert.equal(result.title, '第一章');
  assert.equal(result.navigation.previousURL, null);
  assert.equal(result.navigation.nextURL, 'https://www.wenku8.net/novel/0/1/37.htm');
  assert.equal(result.navigation.contentsURL, 'https://www.wenku8.net/novel/0/1/index.htm');
  assert.ok(result.blocks.every(block => !/上一页|下一页/.test(block.text)));
});

// 目录按真实链接顺序取首章；没有正文链接时不把书评、广告或另一部书作为首章。
test('Wenku8 目录选择首章而非广告或其他书籍', () => {
  const result = wenkuCapture(`<table class="css"><tr><td>
    <a href="https://ads.example.com/first.htm">广告</a><a href="/novel/0/9/3.htm">其他书籍</a>
    <a href="78.htm">序章</a><a href="82.htm">第一章</a></td></tr></table>`, 'index.htm', false);
  assert.equal(result.isContents, true);
  assert.equal(result.firstChapterURL, 'https://www.wenku8.net/novel/0/1/78.htm');
  assert.deepEqual(result.chapterURLs, ['https://www.wenku8.net/novel/0/1/78.htm', 'https://www.wenku8.net/novel/0/1/82.htm']);
  assert.equal(result.nextURL, null);
});

// 同一目录包含卷名、插图章、空卷和重复的别名链接。卷及章的原顺序都要保留。
test('Wenku8 按卷标题分组并去除重复章节', () => {
  const result = wenkuCapture(`<table class="css">
    <tr><td class="vcss" colspan="4">第一卷　春日</td></tr>
    <tr><td class="ccss"><a href="78.htm">序章</a></td><td class="ccss"><a href="80.htm">插图</a></td></tr>
    <tr><td class="vcss" colspan="4">未刊卷</td></tr>
    <tr><td class="vcss" colspan="4">第二卷</td></tr>
    <tr><td class="ccss"><a href="http://wenku8.net/novel/0/1/80.htm#top">上卷插图入口</a></td>
        <td class="ccss"><a href="90.htm">第一章</a></td><td class="ccss" hidden><a href="91.htm">隐藏</a></td></tr>
    </table>`, 'index.htm', false);
  const prefix = 'https://www.wenku8.net/novel/0/1/';
  assert.deepEqual(result.volumes, [
    { title: '第一卷 春日', chapterURLs: [prefix + '78.htm', prefix + '80.htm'] },
    { title: '第二卷', chapterURLs: [prefix + '90.htm'] },
  ]);
  assert.deepEqual(result.chapterURLs, result.volumes.flatMap(volume => volume.chapterURLs));
});

// 详情页的最新章节链接先于目录出现，也应从同书目录取得全部章节。
test('Wenku8 书籍详情找到同书目录', () => {
  const dom = new JSDOM(`<!doctype html><a href="/novel/0/6/index.htm">推荐图书</a>
    <a href="/novel/0/1/99.htm">最新章节</a><a href="/novel/0/1/index.htm">小说目录</a>`,
    { url: 'https://www.wenku8.net/book/1.htm', runScripts: 'outside-only' });
  try {
    const result = JSON.parse(dom.window.eval(`${navigation}\nJSON.stringify(mioLibChapterNavigation())`));
    assert.equal(result.isContents, true);
    assert.equal(result.contentsURL, 'https://www.wenku8.net/novel/0/1/index.htm');
    assert.equal(result.firstChapterURL, null);
  } finally { dom.window.close(); }
});

// 隐藏、禁用、同页、跨书、跨站与脚本地址都不能替换有效的相邻章链接。
test('章节导航过滤伪链接并识别末章', () => {
  const result = wenkuCapture(`<div hidden><a href="3.htm">下一章</a></div>
    <a aria-disabled="true" href="4.htm">下一章</a><a href="javascript:alert(1)">下一章</a>
    <a href="https://evil.example/5.htm">下一章</a><a href="/novel/0/8/6.htm">下一章</a>
    <a href="2.htm#top">下一章</a><a href="index.htm">下一页</a>
    <a href="1.htm">上一章</a><a href="3.htm">下一章推荐</a>`, '2.htm', false);
  assert.equal(result.nextURL, null);
  assert.equal(result.previousURL, 'https://www.wenku8.net/novel/0/1/1.htm');
});

// 仅保留脚本字符串导航的页面仍可切章，提取过程不执行该脚本。
test('Wenku8 脚本字符串导航与插图章', () => {
  const result = wenkuCapture(`<div id="title">插图章</div><div id="content"><img src="/images/test.jpg"/></div>
    <script>throw new Error('不能执行'); var preview_page='1.htm';var next_page='9.htm';var index_page='index.htm';</script>`);
  assert.equal(result.navigation.nextURL, 'https://www.wenku8.net/novel/0/1/9.htm');
  assert.equal(result.blocks[0].kind, 'image');
});

// 通用站点支持 rel=next/prev 和繁体导航文案，保持同源边界。
test('通用章节标签和 rel 导航', () => {
  const result = capture(`<p>${prose}</p>`, '<link rel="next" href="/reading/next"/><a href="/reading/previous">上一節</a>');
  assert.equal(result.navigation.nextURL, 'https://example.com/reading/next');
  assert.equal(result.navigation.previousURL, 'https://example.com/reading/previous');
});

// 站点验证或登录页面没有 #content 时不能被误存为小说章节。
test('Wenku8 登录或验证页面不替换正文', () => {
  assert.throws(() => wenkuCapture(`<main><p>${prose}</p><p>请验证后继续</p></main>`), /未找到章节正文/);
});

// 模拟 WebKit 的注释消息桥。jsdom 无法创建可信输入，直接调用实际注册的捕获回调。
function withFootnotePage(markup, verify) {
  const base = 'readium://library/first-book/';
  const source = base + 'OEBPS/Text/chapter.xhtml';
  const dom = new JSDOM('<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">' +
    '<head><title>测试</title></head><body>' + markup + '</body></html>',
    { url: source, contentType: 'application/xhtml+xml', runScripts: 'outside-only' });
  const { window } = dom;
  const { document } = window;
  const messages = [];
  let listener;
  const original = document.addEventListener.bind(document);
  try {
    window.webkit = { messageHandlers: { readiumFootnoteLink: { postMessage: data => messages.push(data) } } };
    document.addEventListener = (type, callback, options) => {
      if (type === 'click') {
        assert.equal(options.capture, true);
        listener = callback;
      } else {
        original(type, callback, options);
      }
    };
    window.eval(readerFootnotes + '\nreadiumInstallFootnoteLinks(' + JSON.stringify(base) + ');');
    const activate = (selector, event = {}) => {
      const result = { prevented: false, stopped: false };
      listener({
        target: document.querySelector(selector), isTrusted: true, button: 0,
        preventDefault: () => { result.prevented = true; },
        stopImmediatePropagation: () => { result.stopped = true; },
        ...event,
      });
      return result;
    };
    verify({ document, messages, activate, base, source });
  } finally { window.close(); }
}

// 同页和跨文件的注释都直接发送一个已解析的地址，无需等待原生链接导航。
test('注释点击在 WebKit 导航前分流，保留跨页与转义片段', () => {
  const markup = '<p><a href="#%E6%B3%A8%3A1"><sup id="inline">〔注1〕</sup></a>正文' +
    '<a id="cross" epub:type="noteref" href="../Notes/end.xhtml#n2">2</a></p>';
  withFootnotePage(markup, ({ activate, messages, base, source }) => {
    assert.deepEqual(activate('#inline'), { prevented: true, stopped: true });
    assert.deepEqual(activate('#cross'), { prevented: true, stopped: true });
    assert.deepEqual(messages.map(({ source: from, target }) => [from, target]), [
      [source, source + '#%E6%B3%A8%3A1'], [source, base + 'OEBPS/Notes/end.xhtml#n2'],
    ]);
  });
});

// 普通页内链接、回链和书外资源沿用原导航，文字选择与脚本点击也不打开注释。
test('注释点击只处理本书的真实点击', () => {
  const markup = '<p id="paragraph"><a id="chapter" href="#chapter2">下一章</a>' +
    '<a id="back" role="doc-backlink" href="#source">注</a>' +
    '<a id="external" href="readium://other/notes.xhtml#n">注</a>' +
    '<a id="anotherBook" href="/other-book/notes.xhtml#n">注</a>' +
    '<a id="note" href="#n">注</a></p>';
  withFootnotePage(markup, ({ document, activate, messages }) => {
    for (const id of ['chapter', 'back', 'external', 'anotherBook']) {
      assert.deepEqual(activate('#' + id), { prevented: false, stopped: false });
    }
    assert.equal(activate('#note', { isTrusted: false }).prevented, false);
    const range = document.createRange();
    range.selectNodeContents(document.querySelector('#paragraph'));
    document.getSelection().addRange(range);
    assert.equal(activate('#note').prevented, false);
    assert.equal(messages.length, 0);
  });
});

// 对齐有实际排版位置的段落，覆盖空 ID 锚点、旧命名锚点和缺失位置。
test('跳转使用注释段落的实际定位，缺失锚点返回失败', () => {
  const dom = new JSDOM('<a id="emptyId"></a><p>第一条</p><a name="oldName"></a><p>第二条</p><p id="plainId">第三条</p>',
    { runScripts: 'outside-only' });
  try {
    const { window } = dom;
    const visited = [];
    window.CSS = { escape: value => value };
    window.readium = {
      scrollToId: id => { visited.push(window.document.getElementById(id)?.textContent); return true; },
      scrollToLocator: locator => {
        const element = window.document.querySelector(locator.locations.cssSelector);
        if (!element) return false;
        visited.push(element.textContent);
        return true;
      },
    };
    window.eval(readerFootnotes);
    for (const id of ['emptyId', 'oldName', 'plainId']) {
      assert.equal(window.readiumScrollToFragment(id, false), true);
    }
    assert.equal(window.readiumScrollToFragment('notFound', false), false);
    assert.deepEqual(visited, ['第一条', '第二条', '第三条']);
  } finally { dom.window.close(); }
});

// 用模拟的图片和时间验证长按消息，快速松手、滑动、未加载图片和正文不干扰翻页。
test('阅读器图片长按请求保存一次，正文和滑动不触发保存', () => {
  const dom = new JSDOM('<figure><img src="images/image0.jpg"></figure><p>文字</p><img src="https://img.example/a.jpg">',
    { url: 'readium://book/OEBPS/article.xhtml', runScripts: 'outside-only' });
  try {
    const { window } = dom;
    const { document } = window;
    const [illustration, external] = document.querySelectorAll('img');
    const requests = [];
    const timers = new Map();
    let id = 0;
    window.webkit = { messageHandlers: { mioReaderImageMenu: { postMessage: image => requests.push(image) } } };
    window.setTimeout = callback => { timers.set(++id, callback); return id; };
    window.clearTimeout = timer => timers.delete(timer);
    for (const img of [illustration, external]) {
      Object.defineProperties(img, { complete: { value: true }, naturalWidth: { value: 640 } });
    }
    window.eval(readerImageMenu);

    // 指针事件在 jsdom 中通过通用事件补足，阅读脚本不需要更改。
    const dispatch = (target, type, x = 10) => {
      const event = new window.Event(type, { bubbles: true, cancelable: true });
      Object.assign(event, { isPrimary: true, button: 0, pointerId: 1, clientX: x, clientY: 0 });
      return target.dispatchEvent(event);
    };
    dispatch(illustration, 'pointerdown');
    dispatch(illustration, 'pointermove', 45);
    assert.equal(timers.size, 0);
    dispatch(illustration, 'pointerdown');
    dispatch(illustration, 'pointerup');
    assert.equal(timers.size, 0);
    assert.equal(dispatch(external, 'contextmenu'), true);
    assert.equal(dispatch(document.querySelector('p'), 'contextmenu'), true);

    // 手势停留够久，系统随后给出的右键事件不会再打开一次。
    dispatch(illustration, 'pointerdown');
    assert.equal(timers.size, 1);
    [...timers.values()][0]();
    assert.equal(dispatch(illustration, 'contextmenu'), false);
    assert.equal(dispatch(illustration, 'click'), false);
    assert.deepEqual(requests, ['images/image0.jpg']);
  } finally { dom.window.close(); }
});
