// 闪电下载浏览器扩展：把浏览器里的下载交给本机的闪电下载（127.0.0.1:6800）。
// App 没开时什么都不拦，浏览器照常下载；App 只认本扩展的来源（manifest 里的 key 固定了扩展 ID），不需要填密钥。

const APP = "http://127.0.0.1:6800/extension/add";
const PING = "http://127.0.0.1:6800/extension/ping";
const STATUS = "http://127.0.0.1:6800/extension/status";

// 告诉 App 扩展已装好（设置页显示「已连接」）；App 带的扩展版本比现在的新就自己重新加载
// （已解压的扩展浏览器不会自动刷新，App 更新时已把新文件写进扩展文件夹）
async function ping() {
  try {
    const r = await fetch(PING, { method: "POST" });
    const { version } = await r.json();
    if (version && version !== chrome.runtime.getManifest().version) chrome.runtime.reload();
  } catch (_) {}
}
chrome.alarms.create("shandian-ping", { periodInMinutes: 10 });
chrome.alarms.onAlarm.addListener((a) => { if (a.name === "shandian-ping") ping(); });

async function enabled() {
  const { takeover = true } = await chrome.storage.local.get("takeover");
  return takeover;
}

async function refreshBadge() {
  const on = await enabled();
  await chrome.action.setBadgeText({ text: on ? "" : "关" });
  await chrome.action.setBadgeBackgroundColor({ color: "#8E8E93" });
  await chrome.action.setTitle({ title: on ? "闪电下载" : "闪电下载：接管下载已关闭" });
}

// 网盘、登录后才能下的文件要带上浏览器的 Cookie、来源页和 UA，内核才能以同样身份下载
async function headersFor(url, referrer) {
  const headers = { "User-Agent": navigator.userAgent };
  if (referrer) headers["Referer"] = referrer;
  try {
    const cookies = await chrome.cookies.getAll({ url });
    if (cookies.length) headers["Cookie"] = cookies.map((c) => `${c.name}=${c.value}`).join("; ");
  } catch (_) {}
  return headers;
}

// 抖音、小红书要登录才能拿到视频：把浏览器里这两家的登录信息一起交给 App（只在用户右键这两家的页面时）
const LOGIN_SITES = ["douyin.com", "xiaohongshu.com", "xinpianchang.com"];

async function loginCookies(url) {
  const host = new URL(url).hostname;
  const site = LOGIN_SITES.find((d) => host === d || host.endsWith("." + d));
  if (!site) return undefined;
  const cookies = await chrome.cookies.getAll({ domain: site });
  return cookies.map((c) => ({ domain: c.domain, path: c.path, secure: c.secure, expires: c.expirationDate, name: c.name, value: c.value }));
}

// 页面里正在播的视频：浏览器已经拿到了真实地址，直接下它，不用再让下载工具去解析页面
// （10-28 抖音网页加了签名校验，yt-dlp 拿不到；「精选」这类信息流页面地址里也没有视频编号）
function pickPlayingVideo() {
  const area = (v) => {
    const r = v.getBoundingClientRect();
    const w = Math.max(0, Math.min(r.right, innerWidth) - Math.max(r.left, 0));
    const h = Math.max(0, Math.min(r.bottom, innerHeight) - Math.max(r.top, 0));
    return w * h;
  };
  const vids = [...document.querySelectorAll("video")].sort((a, b) => (b.paused ? 0 : 1e9) + area(b) - ((a.paused ? 0 : 1e9) + area(a)));
  for (const v of vids) {
    if (area(v) === 0) continue;
    const srcs = [v.currentSrc, v.src, ...[...v.querySelectorAll("source")].map((s) => s.src)];
    const src = srcs.find((x) => x && /^https?:/.test(x));
    if (src) return { src, title: document.title };
  }
  // 小红书：播放器是 blob，但页面数据里有视频直链（不用再等下载工具读 19 秒网页）
  try {
    const st = window.__INITIAL_STATE__;
    const map = st?.note?.noteDetailMap;
    const id = location.pathname.split("/").pop();
    const note = (map && (map[id] || Object.values(map)[0]))?.note;
    const streams = note?.video?.media?.stream;
    const list = [...(streams?.h264 || []), ...(streams?.h265 || [])];
    const best = list.sort((a, b) => (b.height || 0) - (a.height || 0))[0];
    const url = best?.masterUrl || best?.backupUrls?.[0];
    if (url) return { src: url.replace(/^http:/, "https:"), title: note.title || document.title };
  } catch (_) {}
  return null;
}

