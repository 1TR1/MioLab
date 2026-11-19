// 在 WebKit 的隔离脚本环境运行 Readability，只读取当前用户已能看到的文档。
if (document.querySelectorAll('*').length > 80000) {
  throw new Error('页面过大，请使用原网页阅读。');
}
const navigation = mioLibChapterNavigation();
// Wenku8 正文位于 #content，明确选取该区以保留换行与插图，并排除周围广告和导航。
const wenkuChapter = /(^|\.)wenku8\.net$/i.test(location.hostname)
  && /^\/novel\/\d+\/\d+\/\d+\.htm$/i.test(location.pathname);
const wenkuContent = wenkuChapter && document.querySelector('#content');
if (wenkuChapter && !wenkuContent) throw new Error('未找到章节正文，请在原网页完成登录或网站验证后重试。');
const article = wenkuContent ? {
  title: document.querySelector('#title')?.textContent.trim() || document.title,
  byline: document.querySelector('#info')?.textContent.trim() || '', lang: document.documentElement.lang || 'zh',
  content: wenkuContent.innerHTML, textContent: wenkuContent.textContent,
} : new Readability(document.cloneNode(true), {
  charThreshold: 120, maxElemsToParse: 80000, keepClasses: false,
}).parse();
if (!article || ((!article.textContent || article.textContent.trim().length < 40)
    && !(wenkuContent && wenkuContent.querySelector('img')))) {
  throw new Error('未找到适合阅读模式的正文。请等待正文加载、完成网站登录，或使用原网页阅读。');
}

// 再次去掉交互区和嵌入资源，传回的是文本块，不把网站 HTML 交给阅读器执行。
const content = new DOMParser().parseFromString(article.content, 'text/html').body;
const ignoredElements = 'script,style,noscript,iframe,object,embed,form,input,button,select,textarea,video,audio,canvas,svg,[hidden],[aria-hidden="true"]';
content.querySelectorAll(ignoredElements).forEach(node => node.remove());
const blocks = [];
const collapseWhitespace = value => value.replace(/[\t\r ]+/g, ' ').replace(/ *\n */g, '\n');
const normalize = value => collapseWhitespace(value).trim();
const push = (kind, text, extra = {}) => {
  if (blocks.length >= 20000) throw new Error('正文过长，请使用原网页阅读。');
  if (kind === 'image' || text.trim()) blocks.push({ kind, text, ...extra });
};

// 同页注释使用本章生成的数字编号。外站链接和原网页的 ID 都不会进入离线 EPUB。
const pageURL = new URL(document.URL);
pageURL.hash = '';
const noteLinks = new Map();
const noteBlocks = new Map();
const namedAnchors = new Map(Array.from(content.querySelectorAll('a[name]'), item => [item.getAttribute('name'), item]));
const hasToken = (node, attribute, token) => (node.getAttribute(attribute) || '').split(/\s+/).includes(token);
const isBacklink = node => hasToken(node, 'role', 'doc-backlink') || hasToken(node, 'epub:type', 'backlink');
const noteMarker = value => /^[注註](?:释|釋)?[0-9０-９〇零一二三四五六七八九十百千]*$/
  .test(value.replace(/[\s\[\]()［］（）【】〔〕〈〉《》「」﹝﹞〖〗<>]/g, ''));

// 读取清理后 DOM 中的文字注释，保留段落与换行，跳过返回原文的标记。
const noteText = node => {
  if (node.nodeType === Node.TEXT_NODE) return node.textContent;
  if (node.nodeType !== Node.ELEMENT_NODE || node.matches(ignoredElements) || isBacklink(node)) return '';
  if (node.tagName === 'BR') return '\n';
  const text = Array.from(node.childNodes, noteText).join('');
  return /^(P|DIV|LI|DD|ASIDE|SECTION|BLOCKQUOTE)$/.test(node.tagName) ? '\n' + text + '\n' : text;
};
for (const link of content.querySelectorAll('a[href]')) {
  const label = normalize(link.textContent);
  if (!label || isBacklink(link) || !(hasToken(link, 'epub:type', 'noteref')
      || hasToken(link, 'role', 'doc-noteref') || noteMarker(label))) continue;
  let fragment;
  try {
    const targetURL = new URL(link.getAttribute('href'), document.baseURI);
    fragment = decodeURIComponent(targetURL.hash.slice(1));
    targetURL.hash = '';
    if (!fragment || targetURL.href !== pageURL.href) continue;
  } catch (_) { continue; /* 忽略无效片段。 */ }
  // Readability 可能移除页脚等容器。只从当前原页补取已识别引用的目标文字。
  const target = content.ownerDocument.getElementById(fragment) || namedAnchors.get(fragment)
    || document.getElementById(fragment) || Array.from(document.getElementsByName(fragment)).find(item => item.matches('a'));
  if (!target || !target.ownerDocument.body?.contains(target) || target.closest(ignoredElements)) continue;
  // 兼容段内编号和单独写在注释前面的空锚点。
  const following = target.matches('a:not([href])') && !target.textContent.trim() ? target.nextElementSibling : null;
  const container = target.closest('p,li,aside,dd,blockquote,figcaption')
    || (following?.matches('p,li,aside,dd,blockquote,div') ? following : target);
  if (container.contains(link) || container.matches('body,main,article,img,a[href]') || container.querySelector('img')) continue;
  if (!noteBlocks.has(container)) {
    const text = normalize(noteText(container)).replace(/\n{3,}/g, '\n\n');
    if (!text) continue;
    noteBlocks.set(container, { text, noteID: noteBlocks.size, emitted: false });
  }
  noteLinks.set(link, noteBlocks.get(container).noteID);
}

