# DeepSeek 悬浮窗：余额 + 今日 Token + 今日消费
param(
  [switch]$SelfTest,
  [switch]$TestFetch,
  [string]$ApiKey = '',
  [string]$UsageToken = ''
)
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Security

$script:Root = $PSScriptRoot
if (-not $script:Root) { $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:ConfigPath = Join-Path $script:Root 'config.json'
$script:ExpandedHeight = 238
$script:CollapsedHeight = 62
$script:MainWindow = $null
$script:fetchRunspace = $null
$script:fetchPowerShell = $null
$script:fetchAsync = $null
$script:uiTimer = $null
$script:refreshTimer = $null
$script:authTimer = $null
$script:authProc = $null
$script:authElapsed = 0
$script:authHint = $null
$script:authButton = $null
$script:authUsageBox = $null

function Protect-Text {
  param([string]$Text)
  if ([string]::IsNullOrEmpty($Text)) { return '' }
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $enc = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
  return 'enc:' + [Convert]::ToBase64String($enc)
}

function Unprotect-Text {
  param([string]$Text)
  if ([string]::IsNullOrEmpty($Text)) { return '' }
  if (-not $Text.StartsWith('enc:')) { return $Text }
  try {
    $b64 = $Text.Substring(4)
    $bytes = [Convert]::FromBase64String($b64)
    $plain = [System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [System.Text.Encoding]::UTF8.GetString($plain)
  } catch {
    return ''
  }
}

function Ensure-Config {
  if (-not (Test-Path $script:ConfigPath)) {
    $script:Config = [PSCustomObject]@{ apiKey = ''; usageToken = ''; refreshSeconds = 60; collapsed = $false }
    Save-Config
    return
  }
  try {
    $loaded = Get-Content $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch {
    $loaded = $null
  }
  $script:Config = [PSCustomObject]@{
    apiKey = if ($loaded -and $null -ne $loaded.apiKey) { Unprotect-Text ([string]$loaded.apiKey) } else { '' }
    usageToken = if ($loaded -and $null -ne $loaded.usageToken) { Unprotect-Text ([string]$loaded.usageToken) } else { '' }
    refreshSeconds = if ($loaded -and $loaded.refreshSeconds) { [int]$loaded.refreshSeconds } else { 60 }
    collapsed = if ($loaded -and $null -ne $loaded.collapsed) { [bool]$loaded.collapsed } else { $false }
  }
  if ($script:Config.refreshSeconds -lt 60) { $script:Config.refreshSeconds = 60 }
}

function Save-Config {
  $out = [ordered]@{
    apiKey = Protect-Text ([string]$script:Config.apiKey)
    usageToken = Protect-Text ([string]$script:Config.usageToken)
    refreshSeconds = [int]$script:Config.refreshSeconds
    collapsed = [bool]$script:Config.collapsed
  }
  $json = $out | ConvertTo-Json
  [System.IO.File]::WriteAllText($script:ConfigPath, $json, (New-Object System.Text.UTF8Encoding $false))
}

$script:FetchScript = {
  param([string]$ApiKey, [string]$UsageToken, [int]$RefreshSeconds)
  $r = [ordered]@{
    ok = $false
    balance = 0.0
    currency = 'CNY'
    topped = 0.0
    granted = 0.0
    balanceError = ''
    usageReady = $false
    todayTokens = 0.0
    cacheHit = 0.0
    cacheMiss = 0.0
    response = 0.0
    requests = 0.0
    todayCost = 0.0
    costCurrency = 'CNY'
    usageError = ''
    usageTokenInvalid = $false
    fetchedAt = [DateTime]::Now
  }
  $client = $null
  try {
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(15)
    $null = $client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36')
    $null = $client.DefaultRequestHeaders.TryAddWithoutValidation('Accept', 'application/json')

    if ($ApiKey) {
      $client.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $ApiKey)
      try {
        $resp = $client.GetAsync('https://api.deepseek.com/user/balance').Result
        $body = $resp.Content.ReadAsStringAsync().Result
        $json = $body | ConvertFrom-Json
        if ($resp.IsSuccessStatusCode -and $json.is_available -eq $true -and $json.balance_infos) {
          $info = @($json.balance_infos)[0]
          $r.ok = $true
          $r.balance = [double]$info.total_balance
          $r.topped = [double]$info.topped_up_balance
          $r.granted = [double]$info.granted_balance
          $r.currency = [string]$info.currency
        } else {
          $msg = ''
          if ($json -and $json.error) {
            if ($json.error.message) { $msg = [string]$json.error.message }
            else { $msg = [string]$json.error }
          }
          elseif ($json -and $json.message) { $msg = [string]$json.message }
          if ($msg) { $r.balanceError = "余额查询失败：$msg" }
          else { $r.balanceError = "余额查询失败：HTTP $([int]$resp.StatusCode)" }
        }
      } catch {
        $r.balanceError = "余额查询出错：$($_.Exception.Message)"
      }
    } else {
      $r.balanceError = '尚未配置 API Key'
    }

    if ($UsageToken) {
      $client.DefaultRequestHeaders.Remove('Authorization') | Out-Null
      $client.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $UsageToken)
      $null = $client.DefaultRequestHeaders.TryAddWithoutValidation('x-app-version', '1.0.0')
      $null = $client.DefaultRequestHeaders.TryAddWithoutValidation('Origin', 'https://platform.deepseek.com')
      $null = $client.DefaultRequestHeaders.TryAddWithoutValidation('Referer', 'https://platform.deepseek.com/usage')
      $start = [DateTimeOffset]::new([DateTime]::Today).ToUnixTimeSeconds()
      $end = [DateTimeOffset]::new([DateTime]::Today.AddDays(1)).ToUnixTimeSeconds()
      $tz = [int][DateTimeOffset]::Now.Offset.TotalSeconds
      $amountUrl = "https://platform.deepseek.com/api/v0/usage/by_api_key/amount?start=$start&end=$end&tz=$tz"
      $costUrl = "https://platform.deepseek.com/api/v0/usage/by_api_key/cost?start=$start&end=$end&tz=$tz"
      $amountJson = $null
      $costJson = $null
      try {
        $respA = $client.GetAsync($amountUrl).Result
        $bodyA = $respA.Content.ReadAsStringAsync().Result
        $amountJson = $bodyA | ConvertFrom-Json
      } catch {
        if (-not $r.usageError) { $r.usageError = "用量查询出错：$($_.Exception.Message)" }
      }
      if ($amountJson -and $amountJson.code -eq 0) {
        try {
          $respC = $client.GetAsync($costUrl).Result
          $bodyC = $respC.Content.ReadAsStringAsync().Result
          $costJson = $bodyC | ConvertFrom-Json
        } catch {
          if (-not $r.usageError) { $r.usageError = "消费查询出错：$($_.Exception.Message)" }
        }
        if ($costJson -and $costJson.code -eq 0) {
          $r.usageReady = $true
          $amountBiz = $amountJson.data.biz_data
          if ($amountBiz -and $amountBiz.series) {
            foreach ($s in @($amountBiz.series)) {
              foreach ($b in @($s.buckets)) {
                $u = $b.usage
                if (-not $u) { continue }
                $r.cacheHit += [double]$u.PROMPT_CACHE_HIT_TOKEN
                $r.cacheMiss += [double]$u.PROMPT_CACHE_MISS_TOKEN
                $r.response += [double]$u.RESPONSE_TOKEN
                $r.requests += [double]$u.REQUEST
              }
            }
          }
          $r.todayTokens = $r.cacheHit + $r.cacheMiss + $r.response
          $costBiz = $costJson.data.biz_data
          if ($costBiz -and $costBiz.data) {
            foreach ($c in @($costBiz.data)) {
              if ($c.currency) { $r.costCurrency = [string]$c.currency }
              foreach ($s in @($c.series)) {
                foreach ($b in @($s.buckets)) {
                  $r.todayCost += [double]$b.cost
                }
              }
            }
          }
        } elseif ($costJson -and $costJson.code) {
          $r.usageError = '用量授权失效或过期，请重新授权'
          $r.usageTokenInvalid = $true
        } else {
          $r.usageError = '消费数据返回异常'
        }
      } elseif ($amountJson -and $amountJson.code) {
        $r.usageError = '用量授权失效或过期，请重新授权'
        $r.usageTokenInvalid = $true
      } elseif (-not $r.usageError) {
        $r.usageError = '用量数据返回异常'
      }
    } else {
      $r.usageError = '未配置用量授权，点设置完成授权'
    }
  } catch {
    if (-not $r.balanceError) { $r.balanceError = "请求出错：$($_.Exception.Message)" }
    if (-not $r.usageError) { $r.usageError = "请求出错：$($_.Exception.Message)" }
  } finally {
    if ($client) { $client.Dispose() }
  }
  [PSCustomObject]$r
}

function Format-Currency {
  param([double]$Value, [string]$Currency = 'CNY')
  if ($Currency -eq 'USD') { $sym = '$' } else { $sym = '¥' }
  return $sym + [String]::Format('{0:N2}', $Value)
}

function Format-Number {
  param([double]$Value)
  return [String]::Format('{0:N0}', $Value)
}

function Format-Compact {
  param([double]$Value)
  $v = [Math]::Round($Value)
  if ($v -ge 100000000) { return ('{0:N1}亿' -f ($v / 100000000)) }
  if ($v -ge 10000) { return ('{0:N1}万' -f ($v / 10000)) }
  return ('{0:N0}' -f $v)
}

function New-WindowFromXaml {
  param([string]$Xaml)
  $xml = [xml]$Xaml
  $reader = New-Object System.Xml.XmlNodeReader $xml
  return [System.Windows.Markup.XamlReader]::Load($reader)
}

$script:MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="360" Height="238" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="False" ShowInTaskbar="False"
        ResizeMode="NoResize" WindowStartupLocation="Manual">
  <Window.Resources>
    <Style x:Key="IconBtn" TargetType="Button">
      <Setter Property="Width" Value="30"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Margin" Value="2,0"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Foreground" Value="#FFB8BEC8"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#FF2A2F3A"/>
                <Setter Property="Foreground" Value="#FFFFFFFF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#FF3A4150"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border CornerRadius="14" Background="#FF1B1E24" BorderBrush="#FF343A46" BorderThickness="1">
    <Border.Effect>
      <DropShadowEffect Color="#000000" BlurRadius="18" ShadowDepth="4" Opacity="0.45" Direction="270"/>
    </Border.Effect>
    <Grid Margin="14,0,10,12">
      <Grid.RowDefinitions>
        <RowDefinition Height="40"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <Grid x:Name="TitleBar" Grid.Row="0" Background="Transparent" Cursor="SizeAll">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Border Width="8" Height="8" CornerRadius="2" Background="#FF2DD4BF" Margin="2,0,8,0"/>
          <TextBlock Text="DeepSeek 用量" FontFamily="Segoe UI Semibold" FontSize="13" Foreground="#FFE8EAED" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <Button x:Name="BtnRefresh" Style="{StaticResource IconBtn}" Content="&#xE72C;" ToolTip="刷新"/>
          <Button x:Name="BtnCollapse" Style="{StaticResource IconBtn}" Content="&#xE73F;" ToolTip="收起/展开"/>
          <Button x:Name="BtnSettings" Style="{StaticResource IconBtn}" Content="&#xE713;" ToolTip="设置"/>
          <Button x:Name="BtnClose" Style="{StaticResource IconBtn}" Content="&#xE8BB;" ToolTip="关闭"/>
        </StackPanel>
      </Grid>
      <Grid x:Name="Body" Grid.Row="1">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Grid Grid.Row="0" Margin="0,4,0,10">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <StackPanel Grid.Column="0">
            <TextBlock Text="余额" FontSize="11" Foreground="#FF9AA0AC"/>
            <TextBlock x:Name="TxtBalance" Text="--" FontSize="27" Foreground="#FF2DD4BF" FontFamily="Segoe UI Semibold"/>
            <TextBlock x:Name="SubBalance" Text="等待刷新" FontSize="10" Foreground="#FF9AA0AC" TextTrimming="CharacterEllipsis" MaxWidth="150"/>
          </StackPanel>
          <Border Grid.Column="1" Width="1" Margin="10,2" Background="#FF303541"/>
          <StackPanel Grid.Column="2" Margin="12,0,0,0">
            <TextBlock Text="今日消费" FontSize="11" Foreground="#FF9AA0AC"/>
            <TextBlock x:Name="TxtCost" Text="--" FontSize="27" Foreground="#FFF5B44C" FontFamily="Segoe UI Semibold"/>
            <TextBlock x:Name="SubCost" Text="--" FontSize="10" Foreground="#FF9AA0AC" TextTrimming="CharacterEllipsis" MaxWidth="150"/>
          </StackPanel>
        </Grid>
        <StackPanel Grid.Row="1" Margin="0,0,0,10">
          <TextBlock Text="今日 Token" FontSize="11" Foreground="#FF9AA0AC"/>
          <TextBlock x:Name="TxtTokens" Text="--" FontSize="21" Foreground="#FFE8EAED" FontFamily="Segoe UI Semibold"/>
          <TextBlock x:Name="SubTokens" Text="等待刷新" FontSize="10" Foreground="#FF9AA0AC" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
        <Border Grid.Row="2" Height="1" Background="#FF2B303A"/>
        <Grid Grid.Row="3" Margin="0,8,0,0" VerticalAlignment="Top">
          <StackPanel Orientation="Horizontal">
            <Ellipse x:Name="Dot" Width="8" Height="8" Fill="#FF9AA0AC"/>
            <TextBlock x:Name="TxtStatus" Text="正在启动…" Margin="8,0,0,0" FontSize="11" Foreground="#FF9AA0AC"/>
          </StackPanel>
          <TextBlock x:Name="TxtUpdated" HorizontalAlignment="Right" Text="" FontSize="11" Foreground="#FF6F7582"/>
        </Grid>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

$script:SettingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="540" Height="486" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="False" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" ShowInTaskbar="False">
  <Window.Resources>
    <Style x:Key="FieldLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="#FF9AA0AC"/>
      <Setter Property="Margin" Value="0,12,0,6"/>
    </Style>
    <Style x:Key="InputBox" TargetType="Control">
      <Setter Property="Background" Value="#FF14161B"/>
      <Setter Property="Foreground" Value="#FFE8EAED"/>
      <Setter Property="BorderBrush" Value="#FF3A4150"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="Padding" Value="8,4"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style x:Key="ActionBtn" TargetType="Button">
      <Setter Property="Background" Value="#FF232833"/>
      <Setter Property="Foreground" Value="#FFE8EAED"/>
      <Setter Property="BorderBrush" Value="#FF3A4150"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Padding" Value="14,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#FF2E3542"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#FF39424F"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border CornerRadius="12" Background="#FF20232A" BorderBrush="#FF3A4150" BorderThickness="1">
    <Border.Effect>
      <DropShadowEffect Color="#000000" BlurRadius="20" ShadowDepth="5" Opacity="0.5" Direction="270"/>
    </Border.Effect>
    <Grid Margin="18,12,18,16">
      <Grid.RowDefinitions>
        <RowDefinition Height="38"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <Grid Grid.Row="0" x:Name="SettingsTitle" Background="Transparent" Cursor="SizeAll">
        <TextBlock Text="设置" FontFamily="Segoe UI Semibold" FontSize="14" Foreground="#FFE8EAED" VerticalAlignment="Center"/>
        <Button x:Name="BtnSettingsClose" Style="{StaticResource ActionBtn}" Width="32" Height="30" Padding="0" HorizontalAlignment="Right" Content="&#xE8BB;" FontFamily="Segoe MDL2 Assets" FontSize="13" ToolTip="关闭"/>
      </Grid>
      <TextBlock Grid.Row="1" Text="API Key（DeepSeek 平台 → API Keys 中创建/复制）" Style="{StaticResource FieldLabel}"/>
      <PasswordBox Grid.Row="2" x:Name="TxtApiKey" Style="{StaticResource InputBox}"/>
      <TextBlock Grid.Row="3" Text="用量 Token（查看今日 Token 和消费需要）" Style="{StaticResource FieldLabel}"/>
      <PasswordBox Grid.Row="4" x:Name="TxtUsageToken" Style="{StaticResource InputBox}"/>
      <StackPanel Grid.Row="5" Orientation="Horizontal" Margin="0,12,0,0">
        <Button x:Name="BtnAuth" Style="{StaticResource ActionBtn}" Content="一键授权获取用量 Token" Background="#FF2DD4BF" Foreground="#FF101418"/>
        <Button x:Name="BtnOpenUsage" Style="{StaticResource ActionBtn}" Content="打开平台用量页（手动）" Margin="10,0,0,0"/>
      </StackPanel>
      <TextBlock Grid.Row="6" Text="自动刷新间隔（分钟，1-120）" Style="{StaticResource FieldLabel}"/>
      <TextBox Grid.Row="7" x:Name="TxtInterval" Style="{StaticResource InputBox}" Width="120" HorizontalAlignment="Left"/>
      <TextBlock Grid.Row="8" x:Name="TxtHint" Margin="0,14,0,0" FontSize="11" Foreground="#FF9AA0AC" TextWrapping="Wrap" MaxHeight="56"/>
      <StackPanel Grid.Row="10" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Bottom">
        <Button x:Name="BtnSave" Style="{StaticResource ActionBtn}" Content="保存" Background="#FF2DD4BF" Foreground="#FF101418" Width="92"/>
        <Button x:Name="BtnCancel" Style="{StaticResource ActionBtn}" Content="取消" Margin="10,0,0,0" Width="92"/>
      </StackPanel>
    </Grid>
  </Border>
</Window>
'@

function Set-Status {
  param([string]$Text, [string]$Color = '#FF9AA0AC')
  $script:TxtStatus.Text = $Text
  $script:Dot.Fill = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Color))
}

