# 综合实验应用

`./scripts/build-dev-app.sh --combined-experiment /path/to/output` 生成独立签名测试包，bundle ID 为 `local.jarvis.combined-experiment`，数据目录为 `~/Library/Application Support/Jarvis-Combined-Experiment`。其数据、系统权限和偏好与正式应用独立。它不可与其他实验构建选项同时使用。

三项实验默认关闭：在应用的语音诊断设置里明确开启实验性语音停顿检测；启动进程时分别设置 `JARVIS_EXPERIMENTAL_SAFARI_READ=1` 和 `JARVIS_EXACT_BROWSER_OPT_IN=1`，以启用 Safari 读取和完整网址打开。这些开关相互独立；它们不会跳过具体操作的审批。Safari 读取仍需 macOS 辅助功能权限。不要将测试包用于尚未完成授权或隐私审查的正式用途。
