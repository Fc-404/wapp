import { webview } from '@kit.ArkWeb';
import { window, KeyboardAvoidMode } from '@kit.ArkUI';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { http, socket, connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Site, hostOf, extractAll } from '../model/Site';
import { SiteStore, START_HISTORY, AuthCred } from '../model/SiteStore';

const DOMAIN = 0x0102;
const TAG = 'wapp';
const FALLBACK_BG: string = '#0E1116';
const SYS_BG: ResourceColor = $r('sys.color.background_primary');
const SYS_BG_SUB: ResourceColor = $r('sys.color.background_secondary');
const SYS_TEXT: ResourceColor = $r('sys.color.font_primary');
const SYS_TEXT_SUB: ResourceColor = $r('sys.color.font_secondary');
const THEME_COLOR: string = '#3E7BFA';

/**
 * 页面主题色探测：优先 meta[name=theme-color]，否则用 body/html 实际底色；
 * 用 MutationObserver 跟踪 SPA/暗色模式切换，变化时回调 ArkTS。
 */
const THEME_PROBE_JS: string = `
(function () {
  if (window.__wappThemeHooked) { window.__wappThemePush(); return; }
  window.__wappThemeHooked = true;

  function toHex(c) {
    if (!c) return '';
    c = c.trim().toLowerCase();
    if (c.charAt(0) === '#') {
      if (c.length === 4) return '#' + c[1] + c[1] + c[2] + c[2] + c[3] + c[3];
      if (c.length === 7 || c.length === 9) return c.substring(0, 7);
      return '';
    }
    var m = c.match(/^rgba?\\\\(([^)]+)\\\\)$/);
    if (!m) return '';
    var p = m[1].split(',').map(function (x) { return parseFloat(x); });
    if (p.length >= 4 && p[3] < 0.5) return '';
    function h(n) { var s = Math.max(0, Math.min(255, Math.round(n))).toString(16); return s.length < 2 ? '0' + s : s; }
    return '#' + h(p[0]) + h(p[1]) + h(p[2]);
  }

  function pick() {
    var m = document.querySelector('meta[name="theme-color"]');
    var c = m && m.content ? toHex(m.content) : '';
    if (c) return c;
    var el = document.body;
    if (el) { c = toHex(getComputedStyle(el).backgroundColor); if (c) return c; }
    el = document.documentElement;
    if (el) { c = toHex(getComputedStyle(el).backgroundColor); if (c) return c; }
    var dark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
    return dark ? '#000000' : '#FFFFFF';
  }

  window.__wappThemePush = function () {
    try {
      if (window.wappTheme && window.wappTheme.applyTheme) window.wappTheme.applyTheme(pick());
    } catch (e) {}
  };

  window.__wappThemePush();

  var mo = new MutationObserver(function () { window.__wappThemePush(); });
  mo.observe(document.documentElement, { attributes: true, attributeFilter: ['style', 'class', 'data-theme', 'data-color-mode'] });
  if (document.head) mo.observe(document.head, { childList: true, subtree: true, attributes: true, attributeFilter: ['content', 'href'] });
  if (document.body) mo.observe(document.body, { attributes: true, attributeFilter: ['style', 'class', 'data-theme'] });
  try {
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', window.__wappThemePush);
  } catch (e) {}
})();
`;

class ThemeBridge {
  private onColor: (color: string) => void;

  constructor(onColor: (color: string) => void) {
    this.onColor = onColor;
  }

  applyTheme(color: string): void {
    this.onColor(color);
  }
}

/** '#RRGGBB' → 相对亮度 0..1；解析失败返回 -1 */
function luminance(hex: string): number {
  if (hex.length !== 7 || hex.charAt(0) !== '#') {
    return -1;
  }
  const r = parseInt(hex.substring(1, 3), 16);
  const g = parseInt(hex.substring(3, 5), 16);
  const b = parseInt(hex.substring(5, 7), 16);
  if (isNaN(r) || isNaN(g) || isNaN(b)) {
    return -1;
  }
  return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
}

@Entry
@Component
struct WebShell {
  private controller: webview.WebviewController = new webview.WebviewController();
  private siteId: string = '';
  private homeUrl: string = '';
  private bridge: ThemeBridge = new ThemeBridge((color: string) => this.applyTheme(color));
  @State url: string = '';
  @State title: string = 'wapp';
  @State icon: string = '';
  @State progress: number = 0;
  @State loading: boolean = true;
  @State showSplash: boolean = true;
  @State errorText: string = '';
  @State offline: boolean = false;
  @State reachNote: string = '';
  @State safeTop: number = 0;
  @State safeBottom: number = 0;
  @State showAuth: boolean = false;
  private dnsRepaired: boolean = false;
  @State authUser: string = '';
  @State authPass: string = '';
  @State authHost: string = '';
  @State bgColor: string = '#FFFFFF';
  private lastTheme: string = '';
  private authHandler: HttpAuthHandler | undefined = undefined;
  private started: boolean = false;