function Update-Widget {
  param($Data)
  if (-not $Data) { return }
  if ($Data.ok) {
    $script:TxtBalance.Text = Format-Currency ([double]$Data.balance) ([string]$Data.currency)
    $script:SubBalance.Text = "充值 $(Format-Currency ([double]$Data.topped) ([string]$Data.currency)) · 赠送 $(Format-Currency ([double]$Data.granted) ([string]$Data.currency))"
    $script:TxtBalance.ToolTip = $script:SubBalance.Text
  } else {
    $script:TxtBalance.Text = '--'
    $script:SubBalance.Text = [string]$Data.balanceError
  }
  if ($Data.usageReady) {
    $script:TxtTokens.Text = Format-Number ([double]$Data.todayTokens)
    $script:SubTokens.Text = "命中 $(Format-Compact ([double]$Data.cacheHit)) · 未命中 $(Format-Compact ([double]$Data.cacheMiss)) · 输出 $(Format-Compact ([double]$Data.response)) · $([int]$Data.requests) 次请求"
    $script:TxtCost.Text = Format-Currency ([double]$Data.todayCost) ([string]$Data.costCurrency)
    $script:SubCost.Text = '今日实时累计'
    $script:TxtTokens.ToolTip = $script:SubTokens.Text
  } else {
    $script:TxtTokens.Text = '--'
    $script:TxtCost.Text = '--'
    $script:SubTokens.Text = [string]$Data.usageError
    $script:SubCost.Text = '点右上角设置'
    $script:TxtTokens.ToolTip = ''
  }
  $script:TxtUpdated.Text = "更新于 $($Data.fetchedAt.ToString('HH:mm'))"
  if ($Data.ok -and $Data.usageReady) {
    Set-Status '正常' '#FF2DD4BF'
  } elseif ($Data.ok -and -not $Data.usageReady) {
    Set-Status ([string]$Data.usageError) '#FFF5B44C'
  } else {
    Set-Status ([string]$Data.balanceError) '#FFF06A6A'
  }
}

