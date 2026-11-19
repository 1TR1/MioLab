// 在书页捕获阶段处理注释，单条消息携带点击来源和目标，不依赖另一条点击消息先到。
function readiumInstallFootnoteLinks(publicationURL) {
  const base = new URL(publicationURL);
  const root = base.pathname.endsWith('/') ? base.pathname : base.pathname + '/';
  const inPublication = address => address.protocol === base.protocol && address.host === base.host
    && !address.username && !address.password && address.pathname.startsWith(root);
  const tokens = value => (value || '').toLowerCase().split(/\s+/);
  const isMarker = value => /^[注註](?:释|釋)?[0-9０-９〇零一二三四五六七八九十百千]*$/
    .test(value.replace(/[\s\[\]()［］（）【】〔〕〈〉《》「」﹝﹞〖〗<>]/g, ''));

  document.addEventListener('click', event => {
    const bridge = window.webkit?.messageHandlers?.readiumFootnoteLink;
    if (!bridge || !event.isTrusted || event.defaultPrevented || event.button !== 0
        || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey
        || document.getSelection()?.isCollapsed === false) return;

    const link = event.target instanceof Element ? event.target.closest('a[href]') : null;
    if (!link) return;
    const types = tokens(link.getAttributeNS('http://www.idpf.org/2007/ops', 'type') || link.getAttribute('epub:type'));
    const roles = tokens(link.getAttribute('role'));
    if (types.includes('backlink') || roles.includes('doc-backlink')) return;
    const label = [link.textContent, link.getAttribute('aria-label'),
      link.querySelector('img[alt]')?.getAttribute('alt'), link.getAttribute('title')].find(value => value?.trim()) || '';
    if (!types.includes('noteref') && !roles.includes('doc-noteref') && !isMarker(label)) return;

    // 明确区分书内资源与外部链接。只有可交给阅读器的注释会取消原生导航。
    let source, target;
    try {
      const href = link.getAttribute('href').trim();
      if (!href) return;
      source = new URL(document.URL);
      target = new URL(href, link.baseURI);
      if (!inPublication(source) || !inPublication(target)) return;
      if (source.pathname === target.pathname && source.search === target.search && !target.hash) return;
    } catch (_) { return; }

    bridge.postMessage({ source: source.href, target: target.href, referrer: link.innerHTML });
    event.preventDefault();
    event.stopImmediatePropagation();
  }, { capture: true });
}

// 空锚点附近可能没有可用的排版矩形。优先对齐它标记的注释段落。
function readiumScrollToFragment(id, animated) {
  const byID = document.getElementById(id);
  const selector = byID ? '#' + CSS.escape(id) : 'a[name=' + CSS.escape(id) + ']';
  const anchor = byID || document.querySelector(selector);
  if (!anchor) return false;
  const following = anchor.nextElementSibling;
  if (anchor.localName === 'a' && !anchor.hasAttribute('href') && !anchor.textContent.trim()
      && following?.matches('p,li,div,aside,section,blockquote,dd')) {
    return readium.scrollToLocator({ locations: { cssSelector: selector + ' + *' } }, animated);
  }
  // 普通 ID 和旧书的 name 都使用 Readium 的排版坐标。
  if (byID) return readium.scrollToId(id, animated);
  return readium.scrollToLocator({ locations: { cssSelector: selector } }, animated);
}
