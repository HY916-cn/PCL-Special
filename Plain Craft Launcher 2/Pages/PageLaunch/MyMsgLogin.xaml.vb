Public Class MyMsgLogin
    Private Data As JObject
    Private UserCode As String '需要用户在网页上输入的设备代码
    Private DeviceCode As String '用于轮询的设备代码
    Private Website As String '验证网页的网址
    Private FlowClientId As String
    Private FlowStartedAt As Long
    Private ExpiresInSeconds As Integer
    Private CloseStarted As Boolean

#Region "弹窗"

    Private ReadOnly MyConverter As MyMsgBoxConverter
    Private ReadOnly Uuid As Integer = GetUuid()

    Public Sub New(Converter As MyMsgBoxConverter)
        Try
            InitializeComponent()
            Btn1.Name = Btn1.Name & GetUuid()
            Btn2.Name = Btn2.Name & GetUuid()
            Btn3.Name = Btn3.Name & GetUuid()
            MyConverter = Converter
            ShapeLine.StrokeThickness = GetWPFSize(1)
            Data = Converter.Content
            Init()
        Catch ex As Exception
            Logger.Error(ex, "登录弹窗初始化失败", LogBehavior.Toast)
        End Try
    End Sub

    Private Sub Load(sender As Object, e As EventArgs) Handles MyBase.Loaded
        Try
            If IsFlowExited() Then
                CloseWhenComplete()
                Return
            End If
            '动画
            Opacity = 0
            AniStart(AaColor(FrmMain.PanMsg, Grid.BackgroundProperty, If(MyConverter.IsWarn, New MyColor(140, 80, 0, 0), New MyColor(90, 0, 0, 0)) - FrmMain.PanMsg.Background, 200), "PanMsg Background")
            AniStart({
                AaOpacity(Me, 1, 120, 60),
                AaDouble(Sub(i) TransformPos.Y += i, -TransformPos.Y, 300, 60, New AniEaseOutBack(AniEasePower.Weak)),
                AaDouble(Sub(i) TransformRotate.Angle += i, -TransformRotate.Angle, 300, 60, New AniEaseOutFluent(AniEasePower.Weak))
            }, "MyMsgBox " & Uuid)
            '记录日志
            Logger.Info($"登录弹窗：{LabTitle.Text}")
        Catch ex As Exception
            Logger.Error(ex, "登录弹窗加载失败", LogBehavior.Toast)
        End Try
    End Sub
    Private Sub Close()
        '动画
        AniStart({
            AaCode(
            Sub()
                If Not WaitingMyMsgBox.Any() Then
                    AniStart(AaColor(FrmMain.PanMsg, Grid.BackgroundProperty, New MyColor(0, 0, 0, 0) - FrmMain.PanMsg.Background, 200, Ease:=New AniEaseOutFluent(AniEasePower.Weak)))
                End If
            End Sub, 30),
            AaOpacity(Me, -Opacity, 80, 20),
            AaDouble(Sub(i) TransformPos.Y += i, 20 - TransformPos.Y, 150, 0, New AniEaseOutFluent),
            AaDouble(Sub(i) TransformRotate.Angle += i, 6 - TransformRotate.Angle, 150, 0, New AniEaseInFluent(AniEasePower.Weak)),
            AaCode(Sub() CType(Parent, Grid).Children.Remove(Me), , True)
        }, "MyMsgBox " & Uuid)
    End Sub

    '实现回车和 Esc 的接口（#4857）
    Public Sub Btn1_Click() Handles Btn1.Click
    End Sub
    Public Sub Btn3_Click() Handles Btn3.Click
        Finished(New OperationCanceledException)
    End Sub

    Private Sub Drag(sender As Object, e As MouseButtonEventArgs) Handles PanBorder.MouseLeftButtonDown, LabTitle.MouseLeftButtonDown
        On Error Resume Next
        If e.GetPosition(ShapeLine).Y <= 2 Then FrmMain.DragMove()
    End Sub