function New-FetchRunspace {
  $script:fetchRunspace = [runspacefactory]::CreateRunspace()
  $script:fetchRunspace.Open()
  $script:fetchPowerShell = [powershell]::Create()
  $script:fetchPowerShell.Runspace = $script:fetchRunspace
}

function Start-Fetch {
  if ($script:fetchAsync -and -not $script:fetchAsync.IsCompleted) { return }
  Set-Status '正在刷新…' '#FFF5B44C'
  $ps = $script:fetchPowerShell
  $null = $ps.Commands.Clear()
  $null = $ps.AddScript($script:FetchScript)
  $null = $ps.AddArgument([string]$script:Config.apiKey)
  $null = $ps.AddArgument([string]$script:Config.usageToken)
  $null = $ps.AddArgument([int]$script:Config.refreshSeconds)
  $script:fetchAsync = $ps.BeginInvoke()
}

function Set-RefreshTimer {
  $secs = [Math]::Max(60, [Math]::Min(7200, [int]$script:Config.refreshSeconds))
  $script:refreshTimer.Interval = [TimeSpan]::FromSeconds($secs)
  if (-not $script:refreshTimer.IsEnabled) { $script:refreshTimer.Start() }
}

function Toggle-Collapse {
  $w = $script:MainWindow
  $body = $w.FindName('Body')
  $collapsed = -not [bool]$script:Config.collapsed
  $script:Config.collapsed = $collapsed
  Save-Config
  if ($collapsed) {
    $w.Height = $script:CollapsedHeight
    $body.Visibility = [System.Windows.Visibility]::Collapsed
  } else {
    $w.Height = $script:ExpandedHeight
    $body.Visibility = [System.Windows.Visibility]::Visible
  }
}

