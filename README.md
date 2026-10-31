# PCL HaoyuHuang 特别版

第三方基于 Plain Craft Launcher（PCL）独立修改的 Windows Minecraft 启动器。
原作者：龙腾猫跃。[支持原作者](https://meloong.com/afd/a/LTCat)。

基于上游 `93ede5d9e638c99fcec853a9ba1eecd91ceee7f5`（2.99.0.1），MeloongCore 固定为 `4c60c2962c3b50bc3fe96ed5dd9259b980173580`。

## 使用

解压 Windows 包到一个独立文件夹，双击 `PCL-HaoyuHuang-Special-2.99.0.1.exe`。需要 Windows 和 .NET Framework 4.8。
在“下载”中选择 Minecraft 版本即可安装；模组加载器、整合包安装与文件补全沿用 PCL 的下载流程。
在“更多 → 百宝箱”中使用今日人品、内存优化、清理游戏垃圾、千万别点、回声洞和自定义文件下载。
百宝箱沿用公开版本的布局、文案、动画和功能流程。清理游戏垃圾会删除游戏日志、错误报告、调试输出、可重新解压的原生库和本特别版全部缓存，完成后关闭或重启启动器；自定义缓存路径会在确认框中明确显示。

本版本在编译时开启 Minecraft 下载；启动器自动更新、更新替换入口、远程配置和公告均关闭。
功能所需的联网保留：Minecraft 版本列表、游戏文件、组件、在线主页及百宝箱。遥测与匿名数据上报已移除。
本版本使用独立的注册表、默认缓存目录和单实例标识。请保留独立文件夹，以隔离目录内的配置文件。

这是从公开源码构建的版本。微软登录需要你自行申请并通过环境变量 `PCL_MS_CLIENT_ID` 提供 Client ID；
CurseForge 资源需要通过环境变量 `PCL_CURSEFORGE_API_KEY` 提供 API Key。设置后重新打开启动器。
Minecraft 原版下载不依赖这两个值。联机功能所需的官方远程配置未随公开源码提供。

启动器不会自行接收或安装后续版本。远端下载服务、API 或文件地址未来若发生变化，仍可能需要手动维护。

## 微软正版登录配置

此源码构建未内置应用 Client ID。应用配置由启动器开发者完成一次；获得可用的应用授权并内置 Client ID 后，普通使用者只需使用拥有 Minecraft Java 版的微软个人账号登录。

1. 在 [Microsoft Entra 应用注册](https://entra.microsoft.com/)注册应用，账号类型包含“个人 Microsoft 账号”。当前代码使用 `/consumers`。
2. 在 Authentication 的 Advanced settings 中启用 **Allow public client flows**。本版本使用设备代码流程，无需 Client Secret 或回调地址。
3. 按 [Minecraft 官方 API 审核说明](https://help.minecraft.net/hc/en-us/articles/16254801392141)，通过 [AppID Review](https://aka.ms/mce-reviewappid)申请应用访问授权。Client ID 注册成功不代表 Minecraft Services 已批准访问；若返回 `403 Invalid app registration`，应检查应用审核状态。审核要求身份验证及游戏所有权校验，保留离线启动的应用可能需要调整相关策略才能满足条件，审批结果不作保证。
4. 将 Application (client) ID 保存为 Windows 用户环境变量 `PCL_MS_CLIENT_ID`，关闭全部特别版进程后重新打开。可在 PowerShell 中执行：

```powershell
[Environment]::SetEnvironmentVariable("PCL_MS_CLIENT_ID", (Read-Host "输入自己的应用 Client ID"), "User")
```

Client ID 是应用标识，不是微软账号密码。当前包没有完成真实账号的端到端登录验证；应用授权及游戏所有权仍由 Microsoft/Minecraft 服务核验。

参考：[微软桌面应用配置](https://learn.microsoft.com/en-us/entra/identity-platform/scenario-desktop-app-configuration)、[设备代码协议](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-device-code)。

## 源码与构建

源码随 `PCL-HaoyuHuang-Special-2.99.0.1-Source.zip` 提供，包含特别版本的 MeloongCore。
源码及修改保留仓库中的 `LICENCE`、正版购买提示、原作者署名与赞助链接。
特别版本由 HaoyuHuang 开发，关于页面使用其提供的头像。主题页面的全部 15 项可选，色值和渐变参考公开快照版本的主题实现，包含“滑稽彩”动态轮色、“欧皇彩”固定三段渐变和自定义调色。

主题参数交叉核对来源：[快照版主题实现](https://github.com/TomorrowX6/PCL-Snapshot/blob/d867f395b2b79939127b95e873e2c2c6113cb53f/PCL/ModSecret.cs#L576)、[第二份公开实现](https://github.com/oliverlacey426/PCLCRK/blob/51def4747a2437e9d2b35d7810e3727167fc461b/PCL2_Source_CS/Source/PCL/ModSecret.cs#L474)。

百宝箱布局与流程参考[公开快照实现](https://github.com/TomorrowX6/PCL-Snapshot/blob/d867f395b2b79939127b95e873e2c2c6113cb53f/PCL/PageOtherTest.xaml.cs)，回声洞保留公开版本内置的 735 条文本、原版分组抽取、31 条预设提示及闪烁逐字动画。

Windows 安装 Visual Studio 2022 Build Tools（.NET 桌面开发、.NET Framework 4.8 SDK）、PowerShell 7 及支持 C# 13 的 .NET SDK 后执行：

```powershell
./tools/Build.ps1
pwsh -NoProfile -File ./tools/SmokeTest.ps1 -ExecutablePath ./dist/PCL-HaoyuHuang-Special-2.99.0.1.exe -WorkDirectory ./artifacts/smoke
```

`dist` 目录包含程序、Windows 压缩包、源码压缩包与 SHA-256 校验文件。
`SmokeTest.ps1` 在隔离目录内检验实际下载器、文件哈希及更新行为；结果保存为 `smoke-result.json`。
GitHub Actions 使用 Windows 构建，并固定检出的源代码与 MeloongCore 版本，不同步上游帮助库或源代码。

---

## 上游项目资料

# Plain Craft Launcher

[![Stars](https://img.shields.io/github/stars/Meloong-Git/PCL?style=flat&logo=data:image/svg%2bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZlcnNpb249IjEiIHdpZHRoPSIxNiIgaGVpZ2h0PSIxNiI+PHBhdGggZD0iTTggLjI1YS43NS43NSAwIDAgMSAuNjczLjQxOGwxLjg4MiAzLjgxNSA0LjIxLjYxMmEuNzUuNzUgMCAwIDEgLjQxNiAxLjI3OWwtMy4wNDYgMi45Ny43MTkgNC4xOTJhLjc1MS43NTEgMCAwIDEtMS4wODguNzkxTDggMTIuMzQ3bC0zLjc2NiAxLjk4YS43NS43NSAwIDAgMS0xLjA4OC0uNzlsLjcyLTQuMTk0TC44MTggNi4zNzRhLjc1Ljc1IDAgMCAxIC40MTYtMS4yOGw0LjIxLS42MTFMNy4zMjcuNjY4QS43NS43NSAwIDAgMSA4IC4yNVoiIGZpbGw9IiNlYWM1NGYiLz48L3N2Zz4=&logoSize=auto&label=Stars&labelColor=444444&color=eac54f)](https://github.com/Meloong-Git/PCL/)
[![哔哩哔哩](https://img.shields.io/badge/动态-BiliBili-00A4DB?style=flat&labelColor=444444&logoSize=auto)](https://space.bilibili.com/11343203/dynamic)
[![爱发电](https://img.shields.io/badge/赞助-爱发电-946ce6?style=flat&labelColor=444444&logoSize=auto)](https://meloong.com/afd/a/LTCat)

包含 PCL 的大部分源代码，包括 UI 库、动画模块、下载模块、Minecraft 启动模块等！<br/>
代码并不是实时更新的，它会在每次 PCL 发布更新时同步一次。<br/>
非常感谢社区的大力支持！

<br/>

### 相关资源
- [PCL 下载](https://meloong.com/pcl)：下载可免费使用的正式版 PCL！
- [帮助文档库](https://github.com/LTCatt/PCL2Help)：PCL 内置帮助文档的存储库
