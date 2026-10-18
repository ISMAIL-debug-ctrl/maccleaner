<p align="center"><img src="Resources/AppIcon.png" width="128" alt="MacCleaner icon"></p>

<h1 align="center">MacCleaner</h1>
<p align="center">A free, open-source alternative to CleanMyMac for Apple Silicon Macs.<br>Cleanup, uninstaller, space map, duplicates, memory monitor and maintenance in one native app. No subscription and no tracking.</p>
<p align="center"><a href="#العربية">العربية ⬇</a></p>

---

## Why
Mac cleaners cost a subscription and often show big "freed GB" numbers that don't mean much. MacCleaner does the same jobs for free, tells you honestly what each one does, and is built so it can't delete your work by mistake.

## Features
| Module | What it does |
|---|---|
| **Smart Scan** | One button: junk, Trash, memory, app updates and suspicious launch items, with a summary before anything is cleaned |
| **System Junk** | User caches, logs, crash reports, saved app states, Xcode/simulator/npm/Gradle/CocoaPods leftovers, Homebrew cleanup, old iPhone/iPad updates, broken login items, leftovers of deleted apps. With the helper it also cleans system caches, system crash reports and rotated system logs |
| **Trash Bins** | Empties the Trash on your Mac and on connected drives |
| **Mail Attachments** | Copies Mail saved when you opened attachments. Mailbox attachments are listed, never pre-selected |
| **Photo Junk** | Photos and media-analysis caches outside your library. The Photos library itself is never touched |
| **Large & Old Files** | Finds big files and files you haven't opened in months, in any folder you choose |
| **Duplicates** | Byte-identical files (SHA-256) and visually similar photos (perceptual hash) |
| **Space Lens** | Interactive treemap of what uses your disk. Click to drill down |
| **Uninstaller** | Removes an app plus its caches, preferences, containers and support files, or resets an app by removing only its data |
| **Updater** | Lists outdated apps from the App Store, Sparkle feeds and Homebrew casks |
| **Memory** | **Free RAM** (purge + stop restartable background services, with an honest before → after), **relaunch apps that have grown** (browsers, Electron apps, Finder), and a list of open apps to quit or force quit. Shows pressure, swap, and which part of memory can't be freed (wired) or frees itself (file cache). Optional auto mode when pressure turns yellow |
| **Optimization** | Launch agents (turn yours off and on again), heavy CPU and memory consumers, and a shortcut to Login Items |
| **Maintenance** | Free up RAM (purge), flush DNS, thin Time Machine local snapshots, run maintenance scripts, reindex Spotlight, repair home-folder permissions, rebuild Launch Services |
| **Privacy** | Browser history, cookies, autofill data and caches for Safari, Chrome, Brave, Edge, Arc, Vivaldi, Opera and Firefox, plus the Recent Items list. Opt-in only |
| **Protection** | Flags launch agents and daemons that are unsigned, ad-hoc signed, run from hidden or temp folders, run scripts, or were added this week. Lists browser extensions and highlights the ones that can read every website |
| **Menu bar** | A mini MacCleaner behind the app's own icon: Memory (Free RAM, top apps with Quit, relaunch), Cleanup (quick clean of caches and Trash), CPU (busiest apps) and Storage (free space and shortcuts) |

## About "Free RAM"
MacCleaner doesn't show fake numbers. Free RAM does only the things that actually give memory back, then measures again and shows what really changed:
1. **purge** empties the inactive file cache (needs the helper, or your password).
2. **Background services** like Photos and Spotlight analysis (`mediaanalysisd`, `photoanalysisd`, `mdworker_shared`…) are stopped when they've grown. macOS restarts them later, smaller.
3. **Relaunch apps that have grown**: a browser, an Electron app (Notion, Slack, Discord, Claude…) or Finder gives back everything when it restarts. Relaunch quits it normally (it saves or asks first) and opens it again. Browsers bring your tabs back if "Continue where you left off" is on. For Chromium browsers MacCleaner also points you at the heavy tab (Shift+Esc) and Memory Saver.
4. **Quit what you don't need** from the open-apps list.

Each app's number is its *footprint*, the same as Activity Monitor's Memory column, counted with all its helper processes. Part of it can be compressed or in swap, so one app can hold more than is in RAM right now. That's exactly why swap grows. Wired memory (macOS itself) can't be freed, and the file cache frees itself, so a 16 GB Mac sitting around 50–70% in use is normal.

