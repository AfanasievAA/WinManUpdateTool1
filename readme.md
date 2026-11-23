# WinManUpdateTool1 — Windows Manual Offline Update Tool One
<img width="1282" height="941" alt="image" src="https://github.com/user-attachments/assets/b796778a-e338-4961-b7d9-b459fb008a96" />

**WinManUpdateTool1** is a portable PowerShell + WinForms tool for **searching, downloading, installing, and removing Windows updates manually**, without relying on a running Windows Update service and without contacting Microsoft Update / WSUS servers during scanning. Scanning is performed against a local `wsusscn2.cab` catalog via the Windows Update Agent API (`ServerSelection = ssOthers`). Update files are downloaded directly from the Microsoft CDN (or from a local WSUS store) and installed locally using `wusa.exe` / `DISM` / `msiexec`.

## ✨ Features

- **Offline scanning** — find missing updates using a local `wsusscn2.cab`. No connection to WSUS or Microsoft Update is required for scanning itself.
- **Download** — fetch update files by direct URLs from `DownloadContents` / `BundledUpdates` (Microsoft CDN). Built-in SHA‑1 verification: if a file already exists on disk and its hash matches the file name, it is not downloaded again; corrupted files are re-downloaded (up to 3 attempts). For files without a hash in the name, server-side date verification is used.
- **WSUS download mode (optional)** — you can specify a local WSUS server (HTTP or UNC), and the tool will pull files from its `WSUSContent` store. If a file is missing on WSUS, it automatically falls back to the Microsoft CDN.
- **Installation** — apply packages depending on type:
  - `.msu` → `wusa.exe /quiet /norestart`
  - `.cab` → `DISM /Add-Package /IgnoreCheck` after an _Applicable_ check
  - `.msi` → `msiexec /qn /norestart`
  - `.exe` → `/q /norestart` (for `ndp*`, `ofv*`, `2553065`), `/q` with automatic retry `/qn /norestart` (for MSRT `kb890830`), or `/q /z` for others
  - non‑CBS Office CAB files are extracted and their `.msp` packages are installed via `msiexec /p`.
  - Exit codes `3010`, `1641`, `3017` indicate a reboot is required.
  - Note: `.msu` via `wusa` requires the `wuauserv` service to be running (no WSUS connection needed); `.cab` via `DISM` works even with the update agent disabled.
- **Uninstall** — `wusa.exe /uninstall /kb:N`, plus `DISM /Remove-Package` for servicing packages `Package_for_*`, which `wusa` usually cannot remove on Windows 10/11.
- **Cleanup** — free up disk space after checking installed updates:
  - remove superseded components from the WinSxS store via `DISM /StartComponentCleanup` (the "Disk Cleanup" → "Windows Update Cleanup" engine); with `/ResetBase` updates become permanent;
  - clean Windows Update caches (`SoftwareDistribution\Download`, Delivery Optimization);
  - delete update files downloaded by this tool (a copy of the `wsusscn2.cab` directory is preserved).
- **Audit log** — every installation is recorded in `install-state.json`.
- **Portability** — runs from any folder; if the script folder is read-only, `%ProgramData%` / `%LOCALAPPDATA%` is used.
- **Automatic elevation** — the tool relaunches itself with elevated privileges (UAC) on startup if launched as a regular user. The `-AutoElevate` parameter is kept for backward compatibility but is no longer required.
- **Automatic STA relaunch** — if the host thread is not STA, the script relaunches itself in a separate STA thread for correct WinForms operation.

## 📋 Requirements

- **Windows 10 / 11**
- **Windows PowerShell 5.1** (built into the OS)
- **Internet access** on first run — to download `wsusscn2.cab` (400–600 MB) unless a local path or network share is specified.
- **Administrator rights** — required for install / uninstall / cleanup. The tool elevates privileges automatically.
- **STA thread** — the script relaunches itself with `-STA` if necessary.

## 🚀 Quick Start

