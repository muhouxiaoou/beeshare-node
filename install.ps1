# BeeShare 节点安装脚本（Windows）。在 PowerShell 里运行：
#   irm https://beeshare.cc/install.ps1 | iex
#
# 做的事：读取平台的发布清单 → 下载 windows-amd64 安装包 → 校验 SHA-256 → 试运行确认版本 →
# 装到 %LOCALAPPDATA%\BeeShare\bin 并加入当前用户的 PATH。不需要管理员权限。
# 可用环境变量：BEESHARE_BASE（平台地址）、BEESHARE_INSTALL_DIR（安装目录）、BEESHARE_PROXY（下载走的代理，
# 例如 http://127.0.0.1:7890；不设时用系统代理设置）。
#
# 关于信任：第一次安装信任的是 HTTPS 连接和 beeshare.cc 本身（和 install.sh 一样）；
# 装好之后的每一次更新都会用程序内置的发布公钥验证清单签名。

& {
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue' # Windows PowerShell 5.1 显示进度条会让下载慢很多

  function Fail([string]$msg) { Write-Host "错误: ${msg}" -ForegroundColor Red; throw $msg }
  function Step([string]$n, [string]$msg) { Write-Host "[${n}/4] " -ForegroundColor Yellow -NoNewline; Write-Host $msg }
  function Note([string]$msg) { Write-Host "      ${msg}" -ForegroundColor DarkGray }
  function NetHelp {
    Write-Host '  · 网络不稳定时，重新运行一次安装命令通常就好了'
    Write-Host '  · 本机有代理时，先设置代理再安装，例如：'
    Write-Host '      $env:BEESHARE_PROXY = ''http://127.0.0.1:7890'''
    Write-Host "      irm ${base}/install.ps1 | iex"
  }
  # HttpCode：异常里服务器明确返回的错误状态码（4xx/5xx），网络错误、超时、中途断开（可能带着 200 的响应）都是 0。
  function HttpCode($err) {
    $resp = $err.Exception.Response
    if ($resp -and [int]$resp.StatusCode -ge 400) { return [int]$resp.StatusCode }
    return 0
  }
  # 网络错误、超时、中途断开最多试 3 次；服务器明确返回了错误状态（例如 404）就不再重试，交给调用方判断。
  function WithRetry([scriptblock]$do) {
    for ($i = 1; $i -le 3; $i++) {
      try { return (& $do) }
      catch {
        if ((HttpCode $_) -ne 0 -or $i -eq 3) { throw }
        $next = $i + 1
        Note "连接较慢或中断，正在重试（${next}/3）…"
        Start-Sleep -Seconds 2
      }
    }
  }

  # Windows PowerShell 5.1 默认可能不启用 TLS 1.2
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

  $base = if ($env:BEESHARE_BASE) { $env:BEESHARE_BASE.TrimEnd('/') } else { 'https://beeshare.cc' }
  $net = @{ UseBasicParsing = $true }
  if ($env:BEESHARE_PROXY) { $net.Proxy = $env:BEESHARE_PROXY }

  Write-Host ''
  Write-Host '  蜂享 BeeShare' -ForegroundColor Yellow -NoNewline; Write-Host ' · 节点安装'
  Write-Host '  分享 · 连接 · 共赢 —— 把闲置的 AI 订阅额度共享出去，每一次成功调用都为你带来收益' -ForegroundColor DarkGray
  Write-Host ''

  $arch = $env:PROCESSOR_ARCHITECTURE
  if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 } # 32 位 PowerShell 跑在 64 位系统上
  if ($arch -ne 'AMD64') { Fail "目前只提供 64 位 x86（AMD64）的 Windows 安装包，这台机器是 ${arch}" }
  $platform = 'windows-amd64'
  Step 1 "检测系统：Windows ${arch}（${platform}）"
  if ($env:BEESHARE_PROXY) { Note "使用代理 ${env:BEESHARE_PROXY}" }

  Step 2 '获取最新版本信息…'
  try { $m = WithRetry { Invoke-RestMethod @net -Uri "${base}/node/manifest.json" -TimeoutSec 30 } }
  catch {
    $code = HttpCode $_
    if ($code -eq 0) { NetHelp; Fail "连不上 ${base}（已试 3 次）" }
    if ($code -eq 404) { Fail "平台还没有发布节点安装包（${base}/node/manifest.json 不存在），请稍后再试或联系管理员" }
    Fail "获取发布清单失败：${base}/node/manifest.json 返回 http ${code}"
  }

  $version = [string]$m.version
  if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { Fail '清单里的版本号不合法' }
  $asset = $m.assets.$platform
  if (-not $asset) { Fail "最新版本 ${version} 里没有 ${platform} 的安装包" }
  $file = [string]$asset.file
  $want = ([string]$asset.sha256).ToLowerInvariant()
  if ($file -notmatch '^beeshare-node-[0-9]+\.[0-9]+\.[0-9]+-windows-amd64\.exe$') { Fail "清单里的文件名不合法: ${file}" }
  if ($want -notmatch '^[0-9a-f]{64}$') { Fail '清单里的校验值不合法' }
  Note "最新版本 ${version}"
  $sizeText = if ($asset.size) { '，{0:N1} MB' -f ([double]$asset.size / 1MB) } else { '' }

  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("beeshare-node-" + [guid]::NewGuid().ToString('N') + '.exe')
  try {
    Step 3 "下载安装包（${file}${sizeText}）…"
    Note '下载时不显示进度条（Windows PowerShell 显示进度会让下载慢很多），请稍等'
    try { WithRetry { Invoke-WebRequest @net -Uri "${base}/download/${file}" -OutFile $tmp -TimeoutSec 600 } | Out-Null }
    catch {
      $code = HttpCode $_
      if ($code -eq 0) { NetHelp; Fail "下载失败，连不上 ${base} 或速度太慢（已试 3 次）" }
      Fail "下载失败：${base}/download/${file} 返回 http ${code}"
    }
    Note '校验 SHA-256…'
    $got = (Get-FileHash -Algorithm SHA256 -Path $tmp).Hash.ToLowerInvariant()
    if ($got -ne $want) { Fail '下载文件的 SHA-256 与清单不一致，已放弃安装（可能下载损坏或被篡改）' }

    $gotVer = (& $tmp version 2>$null | Out-String).Trim()
    if ($gotVer -ne $version) { Fail "新程序无法在本机运行或版本不符（得到 '${gotVer}'，应为 '${version}'）" }
    Note '校验通过，试运行正常'

    $dir = if ($env:BEESHARE_INSTALL_DIR) { $env:BEESHARE_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'BeeShare\bin' }
    Step 4 "安装到 ${dir}…"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $dest = Join-Path $dir 'beeshare-node.exe'
    if (Test-Path $dest) {
      # 正在运行的程序不能覆盖，但可以改名：旧版本挪成 .old，新版本放到原位
      $old = "${dest}.old"
      Remove-Item -Force -ErrorAction SilentlyContinue $old
      Move-Item -Force $dest $old
    }
    Move-Item -Force $tmp $dest
  } finally {
    Remove-Item -Force -ErrorAction SilentlyContinue $tmp
  }

  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (-not (($userPath -split ';') -contains $dir)) {
    [Environment]::SetEnvironmentVariable('Path', ($(if ($userPath) { "${userPath};${dir}" } else { $dir })), 'User')
    $env:Path = "${env:Path};${dir}"
    Write-Host "已把 ${dir} 加入当前用户的 PATH（新开的终端生效）。"
  }

  Write-Host ''
  Write-Host "√ 已安装 beeshare-node ${version} → ${dest}" -ForegroundColor Green
  Write-Host ''
  Write-Host '下一步：'
  Write-Host "  1. 在网站「节点 → 添加节点」里生成绑定码：${base}/nodes"
  Write-Host '  2. beeshare-node bind <绑定码>'
  Write-Host '  3. beeshare-node install-service       （登录后自动运行、崩溃自动恢复、自动更新）'
  Write-Host '     或 beeshare-node run               （前台运行，关掉窗口就下线）'
  Write-Host ''
  Write-Host '  beeshare-node console                  打开本机的网页控制台（也可以在那里绑定、设置代理）'
  Write-Host '  beeshare-node doctor                   出问题时先运行它'
  Write-Host '  以后更新：beeshare-node update'
  Write-Host ''
  Write-Host '  欢迎加入蜂享。' -ForegroundColor Yellow -NoNewline; Write-Host "使用指南和收益规则见 ${base}" -ForegroundColor DarkGray
}
