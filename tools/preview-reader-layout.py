"""生成使用项目实际 Readium CSS 的离线阅读预览，不访问私人书库。"""
from pathlib import Path
import html
import json

# 预览只使用自写样文，正文样式直接读取应用资源，不复制参考图中的书籍内容。
root = Path(__file__).resolve().parents[1]
output = root / "output" / "preview-reading-layout"
output.mkdir(parents=True, exist_ok=True)
assets = root / "Vendor/Readium/Sources/Navigator/EPUB/Assets/Static/readium-css/cjk-horizontal"
styles = "\n".join((assets / name).read_text(encoding="utf-8") for name in (
    "ReadiumCSS-before.css", "ReadiumCSS-default.css", "ReadiumCSS-after.css"))
styles += "\n" + (root / "Sources/MioLib/Resources/ReaderLayout.css").read_text(encoding="utf-8")
paragraphs = [
    "清晨推开窗，远处的树影落在桌面上。我把读到一半的书摊开，从昨天停下的地方继续。窗外偶尔传来脚步声，纸上的故事也一点一点向前走。",
    "阅读的节奏可以很慢。一段话读完，停下来想想，再翻到下一页。章节名称留在上方，时间和页码安静地排在下方，视线中间留给文字。",
    "这是一份用于检查排版的样文。左右的留白、段落的首行缩进和标题的位置，都会随着屏幕宽度调整。改变字号之后，每页容纳的文字数量也会改变。",
    "书里的路很长，走到哪里就在哪里停留。等下次再打开，仍然可以从原来的句子开始。这样的片刻，不必着急。",
]
body = '<p data-miolib-chapter-title>第一章</p>' + "".join(
    f"<p>{html.escape(text)}</p>" for text in paragraphs * 10)

# 由 iframe 提供真实视口，分页机制与项目中的横向 Readium CSS 相同。
properties = "--USER__view:readium-paged-on;--USER__advancedSettings:readium-advanced-on;--USER__fontOverride:readium-font-on;--USER__fontFamily:'Microsoft YaHei',sans-serif;--USER__fontSize:112.5%;--USER__lineHeight:1.6;--USER__pageMargins:1.5;--USER__paraIndent:2rem;--USER__paraSpacing:0.45rem;--USER__textAlign:justify;--USER__colCount:1;"
page = f'<!doctype html><html lang="zh" style="{properties}"><head><meta charset="utf-8"><title>第一章</title><style>{styles}</style></head><body>{body}</body></html>'
(output / "chapter.html").write_text(page, encoding="utf-8")

# 周围的页眉页脚是 SwiftUI 布局的离线示意，明确标识它并非真机截图。
preview = """<!doctype html><html lang="zh"><head><meta charset="utf-8"><title>MioLib 阅读排版预览</title>
<style>
body{margin:0;background:#e2e4e8;font:14px 'Microsoft YaHei',sans-serif;color:#333;padding:18px;}
nav{display:flex;gap:8px;align-items:center;margin-bottom:14px;}button{padding:8px 14px;cursor:pointer;}
/* 只模拟常见设备的安全区，实际应用由 iOS 自动提供摄像头及旋转后的边距。 */
#device{width:402px;height:874px;padding:62px 0 34px;box-sizing:border-box;background:white;display:flex;flex-direction:column;box-shadow:0 3px 18px #0002;}
header{padding:16px 30px 0;height:30px;flex-shrink:0;line-height:30px;font-size:12px;}
iframe{border:0;width:100%;flex:1;min-height:0;margin-block:24px;}
footer{height:32px;padding:0 30px 8px;display:flex;align-items:center;gap:7px;font-size:11px;flex-shrink:0;}
footer span:last-child{margin-left:auto;}.battery{display:inline-block;border:1px solid currentColor;border-radius:2px;width:19px;height:8px;padding:1px;}.battery i{display:block;height:100%;width:75%;background:currentColor;}
</style></head><body>
<nav><strong>离线排版示意 · 非真机截图</strong><button onclick="resize(402,874)">手机竖屏</button><button onclick="resize(874,402)">手机横屏</button><button onclick="resize(768,1024)">iPad</button><button onclick="theme('light')">浅色</button><button onclick="theme('dark')">深色</button><button onclick="theme('paper')">暖纸色</button><button onclick="turn()">下一页</button></nav>
<main id="device"><header>第一章</header><iframe id="page" src="chapter.html" title="阅读正文"></iframe><footer><span class="battery"><i></i></span><span>21:00</span><span id="pagination"></span></footer></main>
<script>
// 设备尺寸和主题只影响预览，固定示意时间、电量不会进入应用。
const device=document.getElementById('device'), frame=document.getElementById('page');
function resize(w,h){device.style.width=w+'px';device.style.height=h+'px';device.style.padding=w>h?'0 59px 21px':w>=768?'24px 0 20px':'62px 0 34px';requestAnimationFrame(pages);}
function pages(){const doc=frame.contentDocument;const w=frame.contentWindow.innerWidth;const count=Math.round(doc.scrollingElement.scrollWidth/w);const current=Math.round(frame.contentWindow.scrollX/w)+1;document.getElementById('pagination').textContent=current+'/'+count;}
function theme(name){const colors={light:['#fff','#121212'],dark:['#000','#fefefe'],paper:['#faf4e8','#121212']};const [bg,fg]=colors[name];device.style.background=bg;device.style.color=fg;const style=frame.contentDocument.documentElement.style;style.setProperty('--USER__backgroundColor',bg);style.setProperty('--USER__textColor',fg);}
function turn(){frame.contentWindow.scrollBy(frame.contentWindow.innerWidth,0);requestAnimationFrame(pages);}
frame.addEventListener('load',()=>{theme('light');pages();new ResizeObserver(pages).observe(frame);});
</script></body></html>"""
(output / "index.html").write_text(preview, encoding="utf-8")
print(json.dumps({"preview": str(output / "index.html")}, ensure_ascii=False))