function Start-TokenCapture {
  param($Hint, $AuthButton, $UsageBox)
  $node = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
  $helper = Join-Path $script:Root 'capture-token.mjs'
  if (-not $node) {
    $Hint.Text = '未检测到 Node.js：请手动获取 Token，或先安装 Node.js 后再使用一键授权。'
    return
  }
  if (-not (Test-Path $helper)) {
    $Hint.Text = '缺少 capture-token.mjs，请确认文件与悬浮窗在同一目录。'
    return
  }
  $script:Config.apiKey = $UsageBox.Parent.FindName('TxtApiKey').Password
  Save-Config
  $AuthButton.IsEnabled = $false
  $script:authHint = $Hint
  $script:authButton = $AuthButton
  $script:authUsageBox = $UsageBox
  $script:authElapsed = 0
  $Hint.Text = '已打开授权窗口：请在浏览器中登录 DeepSeek 平台，授权成功后会自动填入。'
  $procArgs = "`"$helper`" `"$script:ConfigPath`""
  $script:authProc = Start-Process -FilePath $node -ArgumentList $procArgs -WindowStyle Hidden -PassThru
  $script:authTimer = New-Object System.Windows.Threading.DispatcherTimer
  $script:authTimer.Interval = [TimeSpan]::FromSeconds(2)
  $script:authTimer.Add_Tick({
    $script:authElapsed += 2
    $ok = $false
    try {
      $cfg = Get-Content $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($cfg.usageToken) {
        $ok = $true
        $script:authTimer.Stop()
        $script:authUsageBox.Password = [string]$cfg.usageToken
        $script:authHint.Text = '授权成功，Token 已自动填入，点击“保存”即可。'
      }
    } catch {}
    if (-not $ok) {
      $exited = $false
      if ($script:authProc) {
        $script:authProc.Refresh()
        $exited = $script:authProc.HasExited
      }
      if ($script:authElapsed -ge 180 -or ($exited -and $script:authElapsed -ge 10)) {
        $script:authTimer.Stop()
        $script:authHint.Text = '未获取到授权：请确认已登录并停留在用量页面后重试，或使用手动方式。'
      }
    }
    if ($ok -or -not $script:authTimer.IsEnabled) { $script:authButton.IsEnabled = $true }
  })
  $script:authTimer.Start()
}

