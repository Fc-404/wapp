# wapp

把网页变成原生鸿蒙应用。基于 ArkWeb 的全屏 WebView 壳，**没有任何浏览器 UI**：没有地址栏、没有标签页、没有工具栏——打开就是一个全屏的网页，像原生 App 一样。

> 类似 Tauri / Capacitor 的思路，但只针对 HarmonyOS：一个桌面图标，长按图标里的「站点管理」可以增删和切换站点。

## 功能

- **单桌面图标**：应用内不提供任何功能栏，进入即全屏网页
- **隐藏控制台**：长按桌面图标 →「站点管理」进入；控制台里可添加/编辑/删除/拖动排序站点，添加时自动抓取网页标题与 favicon
- **沉浸显示**：默认保留状态栏；网页主动 `requestFullscreen` 时才真全屏；状态栏与底部手势条跟随网页主题色（优先 `meta[name=theme-color]`，其次实际底色），并带系统栏安全区留白
- **多站点**：站点数据存 Preferences，首启从 `rawfile/sites.json` 导入；切换站点无需重新打包
- **强刷 / 清缓存**：长按站点卡片 → 强刷（清该站点缓存并重载）或清缓存
- **IPv6-only 站点支持**：系统解析器只查 A 记录时，遇到 `ERR_NAME_NOT_RESOLVED` 会自动用 DoH 解析 AAAA，再 `connection.addCustomDnsRule` 注册应用级解析结果后重载
- **HTTP 401**：自绘登录卡片（ArkWeb 不会自己弹框），凭据按 host 持久化，之后自动登录
- **断网页**：页面不可达时显示蒙版，可直接进入站点管理或重试
- **启动页面**：可选「首页」或「上次停留的页面」
- **跟随系统旋转**；系统返回手势接入网页历史

## 架构

```
entry/src/main/ets/
├── entryability/WebAbility.ets      # 桌面图标入口：全屏 WebView（读当前站点）
├── consoleability/ConsoleAbility.ets# 隐藏控制台入口：无桌面图标，仅从快捷方式进入
├── pages/WebShell.ets               # 网页壳：加载、闪屏、进度条、主题色、断网页、登录框
├── pages/Console.ets                # 站点管理：网格、拖动排序、设置弹层
├── model/Site.ets                   # Site 类型、URL 归一化、DoH 响应解析
└── model/SiteStore.ets              # Preferences 持久化（站点 / 当前站点 / 启动模式 / 登录凭据）
```

- 桌面长按菜单来自 `entry/src/main/resources/base/profile/shortcuts_config.json`，通过 `WebAbility` 的 `metadata.ohos.ability.shortcuts` 挂载，`wants[].parameters` 不能传复杂对象但 `ConsoleAbility` 一个入口就够
- 站点切换走 `startAbility` 携带 `parameters.siteId` → `WebAbility.onNewWant`；不带 `siteId` 的 want（例如从桌面点回来）不会重载页面

## 环境要求

- DevEco Studio 26（本仓库在 26.0.0.851 + hvigor 6.26.8 上验证）
- HarmonyOS SDK API 26（`compatibleSdkVersion` / `targetSdkVersion` 均为 `26.0.0`）
- 真机验证：HUAWEI Pura 70（HarmonyOS 6.0.0 / API 26）

DevEco Studio 没有 Linux 版，构建必须在 Windows 或 macOS 上进行；Linux 侧只有 command-line-tools，没有 IDE/模拟器。

## 构建与安装

1. 用 DevEco Studio 打开本目录，登录华为账号后在 File → Project Structure → Signing Configs 里勾选 **Automatically generate signature**，生成调试证书
2. 把生成的签名块保存到 `.signing/signing.json5`（该目录已被 `.gitignore` 忽略，不会进版本库）：

   ```json5
   {
     "signingConfigs": [
       {
         "name": "default",
         "type": "HarmonyOS",
         "material": {
           "certpath": "C:\\Users\\<you>\\.ohos\\config\\xxx.cer",
           "keyAlias": "debugKey",
           "keyPassword": "<DevEco 生成的加密串>",
           "profile": "C:\\Users\\<you>\\.ohos\\config\\xxx.p7b",
           "signAlg": "SHA256withECDSA",
           "storeFile": "C:\\Users\\<you>\\.ohos\\config\\xxx.p12",
           "storePassword": "<DevEco 生成的加密串>"
         }
       }
     ]
   }
   ```

3. 构建、装机、看日志：

   ```bash
   scripts/build.sh                                   # 默认 debug assembleHap
   scripts/build.sh assembleHap --mode module -p product=default -p buildMode=release
   scripts/deploy.sh                                  # 构建 + 安装 + 启动
   hdc hilog | grep wapp
   ```

`scripts/build.sh` 会在构建前把 `.signing/signing.json5` 临时合入 `build-profile.json5`，构建结束自动还原；没有该文件时会以未签名方式构建（可产出 `entry-default-unsigned.hap`）。

> 构建时的两个坑已经写进脚本：必须设置 `DEVECO_SDK_HOME`，且 `PackageHap` 阶段需要 **Windows 形式**的 `JAVA_HOME`/`PATH`（否则报 `spawn java ENOENT`）。

## 已知限制

- ArkWeb 内核随系统版本走，不能假设桌面 Chrome 的新特性
- `webview.WebviewController.setHttpDns` 在这版内核里不生效，且调用会导致原生崩溃（`SIGSEGV`），因此没有使用；IPv6 支持走 DoH + `addCustomDnsRule` 的应用级方案
- 登录凭据以明文存于应用 Preferences（仅本机、仅本应用可读），目前没有加密

## 目录

```
AppScope/            应用级配置与图标（分层图标）
entry/               模块代码、资源、快捷方式配置
docs/                requirements.md / tech-stack.md / icon.png
scripts/             build.sh、deploy.sh、签名合并脚本
```