#End Region

    Private Sub Finished(Result As Object, Optional ShowSuccessHint As Boolean = False)
        RunInUi(
        Sub()
            SyncLock MyConverter
                If Not MyConverter.IsExited Then
                    MyConverter.IsExited = True
                    MyConverter.Result = Result
                    If ShowSuccessHint Then Hint("网页登录成功！", HintType.Green)
                End If
            End SyncLock
            CloseWhenComplete()
        End Sub)
    End Sub
    Private Function IsFlowExited() As Boolean
        SyncLock MyConverter
            Return MyConverter.IsExited
        End SyncLock
    End Function
    Private Sub CloseWhenComplete()
        RunInUi(
        Sub()
            If Not IsFlowExited() OrElse CloseStarted OrElse Not IsLoaded OrElse Parent Is Nothing Then Return
            CloseStarted = True
            Close()
            AniStart(AaCode(Sub() FrmMain.ShowWindowToTop(), 200), "MyMsgLogin Foreground " & Uuid)
        End Sub)
    End Sub

    Private Sub Init()
        UserCode = Data("user_code")
        DeviceCode = Data("device_code")
        Website = Data("verification_uri")
        FlowClientId = If(Data("__pcl_client_id") Is Nothing, OAuthClientId, Data("__pcl_client_id").ToString())
        FlowStartedAt = If(Data("__pcl_device_code_started_at") Is Nothing, GetTimeMs(), Data("__pcl_device_code_started_at").ToObject(Of Long)())
        ExpiresInSeconds = If(Data("expires_in") Is Nothing, 900, Math.Max(0, Data("expires_in").ToObject(Of Integer)()))
        '设置 UI
        LabTitle.Text = "登录 Minecraft"
        LabCaption.Text =
            $"登录网页将自动开启，请在网页中输入 {UserCode}（已自动复制）。" & vbCrLf & vbCrLf &
            $"如果网络环境不佳，网页可能一直加载不出来，届时请使用加速器或 VPN 改善网络环境。" & vbCrLf &
            $"你也可以用其他设备打开 {Website} 并输入上述代码。"
        CustomEventService.SetEventData(Btn1, Website)
        CustomEventService.SetEventData(Btn2, UserCode)
        '启动工作线程
        RunInNewThread(AddressOf WorkThread, "MyMsgLogin")
    End Sub

    'RFC 8628 §3.2/3.5；微软设备授权流程使用同一次请求的 client_id。
    Public Shared Function GetPollingIntervalSeconds(Value As Integer?) As Integer
        Return If(Value.HasValue AndAlso Value.Value > 0, Value.Value, 5)
    End Function
    Public Shared Function GetNextPollingIntervalSeconds(CurrentSeconds As Integer, ErrorCode As String) As Integer
        Dim Current As Long = GetPollingIntervalSeconds(CurrentSeconds)
        If ErrorCode = "slow_down" Then Current += 5
        If ErrorCode = "timeout" Then Current *= 2
        Return CInt(Math.Min(Integer.MaxValue, Current))
    End Function
    Public Shared Function GetPollingDelayMilliseconds(IntervalSeconds As Integer, ElapsedMilliseconds As Long) As Long
        Return Math.Max(0L, CLng(GetPollingIntervalSeconds(IntervalSeconds)) * 1000L - Math.Max(0L, ElapsedMilliseconds))
    End Function
    Public Shared Function HasDeviceCodeExpired(StartedAtMilliseconds As Long, LifetimeSeconds As Integer, NowMilliseconds As Long) As Boolean
        Return NowMilliseconds - StartedAtMilliseconds >= CLng(Math.Max(0, LifetimeSeconds)) * 1000L
    End Function
    Private Function WaitUntil(DueAt As Long) As Boolean
        Do While Not IsFlowExited()
            Dim NowAt = GetTimeMs()
            If HasDeviceCodeExpired(FlowStartedAt, ExpiresInSeconds, NowAt) Then
                Finished(New Exception("$登录用时太长啦，重新试试吧！"))
                Return False
            End If
            If NowAt >= DueAt Then Return True
            Thread.Sleep(CInt(Math.Min(100L, DueAt - NowAt)))
        Loop
        Return False
    End Function
    Private Sub WorkThread()
        Try
            If Not WaitUntil(GetTimeMs() + 2000L) Then Return
            If IsFlowExited() Then Return
            OpenWebsite(Website)
            If IsFlowExited() Then Return
            ClipboardSet(UserCode)
            Dim Interval = GetPollingIntervalSeconds(If(Data("interval") Is Nothing, Nothing, CType(Data("interval").ToObject(Of Integer)(), Integer?)))
            Dim LastResponseAt = FlowStartedAt
            Dim UnknownFailureCount As Integer = 0
            Do While Not IsFlowExited()
                Dim Delay = GetPollingDelayMilliseconds(Interval, GetTimeMs() - LastResponseAt)
                If Not WaitUntil(GetTimeMs() + Delay) Then Return
                Try
                    If IsFlowExited() Then Return
                    Dim Remaining = FlowStartedAt + CLng(ExpiresInSeconds) * 1000L - GetTimeMs()
                    If Remaining <= 0 Then
                        Finished(New Exception("$登录用时太长啦，重新试试吧！"))
                        Return
                    End If
                    Dim Result = NetRequestByClient(
                        "https://login.microsoftonline.com/consumers/oauth2/v2.0/token", HttpMethod.Post,
                        Content:=
                            "grant_type=urn:ietf:params:oauth:grant-type:device_code" & "&" &
                            "client_id=" & Uri.EscapeDataString(FlowClientId) & "&" &
                            "device_code=" & Uri.EscapeDataString(DeviceCode) & "&" &
                            "scope=XboxLive.signin%20offline_access",
                        ContentType:="application/x-www-form-urlencoded",
                        Timeout:=CInt(Math.Min(Remaining, 5000L + UnknownFailureCount * 5000L)),
                        MakeLog:=False, RequireJson:=True)
                    If IsFlowExited() Then Return
                    If HasDeviceCodeExpired(FlowStartedAt, ExpiresInSeconds, GetTimeMs()) Then
                        Finished(New Exception("$登录用时太长啦，重新试试吧！"))
                        Return
                    End If
                    Dim ResultJson As JObject = Result.DeserializeJson()
                    McLaunchLog($"令牌过期时间：{ResultJson("expires_in")} 秒")
                    Finished({ResultJson("access_token").ToString, ResultJson("refresh_token").ToString}, True)
                    Return
                Catch ex As Exception
                    If IsFlowExited() Then Return
                    If TypeOf ex Is HttpRequestCodeException Then
                        Dim Response = If(CType(ex, HttpRequestCodeException).Response, "")
                        Dim ErrorCode As String = ""
                        Try
                            ErrorCode = JObject.Parse(Response)("error")?.ToString()
                        Catch parseError As Newtonsoft.Json.JsonException
                        End Try
                        If ErrorCode = "authorization_pending" OrElse ErrorCode = "slow_down" Then
                            Interval = GetNextPollingIntervalSeconds(Interval, ErrorCode)
                            UnknownFailureCount = 0
                            Continue Do
                        ElseIf ErrorCode = "authorization_declined" OrElse ErrorCode = "access_denied" Then
                            Finished(New Exception("$你拒绝了 PCL 申请的权限……"))
                            Return
                        ElseIf ErrorCode = "expired_token" Then
                            Finished(New Exception("$登录用时太长啦，重新试试吧！"))
                            Return
                        ElseIf Response.Contains("Account security interrupt") Then
                            Finished(New Exception("$该账号由于安全问题无法登陆，请前往微软账户页获取更多信息。"))
                            Return
                        ElseIf Response.Contains("service abuse") Then
                            Finished(New Exception("$非常抱歉，该账号已被微软封禁，无法登录。"))
                            Return
                        ElseIf Response.Contains("AADSTS70000") Then
                            Finished(New RestartException)
                            Return
                        ElseIf Not String.IsNullOrEmpty(ErrorCode) Then
                            Finished(New Exception("登录轮询失败", ex))
                            Return
                        End If
                    End If
                    If UnknownFailureCount < 3 Then
                        UnknownFailureCount += 1
                        Interval = GetNextPollingIntervalSeconds(Interval, "timeout")
                        Logger.Warn($"登录轮询第 {UnknownFailureCount} 次失败")
                    Else
                        Finished(New Exception("登录轮询失败", ex))
                        Return
                    End If
                Finally
                    LastResponseAt = GetTimeMs()
                End Try
            Loop
        Catch ex As Exception
            If Not IsFlowExited() Then Finished(New Exception("登录轮询失败", ex))
        Finally
            If IsFlowExited() Then CloseWhenComplete()
        End Try
    End Sub

End Class
