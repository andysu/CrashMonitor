# CrashMonitor v2 — Система глибокого моніторингу та діагностики збоїв Windows Server

CrashMonitor v2 — це автономний комплекс моніторингу типу «чорна скринька літака» (Flight Recorder) для Windows Server 2022. Він розроблений для розслідування раптових самовільних перезавантажень, апаратних скидань (Reset), знеструмлень, зависань накопичувачів та синіх екранів смерті (BSOD / BugCheck).

Система працює 24/7 у фоновому режимі як служба через планувальник завдань Windows від імені `NT AUTHORITY\SYSTEM`, фіксує передісторію роботи сервера з високою роздільною здатністю (кожні 3 секунди) і гарантує збереження доказів у разі раптового краху.

---

## Зміст
1. [Архітектура та принцип роботи](#архітектура-та-принцип-роботи)
2. [Детальний опис кожного файлу](#детальний-опис-кожного-файлу)
3. [Метрики та апаратні сенсори (Ring-0)](#метрики-та-апаратні-сенсори-ring-0)
4. [Ковзне вікно логів та збереження інцидентів](#ковзне-вікно-логів-та-збереження-інцидентів)
5. [Класифікація перезавантажень](#класифікація-перезавантажень)
6. [Швидкий старт та щоденні команди](#швидкий-старт-та-щоденні-команди)
7. [Як покращувати та розширювати проект](#як-покращувати-та-розширювати-проект)

---

## Архітектура та принцип роботи

Система побудована за 3-рівневою моделлю процесів для ізоляції збоїв:

```
                          [ Scheduled Task: CrashMonitor_AutoStart ]
                                             │
                                             ▼
                               [ CrashMonitor.ps1 ] (Supervisor)
                         ┌───────────────────┴───────────────────┐
                         │                                       │
     [ Worker.ps1 -Role telemetry ]             [ Worker.ps1 -Role events ]
     • CPU, RAM, Disk Queue, Latency            • System & Application logs
     • 40+ Hardware Sensors (Ring-0)            • WHEA hardware error XML
     • processes-latest.json snapshot           • New-CMIncident (crash packs)
     • Запис telemetry-v2.csv (3s)              • Ротація & обрізання кожні 60s
```

1. **Супервізор (`CrashMonitor.ps1`)**:
   - Запускається при старті ОС (Boot Trigger) ще до входу користувача.
   - Генерує унікальний ідентифікатор сесії завантаження (`BootKey`) та ідентифікатор запуску (`MonitorSessionId`).
   - Веде незалежний високопріоритетний пульс системи ([`heartbeat-v2.csv`](file:///C:/CrashMonitor/Evidence/Logs/heartbeat-v2.csv)). Якщо вся система чи диски зависнуть — за перерваним пульсом визначається точна секунда смерті ОС.
   - Контролює воркерів: якщо будь-який збирач завис або завершився через помилку WMI/CIM, супервізор автоматично перезапускає його без зупинки моніторингу.
2. **Збирач телеметрії (`Worker.ps1 -Role telemetry`)**:
   - Опитує лічильники ОС кожні 3 секунди з жорсткими таймаутами (4 секунди), щоб збій підсистеми не заблокував збір.
   - Зчитує апаратні напруги, температури, струми й вентилятори через бібліотеку ядра.
   - Робить запис проби дискової затримки (`io-probe.tmp`), фіксуючи мікрозависання контролера SSD/HDD перед падінням.
   - Зберігає повний зріз усіх процесів ОС (PID, RAM, CPU, дескриптори) у [`processes-latest.json`](file:///C:/CrashMonitor/Evidence/Logs/processes-latest.json).
3. **Збирач подій та інцидентів (`Worker.ps1 -Role events`)**:
   - Читає події Windows (`System`, `Application`, `WHEA-Logger`, `BugCheck`, `Kernel-Power`).
   - Зберігає повні необрізані XML подій та бінарні `WHEA RawData`.
   - При старті після збою класифікує причину рестарту і формує повний ізольований пакет інциденту в [`Evidence/Incidents/<BootKey>`](file:///C:/CrashMonitor/Evidence/Incidents).
   - Щойно відбулася хвилина роботи — викликає ротацію й обрізання старих логів.
4. **Міжпроцесна синхронізація (`Invoke-CMFileLock`)**:
   - Усі операції запису та ротації використовують глобальні іменовані м'ютекси Windows (`Global\CMFile_<hash>`). Конфлікти блокування файлів між супервізором і збирачами виключені.

---

## Детальний опис кожного файлу

### 1. Кореневі виконавчі файли
- [`CrashMonitor.ps1`](file:///C:/CrashMonitor/CrashMonitor.ps1) — **Головний супервізор**. Перевіряє єдиний екземпляр процесу, реєструє сесію завантаження, запускає фонових воркерів, безперервно пише `heartbeat-v2.csv` та стежить за станом збирачів.
- [`Worker.ps1`](file:///C:/CrashMonitor/Worker.ps1) — **Універсальний воркер**. Запускається параметризовано: `-Role telemetry` або `-Role events`. Реалізує цикл збору, контроль вільного місця на диску та оновлення стану прогресу.
- [`Install.ps1`](file:///C:/CrashMonitor/Install.ps1) — **Скрипт інсталяції та оновлення**. Створює системну задачу в Планувальнику завдань (`CrashMonitor_AutoStart`), налаштовує параметри аварійних дампів пам'яті (опціонально `-EnableCrashDumps`) і робить резервні копії перед зміною файлів.
- [`NightlyLogCleanup.ps1`](file:///C:/CrashMonitor/NightlyLogCleanup.ps1) та [`RegisterNightlyTask.ps1`](file:///C:/CrashMonitor/RegisterNightlyTask.ps1) — сумісні заглушки старого нічного планувальника v1 (деактивовані, оскільки v2 виконує розумне ковзне очищення автоматично щохвилини).

---

### 2. Модулі ядра (`Modules/`)
- [`Common.psm1`](file:///C:/CrashMonitor/Modules/Common.psm1) — **Базова бібліотека спільних функцій**:
  - `Write-CMCsv`: потоковий запис CSV з обов'язковим екрануванням лапок, invariant крапкою в десяткових числах та перевіркою схеми заголовків.
  - `Invoke-CMFileLock`: міжпроцесне блокування на базі системних м'ютексів.
  - `Get-CMBootKey`: обчислення стійкого унікального хешу поточного завантаження ОС.
  - `Get-CMCrashClassification`: евристичний аналізатор подій для визначення типу перезавантаження (`Bugcheck`, `UnexpectedReset`, `RequestedRestart`, `Unknown`).
  - `Invoke-CMRotation`: серце ротації — перевіряє ліміти розміру та викликає очищення.
  - `Limit-CMCsvLog` та `Limit-CMTextLog`: функції ковзного часового зрізу — тримають у файлах CSV лише свіжі записи за останні `RetentionHours` (4 години), відкидаючи старі рядки без зупинки запису.
- [`TelemetryV2.psm1`](file:///C:/CrashMonitor/Modules/TelemetryV2.psm1) — **Збирач продуктивності**:
  - Опитує WMI/CIM класи: `Win32_PerfFormattedData_PerfOS_Processor`, `Win32_OperatingSystem`, `Win32_PerfFormattedData_PerfOS_Memory`, `Win32_PerfFormattedData_PerfDisk_PhysicalDisk`.
  - Здійснює Storage I/O Probe (`io-probe.tmp` із примусовим `Flush`) для виявлення підвисань дискового контролера.
  - Збирає повний зріз процесів ОС та викликає `VoltageMonitor.psm1`.
  - Записує виділений лог температур [`temperatures.csv`](file:///C:/CrashMonitor/Evidence/Logs/temperatures.csv) та формує аварійні тривоги при нагріванні >= 70°C.
- [`VoltageMonitor.psm1`](file:///C:/CrashMonitor/Modules/VoltageMonitor.psm1) — **Модуль низькорівневих апаратних сенсорів (Ring-0)**:
  - Динамічно завантажує C#-інтерфейс до бібліотеки `LibreHardwareMonitorLib.dll`.
  - Опитує Super I/O мікросхему материнської плати (Nuvoton) та MSR-регістри процесора Intel Core i5.
  - Повертає напруги ліній БЖ (`Vcore`, `+3.3V`, `AVCC`, `3VSB`, `VBat`, `VTT`), оберти вентиляторів, температури окремих ядер та енергоспоживання процесора у ватах.
- [`EventCapture.psm1`](file:///C:/CrashMonitor/Modules/EventCapture.psm1) — **Збирач журналів подій**:
  - Зчитує канали подій `System`, `Application` та специфічні провайдери.
  - Підтримує курсори читання (`cursor-*.json`) для збереження позиції між перезапусками монітора.
  - Зберігає повні оригінальні XML подій (включно з необрізаними бінарними `RawData` для апаратних помилок WHEA).
- [`Diagnostics.psm1`](file:///C:/CrashMonitor/Modules/Diagnostics.psm1) — **Пакетувальник інцидентів та звітів**:
  - `New-CMIncident`: генерує детальний автономний інцидент при виявленні перезапуску: експортує EVTX, збирає знімок конфігурації заліза (`inventory.json`), записує хвіст телеметрії (300 точок до збою) та виносить фінальний вердикт.
  - `Export-CMDiagnostics`: упаковує всі матеріали розслідування в єдиний ZIP-архів із SHA-256 маніфестом цілісності.

---

### 3. Скрипти діагностики та перевірки (`Scripts/`)
- [`Watch-LiveSensors.ps1`](file:///C:/CrashMonitor/Scripts/Watch-LiveSensors.ps1) — консольний монітор реального часу. В одному рядку виводить навантаження процесора, його температуру на кристалі, енергоспоживання (W), напругу `Vcore`, оберти кулера (RPM), оперативну пам'ять, температури NVMe SSD (NAND і контролер), температуру HDD та статус тестів.
- [`Get-MonitorStatus.ps1`](file:///C:/CrashMonitor/Scripts/Get-MonitorStatus.ps1) — швидка перевірка працездатності: показує PID супервізора, стан воркерів (Waiting/Collecting), послідовність heartbeat та повертає `PASS`/`FAIL`.
- [`Stop-Monitor.ps1`](file:///C:/CrashMonitor/Scripts/Stop-Monitor.ps1) — безпечна та штатна зупинка монітора через запит `stop.request` без ризику пошкодження відкритих файлів.
- [`Export-Diagnostics.ps1`](file:///C:/CrashMonitor/Scripts/Export-Diagnostics.ps1) — створює діагностичний ZIP-пакет у папці `Exports/` для передачі на аналіз фахівцям.
- [`Invoke-SystemStressTest.ps1`](file:///C:/CrashMonitor/Scripts/Invoke-SystemStressTest.ps1) — комплексний сценарій стрес-тестування системи (диски + пам'ять + CPU) для провокації збою під контролем CrashMonitor.
- [`Watch-DiskStress.ps1`](file:///C:/CrashMonitor/Scripts/Watch-DiskStress.ps1) — утиліта відстеження дискового навантаження під час стрес-тестів.
- [`Get-OcctStatus.ps1`](file:///C:/CrashMonitor/Scripts/Get-OcctStatus.ps1) та [`Get-PostTestReport.ps1`](file:///C:/CrashMonitor/Scripts/Get-PostTestReport.ps1) — скрипти для перевірки стану сторонніх стрес-тестів (наприклад, OCCT) та формування післятестового звіту.
- [`Clear-MemoryStandby.ps1`](file:///C:/CrashMonitor/Scripts/Clear-MemoryStandby.ps1) та [`Test-MemoryStress.ps1`](file:///C:/CrashMonitor/Scripts/Test-MemoryStress.ps1) — утиліти для роботи зі standby-пам'яттю через RAMMap та перевірки стабільності RAM.

---

### 4. Автоматизоване тестування (`Tests/`)
- [`Test-Self.ps1`](file:///C:/CrashMonitor/Tests/Test-Self.ps1) — **43 вбудовані модульні самотести**. Перевіряють синтаксис усіх скриптів, коректність парсингу XML/WHEA, класифікацію BugCheck, механізми ротації, блокування файлів та цілісність CSV. Не потребує зовнішніх залежностей.
- [`Test-Windows.ps1`](file:///C:/CrashMonitor/Tests/Test-Windows.ps1) — димовий тест сумісності в середовищі Windows: перевіряє права, статус Scheduled Task, доступність каналів журналів подій та WMI.

---

### 5. Конфігурація (`Config/`)
- [`Config/config.json`](file:///C:/CrashMonitor/Config/config.json) — діюча конфігурація монітора.
- [`Config/defaults-v2.json`](file:///C:/CrashMonitor/Config/defaults-v2.json) — шаблон типових налаштувань.

---

### 6. Каталог доказів (`Evidence/`)
- **`Evidence/Logs/`** — активні поточні журнали:
  - `telemetry-v2.csv` — головний журнал метрик (22 стовпці кожні 3 секунди).
  - `temperatures.csv` — окремий журнал температур накопичувачів і попереджень.
  - `heartbeat-v2.csv` — незалежний пульс системи.
  - `processes-latest.json` — актуальний повний зріз усіх запущених процесів ОС.
  - `events.jsonl` — структурований індекс подій Windows.
  - `supervisor.log`, `telemetry.log`, `events.log` — технічні журнали роботи компонентів.
- **`Evidence/Events/`** — повні сирі XML-файли подій Windows та бінарні WHEA RawData.
- **`Evidence/Incidents/<BootKey>/`** — автономні пакети по кожному виявленому збою/рестарту (містять `report.json`, `inventory.json`, EVTX-дампи журналів та хвіст телеметрії).
- **`Evidence/State/`** — системний стан: курсори читання подій (`cursor-*.json`), файл поточної сесії (`session.json`), інформація про попереднє завантаження (`previous-session.json`) та статус воркерів.

---

## Метрики та апаратні сенсори (Ring-0)

CrashMonitor зчитує понад 40 апаратних метрик. Частина з них (диски, ОС, мережа) доступні через стандартні API Windows, але низькорівневі напруги БЖ та прямі температури ядер вимагають виконання процесорних інструкцій `rdmsr` та `in/out`, що заборонено у звичайному просторі додатків (Ring-3).

### Як реалізовано доступ до Ring-0:
1. Використовується бібліотека [`Tools/LibreHardwareMonitor/LibreHardwareMonitorLib.dll`](file:///C:/CrashMonitor/Tools/LibreHardwareMonitor).
2. Бібліотека завантажує драйвер режиму ядра `WinRing0`.
3. Оскільки Microsoft Defender за замовчуванням блокує цей драйвер як застарілий за правилом вразливих драйверів (**`VulnerableDriver:WinNT/Winring0`**, Threat ID `2147937641`), у Defender було внесено цільовий дозвіл саме для цього ідентифікатора загрози:
   ```powershell
   Set-MpPreference -ThreatIDDefaultAction_Ids 2147937641 -ThreatIDDefaultAction_Actions 6
   Add-MpPreference -ExclusionPath "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.sys"
   ```
   *Це налаштування зберігається в системному реєстрі назавжди і не скидається після перезавантаження сервера.*

### Що зчитується завдяки цьому:
- **Материнська плата (Nuvoton NCT6796D):**
  - Напруга живлення процесора: `Vcore` (0.65 – 1.10 V)
  - Лінії живлення плати: `+3.3V`, `AVCC` (3.3V), `3VSB` (3.3V), `VTT` (1.06V)
  - Батарейка CMOS на платі: `VBat` (~3.1 V)
  - Оберти процесорного вентилятора: `Fan 2` (~1320 RPM)
- **Процесор Intel Core i5-9400:**
  - `CPU Package Temperature`: загальна температура кристала
  - Температури кожного з 6 ядер окремо (Cores 1–6)
  - Відстань до тротлінгу / критичної межі: `Distance to TjMax`
  - Споживання потужності: `CPU Package Power` (Watt), `Cores Power` (Watt), `Memory Controller Power` (Watt)
  - Тактові частоти кожного ядра (MHz) та напруги VID
- **Накопичувачі (Samsung 980 NVMe & Seagate HDD):**
  - Температура NAND пам'яті NVMe та окремо температура контролера NVMe (Controller Temp)
  - Запас комірок пам'яті (Available Spare %), відсоток зносу (Percentage Used)
  - Прочитано / записано гігабайт за весь час життя
  - Температура жорсткого диска HDD

---

## Ковзне вікно логів та збереження інцидентів

Для розслідування раптових перезавантажень не потрібні гігабайти рутинних логів за попередні тижні — критично важлива **детальна передісторія за останні кілька годин безпосередньо перед моментом збою**.

### Механізм ковзного вікна (`RetentionHours = 4`):
1. У [`Config/config.json`](file:///C:/CrashMonitor/Config/config.json) встановлено параметр `"RetentionHours": 4`.
2. Щохвилини воркер подій викликає функцію `Invoke-CMRotation`.
3. Функція `Limit-CMCsvLog` аналізує стовпець `Utc` у потокових CSV-файлах (`telemetry-v2.csv`, `temperatures.csv`, `heartbeat-v2.csv`).
4. Усі рядки, старіші за `(UtcNow - 4 години)`, потоково відкидаються.
5. Файли завжди містять останні ~4800 точок вимірювання (за 4 години), не розростаються понад розумні межі (тримаються в межах 20–30 МБ) і моментально відкриваються для аналізу.

### Недоторканність аварійних інцидентів:
Коли на сервері стається аварійне вимкнення, перезапуск або синій екран:
- Створюється окрема постійна папка в [`Evidence/Incidents/<BootKey>`](file:///C:/CrashMonitor/Evidence/Incidents).
- У неї назавжди зберігаються: повні логи подій навколо збою, EVTX, дампи WHEA, знімок конфігурації та **300 рядків телеметрії прямо перед моментом смерті ОС**.
- Ротація ковзного вікна **ніколи не видаляє** папки інцидентів (вони зберігаються до ліміту `MaxIncidents: 100`).

---

## Класифікація перезавантажень

При кожному новому старті CrashMonitor аналізує журнали подій Windows і автоматично класифікує попереднє вимкнення:

| Тип вердикту | Значення | Що це означає |
| :--- | :--- | :--- |
| **`Bugcheck`** | Синій екран (BSOD) | Windows зафіксувала stop error, записала BugCheck код і дамп пам'яті (`C:\Windows\Minidump`). |
| **`RequestedRestart`** | Штатний рестарт | Зафіксовано подію `User32` (подія 1074) — перезавантаження ініційовано користувачем, службою оновлення або скриптом. |
| **`UnexpectedReset`** | Апаратний Reset / БЖ | Зафіксовано `Kernel-Power 41` без жодного коду помилки. Свідчить про зникнення живлення, кнопку Reset, спрацювання захисту БЖ або миттєвий апаратний перезапуск материнської плати. |
| **`Unknown`** | Недостатньо даних | Немає чітких слідів завершення. |

---

## Швидкий старт та щоденні команди

Всі команди виконуються у **PowerShell від імені Адміністратора**:

### 1. Перевірити живий стан сенсорів прямо зараз:
```powershell
powershell -ExecutionPolicy Bypass -File C:\CrashMonitor\Scripts\Watch-LiveSensors.ps1
```
*(Для безперервного спостереження кожні 3 секунди: додайте `-Samples 100`)*

### 2. Перевірити статус служби CrashMonitor:
```powershell
powershell -ExecutionPolicy Bypass -File C:\CrashMonitor\Scripts\Get-MonitorStatus.ps1
```

### 3. Запустити вбудовані тести самоперевірки:
```powershell
powershell -ExecutionPolicy Bypass -File C:\CrashMonitor\Tests\Test-Self.ps1
```

### 4. Зібрати повний діагностичний ZIP-пакет для аналізу:
```powershell
powershell -ExecutionPolicy Bypass -File C:\CrashMonitor\Scripts\Export-Diagnostics.ps1
```
*(Готовий архів буде збережено в каталозі `C:\CrashMonitor\Exports\`)*

### 5. Зупинити або перезапустити моніторинг:
```powershell
# Штатна зупинка:
powershell -ExecutionPolicy Bypass -File C:\CrashMonitor\Scripts\Stop-Monitor.ps1

# Запуск через планувальник:
Start-ScheduledTask -TaskName "CrashMonitor_AutoStart"
```

---

## Як покращувати та розширювати проект

Якщо ви хочете доопрацювати CrashMonitor:

1. **Додавання нових апаратних датчиків**:
   - Відкрийте [`Modules/VoltageMonitor.psm1`](file:///C:/CrashMonitor/Modules/VoltageMonitor.psm1).
   - У методі `ReadAllSensors()` словник `dict` містить усі доступні сенсори LibreHardwareMonitor.
   - Щоб додати новий параметр (наприклад, окремі напруги 12V/5V або температури додаткових дисків), додайте відповідні ключі в хеш-таблицю `$snapshot` у функції `Get-CrashMonitorVoltageSnapshot`.
2. **Зміна часу зберігання логів**:
   - У файлі [`Config/config.json`](file:///C:/CrashMonitor/Config/config.json) змініть значення `"RetentionHours"`. Наприклад, `"RetentionHours": 8` зберігатиме історію за останні 8 годин.
3. **Додавання нових каналів Windows Event Log**:
   - У файлі [`Config/config.json`](file:///C:/CrashMonitor/Config/config.json) у масив `"OptionalEventChannels"` додайте потрібний журнал (наприклад, `"Microsoft-Windows-Storage-Storport/Operational"`).
4. **Перевірка після змін**:
   - Після будь-якої модифікації коду обов'язково виконайте:
     ```powershell
     powershell -ExecutionPolicy Bypass -File C:\CrashMonitor\Tests\Test-Self.ps1
     ```
   - Тест перевіряє сумісність синтаксису, роботу блокувань, парсерів та експорту і захищає від внесення регресійних помилок.
