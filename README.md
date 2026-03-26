# cli-screenshot

Windows 原生 PowerShell 截圖剪貼簿工具。截圖後自動將檔案路徑放到剪貼簿，讓 `Ctrl+V` 在 CLI 中直接貼出路徑。

專為 Claude Code CLI 設計 — 解決 Windows PowerShell 無法直接貼圖的問題。

## 功能

- **剪貼簿監控**：自動偵測新截圖（Win+Shift+S）
- **三格式寫入**：同時支援文字路徑、圖片、檔案拖放
- **SHA256 去重**：相同截圖不重複儲存
- **背景模式**：可作為 daemon 靜默運行
- **零依賴**：純 PowerShell，不需額外安裝任何軟體
- **PS5 / PS7 通用**：自動處理 STA 執行緒問題

## 貼上結果

| 貼上位置 | 結果 |
|---------|------|
| PowerShell / CMD / Claude Code | 檔案完整路徑 |
| Paint / 圖片應用 | 截圖圖片 |
| 檔案總管 | PNG 檔案 |

## 安裝

```powershell
irm https://raw.githubusercontent.com/kerwin77106/Cli-Screenshot/main/install.ps1 | iex
```

## 使用方式

```powershell
# 前景模式（按 Ctrl+C 停止）
cli-screenshot start

# 背景模式
cli-screenshot start --daemon

# 查看狀態
cli-screenshot status

# 停止
cli-screenshot stop

# 版本
cli-screenshot version
```

### 參數

| 參數 | 縮寫 | 預設值 | 說明 |
|------|------|--------|------|
| `--daemon` | `-d` | 否 | 背景模式運行 |
| `--interval` | `-i` | 250 | 輪詢間隔（毫秒） |
| `--output` | `-o` | `~/Pictures/Screenshots` | 截圖儲存目錄 |
| `--quiet` | `-q` | 否 | 靜默模式 |

### 本機直接執行

```powershell
# 前景模式
.\cli-screenshot.ps1 start

# 背景模式
.\cli-screenshot.ps1 start -Daemon

# 自訂輸出目錄
.\cli-screenshot.ps1 start -Output "D:\Screenshots"
```

## Claude Code Hooks 整合

搭配 [Claude Code Hooks](https://docs.anthropic.com/en/docs/claude-code/hooks)，可以在啟動 Claude Code 時自動開始監控截圖，結束時自動停止。

### 設定步驟

1. 開啟 Claude Code 的設定檔：

```
~/.claude/settings.json
```

> 路徑通常是 `C:\Users\<你的使用者名稱>\.claude\settings.json`

2. 在 `"hooks"` 區塊中加入 `SessionStart` 和 `SessionEnd`：

```jsonc
{
  "hooks": {
    // 啟動 Claude Code 時自動開始監控截圖
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
    // 關閉 Claude Code 時自動停止監控
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

> 如果你的 `settings.json` 已有其他 hooks（例如 `PreToolUse`），將 `SessionStart` 和 `SessionEnd` 加在同一層即可，不需要覆蓋原有設定。

3. 儲存後重新啟動 Claude Code，截圖監控就會自動運行。

### 驗證

啟動 Claude Code 後，按 `Win+Shift+S` 截圖，然後在對話框中按 `Ctrl+V`，應該會貼出截圖的檔案路徑（例如 `C:\Users\User\Pictures\Screenshots\abc123.png`）。

## 技術細節

- **STA 自動重啟**：PS7 (pwsh) 預設 MTA，腳本自動偵測並以 `-STA` 重啟
- **PID 三層驗證**：防止誤殺不相關的程序（程序存在 → PowerShell → 含 cli-screenshot）
- **剪貼簿 Retry**：Snipping Tool 會短暫鎖定剪貼簿，自動重試最多 5 次
- **記憶體管理**：所有 .NET IDisposable 物件在 finally 區塊顯式 Dispose
- **Log 輪轉**：超過 5MB 自動截斷

## License

MIT