  aboutToAppear(): void {
    this.loadSite();
    this.measureSafeTop();
    // 键盘弹出时压缩页面（默认 OFFSET 在 Web 上不会滚动到输入框，表现为"点输入框没反应"）
    try {
      this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'setKeyboardAvoidMode failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 状态栏高度：网页内容要退到状态栏下方，但背景仍要铺满（沉浸） */
  private async measureSafeTop(): Promise<void> {
    try {
      const win = await window.getLastWindow(this.ctx());
      const area = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      this.safeTop = px2vp(area.topRect.height);
      let bottom = area.bottomRect.height;
      try {
        const indicator = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        if (indicator.bottomRect.height > bottom) {
          bottom = indicator.bottomRect.height;
        }
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'measure navigation indicator failed');
      }
      this.safeBottom = px2vp(bottom);
      hilog.info(DOMAIN, TAG, 'safeTop=%{public}s safeBottom=%{public}s',
        String(this.safeTop), String(this.safeBottom));
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'measureSafeTop failed: %{public}s', JSON.stringify(e));
    }
  }

  private ctx(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  private async loadSite(): Promise<void> {
    if (this.started) {
      return;
    }
    this.started = true;
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const site: Site | undefined = await SiteStore.current(ctx);
      if (site === undefined) {
        this.errorText = '还没有配置任何站点';
        return;
      }
      this.siteId = site.id;
      this.title = site.title;
      this.icon = site.icon;
      this.homeUrl = site.url;
      let target = site.url;
      const mode = await SiteStore.startMode(ctx);
      if (mode === START_HISTORY) {
        const last = await SiteStore.lastUrl(ctx, site.id);
        if (last.length > 0) {
          target = last;
        }
      }
      this.url = target;
      hilog.info(DOMAIN, TAG, 'load site: %{public}s %{public}s', site.title, site.url);
    } catch (e) {
      this.errorText = '读取站点失败';
      hilog.error(DOMAIN, TAG, 'loadSite failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 把状态栏/导航条染成网页底色，并按亮度选白/黑图标 */
  private applyTheme(color: string): void {
    if (!color || color === this.lastTheme) {
      return;
    }
    const lum = luminance(color);
    if (lum < 0) {
      return;
    }
    this.lastTheme = color;
    this.bgColor = color;
    const fg = lum > 0.6 ? '#000000' : '#FFFFFF';
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const win: window.Window = ctx.windowStage.getMainWindowSync();
      win.setWindowBackgroundColor(color);
      win.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        statusBarContentColor: fg,
        navigationBarColor: '#00000000',
        navigationBarContentColor: fg
      }).catch((e: Error) => {
        hilog.warn(DOMAIN, TAG, 'applyTheme failed: %{public}s', e.message);
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'applyTheme error: %{public}s', JSON.stringify(e));
    }
  }

  /** 网页 requestFullscreen 时进入真全屏；退出时恢复状态栏。默认不做全屏。 */
  private setImmersive(on: boolean): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const win: window.Window = ctx.windowStage.getMainWindowSync();
      if (on) {
        win.setWindowLayoutFullScreen(true);
        win.setWindowSystemBarEnable([]).catch((e: Error) => {
          hilog.warn(DOMAIN, TAG, 'hide system bar failed: %{public}s', e.message);
        });
      } else {
        win.setWindowLayoutFullScreen(false);
        win.setWindowSystemBarEnable(['status', 'navigation']).catch((e: Error) => {
          hilog.warn(DOMAIN, TAG, 'show system bar failed: %{public}s', e.message);
        });
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'immersive switch failed: %{public}s', JSON.stringify(e));
    }
  }

  private probeTheme(): void {
    this.controller.runJavaScript(THEME_PROBE_JS);
  }

  private retry(): void {
    this.errorText = '';
    this.reachNote = '';
    this.offline = false;
    this.lastTheme = '';
    this.url = this.homeUrl;
    this.controller.loadUrl(this.homeUrl);
  }

  /** 用系统网络栈再试一次，用来区分「网络不通」还是「ArkWeb 解析/连接失败」 */
  private async checkReachability(): Promise<void> {
    const req = http.createHttp();
    try {
      const res = await req.request(this.homeUrl, {
        method: http.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: 8000,
        usingCache: false
      });
      hilog.info(DOMAIN, TAG, 'reachability probe: code=%{public}d', res.responseCode);
      this.reachNote = '网络是通的，但页面没能打开';
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'reachability probe failed: %{public}s', JSON.stringify(e));
      this.reachNote = '网络似乎不可用，请检查 Wi-Fi / 移动数据';
      this.logNetDns();
    } finally {
      req.destroy();
    }
  }

  /** 打印系统 DNS 配置：判断系统是否拿到了 IPv6 DNS 服务器 */
  private logNetDns(): void {
    try {
      const net = connection.getDefaultNetSync();
      const props = connection.getConnectionPropertiesSync(net);
      const caps = connection.getNetCapabilitiesSync(net);
      hilog.info(DOMAIN, TAG, 'caps: %{public}s', JSON.stringify(caps.networkCap));
      hilog.info(DOMAIN, TAG, 'netif=%{public}s dnsCount=%{public}d',
        props.interfaceName, props.dnses.length);
      for (let i = 0; i < props.dnses.length; i++) {
        hilog.info(DOMAIN, TAG, 'dns: %{public}s family=%{public}d',
          props.dnses[i].address, props.dnses[i].family);
      }
      for (let i = 0; i < props.linkAddresses.length; i++) {
        hilog.info(DOMAIN, TAG, 'link: %{public}s/%{public}d',
          props.linkAddresses[i].address.address, props.linkAddresses[i].prefixLength);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'logNetDns failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 通过 DoH 解析域名，返回地址列表（type: 'A' / 'AAAA'） */
  private async dohAddresses(host: string, type: string): Promise<string[]> {
    const req = http.createHttp();
    try {
      const res = await req.request(`https://doh.pub/dns-query?name=${host}&type=${type}`,
        {
          method: http.RequestMethod.GET,
          header: { 'Accept': 'application/dns-json' },
          connectTimeout: 6000,
          readTimeout: 6000
        });
      const list = extractAll(String(res.result));
      hilog.info(DOMAIN, TAG, 'doh %{public}s -> %{public}s', type, JSON.stringify(list));
      return list;
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'doh failed: %{public}s', JSON.stringify(e));
      return [];
    } finally {
      req.destroy();
    }
  }

  /**
   * 系统解析器只会查 A 记录（路由器没下发 IPv6 DNS 时更明显），
   * 只有 AAAA 的域名在这里必然 ERR_NAME_NOT_RESOLVED。
   * 解法：自己用 DoH 解析，再把结果注册成应用级 DNS 覆写，然后重载。
   */
  private async repairDns(): Promise<void> {
    const host = hostOf(this.url);
    if (host.length === 0) {
      this.offline = true;
      return;
    }
    let ips = await this.dohAddresses(host, 'AAAA');
    if (ips.length === 0) {
      ips = await this.dohAddresses(host, 'A');
    }
    if (ips.length === 0) {
      hilog.error(DOMAIN, TAG, 'dns repair failed: no record for %{public}s', host);
      this.offline = true;
      this.reachNote = '域名没有任何解析记录';
      return;
    }
    try {
      await connection.addCustomDnsRule(host, ips);
      hilog.info(DOMAIN, TAG, 'dns rule added: %{public}s -> %{public}s', host, JSON.stringify(ips));
      this.offline = false;
      this.showSplash = true;
      this.controller.loadUrl(this.url);
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'addCustomDnsRule failed: %{public}s', JSON.stringify(e));
      this.offline = true;
    }
  }

  /** 应用自身能否走 IPv6 建连（绕过系统解析器，直连 DoH 拿到的地址） */
  private async ipv6TcpTest(addr: string): Promise<void> {
    const tcp = socket.constructTCPSocketInstance();
    try {
      await tcp.connect({
        address: { address: addr, family: 2, port: 443 },
        timeout: 6000
      });
      hilog.info(DOMAIN, TAG, 'ipv6 tcp ok: %{public}s', addr);
      this.reachNote = '应用能走 IPv6，但内核没用上这条记录';
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'ipv6 tcp failed: %{public}s %{public}s', addr, JSON.stringify(e));
      this.reachNote = '应用连不上这个 IPv6 地址';
    } finally {
      try {
        tcp.close();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'close socket failed');
      }
    }
  }

  /** HTTP 401 认证：ArkWeb 默认不弹输入框，必须自己接管，否则用户看不到任何登录入口 */
  @Builder
  authSheet() {
    Column({ space: 14 }) {
      Text('需要登录')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(SYS_TEXT)
        .width('100%')
      Text(this.authHost)
        .fontSize(13)
        .fontColor(SYS_TEXT_SUB)
        .width('100%')
      TextInput({ placeholder: '用户名' })
        .height(46)
        .borderRadius(12)
        .backgroundColor('#0D000000')
        .onChange((v: string) => {
          this.authUser = v;
        })
      TextInput({ placeholder: '密码' })
        .type(InputType.Password)
        .height(46)
        .borderRadius(12)
        .backgroundColor('#0D000000')
        .onChange((v: string) => {
          this.authPass = v;
        })
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .height(44)
          .backgroundColor('#14000000')
          .fontColor(SYS_TEXT)
          .onClick(() => {
            const h = this.authHandler;
            this.authHandler = undefined;
            this.showAuth = false;
            if (h !== undefined) {
              h.cancel();
            }
          })
        Button('登录')
          .layoutWeight(1)
          .height(44)
          .backgroundColor(THEME_COLOR)
          .fontColor('#FFFFFF')
          .onClick(() => {
            const h = this.authHandler;
            this.authHandler = undefined;
            this.showAuth = false;
            if (h !== undefined) {
              h.confirm(this.authUser, this.authPass);
            }
            SiteStore.setAuth(this.ctx(), this.authHost, this.authUser, this.authPass).then(() => {
              hilog.info(DOMAIN, TAG, 'auth saved for %{public}s', this.authHost);
            }).catch((e: Error) => {
              hilog.warn(DOMAIN, TAG, 'save auth failed: %{public}s', e.message);
            });
          })
      }
      .width('100%')
    }
    .width('86%')
    .padding(20)
    .borderRadius(22)
    .backgroundColor('#F7FFFFFF')
    .backgroundBlurStyle(BlurStyle.Thick)
    .shadow({ radius: 30, color: '#26000000', offsetY: 12 })
  }

  /** 打不开时进入站点管理面板，换站点或改配置 */
  private openConsole(): void {
    this.ctx().startAbility({
      bundleName: 'com.xazh.wapp',
      abilityName: 'ConsoleAbility'
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'open console failed: %{public}s', e.message);
    });
  }

  private goBack(): void {
    try {
      if (this.controller.accessBackward()) {
        this.controller.backward();
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'backward failed');
    }
  }

  onBackPress(): boolean {
    // 断网页：返回直接退出应用
    if (this.offline) {
      return false;
    }
    try {
      if (this.controller.accessBackward()) {
        this.controller.backward();
        return true;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'accessBackward failed');
    }
    return false;
  }

  @Builder
  splashContent() {
    Column({ space: 16 }) {
      if (this.icon.length > 0) {
        Image(this.icon)
          .width(72)
          .height(72)
          .borderRadius(18)
          .objectFit(ImageFit.Contain)
          .alt($r('app.media.startIcon'))
      } else {
        Text(this.title.length > 0 ? this.title.substring(0, 1).toUpperCase() : 'W')
          .width(72)
          .height(72)
          .borderRadius(18)
          .backgroundColor(SYS_BG_SUB)
          .fontSize(32)
          .fontColor(SYS_TEXT)
          .textAlign(TextAlign.Center)
      }
      Text(this.title)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(SYS_TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(hostOf(this.url))
        .fontSize(12)
        .fontColor(SYS_TEXT_SUB)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      LoadingProgress()
        .width(26)
        .height(26)
        .color(THEME_COLOR)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 40, right: 40 })
    .justifyContent(FlexAlign.Center)
    .backgroundColor(SYS_BG)
  }

  /** 断网 / 打不开时的蒙版：浅色就浅色、深色就深色，图标与文案用红色 */
  @Builder
  offlineMask() {
    Column({ space: 14 }) {
      SymbolGlyph($r('sys.symbol.wifi_slash'))
        .fontSize(44)
        .fontColor(['#E84026'])
      Text('页面不可达')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor('#E84026')
      Text(hostOf(this.url))
        .fontSize(13)
        .fontColor(SYS_TEXT_SUB)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.reachNote.length > 0) {
        Text(this.reachNote)
          .fontSize(12)
          .fontColor(SYS_TEXT_SUB)
          .textAlign(TextAlign.Center)
      }
      Button('站点管理')
        .fontSize(16)
        .height(44)
        .padding({ left: 32, right: 32 })
        .margin({ top: 10 })
        .backgroundColor(THEME_COLOR)
        .fontColor('#FFFFFF')
        .onClick(() => this.openConsole())
      Text('重试')
        .fontSize(14)
        .fontColor(THEME_COLOR)
        .padding({ top: 4, bottom: 4, left: 12, right: 12 })
        .onClick(() => this.retry())
    }
    .width('100%')
    .height('100%')
    .padding({ left: 40, right: 40 })
    .justifyContent(FlexAlign.Center)
    .backgroundColor(SYS_BG)
  }

  /** 断网页跟随系统深浅色设置状态栏图标颜色 */
  private async syncBars(): Promise<void> {
    try {
      const ctx = this.ctx();
      const dark = ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      const win = await window.getLastWindow(ctx);
      await win.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        statusBarContentColor: dark ? '#FFFFFF' : '#000000',
        navigationBarColor: '#00000000',
        navigationBarContentColor: dark ? '#FFFFFF' : '#000000'
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'syncBars failed');
    }
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      if (this.url.length > 0) {
        Column() {
          Web({ src: this.url, controller: this.controller })
          .width('100%')
          .layoutWeight(1)
          .backgroundColor(SYS_BG)
          .domStorageAccess(true)
          .javaScriptAccess(true)
          .javaScriptProxy({
            object: this.bridge,
            name: 'wappTheme',
            methodList: ['applyTheme'],
            controller: this.controller
          })
          .onProgressChange((e) => {
            this.progress = e.newProgress;
            if (e.newProgress >= 100) {
              this.loading = false;
            }
          })
          .onPageBegin(() => {
            this.loading = true;
            this.showSplash = true;
            this.errorText = '';
            this.offline = false;
          })
          .onFirstContentfulPaint(() => {
            this.showSplash = false;
            if (!this.offline) {
              this.probeTheme();
            }
          })
          .onPageEnd(() => {
            this.showSplash = false;
            this.loading = false;
            this.progress = 100;
            if (!this.offline) {
              this.probeTheme();
            }
            const cur = this.controller.getUrl();
            hilog.info(DOMAIN, TAG, 'page end: %{public}s', cur);
            if (this.siteId.length > 0 && cur.length > 0 && cur.indexOf('http') === 0) {
              SiteStore.setLastUrl(this.ctx(), this.siteId, cur);
            }
          })
          .onErrorReceive((e) => {
            if (e.error.getErrorCode() === 0) {
              return;
            }
            hilog.error(DOMAIN, TAG, 'web error: %{public}s code=%{public}d url=%{public}s',
              e.error.getErrorInfo(), e.error.getErrorCode(), e.request.getRequestUrl());
            if (!e.request.isMainFrame()) {
              return;
            }
            if (e.error.getErrorCode() === -105 && !this.dnsRepaired) {
              this.dnsRepaired = true;
              this.repairDns();
              return;
            }
            this.showSplash = false;
            this.loading = false;
            this.errorText = e.error.getErrorInfo();
            this.offline = true;
            this.reachNote = '';
            this.syncBars();
            this.checkReachability();
          })
          .onHttpAuthRequest((e) => {
            hilog.info(DOMAIN, TAG, 'http auth request: %{public}s', e.host);
            const handler = e.handler;
            const host = e.host;
            SiteStore.auth(this.ctx(), host).then((cred: AuthCred | undefined) => {
              if (cred !== undefined && cred.user.length > 0) {
                hilog.info(DOMAIN, TAG, 'http auth reuse saved credential for %{public}s', host);
                handler.confirm(cred.user, cred.pass);
                return;
              }
              this.authHandler = handler;
              this.authHost = host;
              this.authUser = '';
              this.authPass = '';
              this.showAuth = true;
            }).catch(() => {
              this.authHandler = handler;
              this.authHost = host;
              this.authUser = '';
              this.authPass = '';
              this.showAuth = true;
            });
            return true;
          })
          .onFullScreenEnter(() => {
            hilog.info(DOMAIN, TAG, 'web fullscreen enter');
            this.setImmersive(true);
          })
          .onFullScreenExit(() => {
            hilog.info(DOMAIN, TAG, 'web fullscreen exit');
            this.setImmersive(false);
          })
        }
        .width('100%')
        .height('100%')
        .padding({ top: this.safeTop, bottom: this.safeBottom * 0.45 })
        .backgroundColor(this.bgColor)
      }

      if (this.loading && this.progress < 100 && this.url.length > 0) {
        Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(3)
          .color(THEME_COLOR)
          .backgroundColor('#00000000')
      }

      if (this.showSplash && this.url.length > 0) {
        this.splashContent()
      }

      if (this.offline && this.url.length > 0) {
        this.offlineMask()
      }

      if (this.showAuth) {
        Stack() {
          this.authSheet()
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#33000000')
        .alignContent(Alignment.Center)
      }


    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}

// 触发 GitHub linguist 重新统计 ArkTS 语言