function Show-SettingsWindow {
  $dlg = New-WindowFromXaml $script:SettingsXaml
  $dlg.Owner = $script:MainWindow
  $txtApi = $dlg.FindName('TxtApiKey')
  $txtUsage = $dlg.FindName('TxtUsageToken')
  $txtInterval = $dlg.FindName('TxtInterval')
  $txtHint = $dlg.FindName('TxtHint')
  $btnAuth = $dlg.FindName('BtnAuth')
  $btnOpen = $dlg.FindName('BtnOpenUsage')
  $btnSave = $dlg.FindName('BtnSave')
  $btnCancel = $dlg.FindName('BtnCancel')
  $btnClose = $dlg.FindName('BtnSettingsClose')
  $title = $dlg.FindName('SettingsTitle')

  $txtApi.Password = [string]$script:Config.apiKey
  $txtUsage.Password = [string]$script:Config.usageToken
  $txtInterval.Text = [string][int]([int]$script:Config.refreshSeconds / 60)
  $txtHint.Text = '手动方式：打开平台用量页并登录 → 按 F12 → Network → 刷新页面 → 找到 usage/amount 请求 → 复制 Authorization 中 Bearer 后面的内容，粘贴到上方。'

  $title.Add_MouseLeftButtonDown({ $dlg.DragMove() })
  $btnClose.Add_Click({ $dlg.Close() })
  $btnOpen.Add_Click({ Start-Process 'https://platform.deepseek.com/usage' | Out-Null })
  $btnAuth.Add_Click({ Start-TokenCapture -Hint $txtHint -AuthButton $btnAuth -UsageBox $txtUsage })
  $btnSave.Add_Click({
    $script:Config.apiKey = $txtApi.Password
    $script:Config.usageToken = $txtUsage.Password
    $mins = 1
    $parsed = 0
    if ([int]::TryParse($txtInterval.Text, [ref]$parsed)) { $mins = $parsed }
    $mins = [Math]::Max(1, [Math]::Min(120, $mins))
    $script:Config.refreshSeconds = $mins * 60
    Save-Config
    $dlg.Close()
    Set-RefreshTimer
    Start-Fetch
  })
  $btnCancel.Add_Click({ $dlg.Close() })
  $dlg.ShowDialog()
}

