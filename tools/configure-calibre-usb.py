"""通过 Calibre 自带 Python 为已安装的 MioLib USB 插件添加工具栏和右键入口。"""
from calibre.gui2 import gprefs

# 只加入自己的插件动作，保留现有按钮顺序；重复执行不会生成重复入口。
for name in ('action-layout-toolbar', 'action-layout-toolbar-device', 'action-layout-context-menu'):
    actions = list(gprefs[name])
    if 'MioLib USB' not in actions:
        position = actions.index('Add Books') + 1 if 'Add Books' in actions else len(actions)
        actions.insert(position, 'MioLib USB')
        gprefs[name] = actions
print('MioLib USB toolbar configured')
