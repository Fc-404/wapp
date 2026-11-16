import { common, Want, bundleManager } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { vibrator } from '@kit.SensorServiceKit';
import { promptAction } from '@kit.ArkUI';
import { window } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Site, hostOf, normalizeUrl } from '../model/Site';
import { SiteStore, START_HOME, START_HISTORY } from '../model/SiteStore';

const DOMAIN = 0x0101;
const TAG = 'wapp';
const TEXT_MAIN: string = '#182431';
const TEXT_SUB: string = '#7A8699';
const ACCENT: string = '#0A59F7';
const DANGER: string = '#E5484D';
const CARD_BG: string = '#CCFFFFFF';
const BAR_BG: string = '#D9FFFFFF';
const SHEET_BG: string = '#E6FFFFFF';
const INPUT_BG: string = '#0A000000';
const H_PADDING: number = 20;

interface MetaResult {
  t: string;
  i: string;
}

/** 在待添加页面里读标题和 favicon */
const PROBE_JS: string = `
(function () {
  try {
    var t = document.title || '';
    var l = document.querySelector('link[rel~="icon"]') || document.querySelector('link[rel="apple-touch-icon"]') || document.querySelector('link[rel="shortcut icon"]');
    var href = l && l.href ? l.href : '';
    if (!href || href.indexOf('data:') === 0) href = location.origin + '/favicon.ico';
    return JSON.stringify({ t: t, i: href });
  } catch (e) { return ''; }
})();
`;

