# wapp 技术方案

> 状态：v0.2（对齐 requirements.md v0.2：单桌面图标 + 隐藏控制台 + 标签式站点）
> 结论先行：Windows 上的 DevEco Studio / hvigor CLI 构建，ArkTS + ArkWeb 单 HAP，两个 UIAbility，站点数据存 Preferences。

## 1. 为什么不用 WSL

- DevEco Studio 无 Linux 版本；Linux 侧只有 command-line-tools（SDK + hvigorw + ohpm + hdc），没有 IDE、Previewer、模拟器，AGC 自动签名也依赖 IDE。
- hdc 走 USB 需要 usbipd-win 转发；模拟器只跑在 Windows。
- 工程放 `/mnt/c` 构建慢、inotify 不可靠；放 ext4 则 Windows 侧 IDE 打不开。
- 所以：**WSL 只适合读代码/写文档**，构建与装机固定在 Windows。Agent 在 Windows 上用 bash 调 CLI 一样顺。

## 2. 应用结构

单 bundle、单 HAP、两个 UIAbility：

| ability | 桌面图标 | skills | launchType | 作用 |
|---|---|---|---|---|
| `WebAbility` | 有（唯一图标） | `entity.system.home` + `action.system.home` | singleton | 全屏加载当前站点 |
| `ConsoleAbility` | 无 | 空 | singleton | 站点管理（仅快捷方式可达） |

`module.json5` 关键片段（实际字段以构建校验为准）：

```json5
{
  "module": {
    "name": "entry",
    "type": "entry",
    "deviceTypes": ["phone"],
    "abilities": [
      {
        "name": "WebAbility",
        "srcEntry": "./ets/entryability/WebAbility.ets",
        "launchType": "singleton",
        "orientation": "auto_rotation",
        "exported": true,
        "skills": [{ "entities": ["entity.system.home"], "actions": ["action.system.home"] }]
      },
      {
        "name": "ConsoleAbility",
        "srcEntry": "./ets/consoleability/ConsoleAbility.ets",
        "launchType": "singleton",
        "orientation": "auto_rotation",
        "exported": true,
        "skills": []
      }
    ],
    // 关键：stage 模型的 module 层没有 shortcuts 字段（modulecheck/module.json 全文无该关键字）
    // 快捷方式 = abilities[].metadata + 独立 profile 文件
    "metadata": [
      { "name": "ohos.ability.shortcuts", "resource": "$profile:shortcuts_config" }
    ]
  }
}
```

- 没有 `entity.system.home` 的 ability 不会产生桌面图标 → `ConsoleAbility` 天然隐藏。
- 快捷方式的真实配置方式（本机验证：`assembleHap` 通过，产物 `module.json` 里 `WebAbility.metadata` 带上 `ohos.ability.shortcuts`，`resources/base/profile/shortcuts_config.json` 一并打包）：
  - `entry/src/main/resources/base/profile/shortcuts_config.json`：`{"shortcuts":[{"shortcutId","label","icon","wants":[{"bundleName","moduleName","abilityName","parameters":{...}}]}]}`
  - `module.json5` 的 `abilities[].metadata` 加 `{"name":"ohos.ability.shortcuts","resource":"$profile:shortcuts_config"}`，name 只能用这一个字符串。
  - `wants[].parameters` 支持字符串键值（各自 ≤1024 字符）→ **可带参数**，不需要为每个菜单动作单独建 ability。
  - 桌面长按图标最多展示 4 个快捷方式；快捷方式还能长按拖到桌面单独成图标（等于免费多入口）。
  - 参考：https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/typical-scenario-configuration-V5

## 3. 数据与流转

```text
Preferences:
  sites        JSON 数组 [{id,title,url,icon}]
  currentSite  string
首启：rawfile/apps.json → sites → currentSite = sites[0]

点桌面图标 → WebAbility.onCreate/onWindowStageCreate
           → 读 currentSite → WebShell 全屏 loadUrl

长按图标 → "站点管理" → ConsoleAbility（原生列表）
  ├ 点某站点 → startAbility(WebAbility, parameters:{siteId}) → onNewWant → 换 URL
  ├ 新增/编辑/删除 → 写 Preferences（零重建）
  ├ 强刷 → 清该 origin 的存储 + Cookie/Cache + reload
  └ 设为当前 → currentSite = id
```

站点 JSON 结构（`Site`）：

```ts
interface Site { id: string; title: string; url: string; icon?: string }
```

图标抓取：加载页面后在 `onPageEnd` 里 `runJavaScript` 读 `document.querySelector('link[rel~="icon"]')?.href` + `document.title`，回填控制台。首次添加时也可先存 URL + 域名占位图标。

## 4. 关键 API 映射（API 26 已核实）

