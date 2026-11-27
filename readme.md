# WinManUpdateTool1 - Windows Manual Offline Update Tool

**WinManUpdateTool1** is a portable PowerShell + WinForms tool for **searching, downloading, installing, and removing Windows updates manually**, without relying on a running Windows Update service and without contacting Microsoft Update / WSUS servers during scanning. Scanning is performed against a local `wsusscn2.cab` catalog via the Windows Update Agent API (`ServerSelection = ssOthers`). Update files are downloaded directly from the Microsoft CDN (or from a local WSUS store) and installed locally using `wusa.exe` / `DISM` / `msiexec`.
<img width="1282" height="944" alt="ToolPic" src="https://github.com/user-attachments/assets/d17d8552-5f44-4d39-8968-2b89cb61184a" />

## ✨ Features

- **Offline scanning** - find missing updates using a local `wsusscn2.cab`. No connection to WSUS or Microsoft Update is required for scanning itself. **Requires administrator rights**: the scan registers its offline scan package in the Windows Update service store (HKLM), so the scan button is disabled without elevation.
- **Download** - fetch update files by direct URLs from `DownloadContents` / `BundledUpdates` (Microsoft CDN). Built-in SHA-1 verification: if a file already exists on disk and its hash matches the file name, it is reused without network round-trips; corrupted files are re-downloaded (up to 3 attempts) and never left on disk. For files without a hash in the name, server-side date verification is used.
- **Download queue (since 0.7)** - updates found by the offline scan can be added to a persistent queue (the **"Download queue"** tab). The queue is saved to `download-queue.json` in the working folder on every change and on exit, so it travels with the portable project folder. On a computer **with Internet access** the tool can be opened **without administrator rights** and the whole queue downloaded with one button: the queued items carry their direct file URLs (Microsoft CDN or the configured WSUS source), so **no catalog and no scan are needed there**. The files land in the same `Updates\KB_XXXXXXXX` subfolders as a local download would. Copy the folder back to the target computer, run **[Scan (offline)]** again - the downloaded updates are recognized ("files already downloaded") - and **[Install selected]**. Downloading the queue never re-fetches files that are already in the `Updates` folder with a matching SHA-1 checksum; the **[Force re-download]** button re-fetches the whole queue from scratch and overwrites the existing copies.
- **Scan & Install (new in 0.8)** - a single button that runs the full cycle **scan → download → install** in one go. Use it when the required updates are not yet in the `Updates` folder and you want the tool to fetch them from the configured source (Microsoft CDN or WSUS) and install them immediately. The button respects the same rules as the separate steps: SHA-1 verification, WSUS fallback, per-type installer switches, and exit-code handling. If some updates are already downloaded, only the missing files are fetched.
- **WSUS download mode (optional)** - you can specify a local WSUS server (HTTP or UNC), and the tool will pull files from its `WSUSContent` store. If a file is missing on WSUS, it automatically falls back to the Microsoft CDN.
- **Installation** - apply packages depending on type:
  - `.msu` → `wusa.exe /quiet /norestart`
  - `.cab` → `DISM /Add-Package /IgnoreCheck` after an _Applicable_ check
  - `.msi` → `msiexec /qn /norestart`
  - `.exe` → `/q /norestart` (for `ndp*`, `ofv*`, `2553065`), `/q` with automatic retry `/qn /norestart` (for MSRT `kb890830`), or `/q /z` for others
  - non-CBS Office CAB files are extracted and their `.msp` packages are installed via `msiexec /p`.
  - Exit codes `3010`, `1641`, `3017` indicate a reboot is required.
  - Note: `.msu` via `wusa` requires the `wuauserv` service to be running (no WSUS connection needed); `.cab` via `DISM` works even with the update agent disabled.