function Wire-MainWindow {
  $w = $script:MainWindow
  $script:TitleBar = $w.FindName('TitleBar')
  $script:TxtBalance = $w.FindName('TxtBalance')
  $script:SubBalance = $w.FindName('SubBalance')
  $script:TxtCost = $w.FindName('TxtCost')
  $script:SubCost = $w.FindName('SubCost')
  $script:TxtTokens = $w.FindName('TxtTokens')
  $script:SubTokens = $w.FindName('SubTokens')
  $script:TxtStatus = $w.FindName('TxtStatus')
  $script:TxtUpdated = $w.FindName('TxtUpdated')
  $script:Dot = $w.FindName('Dot')

  $btnRefresh = $w.FindName('BtnRefresh')
  $btnCollapse = $w.FindName('BtnCollapse')
  $btnSettings = $w.FindName('BtnSettings')
  $btnClose = $w.FindName('BtnClose')

  $script:TitleBar.Add_MouseLeftButtonDown({ $script:MainWindow.DragMove() })
  $btnRefresh.Add_Click({ Start-Fetch })
  $btnCollapse.Add_Click({ Toggle-Collapse })
  $btnSettings.Add_Click({ Show-SettingsWindow })
  $btnClose.Add_Click({ $script:MainWindow.Close() })
  $w.Add_Activated({ Start-Fetch })
}