## Safety
- **Whitelist only.** Junk cleaning only removes things *inside* a fixed list of cache and log folders. Those folders are kept. Nothing outside the list is ever touched automatically.
- **Your files are never touched automatically.** Documents, Desktop, Downloads, Pictures, Movies, Music, the Photos library, iCloud Drive, app settings and keychains are never cleaned automatically. Files there only go if you pick them yourself, for example in Large Files or Duplicates. Then they go to the **Trash**, so you can undo.
- **Browser caches are kept by default.** So are caches of apps that are open. Both are settings.
- **Preview first.** Every module scans, shows every item with its size, and asks before it removes anything.
- **Links are never followed.** A symlink inside a cache folder is removed as a link; what it points to is not touched. Tests check this.
- Leftovers of deleted apps are **never pre-selected**. The scan ignores vendors that still have an app, agent or plug-in installed, and it ignores licence files.
- Language files inside apps are **reported, not removed**: removing them breaks the app's code signature on modern macOS.

## Requirements
- Apple Silicon Mac on macOS 14 or later. Built and tested on an M2 Pro with macOS 26.
- Xcode Command Line Tools (`xcode-select --install`). MacCleaner is built on your Mac from source, so you can read exactly what you run.

## Install
```bash
git clone https://github.com/ISMAIL-debug-ctrl/maccleaner.git
cd maccleaner
./install.sh
```
- The installer builds the app, copies it to `/Applications`, and asks for your password **once** to install the small root helper. You can skip the helper with `./install.sh --no-helper`. Maintenance tasks then ask for your password each time, and system-wide junk is skipped.
- Then open **System Settings ▸ Privacy & Security ▸ Full Disk Access** and turn on **MacCleaner**. It needs this to see the Trash, Mail and Safari data. After an update you may need to turn it off and on again, because the app is built locally and has no paid Apple signature.
- To open MacCleaner at login (menu bar only), use **Settings ▸ Open at login** in the app. It is then listed in System Settings ▸ General ▸ Login Items.
- Closing the window keeps MacCleaner in the menu bar (the Dock icon hides). Quit it from the menu bar panel.

## Update
When an update is out, the app shows **Update now** (in Settings and in the menu bar panel). You can also run:
```bash
./update.sh
```
Updates only install published releases (`v*` tags on `main`). Your password is only asked again when the helper itself changed.

## Uninstall
```bash
./uninstall.sh
```

## How it works
- **App** (SwiftUI, runs as you): all the scanning, user-level cleaning, uninstalling and the menu bar monitor.
- **Helper** (`/Library/PrivilegedHelperTools/com.ismailx.maccleaner.helper`, root, via launchd): only needed for system folders and admin-only maintenance. The app asks it to do something by writing an *action name* (for example `purgeRAM`) to `command.json` in your own `~/Library/Application Support/MacCleaner` (mode 700). The helper writes its status to root-owned `/Library/Application Support/MacCleaner`.

## Security (root helper)
- **It only runs a fixed list of actions.** It never takes paths, arguments or shell strings from the app. Each action runs a fixed system tool with an absolute path and a clean environment, or a built-in deletion of fixed system folders.
- **Deletion is descriptor-based** (`openat`/`unlinkat` with `O_NOFOLLOW`). Swapping a folder for a symlink mid-way can't redirect root anywhere. It never crosses into another volume, it only enters root-owned folders, and in world-writable `/Library/Caches` it only removes root-owned entries.
- **It only reads input from the logged-in user**, from that user's own folder. It refuses symlinks, FIFOs, devices, files owned by someone else and files over 16 KB. Commands older than 60 s or seen before are ignored. Heavy actions (Spotlight reindex, permissions repair) have a cooldown.
- **Root never writes where a normal user can write.** If its state folder is ever a symlink or isn't owned by root, the helper moves it aside.
- **Installs are verified.** The installer copies the helper into root's private temp folder and checks its SHA-256 there before installing it.
- **No network access, no plugins, no telemetry.** The app's only network calls are the update check (GitHub), App Store and Sparkle version lookups when you open Updater or run Smart Scan, and nothing else.

## Tests
```bash
./Tests/run.sh
```
The tests build a fake home folder in a temp directory and check that junk is cleaned and that browser caches, Documents, Desktop and preferences survive. They also check that symlink and `../` escapes are refused, that leftover matching is exact, that duplicates and Space Lens work, and that the helper's deletion never follows links.

## License
[PolyForm Noncommercial 1.0.0](LICENSE): free to use, share and modify for any noncommercial purpose. Selling it, or using it in a paid product or service, is not allowed.

MacCleaner is an independent project and is not affiliated with MacPaw or CleanMyMac.

---

<div dir="rtl">

## العربية

**MacCleaner** بديل مجاني ومفتوح المصدر لـ CleanMyMac، لأجهزة ماك بمعالج Apple Silicon. ما فيه اشتراك ولا تتبع.