- **Uninstall** - `wusa.exe /uninstall /kb:N`, plus `DISM /Remove-Package` for servicing packages `Package_for_*`, which `wusa` usually cannot remove on Windows 10/11.
- **Cleanup** - free up disk space after checking installed updates:
  - remove superseded components from the WinSxS store via `DISM /StartComponentCleanup` (the "Disk Cleanup" → "Windows Update Cleanup" engine); with `/ResetBase` updates become permanent;
  - clean Windows Update caches (`SoftwareDistribution\Download`, Delivery Optimization);
  - delete update files downloaded by this tool (a copy of the `wsusscn2.cab` directory is preserved).
- **Audit log** - every installation is recorded in `install-state.json`.
- **Portability** - runs from any folder; if the script folder is read-only, `%ProgramData%` / `%LOCALAPPDATA%` is used.
- **Elevation control (since 0.7)** - when started with user rights, the tool shows a **startup dialog**: **Yes** - relaunch elevated via UAC (full functionality); **No** - continue without elevation (the download queue and file downloads work; scan, install, uninstall and cleanup are disabled). The **`-NoElevate`** switch skips the dialog and always continues unelevated. The legacy `-AutoElevate` switch is kept for backward compatibility but has no effect.
- **Automatic STA relaunch** - if the host thread is not STA, the script relaunches itself in a separate STA thread for correct WinForms operation.

## 📋 Requirements

- **Windows 10 / 11**
- **Windows PowerShell 5.1** (built into the OS)
- **Internet access** on first run - to download `wsusscn2.cab` (400-600 MB) unless a local path or network share is specified.
- **Administrator rights** - required for the offline scan, install, uninstall, cleanup, and the **Scan & Install** button. Downloading files and managing the download queue work without elevation.
- **STA thread** - the script relaunches itself with `-STA` if necessary.

## 🚀 Quick Start

1. Download all files: **Code → Download ZIP**.
2. Extract the archive to any folder.
3. Run `WinManUpdateTool1.cmd` (or execute in PowerShell):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WinManUpdateTool1.ps1
```

On first run, the tool will ask for elevation (unless `-NoElevate` is used) and, if needed, download `wsusscn2.cab`.

## 🆕 What's new in version 0.8

- **Scan & Install button** - a one-click action that performs **scan → download → install** in a single pass. Ideal when the required updates are not yet cached locally and you want the tool to fetch them from the configured source (Microsoft CDN or WSUS) and install them immediately.
- **Bug fixes** - various stability and correctness fixes across scanning, downloading and installation.

## 🆕 What was new in version 0.7 (for reference)

- **Download queue** - fill the queue on an offline computer, move the project folder to an online computer, download the whole queue **without administrator rights**, move the folder back and install. The queue is stored in `download-queue.json` and travels with the portable folder.
- **Unelevated download mode** - the new **`-NoElevate`** switch (and the startup elevation dialog) allows the download queue and file downloads to run under a regular user account.
- **Scan requires elevation** - the offline scan now registers its scan package in the Windows Update service store (HKLM), so it is available only in the elevated mode.
- **Force re-download** - the **[Force re-download]** button re-fetches the entire queue from scratch and overwrites the existing files, even if they already passed the checksum verification.
- **Startup elevation dialog** - when started with user rights, the tool asks whether to relaunch elevated or continue without elevation, instead of silently auto-elevating.

## 📖 Usage Examples

**Standard interactive run (asks for elevation if needed):**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WinManUpdateTool1.ps1
```

**Run with a local catalog and a WSUS server (single line):**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WinManUpdateTool1.ps1 -CatalogPath "\\srv\wsus\wsusscn2.cab" -WsusServer "http://wsus:8530"
```

**Run with a custom local catalog only:**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WinManUpdateTool1.ps1 -CatalogPath "D:\wsusscn2.cab"
```

