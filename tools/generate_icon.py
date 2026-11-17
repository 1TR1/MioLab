"""将用户提供的图像适配为不透明 App 图标，保留原始素材。"""
from pathlib import Path
from PIL import Image, ImageOps

# 原图随源码保存，重新构建时不依赖聊天临时目录，也不对角色内容进行重绘。
root = Path(__file__).resolve().parents[1]
source = root / "Assets" / "AppIconSource.png"
with Image.open(source) as original:
    image = ImageOps.fit(original.convert("RGBA"), (1024, 1024), Image.Resampling.LANCZOS)

# iOS 图标必须不透明；仅合成透明通道，圆角由系统安装后统一裁切。
background = Image.new("RGBA", image.size, (246, 245, 242, 255))
background.alpha_composite(image)
destination = root / "Assets" / "AppIcon.png"
background.convert("RGB").save(destination)
print(destination)
