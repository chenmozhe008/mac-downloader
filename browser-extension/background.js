// 闪电下载浏览器扩展：把浏览器里的下载交给本机的闪电下载（127.0.0.1:6800）。
// App 没开时什么都不拦，浏览器照常下载；App 只认本扩展的来源（manifest 里的 key 固定了扩展 ID），不需要填密钥。

const APP = "http://127.0.0.1:6800/extension/add";
const PING = "http://127.0.0.1:6800/extension/ping";

// 告诉 App 扩展已装好（设置页显示「已连接」）
function ping() { fetch(PING, { method: "POST" }).catch(() => {}); }

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
const LOGIN_SITES = ["douyin.com", "xiaohongshu.com"];

async function loginCookies(url) {
  const host = new URL(url).hostname;
  const site = LOGIN_SITES.find((d) => host === d || host.endsWith("." + d));
  if (!site) return undefined;
  const cookies = await chrome.cookies.getAll({ domain: site });
  return cookies.map((c) => ({ domain: c.domain, path: c.path, secure: c.secure, expires: c.expirationDate, name: c.name, value: c.value }));
}

// 抖音网页版看视频时地址常是 ?modal_id=…，换成视频页地址下载工具才认
function videoPageURL(url) {
  const u = new URL(url);
  const id = u.searchParams.get("modal_id") || u.searchParams.get("vid");
  if (u.hostname.endsWith("douyin.com") && id) return `https://www.douyin.com/video/${id}`;
  return url;
}

async function sendToApp(url, referrer) {
  const headers = url.startsWith("http") ? await headersFor(url, referrer) : {};
  const cookies = url.startsWith("http") ? await loginCookies(url) : undefined;
  try {
    const r = await fetch(APP, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url, headers, cookies }),
    });
    return r.ok;
  } catch (_) {
    return false; // App 没开
  }
}

chrome.downloads.onCreated.addListener(async (item) => {
  const url = item.finalUrl || item.url;
  if (!/^https?:/i.test(url) || !(await enabled())) return;
  if (await sendToApp(url, item.referrer)) {
    // App 接下了才取消浏览器这边的，避免两边都没下
    try { await chrome.downloads.cancel(item.id); } catch (_) {}
    try { await chrome.downloads.erase({ id: item.id }); } catch (_) {}
  }
});

chrome.contextMenus.onClicked.addListener(async (info) => {
  if (info.menuItemId === "shandian-page") {
    await sendToApp(videoPageURL(info.pageUrl), info.pageUrl);
    return;
  }
  // 抖音、小红书的视频是 blob: 地址，下不了，改交页面地址
  let url = info.linkUrl || info.srcUrl;
  if (!url || url.startsWith("blob:")) url = info.pageUrl && videoPageURL(info.pageUrl);
  if (url) await sendToApp(url, info.pageUrl);
});

// 弹出面板发来的请求
chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (msg.type === "downloadPage") {
    sendToApp(videoPageURL(msg.url), msg.url).then((ok) => reply({ ok }));
    return true; // 异步回复
  }
  if (msg.type === "refreshBadge") refreshBadge();
});

chrome.runtime.onInstalled.addListener(async () => {
  await chrome.contextMenus.removeAll();   // 更新扩展时旧菜单还在，先清掉再建
  chrome.contextMenus.create({ id: "shandian", title: "用闪电下载", contexts: ["link", "video", "audio"] });
  // 抖音、小红书页面上任何地方右键都有，不用找视频元素
  chrome.contextMenus.create({
    id: "shandian-page", title: "用闪电下载这个视频", contexts: ["page", "frame", "image"],
    documentUrlPatterns: ["*://*.douyin.com/*", "*://*.xiaohongshu.com/*"],
  });
  refreshBadge();
  ping();
});
chrome.runtime.onStartup.addListener(() => { refreshBadge(); ping(); });
