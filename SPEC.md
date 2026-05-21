# cli-screenshot 實作規格書

## Context
使用者在 Windows 原生 PowerShell 使用 Claude Code CLI，無法直接貼圖。需要一個工具：截圖後自動把檔案路徑放到剪貼簿，讓 `Ctrl+V` 直接貼出路徑。參考 wsl-screenshot-cli 但改為純 PowerShell 實作，零依賴。

## 專案結構

```
cli-screenshot\
├── cli-screenshot.ps1          # CLI 入口（參數解析 + 指令分派）
├── lib\
│   ├── Monitor.ps1             # 核心監控迴圈（剪貼簿偵測/去重/三格式寫入）
│   └── Daemon.ps1              # 背景程序管理（start/stop/status）
├── install.ps1                 # 一鍵安裝腳本
├── hooks\
│   └── claude-hooks.json       # Claude Code hooks 設定範本
├── README.md
├── LICENSE
└── .gitignore
```

## 核心功能

### 1. 剪貼簿監控 (`lib/Monitor.ps1`)

#### 職責
偵測剪貼簿中的新截圖、去重、儲存、設定三種剪貼簿格式。

#### 主函式：`Start-ClipboardMonitor`
```powershell
function Start-ClipboardMonitor {
    param(
        [int]$Interval = 250,
        [string]$OutputDir,
        [string]$LogFile
    )
}
```

#### 運作流程
1. 載入 `System.Windows.Forms` 和 `System.Drawing` 組件
2. 確保輸出目錄存在
3. 初始化 `$lastHash = ""` 用於記憶體內快取最後處理的 hash
4. 進入無限迴圈，每 `$Interval` ms 執行一次：
   - 呼叫 `[System.Windows.Forms.Application]::DoEvents()` 維持 STA 訊息幫浦
   - 檢查 `[System.Windows.Forms.Clipboard]::ContainsImage()`
   - **新截圖偵測邏輯**（雙重防護）：
     - 第一層：有 Image 但「沒有」同時有 Text + FileDropList → 可能是新截圖
     - 第二層：計算 SHA256 hash，與 `$lastHash` 比較 → 不同才處理
   - 取得圖片 → 轉 PNG bytes → 計算 SHA256 hash
   - 檔名 = `<sha256_hash>.png`
   - 若檔案不存在 → 寫入磁碟（去重）
   - **無論檔案是否已存在，都更新剪貼簿**（因使用者可能中間複製了其他東西）
   - 寫入三種剪貼簿格式
   - 更新 `$lastHash`
   - **顯式 Dispose 所有 .NET 物件**（Image、MemoryStream）

#### 三格式剪貼簿寫入
```powershell
$data = New-Object System.Windows.Forms.DataObject
$data.SetImage($img)                    # CF_BITMAP → Paint/圖片應用
$data.SetText($filePath)                # CF_UNICODETEXT → 終端機/CMD
$files = New-Object System.Collections.Specialized.StringCollection
$files.Add($filePath) | Out-Null
$data.SetFileDropList($files)           # CF_HDROP → 檔案總管
[System.Windows.Forms.Clipboard]::SetDataObject($data, $true)  # $true = 程式結束後保留
```

#### 貼上結果
| 貼上位置 | 格式 | 結果 |
|---------|------|------|
| PowerShell/CMD/Claude Code | CF_UNICODETEXT | 檔案完整路徑 |
| Paint/圖片應用 | CF_BITMAP | 截圖圖片 |
| 檔案總管 | CF_HDROP | PNG 檔案 |

#### SHA256 去重（含資源釋放）
```powershell
$ms = New-Object System.IO.MemoryStream
try {
    $img.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bytes = $ms.ToArray()
} finally {
    $ms.Dispose()
}

$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $hashBytes = $sha.ComputeHash($bytes)
    $hash = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
} finally {
    $sha.Dispose()
}

$filePath = Join-Path $OutputDir "$hash.png"
```

