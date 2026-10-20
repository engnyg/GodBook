# GodBook

整合 **nhentai**（參考 [NClientV3](https://github.com/maxwai/NClientV3)）與 **禁漫天堂**（參考 [jmcomic](https://github.com/hect0x7/JMComic-Crawler-Python) / [JMComic-APK](https://github.com/hect0x7/JMComic-APK)）的 iOS 原生閱讀器，使用 SwiftUI 製作。

## 功能

- **完全無廣告**：App 只呼叫內容 API（搜尋、分類、作品、章節、收藏、登入），沒有任何廣告 SDK、等待頁、浮動廣告或廣告圖片請求
- 兩個來源合一：瀏覽、排序、搜尋、標籤點擊搜尋、相關作品
- **液態玻璃 (Liquid Glass)**：iOS 26 使用原生 `glassEffect`，iOS 17–25 自動退化為模糊材質
- **自訂主題**：強調色、6 組預設配色、淺/深色；背景可選 系統 / 純色 / 漸層 / **自選相簿圖片**（可調模糊與壓暗）；玻璃染色強度、玻璃開關
- 閱讀器：垂直捲動、左右翻頁、右到左翻頁；自動記錄進度、可從上次位置繼續
- 本機收藏、閱讀歷史；禁漫帳號登入與雲端收藏
- nhentai：可設定鏡像網域與 API Key；輸入純數字直接開啟 ID
- 禁漫：自動從官方網域伺服器取得最新 API 網域、AES 解密、圖片切割還原（scramble）

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
GodBook/Theme/              ThemeStore（主題設定）、GlassStyle（液態玻璃與背景）
GodBook/Core/               資料來源（NHentaiSource、JMComicSource、JMCrypto）、圖片載入、收藏/歷史
GodBook/Views/              首頁、詳情、閱讀器、書庫、設定
```

## 授權與聲明

- nhentai 的 API 呼叫流程移植自 NClientV3（Apache License 2.0）。
- 禁漫 API 的簽章/解密/圖片還原邏輯移植自 jmcomic（MIT）。
- 本專案為第三方客戶端，內容版權屬原網站與作者所有；請遵守所在地法規並確認自己已成年。

## 內建漫畫源

`GodBook/BundledSources/` 收錄 [venera-configs](https://github.com/venera-app/venera-configs) 的漫畫源腳本（index.json 與各 `.js`，不含 `_template_.js`、`_venera_.js`），App 第一次開啟時會自動安裝；之後可在「設定 → 漫畫源」新增、更新或移除。

> 注意：venera-configs 上游 repo 沒有附授權條款，腳本版權屬各原作者。公開散布前請自行評估，或改為在編譯時下載。