1. Download all files: **Code → Download ZIP**.
2. Extract the archive to any folder.
3. Run `WinManUpdateTool1.cmd` (or execute in PowerShell):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WinManUpdateTool1.ps1
```

On first run, the tool will automatically request elevation and, if needed, download `wsusscn2.cab`.

## 🆕 What's new in version 0.6

- **Cleanup** — remove superseded WinSxS components, clean Windows Update caches and temporary update files.
- **SHA‑1 verification on download** — reuse already-downloaded intact files without network requests; automatically re-download corrupted files (up to 3 attempts).
- **Improved MSRT (`kb890830`) handling** — if the package rejects `/q` with code 1639, it automatically retries with `/qn /norestart`.
- **Automatic elevation** — the tool always relaunches with administrator rights on startup; `-AutoElevate` is no longer needed.
- **Extended WSUS support** — added various file naming schemes in the WSUS store (Native, CdnName, PublishedConcat, PublishedUnderscore), improving compatibility with different WSUS configurations.
- **Improved exit code handling** — centralized constants for reboot and installation error codes.

## 📖 Usage Examples

**Run with a local catalog and a WSUS server (single line):**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WinManUpdateTool1.ps1 -CatalogPath "\\srv\wsus\wsusscn2.cab" -WsusServer "http://wsus:8530"
```

**Run with a custom local catalog only:**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WinManUpdateTool1.ps1 -CatalogPath "D:\wsusscn2.cab"
```

**Scan-only mode (no administrator rights):**

Scanning and downloading are available to any user. The tool will not attempt to elevate privileges if it runs in scan-only / download-only mode (via the corresponding GUI menu items).

> Note: PowerShell line‑continuation backticks are intentionally avoided in the examples above — they confuse some Markdown renderers when the README is copy‑pasted as raw text. Keep each command on a single line.

## 📄 License

This project is distributed under the license specified in the [LICENSE](LICENSE) file.

## 📬 Contact

**Author:** Andrew Afanasiev  
**Email:** AfanasievAA@yandex.ru

---

# WinManUpdateTool1 — Инструмент для ручного офлайн‑обновления Windows

**WinManUpdateTool1** — это портативный инструмент на PowerShell + WinForms для **поиска, загрузки, установки и удаления обновлений Windows вручную**, без зависимости от работающей службы Windows Update и без обращения к серверам Microsoft Update / WSUS во время сканирования. Сканирование выполняется по локальному каталогу `wsusscn2.cab` через Windows Update Agent API (`ServerSelection = ssOthers`). Файлы обновлений загружаются напрямую с CDN Microsoft (или из локального хранилища WSUS) и устанавливаются локально с помощью `wusa.exe` / `DISM` / `msiexec`.

## ✨ Возможности

- **Офлайн‑сканирование** — поиск недостающих обновлений по локальному `wsusscn2.cab`. Подключение к WSUS или Microsoft Update для самого сканирования не требуется.
- **Загрузка** — получение файлов обновлений по прямым URL из `DownloadContents` / `BundledUpdates` (Microsoft CDN). Встроенная проверка SHA‑1: если файл уже есть на диске и его хеш совпадает с именем, повторная загрузка не выполняется; повреждённый файл перезагружается (до 3 попыток). Для файлов без хеша в имени используется проверка даты на сервере.
- **Режим загрузки из WSUS (опционально)** — можно указать локальный WSUS‑сервер (HTTP или UNC), и инструмент будет забирать файлы из его хранилища `WSUSContent`. Если файл на WSUS отсутствует, автоматически происходит переключение на CDN Microsoft.
- **Установка** — применение пакетов в зависимости от типа:
  - `.msu` → `wusa.exe /quiet /norestart`
  - `.cab` → `DISM /Add-Package /IgnoreCheck` после проверки _Applicable_
  - `.msi` → `msiexec /qn /norestart`
  - `.exe` → `/q /norestart` (для `ndp*`, `ofv*`, `2553065`), `/q` с автоматическим повтором `/qn /norestart` (для MSRT `kb890830`) или `/q /z` для остальных
  - не‑CBS Office CAB‑файлы распаковываются, и их `.msp`‑пакеты устанавливаются через `msiexec /p`.
  - Коды выхода `3010`, `1641`, `3017` означают необходимость перезагрузки.
  - Примечание: для `.msu` через `wusa` требуется запущенная служба `wuauserv` (подключение к WSUS не нужно); `.cab` через `DISM` работает даже при отключённом агенте обновления.
- **Удаление** — `wusa.exe /uninstall /kb:N`, а также `DISM /Remove-Package` для служебных пакетов `Package_for_*`, которые `wusa` обычно не может удалить в Windows 10/11.
- **Очистка (Cleanup)** — освобождение дискового пространства после проверки установленных обновлений:
  - удаление заменённых компонентов из хранилища WinSxS через `DISM /StartComponentCleanup` (движок «Очистки диска» → «Очистка обновлений Windows»); с `/ResetBase` обновления становятся постоянными;
  - очистка кешей Windows Update (`SoftwareDistribution\Download`, Delivery Optimization);
  - удаление файлов обновлений, загруженных этим инструментом (копия каталога `wsusscn2.cab` сохраняется).
- **Журнал аудита** — каждая установка добавляется в `install-state.json`.
- **Портативность** — работает из любой папки; если папка скрипта доступна только для чтения, используются `%ProgramData%` / `%LOCALAPPDATA%`.
- **Автоматическое повышение прав** — инструмент сам перезапускается с повышением прав (UAC) при старте, если запущен от имени пользователя. Параметр `-AutoElevate` оставлен для обратной совместимости, но больше не требуется.
- **Автоматический перезапуск в STA** — если хост‑поток не STA, скрипт перезапускается в отдельном STA‑потоке для корректной работы WinForms.

## 📋 Требования

- **Windows 10 / 11**
- **Windows PowerShell 5.1** (встроен в ОС)
- **Доступ в Интернет** при первом запуске — для загрузки `wsusscn2.cab` (400–600 МБ), если не указан локальный путь или сетевая папка.
- **Права администратора** — требуются для установки / удаления / очистки. Инструмент повышает права автоматически.
- **STA‑поток** — скрипт сам перезапускается с `-STA`, если это необходимо.

## 🚀 Быстрый старт

1. Скачайте все файлы: **Code → Download ZIP**.
2. Распакуйте архив в любую папку.
3. Запустите `WinManUpdateTool1.cmd` (или выполните в PowerShell):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WinManUpdateTool1.ps1
```

