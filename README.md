# PCL HY916 固定版

第三方基于 Plain Craft Launcher（PCL）独立修改的 Windows Minecraft 启动器。
原作者：龙腾猫跃。[支持原作者](https://meloong.com/afd/a/LTCat)。

基于上游 `93ede5d9e638c99fcec853a9ba1eecd91ceee7f5`（2.99.0.1），MeloongCore 固定为 `4c60c2962c3b50bc3fe96ed5dd9259b980173580`。

## 使用

解压 Windows 包到一个独立文件夹，双击 `PCL-HY916-Fixed-2.99.0.1.exe`。需要 Windows 和 .NET Framework 4.8。
在“下载”中选择 Minecraft 版本即可安装；模组加载器、整合包安装与文件补全沿用 PCL 的下载流程。

本版本在编译时开启 Minecraft 下载；启动器自动更新、更新替换入口、远程配置和公告均关闭，更新设置固定为关闭。
主页支持空白、本地文件与本地预设，联网主页关闭。Minecraft 版本列表、游戏文件及组件仍正常联网获取。
本版本使用独立的注册表、默认缓存目录和单实例标识。请保留独立文件夹，以隔离目录内的配置文件。

这是从公开源码构建的版本。微软登录需要你自行申请并通过环境变量 `PCL_MS_CLIENT_ID` 提供 Client ID；
CurseForge 资源需要通过环境变量 `PCL_CURSEFORGE_API_KEY` 提供 API Key。设置后重新打开启动器。
Minecraft 原版下载不依赖这两个值。源码未包含官方联机配置和赞助主题解锁实现。

启动器不会自行接收或安装后续版本。远端下载服务、API 或文件地址未来若发生变化，仍可能需要手动维护。

## 源码与构建

源码随 `PCL-HY916-Fixed-2.99.0.1-Source.zip` 提供，包含固定版本的 MeloongCore。
源码及修改保留仓库中的 `LICENCE`、正版购买提示、原作者署名与赞助链接。
特别版本由 Haoyu Huang 开发，关于页面使用其提供的头像。主题页面的全部 15 项可选，包含两种动态配色和自定义调色。

Windows 安装 Visual Studio 2022 Build Tools（.NET 桌面开发、.NET Framework 4.8 SDK）及支持 C# 13 的 .NET SDK 后执行：

```powershell
./tools/Build.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File ./tools/SmokeTest.ps1 -ExecutablePath ./dist/PCL-HY916-Fixed-2.99.0.1.exe -WorkDirectory ./artifacts/smoke
```

`dist` 目录包含程序、Windows 压缩包、源码压缩包与 SHA-256 校验文件。
`SmokeTest.ps1` 在隔离目录内检验实际下载器、文件哈希及更新行为；结果保存为 `smoke-result.json`。
GitHub Actions 使用 Windows 构建，并固定检出的源代码与 MeloongCore 版本，不同步上游帮助库或源代码。

---

## 上游项目资料

# Plain Craft Launcher

[![Stars](https://img.shields.io/github/stars/Meloong-Git/PCL?style=flat&logo=data:image/svg%2bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZlcnNpb249IjEiIHdpZHRoPSIxNiIgaGVpZ2h0PSIxNiI+PHBhdGggZD0iTTggLjI1YS43NS43NSAwIDAgMSAuNjczLjQxOGwxLjg4MiAzLjgxNSA0LjIxLjYxMmEuNzUuNzUgMCAwIDEgLjQxNiAxLjI3OWwtMy4wNDYgMi45Ny43MTkgNC4xOTJhLjc1MS43NTEgMCAwIDEtMS4wODguNzkxTDggMTIuMzQ3bC0zLjc2NiAxLjk4YS43NS43NSAwIDAgMS0xLjA4OC0uNzlsLjcyLTQuMTk0TC44MTggNi4zNzRhLjc1Ljc1IDAgMCAxIC40MTYtMS4yOGw0LjIxLS42MTFMNy4zMjcuNjY4QS43NS43NSAwIDAgMSA4IC4yNVoiIGZpbGw9IiNlYWM1NGYiLz48L3N2Zz4=&logoSize=auto&label=Stars&labelColor=444444&color=eac54f)](https://github.com/Meloong-Git/PCL/)
[![Issues](https://img.shields.io/github/issues/Meloong-Git/PCL?style=flat&label=Issues&labelColor=444444&color=1F883D)](https://github.com/Meloong-Git/PCL/issues)
[![哔哩哔哩](https://img.shields.io/badge/动态-BiliBili-00A4DB?style=flat&labelColor=444444&logoSize=auto)](https://space.bilibili.com/11343203/dynamic)
[![爱发电](https://img.shields.io/badge/赞助-爱发电-946ce6?style=flat&labelColor=444444&logoSize=auto)](https://meloong.com/afd/a/LTCat)

包含 PCL 的大部分源代码，包括 UI 库、动画模块、下载模块、Minecraft 启动模块等！<br/>
代码并不是实时更新的，它会在每次 PCL 发布更新时同步一次。<br/>
非常感谢社区的大力支持！

<br/>

### 相关资源
- [PCL 下载](https://meloong.com/pcl)：下载可免费使用的正式版 PCL！
- [PCL 功能投票](https://github.com/Meloong-Git/PCL/discussions/2)：来参加投票吧，开发者会优先处理票数较高的项目！
- [帮助文档库](https://github.com/LTCatt/PCL2Help)：PCL 内置帮助文档的存储库
