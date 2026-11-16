import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SiteStore } from '../model/SiteStore';

const DOMAIN = 0x0100;
const TAG = 'wapp';
const BG_COLOR: string = '#0E1116';

export default class WebAbility extends UIAbility {
  private windowStage: window.WindowStage | undefined = undefined;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'WebAbility onCreate');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.windowStage = windowStage;
    windowStage.loadContent('pages/WebShell', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
      }
    });
    // 内容加载后再设置窗口：此时主窗口才可用（过早调用会报 1300002）
    setTimeout(() => {
      this.applyWindow(windowStage);
    }, 0);
  }

  /** 内容铺满整屏，状态栏/手势条透明浮在网页上，颜色由 WebShell 跟随网页调整 */
  private applyWindow(windowStage: window.WindowStage): void {
    try {
      const win = windowStage.getMainWindowSync();
      win.setWindowBackgroundColor(BG_COLOR);
      win.setWindowLayoutFullScreen(true);
      win.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        statusBarContentColor: '#FFFFFF',
        navigationBarColor: '#00000000',
        navigationBarContentColor: '#FFFFFF'
      }).catch((e: Error) => {
        hilog.warn(DOMAIN, TAG, 'setWindowSystemBarProperties failed: %{public}s', e.message);
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'applyWindow failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 控制台切换站点后走这里：更新当前站点并重载页面 */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'WebAbility onNewWant');
    const params = want.parameters;
    let siteId: string = '';
    let force: boolean = false;
    if (params !== undefined) {
      const sid = params['siteId'];
      const fc = params['force'];
      if (typeof sid === 'string') {
        siteId = sid;
      }
      if (typeof fc === 'boolean') {
        force = fc;
      }
    }
    hilog.info(DOMAIN, TAG, 'onNewWant siteId=%{public}s force=%{public}s', siteId, String(force));

    const stage = this.windowStage;
    if (stage === undefined) {
      return;
    }
    const reload = (): void => {
      stage.loadContent('pages/WebShell', (err) => {
        if (err.code) {
          hilog.error(DOMAIN, TAG, 'reload failed: %{public}s', JSON.stringify(err));
        }
      });
    };
    if (siteId.length === 0) {
      // 只是从桌面/最近任务点回来：保持当前页面，不要重载
      hilog.info(DOMAIN, TAG, 'onNewWant without siteId, keep current page');
      return;
    }
    SiteStore.setCurrentId(this.context, siteId)
      .then(() => {
        if (force) {
          return SiteStore.setLastUrl(this.context, siteId, '');
        }
        return Promise.resolve();
      })
      .then(() => reload())
      .catch((e: Error) => {
        hilog.error(DOMAIN, TAG, 'setCurrentId failed: %{public}s', e.message);
        reload();
      });
  }
}
