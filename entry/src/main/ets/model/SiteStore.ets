import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Site, newSiteId, normalizeUrl } from './Site';

const DOMAIN = 0x0102;
const TAG = 'wapp';
const PREF_NAME = 'wapp_store';
const K_SITES = 'sites';
const K_CURRENT = 'currentId';
const K_START_MODE = 'startMode';
const K_LAST_PREFIX = 'last:';

/** 站点登录凭据（HTTP Basic）：按 host 存，重启后自动带上 */
export class AuthCred {
  user: string = '';
  pass: string = '';
}

const K_AUTH_PREFIX = 'auth:';


export const START_HOME = 'home';
export const START_HISTORY = 'history';

/**
 * 站点数据：Preferences 持久化，首启从 rawfile/sites.json 导入。
 * 只有 UIAbilityContext 能取 resourceManager / preferences。
 */
export class SiteStore {
  private static prefs: preferences.Preferences | undefined = undefined;

  private static async of(ctx: common.UIAbilityContext): Promise<preferences.Preferences> {
    if (SiteStore.prefs === undefined) {
      SiteStore.prefs = await preferences.getPreferences(ctx, PREF_NAME);
    }
    return SiteStore.prefs;
  }

  private static async seedFromRaw(ctx: common.UIAbilityContext): Promise<Site[]> {
    try {
      const data = await ctx.resourceManager.getRawFileContent('sites.json');
      const text = util.TextDecoder.create('utf-8').decodeToString(data);
      const arr = JSON.parse(text) as Site[];
      if (arr && arr.length > 0) {
        return arr;
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'seedFromRaw failed: %{public}s', JSON.stringify(e));
    }
    return [];
  }

  static async list(ctx: common.UIAbilityContext): Promise<Site[]> {
    const p = await SiteStore.of(ctx);
    const raw = await p.get(K_SITES, '') as string;
    if (raw === '') {
      const seeded = await SiteStore.seedFromRaw(ctx);
      if (seeded.length > 0) {
        await p.put(K_SITES, JSON.stringify(seeded));
        await p.put(K_CURRENT, seeded[0].id);
        await p.flush();
      }
      return seeded;
    }
    try {
      const arr = JSON.parse(raw) as Site[];
      const out: Site[] = [];
      for (const it of arr) {
        // 旧数据可能缺字段，统一补默认值，避免 undefined.length 崩溃
        const id = typeof it.id === 'string' ? it.id : '';
        const url = typeof it.url === 'string' ? it.url : '';
        const title = typeof it.title === 'string' ? it.title : '';
        const icon = typeof it.icon === 'string' ? it.icon : '';
        if (id.length > 0 && url.length > 0) {
          out.push({ id: id, title: title.length > 0 ? title : url, url: url, icon: icon });
        }
      }
      return out;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'parse sites failed: %{public}s', JSON.stringify(e));
      return [];
    }
  }

  static async save(ctx: common.UIAbilityContext, sites: Site[]): Promise<void> {
    const p = await SiteStore.of(ctx);
    await p.put(K_SITES, JSON.stringify(sites));
    await p.flush();
  }

  static async currentId(ctx: common.UIAbilityContext): Promise<string> {
    const p = await SiteStore.of(ctx);
    const id = await p.get(K_CURRENT, '') as string;
    if (id !== '') {
      return id;
    }
    const sites = await SiteStore.list(ctx);
    return sites.length > 0 ? sites[0].id : '';
  }

  static async setCurrentId(ctx: common.UIAbilityContext, id: string): Promise<void> {
    const p = await SiteStore.of(ctx);
    await p.put(K_CURRENT, id);
    await p.flush();
  }

  /** 冷启动方式：首页 / 上次页面 */
  static async startMode(ctx: common.UIAbilityContext): Promise<string> {
    const p = await SiteStore.of(ctx);
    return await p.get(K_START_MODE, START_HOME) as string;
  }

  static async setStartMode(ctx: common.UIAbilityContext, mode: string): Promise<void> {
    const p = await SiteStore.of(ctx);
    await p.put(K_START_MODE, mode);
    await p.flush();
  }

  /** 每个站点上次停留的页面，startMode=history 时用它恢复 */
  static async lastUrl(ctx: common.UIAbilityContext, id: string): Promise<string> {
    const p = await SiteStore.of(ctx);
    return await p.get(K_LAST_PREFIX + id, '') as string;
  }

  static async setLastUrl(ctx: common.UIAbilityContext, id: string, url: string): Promise<void> {
    const p = await SiteStore.of(ctx);
    await p.put(K_LAST_PREFIX + id, url);
    await p.flush();
  }

  static async current(ctx: common.UIAbilityContext): Promise<Site | undefined> {
    const sites = await SiteStore.list(ctx);
    if (sites.length === 0) {
      return undefined;
    }
    const id = await SiteStore.currentId(ctx);
    for (const s of sites) {
      if (s.id === id) {
        return s;
      }
    }
    return sites[0];
  }

  /** 新增站点（返回写入后的列表），URL 会归一化 */
  static async add(ctx: common.UIAbilityContext, url: string, title: string, icon: string): Promise<Site[]> {
    const sites = await SiteStore.list(ctx);
    const u = normalizeUrl(url);
    if (u === '') {
      return sites;
    }
    const site: Site = {
      id: newSiteId(),
      title: title.length > 0 ? title : u,
      url: u,
      icon: icon
    };
    sites.push(site);
    await SiteStore.save(ctx, sites);
    return sites;
  }

  static async update(ctx: common.UIAbilityContext, site: Site): Promise<Site[]> {
    const sites = await SiteStore.list(ctx);
    for (let i = 0; i < sites.length; i++) {
      if (sites[i].id === site.id) {
        sites[i] = site;
        break;
      }
    }
    await SiteStore.save(ctx, sites);
    return sites;
  }

  static async remove(ctx: common.UIAbilityContext, id: string): Promise<Site[]> {
    const sites = await SiteStore.list(ctx);
    const keep: Site[] = [];
    for (const s of sites) {
      if (s.id !== id) {
        keep.push(s);
      }
    }
    await SiteStore.save(ctx, keep);
    if (keep.length > 0) {
      const cur = await SiteStore.currentId(ctx);
      if (cur === id) {
        await SiteStore.setCurrentId(ctx, keep[0].id);
      }
    }
    return keep;
  }

  /** 读取某个 host 保存的登录凭据 */
  static async auth(ctx: common.UIAbilityContext, host: string): Promise<AuthCred | undefined> {
    const p = await SiteStore.of(ctx);
    const raw = await p.get(K_AUTH_PREFIX + host, '') as string;
    if (raw.length === 0) {
      return undefined;
    }
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      const cred = new AuthCred();
      const u = parsed['u'];
      const pw = parsed['p'];
      if (typeof u === 'string') {
        cred.user = u;
      }
      if (typeof pw === 'string') {
        cred.pass = pw;
      }
      return cred;
    } catch (e) {
      return undefined;
    }
  }

  /** 保存某个 host 的登录凭据 */
  static async setAuth(ctx: common.UIAbilityContext, host: string, user: string, pass: string): Promise<void> {
    const p = await SiteStore.of(ctx);
    const value = JSON.stringify({ 'u': user, 'p': pass } as Record<string, string>);
    await p.put(K_AUTH_PREFIX + host, value);
    await p.flush();
  }

  /** 清除某个 host 的登录凭据 */
  static async clearAuth(ctx: common.UIAbilityContext, host: string): Promise<void> {
    const p = await SiteStore.of(ctx);
    await p.delete(K_AUTH_PREFIX + host);
    await p.flush();
  }
}
