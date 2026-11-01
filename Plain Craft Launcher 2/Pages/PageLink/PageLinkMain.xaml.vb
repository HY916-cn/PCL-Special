Imports System.Collections.ObjectModel
Imports System.Globalization
Imports System.Net.Sockets
Imports System.Text.RegularExpressions
Imports PCL

Public Class PageLinkMain
    Private Const INVITE_CODE_VERSION As Integer = 2
    Private Const EasyTierVersion As String = "2.6.4"
    Private Const FallbackDiscoverID As Integer = 94
    Private Const FallbackDiscoverAddress As String = "tcp://mc1.easytier.cn:55558"
    Private ModuleArchitecture As String

    '===============================
    '  状态机与前端页面
    '===============================

#Region "状态管理"

    Public Enum LinkStates
        Waiting
        Loading
        Failed
        Finished
    End Enum
    Public Shared LinkState As LinkStates = LinkStates.Waiting

    ''' <summary>
    ''' 切换到指定的状态。
    ''' </summary>
    Private Sub ChangeState(NewState As LinkStates)
        If LinkState = NewState Then Return
        Dim OldState = LinkState
        LinkState = NewState
        Logger.Info($"主状态由 {OldState} 变更为 {NewState}")
        '触发状态切换
        RunInUi(
        Sub()
            Select Case NewState
                Case LinkStates.Waiting
                    SwitchToWaiting(OldState)
                Case LinkStates.Loading
                    SwitchToLoading(OldState)
                Case LinkStates.Failed
                    SwitchToFailed(OldState)
                Case LinkStates.Finished
                    SwitchToFinished(OldState)
            End Select
        End Sub)
    End Sub

    '让加载器的 成功/失败 事件触发状态切换
    Private Sub LoaderInit() Handles Me.Initialized
        PageLoaderInit(Load, PanLoad, PanContent, PanAlways, LinkLoader, AutoRun:=False)
        AddHandler LinkLoader.OnStateChangedUi,
        Sub(Loader As LoaderBase, NewState As LoadState, OldState As LoadState)
            Select Case NewState
                Case LoadState.Finished
                    ChangeState(LinkStates.Finished)
                Case LoadState.Failed
                    ChangeState(LinkStates.Failed)
            End Select
        End Sub
    End Sub

    '页面动画兼容
    Private Sub UpdatePanelVisibility() Handles Me.PageEnter
        FrmLinkMain.PanSelect.Visibility = If(LinkState = LinkStates.Waiting, Visibility.Visible, Visibility.Collapsed)
        FrmLinkMain.PanFinish.Visibility = If(LinkState = LinkStates.Finished, Visibility.Visible, Visibility.Collapsed)
    End Sub

#End Region

#Region "初始页面 (Waiting)"

    '由任意状态切换到 Waiting
    Private Sub SwitchToWaiting(OldState As LinkStates)
        '加载器与进程状态
        LinkLoader.Cancel()
        SyncLock LinkLoader.LockState
            LinkLoader.State = LoadState.Waiting
        End SyncLock
        ProcessStop()
        '页面切换
        If OldState <> LinkStates.Finished Then
            '从完成页面退出时，PageOnContentExit 结束会触发 PageEnter 事件，这会调用 UpdatePanelVisibility
            '如果在现在提前调用了，会丢失完成页面的退出动画
            UpdatePanelVisibility()
        End If
        PageOnContentExit()
    End Sub

    '===============================
    '  页面 UI
    '===============================

    '创建
    Private Sub Create_MouseLeftButtonUp() Handles PanSelectCreate.MouseLeftButtonUp
        '输入端口号
        Dim Port As String = MyMsgBoxInput("输入端口", $"在单人游戏的暂停菜单选择 {vbLQ}对局域网开放{vbRQ}，然后输入端口数字。{vbCrLf}甚至可以输入其他游戏的端口……嗯……",
            ValidateRules:=New Collection(Of Validate) From {New ValidateInteger(1024, 65535)},
            HintText:="端口号")
        If Port Is Nothing Then Return
        '基础信息
        IsServerSide = True
        ServerPort = Port
        Dim GenerateRandomCode =
        Function() As String
            Dim Result As String = ""
            For i = 1 To 5
                Result &= RandomInteger(0, 35).ConvertRadix(36)
            Next
            Return Result.Replace("O", "0").Replace("I", "1")
        End Function
        NetworkName = $"P{ServerPort.ConvertRadix(16).PadLeft(4, "0"c)}-{GenerateRandomCode()}"
        NetworkSecret = GenerateRandomCode()
        DiscoverNodeID = -1
        Logger.Info($"尝试创建房间，端口 {ServerPort}")
        '启动
        ChangeState(LinkStates.Loading)
    End Sub

    '加入
    Private Shared LastCode As String = Nothing
    ''' <summary>
    ''' 输入邀请码，切换到联机页并立即加入房间。
    ''' </summary>
    Public Shared Sub Join() Handles PanSelectJoin.MouseLeftButtonUp
        Dim Code As String = MyMsgBoxInput("输入邀请码", "输入房主发给你的邀请码。",
            HintText:=If(String.IsNullOrEmpty(LastCode), "", "使用上一次的邀请码"))
        If Not String.IsNullOrEmpty(LastCode) AndAlso Code IsNot Nothing AndAlso Code = "" Then Code = LastCode
        If Code Is Nothing Then Return
        Join(Code)
    End Sub
    Public Sub JoinInternal(Code As String)
        If Code Is Nothing Then Return
        '基础格式校验
        Dim ValidateResult = ValidateCodeFormat(Code)
        If ValidateResult IsNot Nothing Then
            Hint(ValidateResult, HintType.Red)
            Return
        End If
        Code = FixCodeFormat(Code)
        '基础信息
        IsServerSide = False
        ServerPort = Code.Substring(1, 4).Upper.ConvertRadix(16, 10)
        NetworkName = Code.Substring(0, 11)
        NetworkSecret = Code.Substring(12, 5)
        If Code.Substring(20, 3) = "000" Then
            DiscoverNodeID = -2
        Else
            DiscoverNodeID = Code.Substring(20, 3).Upper.ConvertRadix(16, 10)
        End If
        Logger.Info($"尝试加入房间，端口 {ServerPort}，发现节点 {DiscoverNodeID}")
        '启动
        LastCode = Code
        ChangeState(LinkStates.Loading)
    End Sub
    Public Shared Function ValidateCodeFormat(Code As String) As String
        If Code Is Nothing Then Return "邀请码为空！"
        Code = FixCodeFormat(Code)
        If Not Regex.IsMatch(Code, "\AP[0-9A-F]{4}-[0-9A-Z]{5}-[0-9A-Z]{5}-[0-9]{2}[0-9A-F]{3}\z") Then
            If Code.StartsWithF("U/") Then
                Return "请让房主使用 PCL 创建房间！"
            ElseIf Code.Length = 10 Then
                Return "请让房主使用非社区版的 PCL 创建房间！"
            End If
            Return "邀请码有误，请让房主使用 PCL 创建房间！"
        End If
        Dim Port = Integer.Parse(Code.Substring(1, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture)
        If Port < 1024 Then Return "邀请码中的端口号有误！"
        Dim Version = Integer.Parse(Code.Substring(18, 2), CultureInfo.InvariantCulture)
        If Version > INVITE_CODE_VERSION Then Return "你的 PCL 版本太老了，请在更新 PCL 之后再联机！"
        If Version < 1 Then Return "邀请码版本有误！"
        Return Nothing
    End Function
    Private Shared Function FixCodeFormat(Code As String) As String
        If Code Is Nothing Then Return Nothing
        Code = Code.Trim().Between("【", "】").Between("[", "]")
        Code = Code.ToUpperInvariant().Replace("O", "0").Replace("I", "1")
        '版本 1 的完整邀请码没有版本与发现节点字段。
        If Regex.IsMatch(Code, "\AP[0-9A-F]{4}-[0-9A-Z]{5}-[0-9A-Z]{5}\z") Then Code &= "-0105E"
        Return Code
    End Function

    '自动加入

    ''' <summary>
    ''' 切换到联机页并立即加入指定房间。
    ''' </summary>
    Public Shared Sub Join(Code As String)
        If LinkState <> LinkStates.Waiting Then
            Hint("你已经在联机房间中了！", HintType.Red)
        ElseIf FrmMain.PageCurrent = FormMain.PageType.Link Then
            FrmLinkMain.JoinInternal(Code)
        Else
            AutoJoinCode = Code
            FrmMain.PageChange(FormMain.PageType.Link, FormMain.PageSubType.LinkMain)
        End If
    End Sub
    '在进入页面时自动尝试加入房间
    Private Shared AutoJoinCode As String = Nothing
    Private Sub PanSelectJoin_Loaded() Handles PanSelectJoin.Loaded
        If AutoJoinCode Is Nothing Then Return
        If LinkState = LinkStates.Waiting Then JoinInternal(AutoJoinCode)
        AutoJoinCode = Nothing
    End Sub

#End Region

#Region "加载页面 (Loading | Failed)"

    '由 Waiting 或 Failed 状态切换到 Loading
    Private Sub SwitchToLoading(OldState As LinkStates)
        '清理变量
        Peers = Nothing
        HasLocalAddress = False
        FailCount = 0
        '加载器与进程状态
        LinkLoader.Start(IsForceRestart:=True)
        '页面切换会由 Loader 调用 MyPageRight 来触发
        'UI 更新
        UpdateProgressBar(0)
        LabLoadTitle.Text = If(IsServerSide, "创建房间中", "加入房间中")
        UpdateLoadingPage("正在初始化……", "准备初始化")
    End Sub

    '由 Loading 状态切换到 Failed
    Private Sub SwitchToFailed(OldState As LinkStates)
        '加载器与进程状态
        LinkLoader.Cancel()
        ProcessStop()
        'UI 更新
        UpdateProgressBar(1)
        '显示错误信息
        LabLoadTitle.Text = FailReason
        Dim Brief As String = LinkLoader.Error.GetDisplay(False)
        Dim InnerEx As Exception = LinkLoader.Error
        If InnerEx.Message.StartsWithF("$") Then Brief = InnerEx.Message
        Do Until InnerEx.InnerException Is Nothing
            InnerEx = InnerEx.InnerException
            If InnerEx.Message.StartsWithF("$") Then Brief = InnerEx.Message
        Loop
        LabLoadDesc.Text = If(Brief.StartsWithF("$"), Brief.TrimStart("$"), LinkLoader.Error.GetDisplay(True))
        Logger.Warn(LinkLoader.Error, LabLoadTitle.Text)
    End Sub

    '===============================
    '  页面 UI
    '===============================

    Private Sub UpdateLoadingPage(Title As String, FailBrief As String)
        If FailReason = FailBrief & "失败" Then Return
        FailReason = FailBrief & "失败"
        Logger.Info($"开始步骤：{Title}")
        RunInUiWait(
        Sub()
            If FrmLinkMain Is Nothing OrElse Not FrmLinkMain.LabLoadDesc.IsLoaded Then Return
            FrmLinkMain.LabLoadDesc.Text = Title
        End Sub)
    End Sub
    Private FailReason As String = "准备初始化"

    '取消加载
    Private Sub BtnLoadCancel_Click() Handles BtnLoadCancel.Click
        ChangeState(LinkStates.Waiting)
    End Sub

    '点击重试
    Private Sub CardLoad_MouseLeftButtonUp() Handles CardLoad.MouseLeftButtonUp
        ChangeState(LinkStates.Loading)
    End Sub

    '进度条
    Private Sub UpdateProgressBar(Optional Value As Double = -1)
        If Value = -1 Then Value = LinkLoader.Progress
        Dim DisplayingProgress As Double = ColumnProgressA.Width.Value
        If Math.Round(Value - DisplayingProgress, 3) = 0 Then Return
        If DisplayingProgress <= Value Then
            Dim NewProgress As Double = If(Value = 1, 1, DisplayingProgress +
                (Value - DisplayingProgress) ^ 2 * 0.5)
            AniStart({
                AaGridLengthWidth(ColumnProgressA, NewProgress - ColumnProgressA.Width.Value, 200),
                AaGridLengthWidth(ColumnProgressB, (1 - NewProgress) - ColumnProgressB.Width.Value, 200)
            }, "Link Progress")
        Else
            ColumnProgressA.Width = New GridLength(Value, GridUnitType.Star)
            ColumnProgressB.Width = New GridLength(1 - Value, GridUnitType.Star)
            AniStop("Link Progress")
        End If
    End Sub
    Private Sub CardLoad_SizeChanged() Handles CardLoad.SizeChanged
        RectProgressClip.Rect = New Rect(0, 0, CardLoad.ActualWidth, 12)
    End Sub

#End Region

#Region "完成页面 (Finished)"

    '由 Loading 状态切换到 Finished
    Private Sub SwitchToFinished(OldState As LinkStates)
        '由于只可能从加载器的完成事件触发，不需要管加载器
        UpdatePanelVisibility() '页面的实际切换会由 Loader 调用 MyPageRight 来触发

        'UI 更新
        If IsServerSide Then
            LabFinishTitle.Text = "已创建房间"
            LabFinishDesc.Text = $"把邀请码发给朋友，让大家加入房间吧！{vbCrLf}邀请码：{GetInviteCode()}"
            BtnFinishExit.Text = "关闭"
            BtnFinishPing.ToolTip = "网络延迟"
            BtnFinishCopy.Visibility = Visibility.Visible
            Copy() '立即复制邀请码
            '下边栏
            BtnFinishPort.Visibility = Visibility.Visible
            LabFinishPort.Visibility = Visibility.Visible
            BtnFinishIp.Visibility = Visibility.Collapsed
            LabFinishIp.Visibility = Visibility.Collapsed
            LabFinishPort.Text = ServerPort
        Else
            LabFinishTitle.Text = "已加入房间"
            LabFinishDesc.Text = $"在多人游戏页面的最下方就能找到联机房间！{vbCrLf}注意：使用离线登录时不要手动输入 IP！"
            BtnFinishExit.Text = "离开"
            BtnFinishPing.ToolTip = "与房主的延迟"
            BtnFinishCopy.Visibility = Visibility.Collapsed
            '下边栏
            BtnFinishPort.Visibility = Visibility.Collapsed
            LabFinishPort.Visibility = Visibility.Collapsed
            LabFinishIp.Text = ClientAddress
            BtnFinishIp.Visibility = Visibility.Visible
            LabFinishIp.Visibility = Visibility.Visible
        End If
        Update() '立即刷新
    End Sub

    '===============================
    '  页面 UI
    '===============================

    '退出
    Private Sub BtnFinishExit_Click() Handles BtnFinishExit.Click
        TryExit(False, False)
    End Sub
    ''' <summary>
    ''' 退出联机。
    ''' 返回是否弹出了警告窗口并且玩家选择了取消。
    ''' </summary>
    Public Function TryExit(Silent As Boolean, Closing As Boolean) As Boolean
        If LinkState = LinkStates.Waiting OrElse LinkState = LinkStates.Failed Then Return False
        If Not Silent Then
            If IsServerSide AndAlso PeopleCount > 1 Then
                If MyMsgBox("你确定要关闭联机房间吗？" & vbCrLf & "所有玩家都需要重新输入邀请码才可加入游戏！", "退出联机", "确定", "取消", IsWarn:=True) = 2 Then Return True
            ElseIf Closing Then
                If MyMsgBox(If(IsServerSide, "你确定要关闭联机房间吗？", "你确定要离开联机房间吗？"), "退出联机", "确定", "取消") = 2 Then Return True
            End If
        End If
        ChangeState(LinkStates.Waiting)
        Return False
    End Function

    '复制邀请码
    Private Sub Copy() Handles BtnFinishCopy.Click
        Dim CodeText As String = $"在 PCL 启动器中输入邀请码【{GetInviteCode()}】，即可加入联机房间！"
        ClipboardSet(CodeText, False)
        Settings.Set("LinkLastAutoJoinInviteCode", CodeText)
        Hint("已复制邀请码！", HintType.Green)
    End Sub
    Private Function GetInviteCode() As String
        Return $"{NetworkName}-{NetworkSecret}-{INVITE_CODE_VERSION.ToString.PadLeft(2, "0"c)}{ _
            If(DiscoverNodeID < 0, 0, DiscoverNodeID).ConvertRadix(16).PadLeft(3, "0"c)}"
    End Function

    '复制 IP
    Private Sub BtnFinishIp_MouseLeftButtonUp(sender As Object, e As MouseButtonEventArgs) Handles BtnFinishIp.MouseLeftButtonUp
        ClipboardSet(ClientAddress, False)
        Hint("已复制服务器地址！", HintType.Green)
    End Sub

#End Region

    '===============================
    '  后端
    '===============================

    ''' <summary>
    ''' EasyTier 所在的文件夹路径，以 \ 结尾。
    ''' </summary>
    Private PathEasyTier As String = Paths.AppDataThenName & "EasyTier\"
    ''' <summary>
    ''' 当前是服务端还是客户端。
    ''' </summary>
    Private IsServerSide As Boolean
    ''' <summary>
    ''' 服务端映射前的端口号。
    ''' </summary>
    Private ServerPort As Integer
    ''' <summary>
    ''' 客户端映射后的端口号。
    ''' </summary>
    Private ClientPort As Integer
    ''' <summary>
    ''' RPC 端口号。
    ''' </summary>
    Private RPCPort As Integer
    ''' <summary>
    ''' 在客户端映射后的地址。
    ''' 除非已作为客户端启动 EasyTier，否则一直为 Nothing。
    ''' </summary>
    Private ClientAddress As String = Nothing
    ''' <summary>
    ''' 发现节点的 ID。
    ''' 若必须设定自定义节点则为 -2；若等待选择则为 -1；选择回退节点则为 0；否则为对应节点的 ID。
    ''' </summary>
    Private DiscoverNodeID As Integer = -1
    ''' <summary>
    ''' 网络信息。
    ''' </summary>
    Private NetworkName As String, NetworkSecret As String

#Region "加载"

    Private WithEvents LinkLoader As New LoaderCombo(Of Integer)("联机", {
        New LoaderTask(Of Integer, Integer)("获取配置", AddressOf InitConfig) With {.ProgressWeight = 8},
        New LoaderTask(Of Integer, List(Of NetFile))("准备下载联机模块", AddressOf InitPrepareDownload) With {.ProgressWeight = 2},
        New LoaderDownload("下载联机模块", New List(Of NetFile)) With {.ProgressWeight = 40},
        New LoaderTask(Of Integer, Integer)("启动联机模块", AddressOf InitLaunch) With {.ProgressWeight = 50}
    })

    '1. 初始化本地模块配置
    Private Sub InitConfig(Task As LoaderTask(Of Integer, Integer))
        UpdateLoadingPage("正在初始化联机配置……", "初始化联机配置")
        Select Case Environment.GetEnvironmentVariable("PROCESSOR_ARCHITECTURE")?.ToUpperInvariant()
            Case "AMD64"
                ModuleArchitecture = "x86_64"
            Case "X86"
                ModuleArchitecture = "i686"
            Case "ARM64"
                ModuleArchitecture = "arm64"
            Case Else
                Throw New PlatformNotSupportedException("联机模块不支持当前 CPU 架构")
        End Select
        PathEasyTier = Path.Combine(Paths.AppDataThenName, "EasyTier", EasyTierVersion & "-" & ModuleArchitecture) & "\"
    End Sub

    Friend Shared Function GetModulePackage(Architecture As String, Destination As String) As NetFile
        Return New NetFile({$"https://github.com/EasyTier/EasyTier/releases/download/v{EasyTierVersion}/easytier-windows-{Architecture}-v{EasyTierVersion}.zip"},
            Path.Combine(Destination, "EasyTier.zip"), New FileChecker With {.MinSize = 2 * 1024 * 1024, .Hash = GetModuleHash(Architecture)})
    End Function
    Private Shared Function GetModuleHash(Architecture As String) As String
        Select Case Architecture
            Case "x86_64"
                Return "27af91e270e554709b048bd32327fefd2dfce5062ae1e8701af7550c6f525f84"
            Case "i686"
                Return "bf557daeccc5525d95b8a230c339d75554fb52d82d1e050e9a5202c92c02e09e"
            Case "arm64"
                Return "37023f8a3451c9234b17ee2089a03dc344ce90d803b5b359cb6c46682b0549b4"
            Case Else
                Throw New PlatformNotSupportedException("联机模块不支持当前 CPU 架构")
        End Select
    End Function
    Friend Shared Sub InstallModule(Archive As String, Destination As String, Architecture As String)
        Dim CheckResult = New FileChecker With {.Hash = GetModuleHash(Architecture)}
        Dim ErrorMessage = CheckResult.Check(Archive)
        If ErrorMessage IsNot Nothing Then Throw New InvalidDataException("联机模块校验失败：" & ErrorMessage)
        Dim ExtractPath = Path.Combine(Path.GetTempPath(), "PCL-EasyTier-" & Guid.NewGuid().ToString("N"))
        Try
            ZipFile.ExtractToDirectory(Archive, ExtractPath)
            Dim CorePath = Directory.GetFiles(ExtractPath, "easytier-core.exe", SearchOption.AllDirectories).Single()
            Dim CliPath = Path.Combine(Path.GetDirectoryName(CorePath), "easytier-cli.exe")
            If Not File.Exists(CliPath) Then Throw New InvalidDataException("联机模块缺少 CLI 程序")
            DirectoryUtils.Copy(Path.GetDirectoryName(CorePath), Destination)
            File.Copy(Path.Combine(Destination, "easytier-core.exe"), Path.Combine(Destination, "联机模块.exe"), True)
            File.Copy(Path.Combine(Destination, "easytier-cli.exe"), Path.Combine(Destination, "联机模块 CLI.exe"), True)
            File.Delete(Path.Combine(Destination, "easytier-core.exe"))
            File.Delete(Path.Combine(Destination, "easytier-cli.exe"))
        Finally
            If Directory.Exists(ExtractPath) Then Directory.Delete(ExtractPath, True)
        End Try
    End Sub

    '2. 获取需要下载的文件
    Private Sub InitPrepareDownload(Task As LoaderTask(Of Integer, List(Of NetFile)))
        UpdateLoadingPage("正在检查联机模块……", "检查联机模块")
        Dim RequiredFiles As New List(Of NetFile)
        If Not (File.Exists(PathEasyTier & "联机模块.exe") AndAlso File.Exists(PathEasyTier & "联机模块 CLI.exe")) Then
            RequiredFiles.Add(GetModulePackage(ModuleArchitecture, PathEasyTier))
        End If
        Task.Output = RequiredFiles
    End Sub

    Private Shared Function IsValidPeerAddress(Address As String) As Boolean
        If String.IsNullOrWhiteSpace(Address) OrElse Address.Any(Function(c) Char.IsWhiteSpace(c) OrElse Char.IsControl(c) OrElse c = """"c OrElse c = "'"c OrElse c = "\"c) Then Return False
        Dim Parsed As Uri = Nothing
        If Not Uri.TryCreate(Address, UriKind.Absolute, Parsed) Then Return False
        Return {"tcp", "udp", "ws", "wss", "quic", "wg"}.Contains(Parsed.Scheme) AndAlso
            Not String.IsNullOrEmpty(Parsed.Host) AndAlso Parsed.Port > 0 AndAlso Parsed.Port <= 65535
    End Function

    Friend Shared Function BuildLinkArguments(IsServer As Boolean, Port As Integer, ForwardPort As Integer, RpcPort As Integer,
        ListenerPort As Integer, RoomName As String, RoomSecret As String, HostName As String,
        PeerAddresses As IEnumerable(Of String), PreferLowLatency As Boolean) As String
        If Port < 1024 OrElse Port > 65535 OrElse ForwardPort < 1 OrElse ForwardPort > 65535 OrElse
            RpcPort < 1 OrElse RpcPort > 65535 OrElse ListenerPort < 1 OrElse ListenerPort > 65533 Then
            Throw New ArgumentOutOfRangeException("Port", "联机端口号有误")
        End If
        If RoomName Is Nothing OrElse Not Regex.IsMatch(RoomName, "\A[A-Za-z0-9_-]{1,64}\z") OrElse
            RoomSecret Is Nothing OrElse Not Regex.IsMatch(RoomSecret, "\A[A-Za-z0-9_-]{1,64}\z") OrElse
            HostName Is Nothing OrElse Not Regex.IsMatch(HostName, "\A[A-Za-z0-9_-]{1,64}\z") Then
            Throw New ArgumentException("联机房间信息格式有误")
        End If
        If PeerAddresses Is Nothing Then Throw New ArgumentException("未提供联机节点")
        Dim Peers = PeerAddresses.Distinct().ToList()
        If Peers.Count = 0 OrElse Peers.Any(Function(p) Not IsValidPeerAddress(p)) Then
            Throw New ArgumentException("联机节点地址有误，请检查自定义节点设置")
        End If
        Dim Arguments = $"--no-tun --use-smoltcp --network-name={RoomName} --network-secret={RoomSecret} --listeners {ListenerPort} --rpc-portal 127.0.0.1:{RpcPort} --private-mode true --hostname={HostName}"
        If IsServer Then
            Arguments &= $" -i 10.114.114.114 --tcp-whitelist={Port} --udp-whitelist={Port}"
        Else
            Arguments &= " -d --tcp-whitelist=0 --udp-whitelist=0"
            For Each Address In {"[::1]", "127.0.0.1"}
                Arguments &= $" --port-forward tcp://{Address}:{ForwardPort}/10.114.114.114:{Port}"
                Arguments &= $" --port-forward udp://{Address}:{ForwardPort}/10.114.114.114:{Port}"
            Next
        End If
        For Each PeerAddress In Peers
            Arguments &= $" -p=""{PeerAddress}"""
        Next
        If PreferLowLatency Then Arguments &= " --latency-first"
        Return Arguments
    End Function

    '3. 启动联机模块
    Private Sub InitLaunch(Task As LoaderTask(Of Integer, Integer))
        '解压文件
        UpdateLoadingPage("正在解压联机模块……", "解压联机模块")
        If FileUtils.Exists(PathEasyTier & "EasyTier.zip") Then
            InstallModule(PathEasyTier & "EasyTier.zip", PathEasyTier, ModuleArchitecture)
            File.Delete(PathEasyTier & "EasyTier.zip")
        End If
        If Task.IsCanceled Then Throw New OperationCanceledException
        Task.Progress = 0.07
        '获取节点列表
        UpdateLoadingPage("正在获取节点列表……", "获取节点列表")
        Dim RawPeers As List(Of String)
        Dim CustomPeers As String = Settings.Get(Of String)("LinkCustomPeer")
        If String.IsNullOrWhiteSpace(CustomPeers) Then
            If DiscoverNodeID = -2 AndAlso Not IsServerSide Then
                Panic("未填写自定义节点设置", $"$你必须在 {vbLQ}自定义节点{vbRQ} 设置中填写与房主相同的内容，{vbCrLf}才能进入该房间！")
                Return
            End If
            RawPeers = GetTargetPeers()
        Else
            If DiscoverNodeID <> -2 AndAlso Not IsServerSide Then Hint("房主可能没有使用自定义节点设置，请确认你们的自定义节点设置是否一致！")
            RawPeers = CustomPeers.Split("，,".ToCharArray).Select(Function(p) p.Trim).Where(Function(p) Not String.IsNullOrEmpty(p)).ToList()
            Logger.Info($"使用 {RawPeers.Count} 个自定义节点")
            DiscoverNodeID = -2
        End If
        Task.Progress = 0.13
        '获取空闲端口
        UpdateLoadingPage("正在启动联机模块……", "启动联机模块")
        Dim FreePorts = FindFreePorts(5, ServerPort)
        ClientPort = FreePorts(0)
        RPCPort = FreePorts(1)
        Dim ListenersPort As Integer = FreePorts(2) '它会占用【当前、当前 +1、当前 +2】共三个端口
        '获取启动参数
        Dim HostName = If(IsServerSide, "Server-", "Client-") & Identify.GetStableHashCode().ConvertRadix(36).TrimStart("-"c).EnsureLength("0", 6)
        Dim Arguments = BuildLinkArguments(IsServerSide, ServerPort, ClientPort, RPCPort, ListenersPort,
            NetworkName, NetworkSecret, HostName, RawPeers, Settings.Get(Of Integer)("LinkLatencyMode") = 1)
        If Not IsServerSide Then ClientAddress = $"localhost:{ClientPort}"
        '启动进程
        If Task.IsCanceled Then Throw New OperationCanceledException
        ProcessStart(Arguments)
        Task.Progress = 0.15
        '等待连接
        Dim TimeoutCounter As Integer = 0
        Do
            Thread.Sleep(500) '为避免还没启动好先跑 CLI 了，先等半秒
            '刷新信息
            CheckCrash()
            RefreshPeerLoader.WaitForExit(IsForceRestart:=True)
            '查找目标节点
            Dim Ping = GetPeerPing()
            If Ping > 0 AndAlso (IsServerSide OrElse HasLocalAddress) Then
                Logger.Info($"已与目标建立连接，当前 Ping 为 {Ping:0.0}ms")
                Exit Do '退出循环
            End If
            '更新进度
            Dim LastProgress = Task.Progress
            Dim PeerCount As Integer = If(Peers Is Nothing, -1, Peers.Where(Function(p) p.Ping > 0).Count)
            Select Case PeerCount
                Case -1 'CLI 无返回
                    Task.Progress = (Task.Progress + 0.02).Clamp(0.15, 0.25)
                Case 0 'CLI 有返回，但未连接到任何节点
                    UpdateLoadingPage("正在连接到节点……", "连接节点")
                    Task.Progress = (Task.Progress + 0.02).Clamp(If(IsServerSide, 0.5, 0.3), If(IsServerSide, 0.95, 0.5))
                Case Else '已连接到节点，但未连接到房主
                    UpdateLoadingPage("正在连接到房主……", "连接房主")
                    Task.Progress = (Task.Progress + 0.02).Clamp(Math.Min(0.45 + PeerCount * 0.05, 0.65), 0.95)
            End Select
            '超时判定
            If LastProgress <> Task.Progress Then
                TimeoutCounter = 0
            ElseIf TimeoutCounter < 30 * 2 Then
                TimeoutCounter += 1
            Else '进度停滞超过 30s
                Select Case PeerCount
                    Case -1 'CLI 无返回
                        Panic("无法启动联机模块", "近期日志：" & vbCrLf & LogHistory.Join(vbCrLf))
                    Case 0 'CLI 有返回，但未连接到任何节点
                        Panic("无法连接到节点", $"请检查你的网络环境是否良好。")
                    Case Else '已连接到节点，但未连接到房主
                        Panic("无法连接到房主", $"可能的原因：{vbCrLf}- 你或者房主的网络环境不佳{vbCrLf}- 房主已关闭房间{vbCrLf}- 邀请码输错了")
                End Select
            End If
        Loop Until Task.IsCanceled
        If Task.IsCanceled Then Throw New OperationCanceledException
        '等待连接稳定，最多 5s
        If IsServerSide Then Return
        UpdateLoadingPage("连接优化中……", "优化连接")
        Task.Progress = 0.999
        For i = 1 To 50
            Dim Server = GetTargetPeer()
            If Server IsNot Nothing AndAlso Not Server.Relay AndAlso Server.Ping < 100 Then Return '结束
            If Task.IsCanceled Then Throw New OperationCanceledException
            Thread.Sleep(100)
        Next
    End Sub
    ''' <summary>
    ''' 从在线配置和 API 获取需要连接的节点列表，并更新发现节点 ID。
    ''' 根据发现节点 ID，会有以下行为变化：
    '''   -1：作为房主，根据负载均衡选择一个发现节点。
    '''   0：作为加入者，但邀请码未提供发现节点 ID，使用回退发现节点。
    '''   >0：作为加入者，根据 ID 选择对应的发现节点；如果没有，使用回退发现节点。
    ''' </summary>
    Private Function GetTargetPeers() As List(Of String)
        Dim FinalPeers As New List(Of String), FinalDiscoverID As Integer = -1
        Try
            '从 API 获取节点列表
            Dim RawNodes As JObject
            Dim IsFallbackRawList As Boolean = False
            Try
                RawNodes = NetRequestByClient("https://uptime.easytier.cn/api/nodes?page=1&per_page=1000", Timeout:=5000, RequireJson:=True).DeserializeJson()
            Catch exx As Exception
                Logger.Warn(exx, "从源站获取节点列表失败，将使用 CDN 缓存")
                RawNodes = NetRequestByClient("https://easytier.meloong.com/?page=1&per_page=1000", Timeout:=5000, RequireJson:=True).DeserializeJson()
                IsFallbackRawList = True
            End Try
            '分析节点列表
            Dim Nodes As New List(Of JObject) '负载会添加在 load 字段上
            For Each Node As JObject In RawNodes("data")("items")
                '状态检查
                Dim ID = Node("id").ToObject(Of Integer)
                If Not Node("is_active").ToObject(Of Boolean) OrElse Not Node("is_approved").ToObject(Of Boolean) Then Continue For
                If ID < 1 OrElse ID > &HFFF Then Continue For
                If Not IsValidPeerAddress(Node("address")?.ToString()) Then Continue For
                If ID = DiscoverNodeID Then GoTo ForcedPass '若为指定的发现节点，忽略后续检查
                If ID = FallbackDiscoverID Then Continue For '不主动选取回退发现节点
                If Node("usage_percentage").ToObject(Of Double) = 0 AndAlso RandomInteger(1, 100) <> 1 Then Continue For '或许节点有问题才导致是 0 负载，让它只有 1% 概率被选中
                '标签检查
                Dim Tags = Node("tags").Select(Function(t) t.ToString).ToList
                If Not Tags.Contains("国内") OrElse Not Tags.Contains("MC中继") Then Continue For
                '计算负载并加入列表
ForcedPass:
                Dim Load As Double = Node("usage_percentage").ToObject(Of Double) '负载
                Load *= 110 - Node("health_percentage_24h").ToObject(Of Double) '可用率
                Node("load") = Load
                Nodes.Add(Node)
            Next
            '排序
            If Not IsFallbackRawList Then
                Nodes = Nodes.OrderBy(Function(n) n("load").ToObject(Of Double)).ToList() '按负载从低到高排序
            Else
                Nodes = Nodes.Shuffle().ToList() '回退到 CDN 缓存时，由于负载数据可能过期，直接随机选择
            End If
            '选取发现节点
            Dim SelectedDiscoverNode As JObject = Nothing
            If DiscoverNodeID = -1 Then '-1：作为房主，根据负载均衡选择一个发现节点
                SelectedDiscoverNode = Nodes.FirstOrDefault(Function(n) Not n("allow_relay").ToObject(Of Boolean))
            ElseIf DiscoverNodeID = FallbackDiscoverID Then
                SelectedDiscoverNode = New JObject From {{"address", FallbackDiscoverAddress}, {"id", FallbackDiscoverID}}
            ElseIf DiscoverNodeID > 0 Then '>0：作为加入者，根据 ID 选择对应的发现节点；如果没有，使用回退发现节点
                SelectedDiscoverNode = Nodes.FirstOrDefault(Function(n) n("id").ToObject(Of Integer) = DiscoverNodeID)
                If SelectedDiscoverNode Is Nothing Then
                    Logger.Warn($"未找到 ID {DiscoverNodeID} 的发现节点")
                    Panic("房间已过期", "请让房主重新创建房间！")
                    Throw New OperationCanceledException
                End If
            End If
            If SelectedDiscoverNode Is Nothing Then '使用回退发现节点
                SelectedDiscoverNode = New JObject From {{"address", FallbackDiscoverAddress}, {"id", FallbackDiscoverID}}
                Logger.Warn("将使用回退发现节点")
            End If
            FinalPeers.Add(SelectedDiscoverNode("address").ToString())
            FinalDiscoverID = SelectedDiscoverNode("id").ToObject(Of Integer)
            Logger.Info($"发现节点：{SelectedDiscoverNode("address")} (ID: {FinalDiscoverID})")
            '选取中继节点
            If ModeDebug OrElse Not IsServerSide Then '房主只连接发现节点，不连接中继节点
                Dim RelayCount As Integer = 2
                Dim RelayNodes = Nodes.Where(Function(n) n("allow_relay").ToObject(Of Boolean)).ToList()
                FinalPeers.AddRange(RelayNodes.Take(RelayCount).Select(Function(n) n("address").ToString()))
            End If
        Catch ex As Exception
            ex.ThrowIfCanceled()
            Logger.Error(ex, "获取节点列表失败，联机质量可能受到影响", LogBehavior.Toast)
            FinalPeers.Add("tcp://public.easytier.top:11010")
            If FinalDiscoverID <= 0 Then
                FinalPeers.Add(FallbackDiscoverAddress)
                FinalDiscoverID = FallbackDiscoverID
            End If
        End Try
        '保留固定发现节点，让节点列表暂不可用时仍有共同的连接入口。
        FinalPeers.Add(FallbackDiscoverAddress)
        '结束
        DiscoverNodeID = FinalDiscoverID
        Return FinalPeers.Distinct.ToList
    End Function

#End Region

#Region "进程与日志"

    ''' <summary>
    ''' EasyTier Core 进程。
    ''' </summary>
    Private Shared ProcessCore As Process
    Private Shared ProcessOutputHandle As AutoResetEvent, ProcessErrorHandle As AutoResetEvent

    ''' <summary>
    ''' 若程序正在运行，则结束程序进程。
    ''' 即使失败也不会抛出异常。
    ''' </summary>
    Public Shared Sub ProcessStop()
        Try
            '关闭由自身启动的进程
            If ProcessCore IsNot Nothing AndAlso Not ProcessCore.HasExited Then
                Logger.Info($"停止所启动的联机模块，PID：{ProcessCore.Id}")
                ProcessCore.Kill()
                ProcessCore.Close()
                ProcessCore = Nothing
            End If
            '释放资源
            ProcessOutputHandle?.Dispose()
            ProcessErrorHandle?.Dispose()
        Catch ex As Exception
            Logger.Warn(ex, "停止联机模块失败")
        End Try
    End Sub
    ''' <summary>
    ''' 出现意外错误，给出错误信息并结束联机。
    ''' </summary>
    Private Sub Panic(Brief As String, Detail As String)
        '常见原因分析
        If Detail.Contains("failed to listen on ") Then
            Detail = $"监听端口失败。{vbCrLf}请点击重试，如果还是出现此错误，可以重启电脑解决。{vbCrLf}{vbCrLf}{Detail}"
        End If
        '显示信息
        If LinkState = LinkStates.Loading Then
            FailReason = Brief
            LinkLoader.Failed(New Exception(Detail))
        Else
            MyMsgBox(Detail, "联机出错：" & Brief, IsWarn:=True)
            ChangeState(LinkStates.Waiting)
        End If
    End Sub

    ''' <summary>
    ''' 启动进程。
    ''' </summary>
    Private Sub ProcessStart(Arguments As String)
        Dim Info = New ProcessStartInfo With {
            .FileName = PathEasyTier & "联机模块.exe",
            .Arguments = Arguments,
            .UseShellExecute = False,
            .CreateNoWindow = True,
            .RedirectStandardError = True,
            .RedirectStandardOutput = True,
            .StandardOutputEncoding = Encoding.UTF8,
            .StandardErrorEncoding = Encoding.UTF8
        }
        Logger.Info($"正在启动 EasyTier {EasyTierVersion}")
        ProcessCore = New Process With {.StartInfo = Info}
        Dim LogLineHandler =
        Sub(sender As Object, e As DataReceivedEventArgs, Handle As AutoResetEvent)
            Try
                If e.Data Is Nothing Then
                    Handle.[Set]()
                    Return
                End If
                ProcessLogLine(e.Data)
            Catch unused As ObjectDisposedException
            Catch ex As Exception
                Logger.Warn(ex, "读取 EasyTier 信息失败")
            End Try
        End Sub
        ProcessOutputHandle = New AutoResetEvent(False)
        AddHandler ProcessCore.OutputDataReceived, Sub(sender, e) LogLineHandler(sender, e, ProcessOutputHandle)
        ProcessErrorHandle = New AutoResetEvent(False)
        AddHandler ProcessCore.ErrorDataReceived, Sub(sender, e) LogLineHandler(sender, e, ProcessErrorHandle)
        ProcessCore.Start()
        ProcessCore.BeginOutputReadLine()
        ProcessCore.BeginErrorReadLine()
    End Sub
    Private Sub ProcessLogLine(Line As String)
        '模块可能输出启动配置；房间凭据只在邀请流程中显示。
        If Not String.IsNullOrEmpty(NetworkSecret) Then Line = Line.Replace(NetworkSecret, "[房间密码]")
        If Not String.IsNullOrEmpty(NetworkName) Then Line = Line.Replace(NetworkName, "[房间网络]")
        Logger.Info(Line)
        LogHistory.Enqueue(Line)
        If LogHistory.Count >= 10 Then LogHistory.Dequeue()
        '检查日志内容
        If Line.ContainsIgnoreCase("new peer connection added") Then
            Logger.Warn($"已建立连接：{If(Line.RegexSeek("(?<=remote_addr.+?"")[^""}]{3,}"), Line)}")
            Update()
        ElseIf Line.ContainsIgnoreCase("peer connection removed") Then
            Logger.Warn($"已断开连接：{If(Line.RegexSeek("(?<=remote_addr.+?"")[^""}]{3,}"), Line)}")
            Update()
        End If
    End Sub
    Private LogHistory As New Queue(Of String)(10)

#End Region

#Region "CLI 节点信息获取"

    Private Class Peer
        ''' <summary>
        ''' 该节点的类型。
        ''' </summary>
        Public ReadOnly Type As Types
        Public Enum Types
            ''' <summary>
            ''' 客户端。
            ''' </summary>
            Client
            ''' <summary>
            ''' 服务器。
            ''' </summary>
            Server
            ''' <summary>
            ''' 公共节点。
            ''' </summary>
            Misc
            ''' <summary>
            ''' 自己，或者自己的重复（它可能返回多个自己）。
            ''' </summary>
            Self
        End Enum
        ''' <summary>
        ''' 与该节点的延迟 (ms)。
        ''' 若是自己则为 0。
        ''' </summary>
        Public ReadOnly Ping As Double
        ''' <summary>
        ''' 名称。
        ''' </summary>
        Public ReadOnly Name As String
        ''' <summary>
        ''' 是否通过中继连接。
        ''' </summary>
        Public ReadOnly Relay As Boolean
        ''' <summary>
        ''' NAT 类型。
        ''' </summary>
        Public ReadOnly NATType As NATTypes

        ''' <summary>
        ''' 从 CLI 给出的信息分析对应的数据。
        ''' </summary>
        Public Sub New(Info As JObject)
            '类别
            Dim PeerName = Info("hostname").ToString
            If Info("cost").ToString = "Local" Then
                Type = Types.Self
            ElseIf PeerName.StartsWithF("Client") Then
                Type = Types.Client
            ElseIf Info("ipv4") = "10.114.114.114" Then '只允许这个 IP 作为房主，避免网络被多个房主搞炸的情况
                Type = Types.Server
            Else
                Type = Types.Misc
            End If
            '基础信息
            Double.TryParse(Info("lat_ms"), NumberStyles.Any, CultureInfo.InvariantCulture, Ping)
            Name = PeerName
            Relay = Info("cost").ToString.ContainsIgnoreCase("relay")
            NATType = EnumUtils.FromString(Of NATTypes)(Info("nat_type"))
        End Sub
        Public Overrides Function ToString() As String
            Return $"{Type} - {Name} - Ping {Ping:0.0}ms [中继? {Relay}] - NAT {NATType}"
        End Function
    End Class
    Private Enum NATTypes
        'https://github.com/EasyTier/EasyTier/blob/6bb2fd9a15ab2499bdeabdcc3a925e9bd9aebf50/easytier/src/proto/common.proto#L129
        Unknown = 0
        OpenInternet = 1
        NoPAT = 2
        FullCone = 3
        Restricted = 4
        PortRestricted = 5
        Symmetric = 6
        SymUdpFirewall = 7
        SymmetricEasyInc = 8
        SymmetricEasyDec = 9
        ''' <summary>
        ''' 尚未获取。
        ''' </summary>
        Pending = 10
    End Enum

    ''' <summary>
    ''' 当前的节点列表，使用 RefreshPeerLoader 来刷新。
    ''' 若尚未成功获取过则为 Nothing，但保证在加载完成后至少是一个列表。
    ''' </summary>
    Private Peers As List(Of Peer) = Nothing
    ''' <summary>
    ''' 自己的 NAT 类型。
    ''' </summary>
    Private NATType As NATTypes = NATTypes.Pending
    Private HasLocalAddress As Boolean

    ''' <summary>
    ''' 调用 EasyTier CLI 获取已连接节点信息。
    ''' 这会过滤掉尚未完成连接的其他节点以及自己。
    ''' 若在加载完成后连续获取失败 3 次，则会强制断开连接。
    ''' </summary>
    Private RefreshPeerLoader As New LoaderTask(Of Integer, List(Of Peer))("EasyTier CLI", AddressOf RefreshPeer)
    Private Sub RefreshPeer()
        Try
            Dim Result = TaskUtils.RunProgramAsync(PathEasyTier & "联机模块 CLI.exe",
                $"-o json -p 127.0.0.1:{RPCPort} peer", 3000, encoding:=Encoding.UTF8).GetAwaiter().GetResult()
            If Result.Item2 <> 0 Then Throw New Exception("CLI 调用失败，退出代码：" & Result.Item2)
            Dim CliResult = Result.Item1
            '解析
            If Not CliResult.TrimStart().StartsWith("[") Then Throw New Exception("CLI 返回了无效的节点信息")
            Dim NewPeers As New List(Of Peer)
            Dim NewHasLocalAddress As Boolean = False
            For Each Line As JObject In CType(CliResult.DeserializeJson(), JArray)
                Try
                    Dim Peer = New Peer(Line)
                    If Peer.Type = Peer.Types.Self Then
                        NATType = Peer.NATType '记录自己的 NAT
                        Dim LocalAddress As IPAddress = Nothing
                        If IPAddress.TryParse(Line("ipv4")?.ToString(), LocalAddress) Then NewHasLocalAddress = True
                    Else
                        NewPeers.Add(Peer)
                    End If
                Catch exx As Exception
                    Logger.Warn(exx, "节点信息格式错误")
                End Try
            Next
            '完成
            Peers = NewPeers
            HasLocalAddress = NewHasLocalAddress
            FailCount = 0
        Catch ex As Exception
            Logger.Warn(ex, "获取节点信息失败")
            If LinkState = LinkStates.Finished Then
                FailCount += 1
                If FailCount >= 4 Then Panic("获取节点信息失败", ex.Message)
            End If
        End Try
    End Sub
    ''' <summary>
    ''' CLI 调用连续失败的次数。
    ''' </summary>
    Private FailCount As Integer = 0

    ''' <summary>
    ''' 根据当前的节点列表获取 Ping 值。
    ''' 服务端会返回所有节点中最低的 Ping，客户端会返回服务端的 Ping。
    ''' 0 代表尚不可用。
    ''' </summary>
    Private Function GetPeerPing() As Double
        Dim Peer = GetTargetPeer()
        If Peer Is Nothing Then Return 0
        Return Peer.Ping
    End Function
    ''' <summary>
    ''' 服务端会返回所有节点中 Ping 大于 0 最低的那一个，客户端会返回服务端。
    ''' 若没有则为 Nothing。
    ''' </summary>
    Private Function GetTargetPeer() As Peer
        If Peers Is Nothing Then Return Nothing
        Dim Targets As IEnumerable(Of Peer)
        If IsServerSide Then
            Targets = Peers.Where(Function(p) p.Ping > 0)
        Else
            Targets = Peers.Where(Function(p) p.Type = Peer.Types.Server AndAlso p.Ping > 0)
        End If
        If Not Targets.Any Then Return Nothing
        '返回 Ping 且最低的那个
        Dim MinPing = Targets.Min(Function(p) p.Ping)
        Return Targets.First(Function(p) p.Ping = MinPing)
    End Function

    ''' <summary>
    ''' 获取当前房间中的人数，包括自己。
    ''' 0 代表不可用。
    ''' </summary>
    Private ReadOnly Property PeopleCount As Integer
        Get
            If Peers Is Nothing Then Return 0
            Return Peers.Where(Function(p) p.Type <> Peer.Types.Misc).Count() + 1 '加上自己
        End Get
    End Property

#End Region

#Region "定时任务"

    '启动
    Private Sub StartTimerThread() Handles Me.Loaded
        Static IsTimerStarted As Boolean = False
        If IsTimerStarted Then Return
        IsTimerStarted = True
        RunInNewThread(
        Sub()
            Dim Counter As Integer = 0
            Do While True
                Try
                    Thread.Sleep(200)
                    Counter += 200
                    '每秒执行一次
                    If Counter >= 1000 Then
                        Counter = 0
                        Update()
                    End If
                    '每 200ms 更新进度条
                    If LinkState = LinkStates.Loading Then RunInUi(AddressOf UpdateProgressBar)
                Catch ex As Exception
                    Logger.Error(ex, "联机模块主时钟出错")
                    Thread.Sleep(10000)
                End Try
            Loop
        End Sub, "Link Timer")
    End Sub

    '每秒或进入页面时触发
    Private Sub Update() Handles Me.Loaded
        If LinkState <> LinkStates.Finished Then Return
        '重新获取信息
        SyncLock RefreshPeerLoader.LockState
            If RefreshPeerLoader.State <> LoadState.Loading Then RefreshPeerLoader.Start(IsForceRestart:=True)
        End SyncLock
        '更新 UI
        If FrmMain.PageCurrent = FormMain.PageType.Link Then
            RunInUi(
            Sub()
                'Logo 旋转动画
                AniStart(AaRotateTransform(ImgFinishLogo, 500, 5000), "Link Logo Rotation")
                'Ping
                Dim Ping As Double = GetPeerPing()
                Dim Connecting As Boolean = Ping Mod 500 = 0 OrElse $"{Ping:0.0}" = "1.0" OrElse FailCount > 0
                If Connecting Then
                    LabFinishPing.Text = "连接优化中"
                Else
                    LabFinishPing.Text = If(Ping >= 10, $"{Ping:0} ms", $"{Ping:0.0} ms")
                End If
                '人数显示
                LabFinishPlayer.Text = PeopleCount & "  人"
                '------------------------
                '  提示条
                '------------------------
                HintFinish.Visibility = Visibility.Collapsed
                If IsServerSide Then Return '服务端没有需要显示的提示
                If Connecting Then Return '连接稳定过程中不显示提示
                '中继提示
                Dim Server As Peer = GetTargetPeer()
                If Server Is Nothing Then Return
                If Server.Relay Then
                    If NATType >= NATTypes.Symmetric AndAlso Server.NATType >= NATTypes.Symmetric Then
                        HintFinish.Text = "你和房主的网络环境都不太好，"
                    ElseIf NATType >= NATTypes.Symmetric Then
                        HintFinish.Text = "你的网络环境不太好，"
                    ElseIf Server.NATType >= NATTypes.Symmetric Then
                        HintFinish.Text = "房主的网络环境不太好，"
                    Else
                        HintFinish.Text = "你或者房主的网络环境不太好，"
                    End If
                    If String.IsNullOrWhiteSpace(Settings.Get(Of String)("LinkCustomPeer")) Then
                        HintFinish.Text &= "正使用社区节点进行中继。"
                    Else
                        HintFinish.Text &= "正通过自定义节点进行中继。"
                    End If
                    HintFinish.Visibility = Visibility.Visible
                    HintFinish.Theme = MyHint.Themes.Yellow
                    Return
                End If
                '环境比房主更好的提示
                If NATType >= NATTypes.PortRestricted Then Return '自身的 NAT 为 2 或更好
                If Server.NATType < NATTypes.PortRestricted Then Return '房主的 NAT 为 3 或更差
                Dim OtherPlayers = Peers.Where(Function(p) p.Type = Peer.Types.Client).ToList()
                If Not OtherPlayers.Any() Then Return '房间里还有其他玩家
                If OtherPlayers.Any(Function(p) p.Relay) Then Return '自己可以与所有玩家打洞
                If OtherPlayers.All(Function(p) p.NATType < NATTypes.PortRestricted) Then Return '任意其他玩家的 NAT 为 3 或更差
                HintFinish.Visibility = Visibility.Visible
                HintFinish.Theme = MyHint.Themes.Blue
                HintFinish.Text = "你的网络环境比房主更好！如果你来当房主，其他玩家或许能更加流畅！"
            End Sub)
        End If
        '检查核心状态
        CheckCrash()
        '检查节点状态
        If Peers Is Nothing OrElse Not Peers.Any Then
            Panic("网络连接已断开", "请检查你的网络环境是否正常。")
            Return
        End If
        If Not IsServerSide AndAlso Not Peers.Any(Function(p) p.Type = Peer.Types.Server) Then
            MyMsgBox("房主已离开房间！", "联机结束")
            ChangeState(LinkStates.Waiting)
            Return
        End If
        '广播联机房间端口
        If Not IsServerSide Then
            Try
                Static BroadcastSocket As New Socket(SocketType.Dgram, ProtocolType.Udp)
                BroadcastSocket.SendTo(
                    Encoding.UTF8.GetBytes($"[MOTD]PCL 联机房间[/MOTD][AD]{ClientPort}[/AD]"),
                    SocketFlags.None,
                    New IPEndPoint(IPAddress.Loopback, 4445))
            Catch ex As Exception
                Logger.Warn(ex, "广播联机房间端口失败")
            End Try
        End If
    End Sub
    ''' <summary>
    ''' 检查联机模块是否崩溃。
    ''' </summary>
    Private Sub CheckCrash()
        If ProcessCore IsNot Nothing AndAlso Not ProcessCore.HasExited Then Return
        Panic("联机模块已崩溃", "近期日志：" & vbCrLf & LogHistory.Join(vbCrLf))
    End Sub

#End Region

End Class