При первом запуске инструмент автоматически запросит повышение прав и при необходимости загрузит `wsusscn2.cab`.

## 🆕 Что нового в версии 0.6

- **Очистка (Cleanup)** — удаление заменённых компонентов WinSxS, очистка кешей Windows Update и временных файлов обновлений.
- **Проверка SHA‑1 при загрузке** — повторное использование уже загруженных целых файлов без сетевых запросов; автоматическая перезагрузка повреждённых файлов (до 3 попыток).
- **Улучшенная обработка MSRT (`kb890830`)** — если пакет отклоняет `/q` с кодом 1639, автоматически выполняется повтор с `/qn /norestart`.
- **Автоматическое повышение прав** — инструмент всегда перезапускается с правами администратора при старте; `-AutoElevate` больше не нужен.
- **Расширенная поддержка WSUS** — добавлены различные схемы имён файлов в хранилище WSUS (Native, CdnName, PublishedConcat, PublishedUnderscore), что повышает совместимость с разными конфигурациями WSUS.
- **Улучшенная обработка кодов выхода** — централизованные константы для кодов перезагрузки и ошибок установки.

## 📖 Примеры использования

**Запуск с локальным каталогом и WSUS‑сервером (одной строкой):**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WinManUpdateTool1.ps1 -CatalogPath "\\srv\wsus\wsusscn2.cab" -WsusServer "http://wsus:8530"
```

**Запуск только с локальным каталогом:**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WinManUpdateTool1.ps1 -CatalogPath "D:\wsusscn2.cab"
```

**Запуск только для сканирования (без прав администратора):**

Сканирование и загрузка доступны любому пользователю. Инструмент не будет пытаться повысить права, если запущен в режиме только сканирования / загрузки (через соответствующие пункты меню GUI).

> Примечание: в примерах выше намеренно не используются переносы строк через обратный апостроф PowerShell — они ломают отображение блока при копировании README как обычного текста. Держите каждую команду в одну строку.

## 📄 Лицензия

Проект распространяется под лицензией, указанной в файле [LICENSE](LICENSE).

## 📬 Контакты

**Автор:** Andrew Afanasiev  
**Email:** AfanasievAA@yandex.ru
