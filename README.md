# PCL特别版

第三方基于 Plain Craft Launcher（PCL）独立修改的 Windows Minecraft 启动器。
制作开发者：Haoyu Huang。
原作者：龙腾猫跃。[支持原作者](https://meloong.com/afd/a/LTCat)。

基于上游 `93ede5d9e638c99fcec853a9ba1eecd91ceee7f5`（2.99.0.1），MeloongCore 固定为 `4c60c2962c3b50bc3fe96ed5dd9259b980173580`。

## 使用

解压 Windows 包到一个独立文件夹，双击 `PCL特别版-2.99.0.1.exe`。需要 Windows 和 .NET Framework 4.8。
在“下载”中选择 Minecraft 版本即可安装；模组加载器、整合包安装与文件补全沿用 PCL 的下载流程。
在“更多 → 百宝箱”中使用今日人品、内存优化、清理游戏垃圾、千万别点、回声洞和自定义文件下载。
百宝箱沿用公开版本的布局、文案、动画和功能流程。清理游戏垃圾会删除游戏日志、错误报告、调试输出、可重新解压的原生库和本特别版全部缓存，完成后关闭或重启启动器；自定义缓存路径会在确认框中明确显示。
百宝箱今日人品使用公开版本的本地设备识别码算法，同一天在同一设备和配置下结果保持一致。设备码由本地主板标识和持久化本地种子生成，仅在本地使用；升级时会兼容迁移此前特别版保存的加密设置与账号缓存。

本版本在编译时开启 Minecraft 下载；启动器自动更新、更新替换入口、远程配置和公告均关闭。
功能所需的联网保留：Minecraft 版本列表、游戏文件、组件、联机、在线主页及百宝箱。遥测与匿名数据上报已移除。
本版本使用独立的注册表、默认缓存目录和单实例标识。请保留独立文件夹，以隔离目录内的配置文件。

微软正版登录默认采用公开发行版使用的应用 Client ID，点击“正版”后在微软官方网站完成设备代码授权。
发行包默认使用与公开发行版 2.99.0.1 相同的 CurseForge API Key，可直接查询 CurseForge 模组与整合包；仍保留 MCIM 镜像切源。可通过环境变量 `PCL_CURSEFORGE_API_KEY` 覆盖默认 Key，设置后重新打开启动器。
Minecraft 原版下载不依赖 CurseForge API Key。联机使用本地固定配置与 EasyTier，保留原版创建房间、邀请码加入和端口转发流程。

启动器不会自行接收或安装后续版本。远端下载服务、API 或文件地址未来若发生变化，仍可能需要手动维护。

## 中国大陆下载源优化

默认的“自动选择”优先尝试 BMCLAPI 镜像，覆盖游戏本体、资源、支持库、版本描述及映射文件。版本与组件列表在首选源尚未完成时，约 1 秒后并行尝试官方源，先成功的结果继续使用；镜像缺少目标新版本时也会尝试官方数据。

在“设置 → 其他 → 下载”中仍可手动选择镜像优先或官方优先。文件下载沿用原下载器的失败切源、文件大小和已知哈希校验，继续使用原有并发与限速设置。默认 64 线程及不限速即可使用本优化。

镜像服务会自行决定缓存、分发或回源。本次连通性检查中，部分客户端 JAR 的镜像入口重定向到了官方 CDN；因此不能保证所有文件都由国内节点分发。当前测试环境不代表中国大陆各运营商线路，实际速度应在你的网络中测量，不承诺固定提速倍数。

服务资料：[BMCLAPI 官方文档](https://bmclapidoc.bangbang93.com/)、[OpenBMCLAPI 官方说明](https://github.com/bangbang93/openbmclapi)。

## 联机

房主先在 Minecraft 单人游戏暂停菜单中选择“对局域网开放”，记下端口，再在启动器顶部“联机 → 创建房间”输入端口。将生成的邀请码发给朋友，朋友在“联机 → 加入房间”中输入邀请码，连接后在 Minecraft 多人游戏列表中进入房间；正版登录时也可使用页面提供的本地服务器地址。建议参与者使用相同的特别版，游戏版本与模组应互相兼容。

首次使用会下载并校验固定的 [EasyTier 2.6.4](https://github.com/EasyTier/EasyTier/releases/tag/v2.6.4)，各架构 ZIP 的 SHA-256 固定在源码中。后续复用本地模块。使用[无 TUN 模式](https://www.easytier.cn/guide/network/no-root.html)转发所选游戏端口，无需安装虚拟网卡。模块版本由本地代码确定；联机不会接收 PCL 远程配置中的版本门槛或关闭指令。

默认保留社区节点选择与固定节点回退。可在“设置 → 联机 → 高级设置 → 自定义节点”中填写自己的 EasyTier 节点，多个地址用逗号分隔，房主与加入者应填写一致。连接结果仍受双方 NAT、防火墙、网络线路和社区节点状态影响。

验证脚本会使用实际 Windows 模块下载器、安装函数和启动参数，运行两个回环连接的原生进程并检查 TCP、UDP 数据转发、客户端地址分配与 CLI 节点信息；这不等同于跨运营商 NAT 穿透或公网中继测试。

## 微软正版登录

默认 Client ID 为 `fe72edc2-3a6f-4280-90e8-e2beb64ce7e1`，已静态核对公开发行版 2.99.0.1 与[公开快照实现](https://github.com/TomorrowX6/PCL-Snapshot/blob/d867f395b2b79939127b95e873e2c2c6113cb53f/PCL/ModSecret.cs#L380)使用相同值。它是原版的应用注册标识；微软授权界面展示该应用的注册信息。

在启动页选择“正版”，点击登录并在自动打开的微软网页输入设备代码，使用拥有 Minecraft Java 版的微软个人账号授权。随后由 Microsoft、Xbox 与 Minecraft 服务完成账号和游戏资格验证。设备码只在登录弹窗中显示，不写入日志。

已验证默认应用可以向微软接口申请设备登录码。设备码签发不代表完整账号登录成功，当前包尚未完成真实账号端到端登录验证。应用所有者和 Microsoft/Minecraft 服务仍可调整或撤销该应用的访问权限。

如果你希望使用自己注册的应用，可通过 `PCL_MS_CLIENT_ID` 覆盖默认值。更换应用后应在启动器中退出账号并重新登录，旧应用的刷新令牌不能用于新应用。自有应用配置如下：

1. 在 [Microsoft Entra 应用注册](https://entra.microsoft.com/)注册应用，账号类型包含“个人 Microsoft 账号”。当前代码使用 `/consumers`。
2. 在 Authentication 的 Advanced settings 中启用 **Allow public client flows**。本版本使用设备代码流程，无需 Client Secret 或回调地址。
3. 按 [Minecraft 官方 API 审核说明](https://help.minecraft.net/hc/en-us/articles/16254801392141)，通过 [AppID Review](https://aka.ms/mce-reviewappid)申请应用访问授权。Client ID 注册成功不代表 Minecraft Services 已批准访问；若返回 `403 Invalid app registration`，应检查应用审核状态。审核要求身份验证及游戏所有权校验，保留离线启动的应用可能需要调整相关策略才能满足条件，审批结果不作保证。
4. 将 Application (client) ID 保存为 Windows 用户环境变量 `PCL_MS_CLIENT_ID`，关闭全部特别版进程后重新打开。可在 PowerShell 中执行：

```powershell
[Environment]::SetEnvironmentVariable("PCL_MS_CLIENT_ID", (Read-Host "输入自己的应用 Client ID"), "User")
```

Client ID 是应用标识，不是微软账号密码；此设备代码流程不需要 Client Secret。

参考：[微软桌面应用配置](https://learn.microsoft.com/en-us/entra/identity-platform/scenario-desktop-app-configuration)、[设备代码协议](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-device-code)。

## 源码与构建

源码随 `PCL特别版-2.99.0.1-Source.zip` 提供，包含特别版本的 MeloongCore。
源码及修改保留仓库中的 `LICENCE`、正版购买提示、原作者署名与赞助链接。
PCL特别版由 Haoyu Huang 制作开发，关于页面使用其提供的头像。主题页面的全部 15 项可选，色值和渐变参考公开快照版本的主题实现，包含“滑稽彩”动态轮色、“欧皇彩”固定三段渐变和自定义调色。

主题参数交叉核对来源：[快照版主题实现](https://github.com/TomorrowX6/PCL-Snapshot/blob/d867f395b2b79939127b95e873e2c2c6113cb53f/PCL/ModSecret.cs#L576)、[第二份公开实现](https://github.com/oliverlacey426/PCLCRK/blob/51def4747a2437e9d2b35d7810e3727167fc461b/PCL2_Source_CS/Source/PCL/ModSecret.cs#L474)。

百宝箱布局与流程参考[公开快照实现](https://github.com/TomorrowX6/PCL-Snapshot/blob/d867f395b2b79939127b95e873e2c2c6113cb53f/PCL/PageOtherTest.xaml.cs)，回声洞保留公开版本内置的 735 条文本、原版分组抽取、31 条预设提示及闪烁逐字动画。

Windows 安装 Visual Studio 2022 Build Tools（.NET 桌面开发、.NET Framework 4.8 SDK）、PowerShell 7 及支持 C# 13 的 .NET SDK 后执行：

```powershell
./tools/Build.ps1
pwsh -NoProfile -File ./tools/SmokeTest.ps1 -ExecutablePath ./dist/PCL特别版-2.99.0.1.exe -WorkDirectory ./artifacts/smoke
```

`dist` 目录包含程序、Windows 压缩包、源码压缩包与 SHA-256 校验文件。
CurseForge Key 通过受保护的 GitHub Actions Secret 在编译时注入，源码与源码压缩包保留空默认值。本地构建如需内置 Key，请在运行构建脚本前设置进程环境变量 `PCL_CURSEFORGE_API_KEY`；也可在运行启动器时通过该变量提供 Key。
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
