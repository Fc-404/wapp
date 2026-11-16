export interface Site {
  id: string;
  title: string;
  url: string;
  icon: string;
}

export function newSiteId(): string {
  return 's' + Date.now().toString(36) + Math.floor(Math.random() * 1e6).toString(36);
}

/** 只接受 http/https，缺协议时补 https:// */
export function normalizeUrl(raw: string): string {
  let u = raw.trim();
  if (u.length === 0) {
    return '';
  }
  if (!/^https?:\/\//i.test(u)) {
    u = 'https://' + u;
  }
  return u;
}

export function hostOf(url: string): string {
  const m = url.match(/^https?:\/\/([^/?#]+)/i);
  return m ? m[1] : url;
}

/** 从 DoH JSON 响应里取出第一条 AAAA 记录 */
export function extractAAAA(json: string): string {
  try {
    const parsed = JSON.parse(json) as Record<string, Object>;
    const answers = parsed['Answer'];
    if (answers === undefined) {
      return '';
    }
    const list = answers as Array<Record<string, Object>>;
    for (let i = 0; i < list.length; i++) {
      const data = list[i]['data'];
      if (typeof data === 'string') {
        return data;
      }
    }
  } catch (e) {
    return '';
  }
  return '';
}

/** 从 DoH JSON 响应里取出全部地址记录 */
export function extractAll(json: string): string[] {
  const out: string[] = [];
  try {
    const parsed = JSON.parse(json) as Record<string, Object>;
    const answers = parsed['Answer'];
    if (answers === undefined) {
      return out;
    }
    const list = answers as Array<Record<string, Object>>;
    for (let i = 0; i < list.length; i++) {
      const data = list[i]['data'];
      if (typeof data === 'string') {
        out.push(data);
      }
    }
  } catch (e) {
    return out;
  }
  return out;
}