async function downloadVideoInTab(tab) {
  let picked = null;
  try {
    // MAIN：要读页面自己的变量（小红书的 __INITIAL_STATE__）
    const [res] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: pickPlayingVideo, world: "MAIN" });
    picked = res?.result;
  } catch (_) {}
  if (picked) {
    const title = (picked.title || "视频").replace(/\s*[-|]\s*(抖音|小红书|哔哩哔哩.*|YouTube)\s*$/, "").trim().slice(0, 80) || "视频";
    return sendToApp(picked.src, tab.url, title.replace(/[\\/:*?"<>|]/g, " ") + ".mp4", tab.id);
  }
  return sendToApp(videoPageURL(tab.url), tab.url, undefined, tab.id);   // 页面上找不到能直接下的视频，交页面地址给 yt-dlp
}

// 抖音网页版看视频时地址常是 ?modal_id=…，换成视频页地址下载工具才认
function videoPageURL(url) {
  const u = new URL(url);
  const id = u.searchParams.get("modal_id") || u.searchParams.get("vid");
  if (u.hostname.endsWith("douyin.com") && id) return `https://www.douyin.com/video/${id}`;
  return url;
}

async function appReady() {
  try {
    const r = await fetch(PING, { method: "POST" });
    return (await r.json()).ready !== false;
  } catch (_) {
    return false;
  }
}

// 用户主动点的（面板按钮、右键菜单）App 没开就把它打开：在当前标签页打开 shandian://open，
// 浏览器会问一次「要打开闪电下载吗」，勾「始终允许」后不再问；然后等内核就绪（最多 20 秒）
async function launchApp(tabId) {
  if (await appReady()) return true;
  try { await chrome.tabs.update(tabId, { url: "shandian://open" }); } catch (_) { return false; }
  for (let i = 0; i < 40; i++) {
    await new Promise((r) => setTimeout(r, 500));
    if (await appReady()) return true;
  }
  return false;
}

// tabId：传了就表示是用户主动点的，App 没开时自动打开它；浏览器自动接管的下载不传，App 没开就让浏览器自己下
async function sendToApp(url, referrer, name, tabId) {
  const headers = url.startsWith("http") ? await headersFor(url, referrer) : {};
  const cookies = url.startsWith("http") ? await loginCookies(referrer || url) : undefined;
  const post = () => fetch(APP, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ url, headers, cookies, name }),
  }).then((r) => r.ok);
  try {
    return await post();
  } catch (_) {
    // App 没开
    if (tabId === undefined || !(await launchApp(tabId))) return false;
    return post().catch(() => false);
  }
}

// 图片、网页、文本和已知很小的文件留给浏览器：多连接快不了，交出去反而多一个出错环节（参照 IDM 默认不接图片）
const SMALL = 5 * 1024 * 1024;
function worthTakingOver(item) {
  const mime = (item.mime || "").toLowerCase();
  if (/^(image|text)\//.test(mime) || mime === "application/xhtml+xml") return false;
  const size = item.totalBytes > 0 ? item.totalBytes : item.fileSize;
  return !(size > 0 && size < SMALL);
}

// 失败后交回浏览器重下的链接：浏览器再建下载时不再拦
const handedBack = new Set();

// 交给 App 后盯 5 分钟：App 那边失败了（会自己移除任务）就用浏览器重新下，不让这次下载丢掉
async function watchHandOver(url) {
  for (let i = 0; i < 60; i++) {
    await new Promise((r) => setTimeout(r, 5000));
    await chrome.runtime.getPlatformInfo(); // 调一次扩展接口，后台脚本不会因空闲 30 秒被回收
    let state;
    try {
      const r = await fetch(STATUS, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ url }) });
      state = (await r.json()).state;
    } catch (_) {
      return; // App 关了：不再管
    }
    if (state === "failed") {
      handedBack.add(url);
      chrome.downloads.download({ url });
      return;
    }
    if (state === "done" || state === "none") return;
  }
}