#### 剪貼簿操作 Retry 機制
```powershell
function Invoke-ClipboardAction {
    param(
        [scriptblock]$Action,
        [int]$MaxRetries = 5,
        [int]$RetryDelayMs = 50
    )
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            return (& $Action)
        } catch [System.Runtime.InteropServices.ExternalException] {
            if ($attempt -eq $MaxRetries) { throw }
            Start-Sleep -Milliseconds $RetryDelayMs
        }
    }
}

# 使用範例：
$img = Invoke-ClipboardAction { [System.Windows.Forms.Clipboard]::GetImage() }
Invoke-ClipboardAction { [System.Windows.Forms.Clipboard]::SetDataObject($data, $true) }
```

**為什麼需要 Retry：** Win+Shift+S 截圖時，Snipping Tool 會短暫鎖定剪貼簿。若在鎖定期間讀寫，會拋出 `ExternalException (Requested Clipboard operation did not succeed)`。Retry 間隔 50ms，最多 5 次（共 250ms），足以等待 Snipping Tool 釋放。

#### 記憶體管理（致命風險防護）
每 250ms 輪詢一次，`GetImage()` 會產生 .NET Image 物件和底層 GDI Handle。**必須顯式 Dispose**：

```powershell
$img = $null
try {
    $img = Invoke-ClipboardAction { [System.Windows.Forms.Clipboard]::GetImage() }
    if ($null -eq $img) { continue }

    # ... 處理圖片、計算 hash、寫入檔案 ...
    # ... 寫入三格式剪貼簿 ...

} catch {
    Write-Log $LogFile "ERROR: $($_.Exception.Message)"
} finally {
    if ($null -ne $img) { $img.Dispose() }
}
```

**所有 IDisposable 物件清單：**
- `$img`（System.Drawing.Image）→ GDI Handle
- `$ms`（System.IO.MemoryStream）→ 記憶體緩衝區
- `$sha`（SHA256）→ 加密資源

#### 邊界條件：網頁複製圖片
瀏覽器複製圖片時通常只有 Image + HTML Format（無 Text + FileDropList），會觸發本工具。
**這是預期行為**：使用者複製任何圖片到剪貼簿，都會被存檔並轉為路徑格式，方便在 CLI 中使用。

#### 輔助函式：`Write-Log`
- 寫入 log 檔案（附時間戳）
- Log 輪轉：超過 5MB 時截斷前半部分
- 同時輸出到 console（前景模式時）

---

### 2. Daemon 管理 (`lib/Daemon.ps1`)

#### 檔案位置
- PID 檔：`$env:TEMP\cli-screenshot.pid`
- Log 檔：`$env:TEMP\cli-screenshot.log`
- 引用計數檔：`$env:TEMP\cli-screenshot.refcount`

#### 函式：`Start-CliScreenshot`
```powershell
function Start-CliScreenshot {
    param(
        [switch]$Daemon,
        [int]$Interval = 250,
        [string]$Output,
        [switch]$Quiet
    )
}
```

**前景模式**（無 `--daemon`）：
1. 檢查是否已有 daemon 在跑（讀 PID 檔 + 嚴謹驗證，見下方）
2. 寫入當前 PID 到 PID 檔
3. 直接呼叫 `Start-ClipboardMonitor`
4. Ctrl+C 中止時清理 PID 檔（finally 區塊）

**背景模式**（`--daemon`）：
1. 同樣先檢查重複啟動
2. 偵測當前 PowerShell 版本，選擇正確的執行檔和 STA 參數：
   - PS 5.1：`powershell.exe -WindowStyle Hidden`
   - PS 7.x：`pwsh.exe -STA -WindowStyle Hidden`
3. 參數：`-NoProfile -ExecutionPolicy Bypass -File cli-screenshot.ps1 start -Interval $Interval -Output $Output`
4. 寫入子程序 PID 到 PID 檔
5. 輸出啟動訊息後返回

#### 函式：`Stop-CliScreenshot`
1. 讀 PID 檔
2. **嚴謹 PID 驗證**（防誤殺，三層驗證）
3. **引用計數檢查**：
   - RefCount - 1 > 0 → 其他 session 還在用，不停止 daemon
   - RefCount - 1 ≤ 0 → 最後一個 session，停止 daemon 並清理所有檔案
4. 刪除 PID 檔和引用計數檔

**為什麼需要三層驗證：** 電腦重開機或程式崩潰後，PID 檔殘留。該 PID 可能已被系統分配給 Chrome 或其他服務，直接 `Stop-Process` 會誤殺。

