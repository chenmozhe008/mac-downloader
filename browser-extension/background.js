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
  await chrome.action.setTitle({ title: on ? "闪电下载：接管下载已开启（点击关闭）" : "闪电下载：接管下载已关闭（点击开启）" });
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

async function sendToApp(url, referrer) {
  const headers = url.startsWith("http") ? await headersFor(url, referrer) : {};
  try {
    const r = await fetch(APP, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url, headers }),
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
  const url = info.linkUrl || info.srcUrl;
  if (url) await sendToApp(url, info.pageUrl);
});

chrome.action.onClicked.addListener(async () => {
  await chrome.storage.local.set({ takeover: !(await enabled()) });
  await refreshBadge();
});

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({ id: "shandian", title: "用闪电下载", contexts: ["link", "video", "audio"] });
  refreshBadge();
  ping();
});
chrome.runtime.onStartup.addListener(() => { refreshBadge(); ping(); });