**Online computer: download the queue without administrator rights:**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WinManUpdateTool1.ps1 -NoElevate
```

**Using the Scan & Install button (GUI):**

Open the tool with administrator rights, make sure the catalog is available (or let it download `wsusscn2.cab`), then click **Scan & Install**. The tool will scan for missing updates, download any missing files from the configured source, and install them in one pass.

**Offline → online workflow (two computers):**

1. On the **offline** computer: run **[Scan (offline)]**, mark the needed updates, press **[Add checked to queue]**, and close the tool (the queue is saved to `download-queue.json`).
2. Move the whole project folder to a computer **with Internet access**.
3. Start the tool there **without elevation** (answer **No** in the startup dialog or use `-NoElevate`).
4. On the **"Download queue"** tab press **[Download queue]** - the files land in the `Updates` subfolder.
5. Move the `Updates` folder (or the whole project folder) back to the target computer.
6. Run **[Scan (offline)]** again - the downloaded updates are recognized as "files already downloaded" - and **[Install selected]**.

> Note: PowerShell line-continuation backticks are intentionally avoided in the examples above - they confuse some Markdown renderers when the README is copy-pasted as raw text. Keep each command on a single line.

## 📄 License

This project is distributed under the license specified in the [LICENSE](https://github.com/AfanasievAA/WinManUpdateTool1/blob/main/LICENSE) file.

## 📬 Contact

**Author:** Andrew Afanasiev  
**Email:** [AfanasievAA@yandex.ru](mailto:AfanasievAA@yandex.ru)

---

# WinManUpdateTool1 - Инструмент для ручного офлайн-обновления Windows

**WinManUpdateTool1** - это портативный инструмент на PowerShell + WinForms для **поиска, загрузки, установки и удаления обновлений Windows вручную**, без зависимости от работающей службы Windows Update и без обращения к серверам Microsoft Update / WSUS во время сканирования. Сканирование выполняется по локальному каталогу `wsusscn2.cab` через Windows Update Agent API (`ServerSelection = ssOthers`). Файлы обновлений загружаются напрямую с CDN Microsoft (или из локального хранилища WSUS) и устанавливаются локально с помощью `wusa.exe` / `DISM` / `msiexec`.

## ✨ Возможности

- **Офлайн-сканирование** - поиск недостающих обновлений по локальному `wsusscn2.cab`. Подключение к WSUS или Microsoft Update для самого сканирования не требуется. **Требуются права администратора**: сканирование регистрирует пакет офлайн-сканирования в хранилище службы Windows Update (HKLM), поэтому без повышения прав кнопка сканирования недоступна.
- **Загрузка** - получение файлов обновлений по прямым URL из `DownloadContents` / `BundledUpdates` (Microsoft CDN). Встроенная проверка SHA-1: если файл уже есть на диске и его хеш совпадает с именем, он используется без сетевых запросов; повреждённый файл перезагружается (до 3 попыток) и никогда не остаётся на диске. Для файлов без хеша в имени используется проверка даты на сервере.
- **Очередь загрузки (начиная с 0.7)** - обновления, найденные при офлайн-сканировании, можно добавить в постоянную очередь (вкладка **«Download queue»**). Очередь сохраняется в `download-queue.json` в рабочей папке при каждом изменении и при выходе, поэтому переносится вместе с портативной папкой проекта. На компьютере **с доступом в Интернет** инструмент можно открыть **без прав администратора** и скачать всю очередь одной кнопкой: элементы очереди содержат прямые URL файлов (Microsoft CDN или настроенный источник WSUS), поэтому **ни каталог, ни сканирование там не нужны**. Файлы попадают в те же подпапки `Updates\KB_XXXXXXXX`, что и при локальной загрузке. Скопируйте папку обратно на целевой компьютер, снова запустите **[Scan (offline)]** - загруженные обновления распознаются как «files already downloaded» - и нажмите **[Install selected]**. При загрузке очереди файлы, уже находящиеся в папке `Updates` с совпадающей контрольной суммой SHA-1, повторно не скачиваются; кнопка **[Force re-download]** заново скачивает всю очередь с нуля и перезаписывает существующие копии.
- **Scan & Install (новое в 0.8)** - одна кнопка, запускающая полный цикл **сканирование → загрузка → установка** за один проход. Используйте её, когда нужных обновлений ещё нет в папке `Updates` и вы хотите, чтобы инструмент сам скачал их из настроенного источника (Microsoft CDN или WSUS) и сразу установил. Кнопка соблюдает те же правила, что и отдельные шаги: проверка SHA-1, переключение на CDN при отсутствии файла на WSUS, параметры установщиков по типам файлов и обработка кодов выхода. Если часть обновлений уже загружена, скачиваются только недостающие файлы.
- **Режим загрузки из WSUS (опционально)** - можно указать локальный WSUS-сервер (HTTP или UNC), и инструмент будет забирать файлы из его хранилища `WSUSContent`. Если файл на WSUS отсутствует, автоматически происходит переключение на CDN Microsoft.
- **Установка** - применение пакетов в зависимости от типа:
  - `.msu` → `wusa.exe /quiet /norestart`
  - `.cab` → `DISM /Add-Package /IgnoreCheck` после проверки _Applicable_
  - `.msi` → `msiexec /qn /norestart`
  - `.exe` → `/q /norestart` (для `ndp*`, `ofv*`, `2553065`), `/q` с автоматическим повтором `/qn /norestart` (для MSRT `kb890830`) или `/q /z` для остальных
  - не-CBS Office CAB-файлы распаковываются, и их `.msp`-пакеты устанавливаются через `msiexec /p`.
  - Коды выхода `3010`, `1641`, `3017` означают необходимость перезагрузки.
  - Примечание: для `.msu` через `wusa` требуется запущенная служба `wuauserv` (подключение к WSUS не нужно); `.cab` через `DISM` работает даже при отключённом агенте обновления.
- **Удаление** - `wusa.exe /uninstall /kb:N`, а также `DISM /Remove-Package` для служебных пакетов `Package_for_*`, которые `wusa` обычно не может удалить в Windows 10/11.
- **Очистка (Cleanup)** - освобождение дискового пространства после проверки установленных обновлений:
  - удаление заменённых компонентов из хранилища WinSxS через `DISM /StartComponentCleanup` (движок «Очистки диска» → «Очистка обновлений Windows»); с `/ResetBase` обновления становятся постоянными;
  - очистка кешей Windows Update (`SoftwareDistribution\Download`, Delivery Optimization);
  - удаление файлов обновлений, загруженных этим инструментом (копия каталога `wsusscn2.cab` сохраняется).
- **Журнал аудита** - каждая установка добавляется в `install-state.json`.
- **Портативность** - работает из любой папки; если папка скрипта доступна только для чтения, используются `%ProgramData%` / `%LOCALAPPDATA%`.
- **Управление повышением прав (начиная с 0.7)** - при запуске от имени пользователя инструмент показывает **диалог**: **Yes** - перезапуститься с повышением прав через UAC (полный функционал); **No** - продолжить без повышения прав (очередь загрузки и скачивание файлов работают; сканирование, установка, удаление и очистка отключены). Параметр **`-NoElevate`** пропускает диалог и всегда продолжает без повышения прав. Устаревший параметр `-AutoElevate` оставлен для обратной совместимости, но не действует.
- **Автоматический перезапуск в STA** - если хост-поток не STA, скрипт перезапускается в отдельном STA-потоке для корректной работы WinForms.

## 📋 Требования

- **Windows 10 / 11**
- **Windows PowerShell 5.1** (встроен в ОС)
- **Доступ в Интернет** при первом запуске - для загрузки `wsusscn2.cab` (400-600 МБ), если не указан локальный путь или сетевая папка.
- **Права администратора** - требуются для офлайн-сканирования, установки, удаления, очистки и для кнопки **Scan & Install**. Загрузка файлов и работа с очередью загрузки доступны без повышения прав.
- **STA-поток** - скрипт сам перезапускается с `-STA`, если это необходимо.

## 🚀 Быстрый старт

1. Скачайте все файлы: **Code → Download ZIP**.
2. Распакуйте архив в любую папку.
3. Запустите `WinManUpdateTool1.cmd` (или выполните в PowerShell):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WinManUpdateTool1.ps1
```