chrome.downloads.onCreated.addListener(async (item) => {
  const url = item.finalUrl || item.url;
  if (handedBack.delete(url) || handedBack.delete(item.url)) return;
  if (!/^https?:/i.test(url) || !worthTakingOver(item) || !(await enabled())) return;
  if (await sendToApp(url, item.referrer)) {
    // App 接下了才取消浏览器这边的，避免两边都没下
    try { await chrome.downloads.cancel(item.id); } catch (_) {}
    try { await chrome.downloads.erase({ id: item.id }); } catch (_) {}
    watchHandOver(url);
  }
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId === "shandian-page") {
    await downloadVideoInTab(tab);
    return;
  }
  // 抖音、小红书的视频是 blob: 地址，下不了，改交页面地址
  let url = info.linkUrl || info.srcUrl;
  if (!url || url.startsWith("blob:")) url = info.pageUrl && videoPageURL(info.pageUrl);
  if (url) await sendToApp(url, info.pageUrl, undefined, tab?.id);
});

// 弹出面板发来的请求
chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (msg.type === "downloadPage") {
    chrome.tabs.get(msg.tabId).then(downloadVideoInTab).then((ok) => reply({ ok }));
    return true; // 异步回复
  }
  if (msg.type === "refreshBadge") refreshBadge();
  if (msg.type === "linkPikPak") {
    linkPikPak(msg.tabId).then((ok) => reply({ ok }));
    return true;
  }
});

chrome.runtime.onInstalled.addListener(async () => {
  await chrome.contextMenus.removeAll();   // 更新扩展时旧菜单还在，先清掉再建
  chrome.contextMenus.create({ id: "shandian", title: "用闪电下载", contexts: ["link", "video", "audio"] });
  // 抖音、小红书页面上任何地方右键都有，不用找视频元素
  chrome.contextMenus.create({
    id: "shandian-page", title: "用闪电下载这个视频", contexts: ["page", "frame", "image"],
    documentUrlPatterns: ["*://*.douyin.com/*", "*://*.xiaohongshu.com/*", "*://*.xinpianchang.com/*"],
  });
  refreshBadge();
  ping();
});
chrome.runtime.onStartup.addListener(() => { refreshBadge(); ping(); });

// 把浏览器里已经登录着的 PikPak 关联到闪电下载（App 用 mypikpak.com/drive/#shandian-link 打开这个页面）。
// 取走网页存的登录信息后删掉网页那份：同一份登录两边都刷新会互相作废，所以之后网页端会变成未登录
function grabPikPakSession() {
  const k = Object.keys(localStorage).find((k) => k.startsWith("credentials_"));
  if (!k) return null;
  const c = JSON.parse(localStorage.getItem(k) || "{}");
  if (!c.access_token || !c.refresh_token) return null;
  const out = { key: k, c, device: localStorage.getItem("deviceid") || "" };
  localStorage.removeItem(k);
  return out;
}

// PikPak 网页一打开会自己跳到 /drive/all，地址里的 #shandian-link 会丢：记住是哪个标签页
const linkTabs = new Set();

chrome.tabs.onUpdated.addListener(async (tabId, change, tab) => {
  if ((change.url || tab.url || "").includes("#shandian-link")) linkTabs.add(tabId);
  if (change.status !== "complete" || !linkTabs.has(tabId) || !tab.url || !tab.url.startsWith("https://mypikpak.com/")) return;
  linkTabs.delete(tabId);
  await linkPikPak(tabId);
});

async function linkPikPak(tabId) {
  for (let i = 0; i < 10; i++) {   // 网页登录信息可能稍后才写好
    const [res] = await chrome.scripting.executeScript({ target: { tabId }, func: grabPikPakSession }).catch(() => [null]);
    const s = res?.result;
    if (s) {
      const ok = await fetch("http://127.0.0.1:6800/extension/pikpak", {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(s),
      }).then((r) => r.ok).catch(() => false);
      await chrome.scripting.executeScript({ target: { tabId }, func: (ok) => {
        document.title = ok ? "已关联到闪电下载" : "关联失败";
        alert(ok ? "PikPak 已关联到闪电下载，可以关掉这个页面了。" : "没能交给闪电下载，请确认闪电下载已打开。");
      }, args: [ok] });
      return true;
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
  return false;   // 没登录：留在页面上让用户登录，登录后再点一次关联
}
