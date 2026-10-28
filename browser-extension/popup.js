// 点扩展图标弹出的小面板：视频网站页面上直接「下载这个视频」；下面是接管下载的开关
const VIDEO_SITES = ["douyin.com", "xiaohongshu.com", "bilibili.com", "youtube.com", "x.com", "twitter.com", "weibo.com", "ixigua.com", "kuaishou.com", "vimeo.com"];

async function main() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const host = tab?.url ? new URL(tab.url).hostname : "";
  const onVideoSite = VIDEO_SITES.some((d) => host === d || host.endsWith("." + d));
  const page = document.getElementById("page");
  if (!onVideoSite) {
    page.querySelector("#title").textContent = "当前页面不是视频网站";
    page.querySelector("#dl").style.display = "none";
    page.querySelector("#hint").textContent = "网页上的下载链接会自动交给闪电下载；也可以在链接上右键「用闪电下载」。";
  } else {
    page.querySelector("#title").textContent = tab.title || tab.url;
    const btn = page.querySelector("#dl");
    btn.onclick = async () => {
      btn.disabled = true; btn.textContent = "正在交给闪电下载…";
      const r = await chrome.runtime.sendMessage({ type: "downloadPage", tabId: tab.id });
      btn.textContent = r?.ok ? "已开始下载" : "闪电下载没打开";
      page.querySelector("#hint").textContent = r?.ok ? "在闪电下载里能看到进度。" : "请先打开闪电下载再试。";
      if (r?.ok) setTimeout(() => window.close(), 1200);
    };
  }
  const box = document.getElementById("takeover");
  const { takeover = true } = await chrome.storage.local.get("takeover");
  box.checked = takeover;
  box.onchange = async () => {
    await chrome.storage.local.set({ takeover: box.checked });
    chrome.runtime.sendMessage({ type: "refreshBadge" });
  };
}
main();