### وش يسوي
- **الفحص الذكي**: زر واحد يفحص الملفات الزايدة والسلة والرام وتحديثات البرامج والأشياء المشبوهة اللي تشتغل لحالها، ويعرض لك الملخص قبل لا يمسح أي شي.
- **ملفات النظام الزايدة**: الكاش، اللوقات، تقارير الكراش، بقايا Xcode والمحاكيات وnpm وHomebrew، تحديثات الآيفون القديمة، عناصر الدخول المكسورة، وبقايا البرامج المحذوفة.
- **السلة** و**مرفقات البريد** و**كاش الصور**. مكتبة الصور نفسها ما يلمسها أبداً.
- **الملفات الكبيرة والقديمة** و**المكررات** (نفس الملف بالضبط، أو صور متشابهة).
- **خريطة المساحة** (Space Lens): تشوف وش ماخذ مساحة جهازك، وتضغط على أي مجلد وتدخل فيه.
- **إزالة البرامج** مع كل ملفاتها، و**قائمة البرامج اللي لها تحديث**.
- **الرام**: زر **تفريغ الرام** (purge + إيقاف خدمات الخلفية اللي ترجع لحالها) ويوريك قبل/بعد بصدق، و**إعادة تشغيل البرامج اللي كبرت** (المتصفح، برامج Electron، Finder)، وقائمة البرامج المفتوحة مع إغلاق وإغلاق إجباري.
- **الصيانة**: تفريغ الرام (purge)، تنظيف كاش الـ DNS، حذف لقطات Time Machine المحلية، إعادة فهرسة Spotlight، إصلاح صلاحيات مجلدك.
- **الخصوصية**: سجل المتصفحات والكوكيز. ما يتحدد أي شي إلا إذا أنت اخترته.
- **الحماية**: يوريك البرامج اللي تشتغل لحالها وهي غير موقّعة أو من مجلدات مخفية، وإضافات المتصفح اللي تقدر تقرا كل المواقع.
- **شريط القوائم**: أيقونة البرنامج، وتفتح لك نسخة مصغّرة من MacCleaner فيها: الرام، التنظيف السريع، المعالج، والتخزين.
- إذا سكّرت النافذة يبقى البرنامج شغال في شريط القوائم، وتقدر تخليه يفتح مع تشغيل الجهاز من الإعدادات.

### عن زر "تفريغ الرام"
ما نعطيك أرقام وهمية. الزر يسوي بس الأشياء اللي فعلاً ترجع رام: يفرّغ كاش الملفات، ويوقف خدمات الخلفية الكبيرة (تحليل الصور وSpotlight، وترجع لحالها بحجم أصغر). وبعدها يقيس مرة ثانية ويوريك وش تغيّر بالضبط. وأكبر فرق تحصّله من **إعادة تشغيل** البرنامج اللي كبر (المتصفح أو Notion أو Finder)، أو إنك تقفل البرنامج اللي ما تحتاجه. الجزء "Wired" هو النظام نفسه وما ينفرغ، وكاش الملفات يفرّغ نفسه، فطبيعي جهاز 16 جيجا يكون مستخدم 50–70%.

### الأمان
- التنظيف من **قائمة مجلدات محددة** بس (كاش ولوقات). المجلدات نفسها تبقى، ويُمسح اللي داخلها بس.
- **ملفاتك الشخصية** (المستندات، سطح المكتب، التنزيلات، الصور، الأفلام، مشاريعك، إعدادات البرامج) ما تنلمس لحالها أبداً. إذا اخترت ملفات منها بنفسك، تروح **للسلة** وتقدر ترجعها.
- **كاش المتصفحات يبقى** افتراضياً، وكذلك كاش البرامج المفتوحة.
- كل قسم **يعرض لك القائمة قبل** المسح ويطلب تأكيدك.
- بقايا البرامج المحذوفة **ما تتحدد افتراضياً**، وملفات الترخيص (licence) ما تنعرض أصلاً.

### التثبيت
```bash
git clone https://github.com/ISMAIL-debug-ctrl/maccleaner.git
cd maccleaner
./install.sh
```
- يطلب الباسوورد **مرة وحدة** عشان يركّب المساعد (helper). إذا ما تبيه: `./install.sh --no-helper`.
- بعدها روح **إعدادات النظام ▸ الخصوصية والأمان ▸ الوصول الكامل للقرص** وفعّل **MacCleaner**.

### التحديث
لما ينزل تحديث يطلع لك زر **Update now** داخل البرنامج، أو شغّل `./update.sh`. الباسوورد ما ينطلب إلا إذا تغيّر المساعد نفسه.

### الحذف
```bash
./uninstall.sh
```

### الترخيص
مجاني للاستخدام والمشاركة والتعديل لأي غرض غير تجاري. **ممنوع بيعه** أو استخدامه في منتج أو خدمة مدفوعة.

</div>