// 正文里的目标只输出一次，初始位置由原文块顺序决定。
const emitNote = note => {
  if (note.emitted) return;
  push('footnote', note.text, { noteID: note.noteID });
  note.emitted = true;
};

// 图片只保留 HTTP(S) 来源；本机随后尝试保存栅格图片，失败仍可阅读全部文字。
const image = node => {
  if (Number(node.getAttribute('width')) > 0 && Number(node.getAttribute('width')) < 32
      && Number(node.getAttribute('height')) > 0 && Number(node.getAttribute('height')) < 32) return;
  try {
    const raw = node.getAttribute('data-src') || node.getAttribute('data-original') || node.getAttribute('src');
    if (!raw) return;
    const url = new URL(raw, document.baseURI);
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) return;
    push('image', normalize(node.getAttribute('alt') || ''), { url: url.href });
  } catch (_) { /* 无效图片来源不影响正文提取。 */ }
};

// 普通行内节点合并为一段，换行与图片位置保留，避免嵌套 div 造成文字重复。
const inline = (nodes, kind = 'paragraph', prefix = '', extra = {}) => {
  let text = prefix;
  let markers = [];
  const flush = () => {
    // 正文归一化压缩空白后，再计算链接范围。逐段计数与 Swift 的 UTF-16 范围一致。
    const data = { ...extra };
    if (markers.length) {
      let cursor = 0;
      let offset = 0;
      data.noteReferences = markers.map(marker => {
        const gap = collapseWhitespace(text.slice(cursor, marker.offset));
        offset += (cursor === 0 ? gap.trimStart() : gap).length;
        const reference = { offset, length: marker.length, noteID: marker.noteID };
        offset += marker.length;
        cursor = marker.offset + marker.length;
        return reference;
      });
    }
    push(kind, normalize(text), data);
    text = '';
    markers = [];
  };
  const visit = child => {
    if (child.nodeType === Node.TEXT_NODE) { text += child.textContent; return; }
    if (child.nodeType !== Node.ELEMENT_NODE) return;
    if (noteBlocks.has(child)) { flush(); emitNote(noteBlocks.get(child)); return; }
    if (noteLinks.has(child)) {
      const raw = child.textContent;
      const label = normalize(raw);
      text += raw.slice(0, raw.length - raw.trimStart().length);
      markers.push({ offset: text.length, length: label.length, noteID: noteLinks.get(child) });
      text += label + raw.slice(raw.trimEnd().length);
      return;
    }
    if (child.tagName === 'IMG') { flush(); image(child); return; }
    if (child.tagName === 'BR') { text += '\n'; return; }
    if (/^(UL|OL)$/.test(child.tagName)) { flush(); walk(child); return; }
    for (const nested of child.childNodes) visit(nested);
    if (/^(P|DIV)$/.test(child.tagName)) text += '\n';
  };
  for (const child of nodes) visit(child);
  flush();
};

// 标题成为目录锚点，列表、引文、代码和表格保留各自的文字顺序。
const walk = node => {
  if (node.nodeType === Node.TEXT_NODE) { push('paragraph', normalize(node.textContent)); return; }
  if (node.nodeType !== Node.ELEMENT_NODE) return;
  if (noteBlocks.has(node)) { emitNote(noteBlocks.get(node)); return; }
  const tag = node.tagName;
  if (/^H[1-6]$/.test(tag)) { inline(node.childNodes, 'heading', '', { level: Number(tag[1]) }); return; }
  if (tag === 'IMG') { image(node); return; }
  if (tag === 'PRE') { push('code', node.textContent.trim()); return; }
  if (tag === 'BLOCKQUOTE') { inline(node.childNodes, 'quote'); return; }
  if (tag === 'LI') {
    const siblings = Array.from(node.parentElement.children).filter(child => child.tagName === 'LI');
    const start = Number(node.parentElement.getAttribute('start')) || 1;
    const prefix = node.parentElement.tagName === 'OL' ? `${start + siblings.indexOf(node)}. ` : '• ';
    inline(node.childNodes, 'listItem', prefix); return;
  }
  if (tag === 'TABLE') {
    for (const row of node.querySelectorAll('tr')) {
      push('paragraph', Array.from(row.cells).map(cell => normalize(cell.textContent)).join(' | '));
    }
    return;
  }
  if (tag === 'P' || tag === 'FIGCAPTION' || !node.querySelector('p,div,section,article,h1,h2,h3,h4,h5,h6,ul,ol,li,blockquote,pre,figure,table')) {
    inline(node.childNodes); return;
  }
  // 容器中的连续行内文字先合并，遇到块元素再递归，保持原来的阅读顺序。
  let pending = [];
  const flush = () => { inline(pending); pending = []; };
  for (const child of node.childNodes) {
    if (child.nodeType === Node.ELEMENT_NODE && (noteBlocks.has(child)
        || /^(P|DIV|SECTION|ARTICLE|MAIN|HEADER|H[1-6]|UL|OL|LI|BLOCKQUOTE|PRE|FIGURE|FIGCAPTION|TABLE|IMG)$/.test(child.tagName))) {
      flush(); walk(child);
    } else { pending.push(child); }
  }
  flush();
};
walk(content);
// 少数嵌套结构只产出普通段落，把未单独写入的注释补在章末。
for (const note of noteBlocks.values()) emitNote(note);

// 使用有大小上限的 JSON 传给 Swift；标题和作者仍作为普通文字处理。
const result = JSON.stringify({
  title: (article.title || document.title || '').slice(0, 2000),
  byline: (article.byline || '').slice(0, 2000),
  language: article.lang || document.documentElement.lang || 'zh', blocks,
  pageURL: pageURL.href, navigation,
});
if (result.length > 8 * 1024 * 1024) throw new Error('正文过大，请使用原网页阅读。');
return result;