**為什麼需要引用計數：** 多個 Claude Code session 透過 SessionStart/SessionEnd hooks 共用同一個 daemon。沒有引用計數時，任一 session 結束都會殺掉 daemon，導致其他 session 的截圖功能失效。

#### 函式：`Get-CliScreenshotStatus`
輸出資訊：
- Status: RUNNING / STOPPED
- PID
- RefCount（目前使用中的 session 數量）
- Memory（MB）
- Uptime（hh:mm:ss）
- Screenshots saved（從 log 統計 "NEW screenshot saved" 出現次數）

同樣使用三層 PID 驗證確認狀態。

---

### 3. CLI 入口 (`cli-screenshot.ps1`)

#### 指令介面
```
cli-screenshot start [--daemon] [--interval 250] [--output <path>] [--quiet]
cli-screenshot stop [--quiet]
cli-screenshot status
cli-screenshot version
```

#### 參數定義
```powershell
param(
    [Parameter(Position=0)]
    [ValidateSet('start','stop','status','version')]
    [string]$Command = 'start',

    [Alias('d')]
    [switch]$Daemon,

    [Alias('i')]
    [int]$Interval = 250,

    [Alias('o')]
    [string]$Output = (Join-Path $env:USERPROFILE 'Pictures\Screenshots'),

    [Alias('q')]
    [switch]$Quiet
)
```

#### STA 自動重啟機制
不再強制降級到 PowerShell 5.1。改為自動偵測並重啟：

```powershell
# STA 檢查：若在 MTA 環境，自動用 -STA 重啟自己
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $exe = (Get-Process -Id $PID).Path  # 取得當前 PS 執行檔路徑
    $allArgs = @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $MyInvocation.MyCommand.Path) + $args
    & $exe @allArgs
    exit $LASTEXITCODE
}
```

**效果：** 不管使用者用 `powershell.exe` 或 `pwsh.exe` 啟動，都能自動處理 STA 問題，無需手動操心。

#### 指令分派
```powershell
switch ($Command) {
    'start'   { Start-CliScreenshot -Daemon:$Daemon -Interval $Interval -Output $Output -Quiet:$Quiet }
    'stop'    { Stop-CliScreenshot -Quiet:$Quiet }
    'status'  { Get-CliScreenshotStatus }
    'version' { Write-Host "cli-screenshot v1.1.0" }
}
```

---

### 4. 一鍵安裝 (`install.ps1`)

#### 安裝指令
```powershell
irm https://raw.githubusercontent.com/<user>/cli-screenshot/main/install.ps1 | iex
```

#### 安裝流程
1. 設定安裝目錄：`$env:USERPROFILE\.cli-screenshot\`
2. 下載 repo zip：`https://github.com/<user>/cli-screenshot/archive/refs/heads/main.zip`
3. 解壓到安裝目錄
4. 建立 `.cmd` wrapper：
   ```batch
   @echo off
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.cli-screenshot\cli-screenshot.ps1" %*
   ```