| 需求 | 实现 | 位置 |
|---|---|---|
| 全屏布局 | `windowStage.getMainWindow()` → `setWindowLayoutFullScreen(true)` | `@ohos.window.d.ts:4546` |
| 隐藏状态栏/导航栏 | `setWindowSystemBarEnable([])`，或 `setSpecificSystemBarEnabled('status'/'navigationIndicator', false)` | `:4631` / `:4657` |
| 内容进安全区 | `expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])` | `common.d.ts:17204+` |
| 顶部进度 | `Web().onProgressChange(e => progress = e.newProgress)` | `web.d.ts:6259` |
| 闪屏撤除 | `onFirstContentfulPaint`（`:7167`）优先，`onPageEnd`（`:6198`）兜底 | `web.d.ts` |
| 错误页 | `onErrorReceive`（`:6409`）+ `onHttpErrorReceive`（`:6423`） | `web.d.ts` |
| 侧滑返回 | `UIAbility.onBackPressed(): boolean` → controller 可后退则后退出并 return true | `UIAbility.d.ts:737` |
| 后退判定 | `accessBackward()` / `backward()` | `@ohos.web.webview.d.ts:2878/2915` |
| 上传 | `Web().onShowFileSelector(cb)` → `FilePicker`/`photoAccessHelper` → `result.handleFileList(...)` | `web.d.ts:6508` |
| Cookie 持久化 | 默认即持久（应用级 Cookie 库），可选 `WebCookieManager` 读写 | `@ohos.web.webview.d.ts:1075/1124` |
| 强刷/清数据 | `WebStorage.deleteOrigin(origin)`、`controller.clearHistory()`、`controller.refresh()`、重新 `loadUrl` | `:763` / `:2926` / `:2964` / `:3021` |
| 断网检测 | `@ohos.net.connection` 查默认网络，配合 `onErrorReceive` 的 `errorCode`（-2/-6/-5 等） | — |
| 调试 | `setWebDebuggingAccess(true)`（debug 构建），DevTools 走 `chrome://inspect` | `:2833` |

## 5. 实现要点

1. **闪屏**：`WebShell` 用 `Stack{ Web; Stack{icon,title,url}.opacity(splashOpacity) }`，`aboutToAppear` 即显示，首帧后 200ms 淡出。不设人为延时，不做 `setTimeout(1500)` 之类。
2. **白屏防护**：Web 组件背景色设成站点主题色/深色，闪屏层常驻到首帧回调。
3. **侧滑返回**：`onBackPressed` 里同步判断 `accessBackward()`；`backward()` 后返回 true。首页时返回 false 让系统退出 app。注意：进度条/错误页状态优先消费返回键。
4. **旋转**：`orientation: "auto_rotation"`；`Web` 组件尺寸用百分比，不要在 `onAreaChange` 里 `reload`。
5. **上传**：`onShowFileSelector` 返回 `false` 才走系统默认；自己实现时接受 `result.resultCode = 0` 并调用 `result.handleFileList([uri])`。Pura 70 用 `photoAccessHelper.PhotoViewPicker` 取图片/文件。
6. **多站点隔离**：Cookie 按域名共享（内核行为），接受；`incognitoMode` 不能按标签开（Web 组件级的），不采用。
7. **IPv6 仅 AAAA**：不做特殊处理，依赖系统 DNS/双栈；`cleartextTraffic` 保持默认 false（全 https）。错误页里把"当前网络是否有 IPv6"作为诊断项展示。
8. **控制台校验参数**：`onNewWant(want)` 读 `want.parameters.siteId`；需要 `want.parameters` 是 `Record<string, Object>`，取值 `as string`。
9. **签名**：首次在 IDE File → Project Structure → Signing Configs 勾自动签名，生成 `.ohos/config` 调试证书；之后 CLI 复用，`hdc install -r`。

## 6. 关于 Service Worker / PWA（修正）

- ArkWeb 内核为 Chromium 系（M114/M132），**支持 Service Worker 与 Cache API**：站点自身注册了 SW 就有离线缓存能力（这就是用户说的"安装"）。
- **不支持** PWA 安装流程：无 `beforeinstallprompt`、无 manifest 驱动图标、无 OHOS 侧 API 管理 SW；配额由内核管理，可能被系统回收。
- 因此产品上不承诺"离线可用"；靠站点自身 SW + HTTP 缓存，管理页提供"清数据/强刷"兜底。
- 系统"坚盾守护模式"会禁用 SW（与 wapp 无关，提示即可）。

## 7. 目录结构

