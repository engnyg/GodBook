# GodBook

整合 **nhentai**（參考 [NClientV3](https://github.com/maxwai/NClientV3)）、**禁漫天堂**（參考 [jmcomic](https://github.com/hect0x7/JMComic-Crawler-Python) / [JMComic-APK](https://github.com/hect0x7/JMComic-APK)）與 **venera 漫畫源**的 iOS 原生閱讀器，使用 SwiftUI 製作。

## 功能

- **完全無廣告**：App 只呼叫內容 API（搜尋、分類、作品、章節、收藏、登入），沒有任何廣告 SDK、等待頁、浮動廣告或廣告圖片請求
- **多來源合一**：nhentai、禁漫，以及相容 venera 的 JavaScript 漫畫源（內建一批，可自行新增、更新、停用、排序）
- 瀏覽與搜尋：排序、篩選、分類 / 排行、標籤點擊搜尋、搜尋紀錄與建議、跨來源聚合搜尋、關鍵字屏蔽
- **閱讀器**：6 種閱讀模式、縮放、點擊 / 音量鍵 / 自動翻頁、預載、自動接續上下章、每部作品獨立設定；自動記錄進度
- 收藏與追蹤：本機收藏資料夾、閱讀歷史、追更（自動檢查新章節）、單張圖片收藏；禁漫與部分漫畫源的雲端收藏、評論、按讚 / 評分
- **離線下載**：章節下載、暫停 / 續傳；匯出 CBZ / PDF / EPUB；匯入本機漫畫
- **雲端儲存**：已下載的章節可上傳到 **OneDrive 個人版、OneDrive 商業版（Microsoft 365）、Google Drive、WebDAV**，並依保存策略釋放手機空間，詳見下方「雲端儲存」
- **多國語言**：繁體中文、English、简体中文，可在 App 內隨時切換（設定頁最上方，或右上角的地球按鈕）
- **液態玻璃 (Liquid Glass)**：iOS 26 使用原生 `glassEffect`，iOS 17–25 自動退化為模糊材質
- **自訂主題**：強調色、6 組預設配色、淺/深色；背景可選 系統 / 純色 / 漸層 / **自選相簿圖片**（可調模糊與壓暗）；玻璃染色強度、玻璃開關
- 隱私與安全：App 鎖（Face ID / 密碼）、安全模式（隱藏 18+ 來源與內容）
- 備份：匯出 / 匯入全部資料，或同步到 WebDAV
- 網路：系統 / 直連 / 手動代理（HTTP、SOCKS5）、可選擇忽略憑證錯誤、圖片磁碟快取
- nhentai：可設定鏡像網域與 API Key；輸入純數字直接開啟 ID
- 禁漫：自動從官方網域伺服器取得最新 API 網域、AES 解密、圖片切割還原（scramble）

## 雲端儲存

在「設定 → 下載 → 雲端儲存」設定：

- **支援服務**：OneDrive 個人版、OneDrive 商業版（Microsoft 365，例如 E3）、Google Drive、WebDAV
- **上傳方式**：每話打包成一個 CBZ，確認雲端檔案大小與本機一致才算上傳成功；可設定下載完成後自動上傳、只在 Wi-Fi 上傳
- **雲端資料夾**：預設 `GodBook`，可自訂，也可用 `/` 建多層資料夾
- **本機保存策略**（可設預設值，每部作品也能另外指定）：
  - 永遠保留本機（預設）
  - 上傳後刪除本機
  - 只保留最近幾話
  - 空間不足時才釋放
- **閱讀只在雲端的章節**：自動下載到容量有上限的暫存區；也可以逐話或整部「從雲端下載回本機」，或手動釋放本機空間
- **換裝置**：連結同一個雲端帳號後按「從雲端還原下載清單」

OneDrive 與 Google Drive 需要先自行建立 OAuth 用戶端 ID，再貼到 App 裡。逐步教學（Azure 應用程式註冊、Microsoft 365 管理員同意、Google Cloud 設定）見 [docs/cloud-setup.md](docs/cloud-setup.md)。

## 編譯 IPA（GitHub Actions）

推送到 `main` / `master` / `claude/**`、開 PR、手動執行 workflow、或推 `v*` tag，都會觸發 `.github/workflows/build-ipa.yml`：

1. `macos-26` runner + Xcode 26（iOS 26 SDK）
2. `xcodegen` 依 `project.yml` 產生 Xcode 專案
3. `xcodebuild` 無簽章編譯，`ldid` 偽簽章，打包成 `GodBook.ipa`
4. 上傳為 Actions artifact（名稱 `GodBook-ipa`）；推 `v*` tag 時同時發佈到 Release

產出的是 **未簽章 IPA**，請用 [AltStore](https://altstore.io) / [Sideloadly](https://sideloadly.io) / [TrollStore](https://github.com/opa334/TrollStore) 等工具自行簽章安裝。

本機開發：

```bash
brew install xcodegen
xcodegen generate
open GodBook.xcodeproj
```

## 專案結構

```
project.yml                 XcodeGen 專案定義
GodBook/App/                App 進入點
GodBook/Theme/              ThemeStore（主題設定）、GlassStyle（液態玻璃與背景）
GodBook/Core/               資料來源（NHentaiSource、JMComicSource、JMCrypto）、網路、圖片載入、下載、收藏/歷史、備份
GodBook/Venera/             venera 漫畫源執行環境（JavaScriptCore）
GodBook/Cloud/              雲端儲存（OAuth 登入、OneDrive / Google Drive / WebDAV、同步與保存策略）
GodBook/Views/              首頁、詳情、閱讀器、書庫、設定
GodBook/Resources/          多國語言字串（zh-Hant / en / zh-Hans）、圖示
GodBook/BundledSources/     內建的 venera 漫畫源腳本
docs/cloud-setup.md         雲端儲存設定教學
```

## 授權與聲明

- nhentai 的 API 呼叫流程移植自 NClientV3（Apache License 2.0）。
- 禁漫 API 的簽章/解密/圖片還原邏輯移植自 jmcomic（MIT）。
- 本專案為第三方客戶端，內容版權屬原網站與作者所有；請遵守所在地法規並確認自己已成年。

## 內建漫畫源

`GodBook/BundledSources/` 收錄 [venera-configs](https://github.com/venera-app/venera-configs) 的漫畫源腳本（index.json 與各 `.js`，不含 `_template_.js`、`_venera_.js`），App 第一次開啟時會自動安裝；之後可在「設定 → 來源管理」新增、更新或移除。

> 注意：venera-configs 上游 repo 沒有附授權條款，腳本版權屬各原作者。公開散布前請自行評估，或改為在編譯時下載。