5. Wrapper 放到 `$env:USERPROFILE\.cli-screenshot\bin\cli-screenshot.cmd`
6. 若 `bin\` 不在 User PATH → 自動加入（永久，User 級別）
7. 同時更新當前 session 的 `$env:Path`
8. 清理暫存檔
9. 顯示提示：「安裝完成！若 `cli-screenshot` 指令無法使用，請重新啟動終端機。」

#### 設計重點
- 不需管理員權限
- 使用 `.cmd` wrapper 讓 CMD 和 PowerShell 都能直接呼叫 `cli-screenshot`
- bin 目錄放在 `.cli-screenshot\bin\` 下（與安裝目錄一起管理，避免分散到 `.local\bin`）
- 安裝後更新當前 session PATH + 提示重啟終端機（雙重確保）

---

### 5. Claude Code Hooks 整合

#### 設定範本 (`hooks/claude-hooks.json`)
```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "cli-screenshot start --daemon --quiet"
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "cli-screenshot stop --quiet"
          }
        ]
      }
    ]
  }
}
```

使用者需手動合併到 `~/.claude/settings.json`。

---

## 技術要點

### STA 執行緒
- `System.Windows.Forms.Clipboard` 要求 STA（Single-Threaded Apartment）
- `powershell.exe`（5.1）預設 STA → 直接可用
- `pwsh.exe`（7.x）預設 MTA → 腳本自動偵測並以 `-STA` 重啟自己
- 不再強制降級到 5.1，PS5 和 PS7 使用者都能無痛使用

### 記憶體管理（致命風險防護）
- 每 250ms 輪詢產生的 Image 物件和 GDI Handle **必須顯式 Dispose**
- 所有 IDisposable 物件（Image、MemoryStream、SHA256）都在 finally 區塊釋放
- 不 Dispose 的後果：背景程式記憶體在 1-2 天內暴增至數 GB

### 剪貼簿操作 Retry 機制
- Snipping Tool 截圖時會短暫鎖定剪貼簿
- 所有剪貼簿讀寫操作包裹在 `Invoke-ClipboardAction` 中
- 失敗時 Sleep 50ms 重試，最多 5 次
- 只捕捉 `ExternalException`，其他例外正常拋出

### PID 三層驗證（防誤殺）
1. 程序是否存在（`Get-Process`）
2. 程序名稱是否為 PowerShell（`$proc.Name -match 'powershell|pwsh'`）
3. 啟動參數是否包含 cli-screenshot（`Get-CimInstance Win32_Process` 查 CommandLine）

### 新截圖偵測（雙重防護）
1. 第一層：剪貼簿格式指紋 — 有 Image 但無 Text+FileDropList 三格式組合
2. 第二層：記憶體內快取 `$lastHash` — 即使格式判斷出錯，hash 相同也不會重複處理

### 競態條件防護
- 剪貼簿操作全部透過 Retry 機制處理
- 寫入三格式後，下一輪偵測會看到三格式都有而跳過（避免自我觸發無限迴圈）
- 即使使用者手動清除 Text 格式導致誤判，`$lastHash` 快取也能擋下

### SetDataObject 第二參數
- `$true` = 程式結束後剪貼簿內容保留
- `$false` = 程式結束後剪貼簿清空 → 不能用

### 去重但仍更新剪貼簿
- SHA256 hash 相同 → 不重寫檔案（節省磁碟）
- 但仍然執行三格式寫入（因使用者可能中間複製了其他內容，需恢復路徑格式）

### Log 輪轉策略
- 每次寫 log 時檢查檔案大小
- 超過 5MB → 只保留最後 2.5MB 內容

---

## 實作順序

1. 建立專案目錄結構 + `.gitignore`
2. `lib/Monitor.ps1` — 核心剪貼簿監控迴圈（含 Retry、Dispose、lastHash 快取）
3. `lib/Daemon.ps1` — 背景程序管理（含三層 PID 驗證）
4. `cli-screenshot.ps1` — CLI 入口點（含 STA 自動重啟）
5. 本地測試完整流程
6. `install.ps1` — 一鍵安裝腳本
7. `hooks/claude-hooks.json` — Claude Code 設定範本
8. `README.md` + `LICENSE`
9. 初始化 Git repo + 推送 GitHub

---

## 驗證方式

1. 執行 `.\cli-screenshot.ps1 start`（前景模式）
2. `Win+Shift+S` 截圖並儲存
3. 到 PowerShell/CMD 按 `Ctrl+V` → 應出現檔案路徑
4. 到 Paint 按 `Ctrl+V` → 應貼上圖片
5. 到檔案總管按 `Ctrl+V` → 應貼上 PNG 檔案
6. 再截同一張圖 → 不應產生新檔案（SHA256 去重）
7. `.\cli-screenshot.ps1 status` → 顯示運行狀態
8. `.\cli-screenshot.ps1 stop` → 停止監控
9. `.\cli-screenshot.ps1 start --daemon` → 背景模式啟動
10. 重複步驟 2-6 驗證背景模式
11. 在 `pwsh.exe`（PS7）中執行 → 應自動以 `-STA` 重啟
12. 強制 kill 背景程序後執行 `status` → 應正確顯示 STOPPED（不殘留 stale PID）
13. 長時間運行測試 → 透過 `status` 觀察記憶體用量不應持續增長