function originOf(url: string): string {
  const m = url.match(/^https?:\/\/[^/?#]+/i);
  return m ? m[0] : url;
}

@Entry
@Component
struct Console {
  @State sites: Site[] = [];
  @State editMode: boolean = false;
  @State showSettings: boolean = false;
  @State versionName: string = '-';
  @State apiLevel: string = '-';
  @State startMode: string = START_HOME;
  @State editorVisible: boolean = false;
  @State editorIsNew: boolean = true;
  @State editorId: string = '';
  @State editorUrl: string = '';
  @State editorTitle: string = '';
  @State editorIcon: string = '';
  @State editorHint: string = '';
  @State probeUrl: string = '';
  @State probing: boolean = false;
  @State brokenIcons: string[] = [];
  @State menuSite: Site | undefined = undefined;
  @State menuSiteId: string = '';
  @State askDelete: boolean = false;
  @State deleteTarget: Site | undefined = undefined;
  private pressTimer: number = -1;
  private pressId: string = '';
  private pressX: number = 0;
  private pressY: number = 0;
  private longFired: boolean = false;
  @State safeTop: number = 0;
  @State safeBottom: number = 0;
  private probe: webview.WebviewController = new webview.WebviewController();
  private probeTimer: number = -1;
  private busy: boolean = false;

  aboutToAppear(): void {
    this.reload();
    this.readVersion();
    this.readStartMode();
    this.measureSafeArea();
  }

  private ctx(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  private mainWindow(): window.Window | undefined {
    try {
      return this.ctx().windowStage.getMainWindowSync();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'main window failed: %{public}s', JSON.stringify(e));
      return undefined;
    }
  }

  /** 状态栏 / 手势条高度，用来给内容留白，同时让底色铺满整屏 */
  private measureSafeArea(): void {
    const win = this.mainWindow();
    if (win === undefined) {
      return;
    }
    try {
      const top = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height;
      const bottom = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).bottomRect.height;
      this.safeTop = px2vp(top);
      let bottomPx = bottom;
      try {
        const indicator = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        if (indicator.bottomRect.height > bottomPx) {
          bottomPx = indicator.bottomRect.height;
        }
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'measure navigation indicator failed');
      }
      this.safeBottom = px2vp(bottomPx);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'avoid area failed: %{public}s', JSON.stringify(e));
    }
  }

  private readVersion(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      this.versionName = info.versionName.length > 0 ? info.versionName : '-';
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'bundle info failed: %{public}s', JSON.stringify(e));
      this.versionName = '1.0.0';
    }
    this.apiLevel = String(deviceInfo.sdkApiVersion);
  }

  private async readStartMode(): Promise<void> {
    this.startMode = await SiteStore.startMode(this.ctx());
  }

  private async reload(): Promise<void> {
    this.sites = await SiteStore.list(this.ctx());
  }

  private async switchTo(site: Site): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    hilog.info(DOMAIN, TAG, 'tile tap: %{public}s', site.id);
    try {
      await SiteStore.setCurrentId(this.ctx(), site.id);
      const want: Want = {
        bundleName: 'com.xazh.wapp',
        abilityName: 'WebAbility',
        parameters: { siteId: site.id, force: false }
      };
      await this.ctx().startAbility(want);
      await this.ctx().terminateSelf();
    } catch (e) {
      this.busy = false;
      hilog.error(DOMAIN, TAG, 'switchTo failed: %{public}s', JSON.stringify(e));
      promptAction.showToast({ message: '切换失败' });
    }
  }

  private async hardReload(site: Site): Promise<void> {
    try {
      webview.WebStorage.deleteOrigin(originOf(site.url));
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'deleteOrigin failed: %{public}s', JSON.stringify(e));
    }
    await SiteStore.setLastUrl(this.ctx(), site.id, '');
    const want: Want = {
      bundleName: 'com.xazh.wapp',
      abilityName: 'WebAbility',
      parameters: { siteId: site.id, force: true }
    };
    await this.ctx().startAbility(want);
    await this.ctx().terminateSelf();
  }

  private clearCache(site: Site): void {
    try {
      webview.WebStorage.deleteOrigin(originOf(site.url));
      promptAction.showToast({ message: `已清除 ${hostOf(site.url)} 的缓存` });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'clear cache failed: %{public}s', JSON.stringify(e));
      promptAction.showToast({ message: '清除失败' });
    }
  }

  private openEditor(site: Site | undefined): void {
    this.editorIsNew = site === undefined;
    this.editorId = site === undefined ? '' : site.id;
    this.editorUrl = site === undefined ? '' : site.url;
    this.editorTitle = site === undefined ? '' : site.title;
    this.editorIcon = site === undefined ? '' : site.icon;
    this.editorHint = '';
    this.editorVisible = true;
  }

  private closeEditor(): void {
    this.editorVisible = false;
    this.probeUrl = '';
    this.probing = false;
    this.editorHint = '';
    if (this.probeTimer >= 0) {
      clearTimeout(this.probeTimer);
      this.probeTimer = -1;
    }
  }

  private async saveEditor(): Promise<void> {
    const url = normalizeUrl(this.editorUrl);
    if (url === '') {
      this.editorHint = '先填一个网址';
      return;
    }
    if (this.editorIsNew) {
      if (this.editorTitle.trim() === '') {
        this.startProbe(url);
        return;
      }
      try {
        await SiteStore.add(this.ctx(), url, this.editorTitle.trim(), this.editorIcon);
        this.closeEditor();
        await this.reload();
        promptAction.showToast({ message: '已添加' });
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'add site failed: %{public}s', JSON.stringify(e));
        this.editorHint = '添加失败';
      }
      return;
    }
    const site: Site = {
      id: this.editorId,
      title: this.editorTitle.trim() === '' ? hostOf(url) : this.editorTitle.trim(),
      url: url,
      icon: this.editorIcon
    };
    await SiteStore.update(this.ctx(), site);
    this.closeEditor();
    await this.reload();
  }

  /** 加载一次页面拿标题和图标，最多等 5 秒 */
  private startProbe(url: string): void {
    this.probing = true;
    this.editorHint = '正在读取标题…';
    this.probeUrl = url;
    this.probeTimer = setTimeout(() => {
      if (this.probing) {
        this.finishProbe(url, '', '');
      }
    }, 5000);
  }

  private async onProbePageEnd(): Promise<void> {
    if (!this.probing) {
      return;
    }
    let title = '';
    let icon = '';
    try {
      const res = await this.probe.runJavaScript(PROBE_JS);
      // runJavaScript 会把结果再编码一层字符串，先剥掉
      let text: string = res;
      if (text.length > 1 && text.charAt(0) === '"') {
        text = JSON.parse(text) as string;
      }
      if (text.length > 0) {
        const parsed: MetaResult = JSON.parse(text) as MetaResult;
        title = parsed.t === undefined ? '' : parsed.t;
        icon = parsed.i === undefined ? '' : parsed.i;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'probe failed: %{public}s', String(e));
    }
    this.finishProbe(this.probeUrl, title, icon);
  }

  private async finishProbe(url: string, title: string, icon: string): Promise<void> {
    if (!this.probing) {
      return;
    }
    this.probing = false;
    if (this.probeTimer >= 0) {
      clearTimeout(this.probeTimer);
      this.probeTimer = -1;
    }
    const finalTitle = title.trim() === '' ? hostOf(url) : title.trim();
    try {
      await SiteStore.add(this.ctx(), url, finalTitle, icon);
      this.closeEditor();
      await this.reload();
      promptAction.showToast({ message: `已添加 ${finalTitle}` });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'add site failed: %{public}s', JSON.stringify(e));
      promptAction.showToast({ message: '添加失败' });
    }
  }

  private async doDelete(site: Site): Promise<void> {
    await SiteStore.remove(this.ctx(), site.id);
    await SiteStore.setLastUrl(this.ctx(), site.id, '');
    await this.reload();
  }

  private async persistOrder(list: Site[]): Promise<void> {
    await SiteStore.save(this.ctx(), list);
  }

  private async setStartMode(mode: string): Promise<void> {
    this.startMode = mode;
    await SiteStore.setStartMode(this.ctx(), mode);
  }

  private haptic(): void {
    try {
      vibrator.startVibration({ type: 'time', duration: 18 }, { id: 0, usage: 'touch' });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'vibrate failed');
    }
  }

  @Builder
  siteMenu() {
    Menu() {
      MenuItem({ content: '强刷' })
        .onClick(() => {
          const target = this.menuSite;
          if (target !== undefined) {
            this.hardReload(target);
          }
        })
      MenuItem({ content: '编辑' })
        .onClick(() => {
          const target = this.menuSite;
          if (target !== undefined) {
            this.openEditor(target);
          }
        })
      MenuItem({ content: '删除' })
        .onClick(() => {
          const target = this.menuSite;
          if (target !== undefined) {
            this.deleteTarget = target;
            this.askDelete = true;
          }
        })
    }
    .radius(18)
    .backgroundColor('#F5FFFFFF')
    .padding({ top: 6, bottom: 6 })
  }

  /** 删除确认（自己的卡片，不用 showDialog） */
  @Builder
  deleteDialog() {
    Column({ space: 16 }) {
      Text('删除站点')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_MAIN)
      Text(this.deleteTarget === undefined ? '' : `确定删除「${this.deleteTarget.title}」吗？`)
        .fontSize(14)
        .fontColor(TEXT_SUB)
        .textAlign(TextAlign.Center)
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .backgroundColor('#14000000')
          .fontColor(TEXT_MAIN)
          .onClick(() => {
            this.askDelete = false;
            this.deleteTarget = undefined;
          })
        Button('删除')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .backgroundColor(DANGER)
          .fontColor('#FFFFFF')
          .onClick(() => {
            const target = this.deleteTarget;
            this.askDelete = false;
            this.deleteTarget = undefined;
            if (target !== undefined) {
              this.doDelete(target);
            }
          })
      }
      .width('100%')
    }
    .width('78%')
    .padding(20)
    .borderRadius(22)
    .backgroundColor('#F7FFFFFF')
    .backgroundBlurStyle(BlurStyle.Thick)
    .shadow({ radius: 30, color: '#26000000', offsetY: 12 })
  }

  @Builder
  dragCardPreview(title: string) {
    Text(title)
      .fontSize(13)
      .fontColor(TEXT_MAIN)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .padding(12)
      .backgroundColor('#F2FFFFFF')
      .borderRadius(18)
      .shadow({ radius: 16, color: '#1F000000', offsetY: 8 })
  }

  @Builder
  sheetTitle(title: string) {
    Text(title)
      .fontSize(24)
      .fontWeight(FontWeight.Bold)
      .fontColor(TEXT_MAIN)
      .width('100%')
  }

  @Builder
  rowCard() {
    Column() {
      this.settingsRow($r('sys.symbol.doc_text'), '版本', 'v' + this.versionName + '@API' + this.apiLevel)
      Divider().color('#0D000000').margin({ left: 56, right: 16 })
      Row({ space: 14 }) {
        SymbolGlyph($r('sys.symbol.clock'))
          .fontSize(22)
          .fontColor([TEXT_MAIN])
        Text('启动页面')
          .fontSize(16)
          .fontColor(TEXT_MAIN)
        Blank()
        Select([{ value: '首页' }, { value: '页面历史' }])
          .selected(this.startMode === START_HISTORY ? 1 : 0)
          .value(this.startMode === START_HISTORY ? '页面历史' : '首页')
          .font({ size: 15 })
          .optionFont({ size: 15 })
          .selectedOptionFont({ size: 15 })
          .width(120)
          .onSelect((index: number) => {
            this.setStartMode(index === 0 ? START_HOME : START_HISTORY);
          })
      }
      .width('100%')
      .height(60)
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
    .borderRadius(22)
    .backgroundColor('#99FFFFFF')
    .backgroundBlurStyle(BlurStyle.Thin)
    .clip(true)
  }

  @Builder
  settingsRow(icon: Resource, title: string, value: string) {
    Row({ space: 14 }) {
      SymbolGlyph(icon)
        .fontSize(22)
        .fontColor([TEXT_MAIN])
      Text(title)
        .fontSize(16)
        .fontColor(TEXT_MAIN)
      Blank()
      Text(value)
        .fontSize(15)
        .fontColor(TEXT_SUB)
    }
    .width('100%')
    .height(60)
    .padding({ left: 16, right: 16 })
  }

  @Builder
  modeChip(label: string, mode: string) {
    Text(label)
      .fontSize(13)
      .fontColor(this.startMode === mode ? '#FFFFFF' : TEXT_MAIN)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(12)
      .backgroundColor(this.startMode === mode ? ACCENT : '#14000000')
      .onClick(() => {
        this.setStartMode(mode);
      })
  }

  @Builder
  settingsSheet() {
    Column({ space: 16 }) {
      this.sheetTitle('设置')
      this.rowCard()
    }
    .width('100%')
    .padding({ left: H_PADDING, right: H_PADDING, top: 40, bottom: 28 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  editorSheet() {
    Column({ space: 14 }) {
      Row() {
        this.sheetTitle(this.editorIsNew ? '添加站点' : '编辑站点')
        if (this.probing) {
          LoadingProgress()
            .width(22)
            .height(22)
            .color(ACCENT)
        }
      }
      .width('100%')

      TextInput({ placeholder: 'https://example.com', text: this.editorUrl })
        .height(48)
        .fontSize(16)
        .backgroundColor(INPUT_BG)
        .borderRadius(14)
        .padding({ left: 14, right: 14 })
        .onChange((v: string) => {
          this.editorUrl = v;
          this.editorHint = '';
        })
      TextInput({ placeholder: '标题，可留空自动获取', text: this.editorTitle })
        .height(48)
        .fontSize(16)
        .backgroundColor(INPUT_BG)
        .borderRadius(14)
        .padding({ left: 14, right: 14 })
        .onChange((v: string) => {
          this.editorTitle = v;
        })
      if (this.editorHint.length > 0) {
        Text(this.editorHint)
          .fontSize(13)
          .fontColor(TEXT_SUB)
          .width('100%')
      }
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .height(46)
          .fontSize(16)
          .backgroundColor('#14000000')
          .fontColor(TEXT_MAIN)
          .onClick(() => this.closeEditor())
        Button('保存')
          .layoutWeight(1)
          .height(46)
          .fontSize(16)
          .backgroundColor(ACCENT)
          .onClick(() => this.saveEditor())
      }
      .width('100%')
      .margin({ top: 4 })
    }
    .width('100%')
    .padding({ left: H_PADDING, right: H_PADDING, top: 40, bottom: 28 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  iconBox(site: Site) {
    Stack({ alignContent: Alignment.Center }) {
      Text(site.title.length > 0 ? site.title.substring(0, 1).toUpperCase() : 'W')
        .width(60)
        .height(60)
        .borderRadius(18)
        .backgroundColor('#E3ECFB')
        .fontSize(26)
        .fontWeight(FontWeight.Medium)
        .fontColor(ACCENT)
        .textAlign(TextAlign.Center)
      if (site.icon.length > 0 && !this.brokenIcons.includes(site.id)) {
        Image(site.icon)
          .width(60)
          .height(60)
          .borderRadius(18)
          .objectFit(ImageFit.Contain)
          .backgroundColor('#FFFFFF')
          .onError(() => {
            this.brokenIcons = this.brokenIcons.concat([site.id]);
          })
      }
    }
    .width(60)
    .height(60)
  }

  @Builder
  tile(site: Site) {
    Column({ space: 10 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        this.iconBox(site)
        if (this.editMode) {
          Stack() {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(11)
              .fontColor(['#FFFFFF'])
          }
          .width(22)
          .height(22)
          .borderRadius(11)
          .backgroundColor('#99000000')
          .offset({ x: 8, y: -8 })
          .onClick(() => {
            this.deleteTarget = site;
            this.askDelete = true;
          })
        }
      }
      .width(60)
      .height(60)

      Column({ space: 4 }) {
        Text(site.title)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(TEXT_MAIN)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Center)
        Text(hostOf(site.url))
          .fontSize(11)
          .fontColor(TEXT_SUB)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Center)
      }
      .width('100%')
    }
    .width('100%')
    .padding({ top: 18, bottom: 16, left: 8, right: 8 })
    .borderRadius(24)
    .backgroundColor(CARD_BG)
    .backgroundBlurStyle(BlurStyle.Thin)
    .shadow({ radius: 18, color: '#12000000', offsetY: 8 })
    .onClick(() => {
      if (!this.editMode) {
        this.switchTo(site);
      }
    })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.menuSite = site;
        this.menuSiteId = site.id;
      }
    })
    .bindContextMenu(this.siteMenu, this.editMode ? ResponseType.RightClick : ResponseType.LongPress, {
      hapticFeedbackMode: HapticFeedbackMode.ENABLED,
      backgroundColor: '#F5FFFFFF',
      borderRadius: 18
    })
  }

  @Builder
  addTile() {
    Column({ space: 10 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(26)
          .fontColor([ACCENT])
      }
      .width(60)
      .height(60)
      .borderRadius(18)
      .backgroundColor('#66FFFFFF')
      .border({ width: 1.5, color: '#3D0A59F7', style: BorderStyle.Dashed })

      Column({ space: 4 }) {
        Text('添加站点')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(ACCENT)
          .width('100%')
          .textAlign(TextAlign.Center)
        Text(' ')
          .fontSize(11)
          .width('100%')
      }
      .width('100%')
    }
    .width('100%')
    .padding({ top: 18, bottom: 16, left: 8, right: 8 })
    .borderRadius(24)
    .backgroundColor('#66FFFFFF')
    .border({ width: 1, color: '#330A59F7' })
    .onClick(() => this.openEditor(undefined))
  }

  @Builder
  bottomBar() {
    Row({ space: 4 }) {
      Button({ type: ButtonType.Normal, stateEffect: true }) {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.gearshape'))
            .fontSize(18)
            .fontColor([TEXT_MAIN])
          Text('设置')
            .fontSize(15)
            .fontColor(TEXT_MAIN)
        }
      }
      .height(44)
      .padding({ left: 20, right: 20 })
      .borderRadius(22)
      .backgroundColor('#00000000')
      .stateEffect(true)
      .onClick(() => {
        this.showSettings = true;
      })

      Divider()
        .vertical(true)
        .height(18)
        .color('#1A000000')

      Button({ type: ButtonType.Normal, stateEffect: true }) {
        Row({ space: 6 }) {
          SymbolGlyph(this.editMode ? $r('sys.symbol.checkmark') : $r('sys.symbol.square_and_pencil'))
            .fontSize(18)
            .fontColor([this.editMode ? ACCENT : TEXT_MAIN])
          Text(this.editMode ? '完成' : '编辑')
            .fontSize(15)
            .fontColor(this.editMode ? ACCENT : TEXT_MAIN)
        }
      }
      .height(44)
      .padding({ left: 20, right: 20 })
      .borderRadius(22)
      .backgroundColor('#00000000')
      .stateEffect(true)
      .onClick(() => {
        this.editMode = !this.editMode;
      })
    }
    .padding({ left: 6, right: 6 })
    .borderRadius(26)
    .backgroundColor(BAR_BG)
    .backgroundBlurStyle(BlurStyle.Thin)
    .shadow({ radius: 22, color: '#1A000000', offsetY: 10 })
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column() {
        Column({ space: 6 }) {
          Text('站点')
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor(TEXT_MAIN)
          Text(`${this.sites.length} 个应用`)
            .fontSize(13)
            .fontColor(TEXT_SUB)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: H_PADDING, right: H_PADDING, top: 12 })

        Grid() {
          ForEach(this.sites, (site: Site) => {
            GridItem() {
              this.tile(site)
            }
          }, (site: Site) => site.id)
          GridItem() {
            this.addTile()
          }
        }
        .columnsTemplate('1fr 1fr 1fr')
        .columnsGap(16)
        .rowsGap(16)
        .editMode(this.editMode)
        .onItemDragStart((event: ItemDragInfo, itemIndex: number) => {
          if (itemIndex >= this.sites.length) {
            return this.dragCardPreview('');
          }
          return this.dragCardPreview(this.sites[itemIndex].title);
        })
        .onItemDrop((event: ItemDragInfo, itemIndex: number, insertIndex: number, isSuccess: boolean) => {
          if (!isSuccess || itemIndex >= this.sites.length || insertIndex > this.sites.length) {
            return;
          }
          const arr = this.sites.slice();
          const moved = arr.splice(itemIndex, 1)[0];
          arr.splice(insertIndex, 0, moved);
          this.sites = arr;
          this.persistOrder(arr);
        })
        .width('100%')
        .layoutWeight(1)
        .supportAnimation(true)
        .clip(false)
        .padding({ left: H_PADDING + 6, right: H_PADDING + 6, top: 24, bottom: 12 })
        .scrollBar(BarState.Off)
        .bindSheet($$this.editorVisible, this.editorSheet, {
          height: 360,
          dragBar: true,
          showClose: true,
          backgroundColor: SHEET_BG,
          blurStyle: BlurStyle.COMPONENT_THICK,
          maskColor: '#26000000',
          onDisappear: () => {
            this.probeUrl = '';
            this.probing = false;
          }
        })

        Row() {
          this.bottomBar()
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ bottom: 8 + this.safeBottom * 0.45 })
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.safeTop + 8, bottom: this.safeBottom })

      if (this.askDelete) {
        Stack() {
          this.deleteDialog()
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#33000000')
        .alignContent(Alignment.Center)
        .onClick(() => {
          this.askDelete = false;
          this.deleteTarget = undefined;
        })
      }

      if (this.probeUrl.length > 0) {
        Web({ src: this.probeUrl, controller: this.probe })
          .width(1)
          .height(1)
          .opacity(0)
          .javaScriptAccess(true)
          .onPageEnd(() => {
            this.onProbePageEnd();
          })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .bindSheet($$this.showSettings, this.settingsSheet, {
      height: 330,
      maskColor: '#26000000',
      dragBar: true,
      showClose: true,
      backgroundColor: SHEET_BG,
      blurStyle: BlurStyle.COMPONENT_THICK
    })
  }
}
