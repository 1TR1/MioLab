// 网页书的插图由 EPUB 包提供。只在图片的长按手势上显示原生保存菜单。
(() => {
  const imageFile = /^images\/image\d+\.(?:jpg|jpeg|png)$/i;
  const imageAt = event => {
    const image = event.target instanceof Element ? event.target.closest('img') : null;
    return image?.complete && image.naturalWidth > 0 && imageFile.test(image.getAttribute('src') || '') ? image : null;
  };
  let press;
  let lastMenu;
  const cancelPress = () => {
    if (press) clearTimeout(press.timer);
    press = undefined;
  };

  // 某些系统还会触发 contextmenu，同一次长按只发送一条消息。
  const open = image => {
    if (lastMenu?.image === image && Date.now() - lastMenu.time < 900) return;
    lastMenu = { image, time: Date.now() };
    window.webkit.messageHandlers.mioReaderImageMenu.postMessage(image.getAttribute('src'));
  };
  document.addEventListener('pointerdown', event => {
    cancelPress();
    const image = imageAt(event);
    if (!image || !event.isPrimary || event.button !== 0) return;
    press = { pointer: event.pointerId, x: event.clientX, y: event.clientY,
      timer: setTimeout(() => open(image), 520) };
  }, { capture: true, passive: true });
  document.addEventListener('pointermove', event => {
    if (!press || event.pointerId !== press.pointer) return;
    if (Math.hypot(event.clientX - press.x, event.clientY - press.y) > 12) cancelPress();
  }, { capture: true, passive: true });

  // 释放、多指缩放和翻页都会停止计时，平常点按或划页不阻断 Readium 的事件。
  for (const type of ['pointerup', 'pointercancel', 'scroll', 'visibilitychange']) {
    document.addEventListener(type, cancelPress, { capture: true, passive: true });
  }
  document.addEventListener('contextmenu', event => {
    const image = imageAt(event);
    if (!image) return;
    event.preventDefault();
    cancelPress();
    open(image);
  }, true);
  document.addEventListener('click', event => {
    if (lastMenu?.image !== imageAt(event) || Date.now() - lastMenu.time >= 900) return;
    // 长按松手后系统可能继续派发点击，避免同时翻页或切换工具栏。
    event.preventDefault();
    event.stopImmediatePropagation();
  }, true);
})();
