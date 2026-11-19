// 在正文清理前读取原页面导航；只解析链接和字符串常量，不执行网站脚本。
function mioLibChapterNavigation(requireReadableChapter = false) {
  const current = new URL(document.URL);
  const isWenku8 = /(^|\.)wenku8\.net$/i.test(current.hostname);
  const chapterPath = /^\/novel\/\d+\/\d+\/\d+\.htm$/i;
  const directoryPath = /^\/novel\/\d+\/(\d+)\/index\.htm$/i;
  const details = isWenku8 && current.pathname.match(/^\/book\/(\d+)\.htm$/i);
  // 旧缓存补导航时也要拒绝验证或登录页，避免把空导航永久写入正常章节。
  if (requireReadableChapter && isWenku8 && chapterPath.test(current.pathname) && !document.querySelector('#content')) {
    throw new Error('未找到章节正文，请在原网页完成登录或网站验证后重试。');
  }
  const bookPath = current.pathname.replace(/[^/]*$/, '');
  const stripHash = url => { const copy = new URL(url); copy.hash = ''; return copy.href; };
  const canonical = (raw, chapterOnly = true) => {
    try {
      if (!raw || !raw.trim() || raw.trim().startsWith('#')) return null;
      const url = new URL(raw, document.baseURI);
      if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) return null;
      if (stripHash(url) === stripHash(current)) return null;
      if (url.hostname !== current.hostname && !(isWenku8 && /(^|\.)wenku8\.net$/i.test(url.hostname))) return null;
      if (isWenku8 && details) {
        if (chapterOnly || url.pathname.match(directoryPath)?.[1] !== details[1]) return null;
      } else if (isWenku8 && (url.pathname.replace(/[^/]*$/, '') !== bookPath || (chapterOnly && !chapterPath.test(url.pathname)))) {
        return null;
      }
      url.hash = '';
      return url.href;
    } catch (_) { return null; /* 无效链接不阻断正文阅读。 */ }
  };
  const result = { previousURL: null, nextURL: null, contentsURL: null, firstChapterURL: null,
    isContents: Boolean(details || (isWenku8 && directoryPath.test(current.pathname))) };
  const label = value => value.toLowerCase().replace(/[\s\u3000\[\]【】<>《》〈〉«»‹›←→]/g, '');
  // 标签匹配使用完整短词，避免把“下一章推荐”等广告文字当作翻章按钮。
  const nextLabel = /^(?:下一[章节節页頁]|下章|next(?:chapter|page)?)$/;
  const previousLabel = /^(?:上一[章节節页頁]|上章|前一章|前章|prev(?:ious)?(?:chapter|page)?)$/;
  const contentsLabel = /^(?:返回|回到|回)?(?:章节|章節|小说|小說)?(?:目录|目錄|contents|toc)$/;
  const candidates = [...document.querySelectorAll('a[href],link[rel][href]')];
  const usable = anchor => !anchor.closest('[hidden],[aria-hidden="true"],[aria-disabled="true"],.disabled,[disabled]');
  for (const anchor of candidates) {
    if (!usable(anchor)) continue;
    const raw = anchor.getAttribute('href');
    const text = label(anchor.textContent || anchor.getAttribute('aria-label') || anchor.getAttribute('title') || '');
    const relation = (anchor.getAttribute('rel') || '').toLowerCase().split(/\s+/);
    if (nextLabel.test(text) || relation.includes('next')) result.nextURL ||= canonical(raw);
    if (previousLabel.test(text) || relation.includes('prev') || relation.includes('previous')) result.previousURL ||= canonical(raw);
    if (contentsLabel.test(text) || relation.includes('contents')) result.contentsURL ||= canonical(raw, false);
    // 详情页的目录入口以同一书号识别，防止把“最新章节”当成全书入口。
    if (details) result.contentsURL ||= canonical(raw, false);
  }
  // Wenku8 的键盘导航用 next_page / preview_page / index_page 字符串，目录边界不能变成正文。
  if (isWenku8) {
    for (const script of document.querySelectorAll('script:not([src])')) {
      for (const [variable, field, chapterOnly] of [
        ['next_page', 'nextURL', true], ['preview_page', 'previousURL', true], ['index_page', 'contentsURL', false],
      ]) {
        const match = script.textContent.match(new RegExp('(?:var\\s+)?' + variable + '\\s*=\\s*["\']([^"\'\\r\\n]+)["\']'));
        if (match) result[field] ||= canonical(match[1], chapterOnly);
      }
    }
    // 目录按站点的实际顺序收集所有章节，包含上一章／下一章可能跳过的插图。
    if (result.isContents && !details) {
      const chapters = new Map();
      const volumes = [];
      let volume = { title: '全书', chapterURLs: [] };
      // 文库8的 vcss 是卷标题单元格，后面的章节格归属当前卷，空卷不进入选择器。
      for (const element of document.querySelectorAll('table.css td.vcss,table.css a[href],.chapterlist a[href],#content a[href]')) {
        if (!usable(element)) continue;
        if (element.matches('td.vcss')) {
          if (volume.chapterURLs.length) volumes.push(volume);
          volume = { title: element.textContent.trim().replace(/\s+/g, ' ').slice(0, 300) || '正文', chapterURLs: [] };
          continue;
        }
        const target = canonical(element.getAttribute('href'));
        if (!target) continue;
        const url = new URL(target);
        const key = url.pathname + url.search;
        if (!chapters.has(key)) {
          chapters.set(key, target);
          volume.chapterURLs.push(target);
        }
        if (chapters.size > 2000) break;
      }
      if (volume.chapterURLs.length) volumes.push(volume);
      if (volumes.length) result.volumes = volumes;
      result.chapterURLs = Array.from(chapters.values());
      result.firstChapterURL = result.chapterURLs[0] || result.nextURL;
      result.previousURL = null;
      result.nextURL = null;
    }
  }
  return result;
}
