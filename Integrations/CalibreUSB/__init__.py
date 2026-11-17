from calibre.customize import InterfaceActionBase


# 命令行只加载插件说明，Qt 界面和传书代码在用户打开按钮时才载入。
class MioLibUSBPlugin(InterfaceActionBase):
    name = 'MioLib USB'
    description = '通过 USB 将 Calibre 所选书籍直接发送至 iPhone 上的 MioLib'
    supported_platforms = ['windows']
    author = 'MioLib'
    version = (1, 0, 0)
    minimum_calibre_version = (7, 0, 0)
    actual_plugin = 'calibre_plugins.miolib_usb.ui:MioLibUSBAction'
