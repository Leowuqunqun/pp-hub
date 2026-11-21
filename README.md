# pp-hub

一个常驻菜单栏的 macOS 小工具，把日常最常用的几件事合成一个应用：**启动器 + 文件搜索、窗口吸附、语音听写、会议转写、剪贴板历史**。

设计原则只有一条：**每加一个能力，都要能因此卸载一个应用**。做不到就不加。

| 能力 | 替代谁 |
|---|---|
| 应用启动 + 文件搜索（`⌥Space`） | Alfred 的应用/文件搜索 |
| 窗口吸附（`⌃⌥` + 方向键/字母） | Rectangle |
| 语音听写（轻点右 `⌘`） | Typeless |
| 会议转写（`⌃⌥M`） | Typeless 的会议记录 |
| 剪贴板历史（`⌃⌥V`） | Paste |

## 环境要求

- **macOS 26 (Tahoe) 或更新**，Apple Silicon（arm64）
- 语音功能依赖系统端侧识别框架 `SpeechAnalyzer`，这也是不能跑在更老系统的原因
- 构建需要 Xcode Command Line Tools（不需要完整 Xcode）

## 安装

1. 从 [Releases](https://github.com/Leowuqunqun/pp-hub/releases) 下载 `pp-hub-<版本>-macos26-arm64.zip`
2. 解压，把 `pp-hub.app` 拖进 `/Applications`
3. **首次打开会被 Gatekeeper 拦下**（这个包没有 Apple 开发者证书、未公证）：

   ```bash
   xattr -dr com.apple.quarantine /Applications/pp-hub.app
   open /Applications/pp-hub.app
   ```

   也可以在 Finder 里右键 → 打开 → 再点「打开」。

首次运行会请求三个权限，缺一不可：**辅助功能**（全局快捷键、窗口吸附、听写上屏）、**麦克风**（听写/会议）、**语音识别**。没授予辅助功能时，应用照常出现在菜单栏，但快捷键无效。

## 快捷键

| 键 | 作用 |
|---|---|
| `⌥Space` / `⌥⌘Space` | 唤出面板（搜应用、搜文件） |
| `⌃⌥←→` | 左/右半屏；1.5 秒内连按 → ⅔ → ⅓ |
| `⌃⌥↑↓` | 上/下半屏 |
| `⌃⌥U I J K` | 四角 |
| `⌃⌥↩` | 最大化 |
| `⌃⌥[` / `⌃⌥]` | 移到上/下一个显示器 |
| 轻点右 `⌘` | 开始/结束听写 |
| `⌃⌥M` | 开始/结束会议记录 |
| `⌃⌥V` | 剪贴板历史 |
| `⌘↩`（面板内） | 把选中的文件/目录交给 QSpace（可选，未装则忽略） |

窗口也可以直接拖到屏幕边缘吸附：左侧/右侧=半屏，顶部=最大化，四角=四分之一。

## 隐私

- **默认不出网**。语音识别、窗口吸附、剪贴板、搜索全部在本机完成。
- 唯一的出网点是听写的**模型润色**，默认关闭。开启后会把识别出的文本发送到你自己在 `config.json` 里配置的 OpenAI 兼容接口；不配就没有任何网络请求。
- 剪贴板历史存本地 SQLite，尊重系统敏感标记（`org.nspasteboard.ConcealedType` / `TransientType`，密码管理器靠这个标记），这类内容不采集。
- 数据与日志都在 `~/Library/Application Support/pp-hub/`，删掉目录即清空。

## 构建

```bash
./build.sh            # swiftc 直接编，无需 Xcode 工程
./build.sh run        # 前台运行，日志直接打屏
./build.sh package    # 产出 build/pp-hub-<版本>-macos26-arm64.zip
open build/pp-hub.app # 运行（首次会注册开机自启）
```

签名：默认 ad-hoc。若本机有稳定证书，用环境变量指定，这样辅助功能授权能跨重建保留：

```bash
PPHUB_IDENTITY="Apple Development: 你的名字 (XXXXXXXXXX)" ./build.sh
```

## 自检

```bash
./Tests/smoke.sh                                                  # 一条命令跑完验收项
build/pp-hub.app/Contents/MacOS/pp-hub --selftest apps  calc      # 应用搜索
build/pp-hub.app/Contents/MacOS/pp-hub --selftest files 简历       # 文件搜索
build/pp-hub.app/Contents/MacOS/pp-hub --selftest snaps           # 吸附几何
build/pp-hub.app/Contents/MacOS/pp-hub --selftest offline         # 断网降级
build/pp-hub.app/Contents/MacOS/pp-hub --selftest meeting 5       # 会议记录（录 5 秒）
build/pp-hub.app/Contents/MacOS/pp-hub --selftest clip            # 剪贴板往返
build/pp-hub.app/Contents/MacOS/pp-hub --selftest panel           # 结果分组与下标换算
build/pp-hub.app/Contents/MacOS/pp-hub --selftest qspace          # QSpace 唤起 + 读回校验
open "pphub://diag-files?kw=网易"                                  # 应用内 mdfind 诊断
```

## 实现要点

### 文件搜索的两条硬纪律

1. **超时 ≠ 没有结果**。`mdfind` 冷启动常在 1.5s 内跑不完，第一次拿不到结果时会自动放宽到 3.5s 重试。
2. **空结果永不进入缓存**。曾经的 bug：冷启动超时返回空 → 空结果被缓存 → 同一关键词**此后永远搜不到文件**，而且没有任何报错。现在只有拿到结果的查询才缓存，缓存 120 秒过期。

排查入口：`open "pphub://diag-files?kw=关键词"` 会在**运行中的 app 进程内**跑一次 mdfind，把输出行数、退出码、路径可读性写进日志——用来区分「索引里没有」和「权限/进程环境问题」。

### 搜索结果分组

结果按类别分组：**应用** 在上、**文件** 在下，每组带标题与数量。键盘选择仍是一条连续序列（↑↓ 跨组），所以「应用最后一项 → 下一条就是文件第一项」。换算抽成纯函数 `ResultCompose`，`--selftest panel` 会校验「视觉第几行 ↔ 扁平第几项」不串位，越界返回 `-1`（否则会误打开第一项）。

### 输入法协作

两个面板都做了 IME 保护：拼音还在候选状态时，`↩` 必须交给输入法上字，不能被「选中结果」抢走。判据是 `NSTextView.hasMarkedText()`。

另外 `LSUIElement` 应用没有主菜单栏，`⌘A/⌘C/⌘V/⌘Z` 这些「菜单快捷键」根本不会派发——所以内部装了一份隐藏的编辑菜单，并给输入框补了 `⌘A` 兜底。

### 壳化唤起：QSpace（可选，`⌘↩`）

商品类应用不重造，只做「把某个目录交给它」：

| 方向 | 契约 |
|---|---|
| 开到位 | `NSWorkspace.open([目录], withApplicationAt: QSpace)`，读回 `URL of root item` 校验 |
| 读回来 | AppleScript 读根目录（需「自动化」权限，首次弹一次） |

文件搜索结果按 `⌘↩` → QSpace 跳到该文件所在目录；右键菜单也能开门到主目录/下载/桌面/文稿。外部调用：`open "pphub://qspace?path=/some/dir"`。

### 剪贴板历史

**不是剪贴板替代品**——`⌘C/⌘V` 该怎么样还怎么样，只负责「找回」。

| 按键 | 作用 |
|---|---|
| `↑↓` / `↩` | 选择 / 整份贴回 |
| `⌘1`–`⌘9` | 快贴 |
| `⌘D` / `⌘⌥P` | 删除 / 置顶 |
| `Esc` | 收起 |

保留**全部表示**：富文本存 RTF+HTML+纯文本，图片存 PNG，多文件存 URL 列表，贴回去时原样还原，不做纯文本降级。上限 200 条，置顶的不会被挤掉，自己写回剪贴板的那次不会被再采集。

### 听写 vs 会议

听写是「说完立刻上屏」，几百字以内；会议是「边录边落盘」，按段追加到 `~/Documents/pp-hub 会议/<日期>--<时间>--会议.md`，每 5 分钟轮换识别会话（防内存上涨与识别漂移）。两者互斥——麦克风只有一只。

会议记录不上屏、不逐句润色。

## 目录

```
Sources/            31 个 swift 文件，约 4700 行
  AppDelegate.swift 启动、菜单、URL scheme
  Panel/            启动器面板：搜索、分组、键盘与输入法
  Window/           窗口吸附：几何计算、拖拽、跨屏
  Voice/            语音：听写、会议、润色、配置
  Clip/             剪贴板：采集、存储、面板
  Core/             应用索引、文件搜索、拼音、日志、自检
  Ctl/              远程操作接口（默认关闭，见下文）
Resources/Info.plist
Tests/smoke.sh      验收脚本
build.sh            swiftc 构建 + 打包
```

数据：`~/Library/Application Support/pp-hub/config.json`（润色开关、热键、会议目录、固定纠错表）与 `log.txt`。
日志是排障第一入口，带 `snap:` / `voice:` / `clip:` / `filesearch:` / `panel:` 前缀。

## 远程操作接口（默认关闭）

除了手动按键，pp-hub 提供一个 URL 通道，让脚本或自动化程序驱动这台机器：

```
pphub://ctl/key?combo=ctrl+alt+left&token=<令牌>
pphub://ctl/type?text=你好&token=<令牌>
pphub://ctl/click?x=800&y=400&token=<令牌>
pphub://ctl/focus?app=com.apple.finder&token=<令牌>
pphub://ctl/ax?app=com.apple.finder&depth=3&token=<令牌>      # 读界面元素树
pphub://ctl/ax-click?app=com.apple.TextEdit&label=删除&token=<令牌>
pphub://ctl/status?token=<令牌>
```

结果没有回传通道（URL 单向），写到 `~/Library/Application Support/pp-hub/ctl-last.txt`，调用方读文件取结果。

**为什么放在应用里而不是做一个命令行工具**：macOS 的辅助功能授权按*进程身份*发放。命令行工具没有应用身份，它注入按键时系统认定的"责任进程"是调用它的那个程序，而那个进程在设置里没有条目，于是永远被拒。应用本身有身份、有授权，把它做在这里一次授权就够。

**默认关闭，且必须带令牌**。`config.json` 里两个字段缺一不可：

```json
{ "ctlEnabled": true, "ctlToken": "<32 位随机串>" }
```

理由很直接：这个接口能替你敲键盘、点鼠标。如果默认开启或不要令牌，任何网页只要让你点一个 `pphub://ctl/...` 链接，就能在你电脑上打字。所以默认关闭、令牌不匹配即拒绝，拒绝原因写日志。

## 已知限制

- **需要 macOS 26**（端侧语音识别依赖），arm64
- **未签名公证**，首次打开需手动放行一次（见上文）
- 语音听写依赖辅助功能权限向目标应用注入按键；权限被撤销后快捷键与听写都会失效
- 只做了 macOS 26 的窗口管理 API，跨屏移动是整窗搬运，不是「带着窗口拖动」

## License

MIT