```text
wapp/
├─ AppScope/
│  ├─ app.json5
│  └─ resources/base/{element/string.json, media/app_icon.png}
├─ build-profile.json5          # signingConfigs / products / targets
├─ hvigorfile.ts
├─ oh-package.json5
├─ entry/
│  ├─ build-profile.json5
│  ├─ hvigorfile.ts
│  ├─ oh-package.json5
│  └─ src/main/
│     ├─ module.json5
│     ├─ ets/
│     │  ├─ entryability/WebAbility.ets
│     │  ├─ consoleability/ConsoleAbility.ets
│     │  ├─ pages/WebShell.ets        # 全屏 + 闪屏 + 进度 + 错误页
│     │  ├─ pages/Console.ets         # 站点列表/编辑
│     │  ├─ model/Site.ets
│     │  ├─ model/SiteStore.ets       # Preferences 读写
│     │  └─ common/Net.ets
│     └─ resources/
│        ├─ base/{element,media,profile/main_pages.json}
│        └─ rawfile/apps.json
├─ scripts/{build.sh,install.sh,logs.sh}
└─ docs/
```

## 8. 里程碑

| M | 内容 | 验收 |
|---|---|---|
| M0 | 工程骨架（AppScope/build-profile/entry/module.json5/空页面） | `assembleHap` exit 0，装到设备能启动 |
| M1 | 单站点全屏壳：沉浸 + 闪屏 + 进度 + 错误页 + 返回 + 旋转 + Cookie + 上传 | 手工验收清单 1–12 中与单站点相关的项 |
| M2 | ConsoleAbility + shortcuts + 站点 CRUD/切换（onNewWant） | 长按出现"站点管理"，添加站点后点开可用，无重建 |
| M3 | 强刷/清数据/诊断 + 多站点回归 | 验收清单全绿 |
| M4 | 打磨：图标抓取、排序、UA、错误页文案 | — |

## 9. 已知风险

| 风险 | 影响 | 对策 |
|---|---|---|
| 长按菜单并非所有桌面版本都展示 shortcuts | 控制台不可达 | 已用 metadata + shortcuts_config.json 打包成功；装机实测长按是否出现；不出现则用 `setShortcutVisibleForSelf` 校验，极端情况再加软入口（会破 D2，需用户同意） |
| 内核版本随系统 | 新 CSS/JS 不可用 | 页面按 M114+ 基线写；UA 可伪装 |
| SW 配额被回收 | 离线缓存丢失 | 明确不承诺离线 |
| 侧滑与网页手势冲突 | 误退出 | 只在 `accessBackward()` 为 true 时消费 |

## 10. 构建/装机命令

```bash
DEV="/c/Program Files/Huawei/DevEco Studio"
export DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'   # 必设，否则 00303217
export PATH="$DEV/jbr/bin:$PATH"                                        # PackageHap 内 spawn java，需 JBR 的 java
"$DEV/tools/node/node.exe" "$DEV/tools/hvigor/bin/hvigorw.js" \
  assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
"$DEV/sdk/default/openharmony/toolchains/hdc.exe" install -r \
  entry/build/default/outputs/default/entry-default-signed.hap
"$DEV/sdk/default/openharmony/toolchains/hdc.exe" shell aa start -a WebAbility -b com.xazh.wapp
"$DEV/sdk/default/openharmony/toolchains/hdc.exe" hilog | grep -i wapp
```

实测结论（2026-11-16，Windows 侧，已跑通）：

- `assembleHap` BUILD SUCCESSFUL，产物 `entry/build/default/outputs/default/entry-default-unsigned.hap`（约 132 KB）。工程模板取自 `.../plugins/codegenie-plugin/previewProjectTemplate`。
- `compatibleSdkVersion` / `targetSdkVersion` 必须写 `"26.0.0"`：写 `"26"` 报 `00308018 api version parameter is illegal`，写 `"26.0.0(26)"` 报 `00306042 ... must be a string (for example, '26.0.0')`。
- `signingConfigs` 目前为空 → 只出 unsigned HAP（日志 `Will skip sign 'hos_hap'`）。真机 `hdc install` 需签名，**首次须在 DevEco Studio 登录华为账号并勾自动签名**（File → Project Structure → Signing Configs → Automatically generate signature；手机 USB 连接 + 开调试）。之后 CLI 复用 `%USERPROFILE%\.ohos\config\` 下的证书/profile，可纯命令行构建装机。
- hvigor 要写 `%USERPROFILE%\.hvigor`（装 pnpm、软链 `tools\hvigor`）与 `%TEMP%`：受限沙箱下必失败（EPERM symlink 等），所以构建必须在 danger-full-access 会话里跑；别把 `HVIGOR_USER_HOME` 指到工程内。
- 签名用 DevEco 自带 JBR（`.../jbr/bin/java.exe`，OpenJDK 25.0.2），系统无独立 JDK 也能构建。
