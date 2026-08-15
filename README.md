# DeepSeek 桌面悬浮窗

一个运行在 Windows 桌面上的小型悬浮窗，实时显示 DeepSeek API 余额、今日 Token 用量和今日消费。

## 功能

- 余额、今日 Token、今日消费一眼可见
- 支持拖动、收起、手动刷新
- 默认每 1 分钟自动刷新，窗口重新激活时也会刷新，可在设置中改为 1-120 分钟
- API Key 和用量 Token 使用 Windows 当前用户加密后保存在本机
- 支持一键授权获取用量 Token，也支持手动粘贴

## 环境要求

- Windows 10 / Windows 11
- PowerShell 5.1（Windows 自带）
- Node.js（可选，仅“一键授权获取用量 Token”需要）

## 快速开始

1. 下载本项目，双击 `start-widget.bat` 启动，窗口默认出现在屏幕右上角。
2. 点击右上角设置按钮，粘贴你的 DeepSeek API Key。
3. 点击“一键授权获取用量 Token”，在弹出的浏览器窗口中登录 DeepSeek 平台并停留在用量页面，授权会自动完成。
4. 点击“保存”，悬浮窗立即刷新并显示余额、今日 Token 和今日消费。

详细步骤见 [使用说明.md](使用说明.md)。

## 配置与隐私

- 余额来自 DeepSeek 官方接口 `/user/balance`。
- 今日 Token 和消费来自 DeepSeek 平台用量接口。DeepSeek 没有开放官方的用量查询 API，因此需要一次登录授权；Token 失效后重新授权一次即可。
- API Key 和用量 Token 只保存在本机 `config.json`，保存后会用 Windows 当前用户加密，不会上传到任何地方。
- 本仓库不包含 `config.json`，首次使用请参考 `config.example.json` 手动创建，或直接在设置窗口中填写并保存。

## 开机自启

把 `start-widget.bat` 的快捷方式放入“启动”文件夹（按 Win+R 输入 `shell:startup` 回车即可打开）。

## 项目结构

```text
DeepSeek悬浮窗/
├─ DeepSeekWidget.ps1    # 悬浮窗主程序（PowerShell/WPF）
├─ start-widget.bat      # 一键启动脚本
├─ capture-token.mjs     # 一键授权辅助脚本（需要 Node.js）
├─ config.example.json   # 配置示例
└─ 使用说明.md            # 详细使用说明
```

## License

MIT
