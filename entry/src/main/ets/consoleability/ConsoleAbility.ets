import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { webview } from '@kit.ArkWeb';

const DOMAIN = 0x0101;
const TAG = 'wapp';

export default class ConsoleAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'ConsoleAbility onCreate');
    try {
      webview.WebviewController.setHttpDns(webview.SecureDnsMode.AUTO, 'https://doh.pub/dns-query');
      hilog.info(DOMAIN, TAG, 'httpDns enabled');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'setHttpDns failed: %{public}s', JSON.stringify(e));
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    try {
      const win = windowStage.getMainWindowSync();
      win.setWindowBackgroundColor('#FBFCFE');
      // 渐变底铺满整屏，状态栏与手势条透明浮在上面
      win.setWindowLayoutFullScreen(true);
      win.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        statusBarContentColor: '#000000',
        navigationBarColor: '#00000000',
        navigationBarContentColor: '#000000'
      }).catch((e: Error) => {
        hilog.warn(DOMAIN, TAG, 'set system bar failed: %{public}s', e.message);
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'set window bg failed');
    }
    windowStage.loadContent('pages/Console', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
      }
    });
  }
}