При первом запуске инструмент запросит повышение прав (если не указан `-NoElevate`) и при необходимости загрузит `wsusscn2.cab`.

## 🆕 Что нового в версии 0.8

- **Кнопка Scan & Install** - одно действие, выполняющее **сканирование → загрузку → установку** за один проход. Идеально подходит, когда нужных обновлений ещё нет в локальном кеше и вы хотите, чтобы инструмент сам скачал их из настроенного источника (Microsoft CDN или WSUS) и сразу установил.
- **Исправления ошибок** - различные исправления стабильности и корректности в сканировании, загрузке и установке.

## 🆕 Что было нового в версии 0.7 (для справки)

- **Очередь загрузки** - заполните очередь на офлайн-компьютере, перенесите папку проекта на онлайн-компьютер, скачайте всю очередь **без прав администратора**, верните папку обратно и установите обновления. Очередь хранится в `download-queue.json` и переносится вместе с портативной папкой.
- **Режим загрузки без повышения прав** - новый параметр **`-NoElevate`** (и диалог выбора при старте) позволяет работать с очередью загрузки и скачивать файлы от имени обычного пользователя.
- **Сканирование требует повышения прав** - офлайн-сканирование теперь регистрирует пакет сканирования в хранилище службы Windows Update (HKLM), поэтому доступно только в режиме с повышением прав.
- **Force re-download** - кнопка **[Force re-download]** заново скачивает всю очередь с нуля и перезаписывает существующие файлы, даже если они уже прошли проверку контрольных сумм.
- **Диалог повышения прав при старте** - при запуске от имени пользователя инструмент спрашивает, перезапуститься ли с повышением прав или продолжить без него, вместо автоматического повышения без выбора.