function Stop-Widget {
  if ($script:uiTimer) { $script:uiTimer.Stop() }
  if ($script:refreshTimer) { $script:refreshTimer.Stop() }
  if ($script:authTimer) { $script:authTimer.Stop() }
  if ($script:fetchAsync) {
    try { $null = $script:fetchAsync.AsyncWaitHandle.WaitOne(1500) } catch {}
  }
  if ($script:fetchPowerShell) { $script:fetchPowerShell.Dispose() }
  if ($script:fetchRunspace) {
    $script:fetchRunspace.Close()
    $script:fetchRunspace.Dispose()
  }
}

function Show-MainWindow {
  Ensure-Config
  $script:MainWindow = New-WindowFromXaml $script:MainXaml
  $w = $script:MainWindow
  $w.Left = [System.Windows.SystemParameters]::PrimaryScreenWidth - $w.Width - 28
  $w.Top = 90
  if ($script:Config.collapsed) {
    $w.Height = $script:CollapsedHeight
    $w.FindName('Body').Visibility = [System.Windows.Visibility]::Collapsed
  }
  Wire-MainWindow
  New-FetchRunspace

  $script:uiTimer = New-Object System.Windows.Threading.DispatcherTimer
  $script:uiTimer.Interval = [TimeSpan]::FromMilliseconds(400)
  $script:uiTimer.Add_Tick({
    if ($script:fetchAsync -and $script:fetchAsync.IsCompleted) {
      try {
        $data = @($script:fetchPowerShell.EndInvoke($script:fetchAsync))[0]
        Update-Widget $data
      } catch {
        Set-Status "刷新失败：$($_.Exception.Message)" '#FFF06A6A'
      } finally {
        $script:fetchAsync = $null
      }
    }
  })
  $script:uiTimer.Start()

  $script:refreshTimer = New-Object System.Windows.Threading.DispatcherTimer
  $script:refreshTimer.Add_Tick({ Start-Fetch })
  Set-RefreshTimer

  $w.Add_Closed({ Stop-Widget })
  Start-Fetch
  $w.ShowDialog()
}

if ($SelfTest) {
  $w1 = New-WindowFromXaml $script:MainXaml
  $w2 = New-WindowFromXaml $script:SettingsXaml
  $null = $w1.FindName('TxtBalance')
  $null = $w2.FindName('TxtApiKey')
  $w1.Close()
  $w2.Close()
  Write-Output 'SELFTEST OK'
  exit 0
}

if ($TestFetch) {
  Ensure-Config
  $data = & $script:FetchScript -ApiKey $script:Config.apiKey -UsageToken $script:Config.usageToken -RefreshSeconds $script:Config.refreshSeconds
  $data | Format-List
  exit 0
}

Show-MainWindow