## 📖 Примеры использования

**Обычный интерактивный запуск (при необходимости запросит повышение прав):**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WinManUpdateTool1.ps1
```

**Запуск с локальным каталогом и WSUS-сервером (одной строкой):**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WinManUpdateTool1.ps1 -CatalogPath "\\srv\wsus\wsusscn2.cab" -WsusServer "http://wsus:8530"
```

**Запуск только с локальным каталогом:**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WinManUpdateTool1.ps1 -CatalogPath "D:\wsusscn2.cab"
```

**Онлайн-компьютер: скачать очередь без прав администратора:**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WinManUpdateTool1.ps1 -NoElevate
```

**Использование кнопки Scan & Install (GUI):**

Откройте инструмент с правами администратора, убедитесь, что каталог доступен (или дайте инструменту скачать `wsusscn2.cab`), и нажмите **Scan & Install**. Инструмент выполнит сканирование, скачает недостающие файлы из настроенного источника и установит их за один проход.

**Сценарий «офлайн → онлайн» (два компьютера):**

1. На **офлайн**-компьютере: запустите **[Scan (offline)]**, отметьте нужные обновления, нажмите **[Add checked to queue]** и закройте инструмент (очередь сохранится в `download-queue.json`).
2. Перенесите всю папку проекта на компьютер **с доступом в Интернет**.
3. Запустите там инструмент **без повышения прав** (ответьте **No** в диалоге или используйте `-NoElevate`).
4. На вкладке **«Download queue»** нажмите **[Download queue]** - файлы попадут в подпапку `Updates`.
5. Верните папку `Updates` (или всю папку проекта) на целевой компьютер.
6. Снова запустите **[Scan (offline)]** - загруженные обновления распознаются как «files already downloaded» - и нажмите **[Install selected]**.

> Примечание: в примерах выше намеренно не используются переносы строк через обратный апостроф PowerShell - они ломают отображение блока при копировании README как обычного текста. Держите каждую команду в одну строку.

## 📄 Лицензия

Проект распространяется под лицензией, указанной в файле [LICENSE](https://github.com/AfanasievAA/WinManUpdateTool1/blob/main/LICENSE).

## 📬 Контакты

**Автор:** Andrew Afanasiev  
**Email:** [AfanasievAA@yandex.ru](mailto:AfanasievAA@yandex.ru)
