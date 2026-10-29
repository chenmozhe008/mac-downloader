// 抖音：网页播放器是 blob，页面里拿不到视频地址；yt-dlp 去调接口要算签名（a_bogus），带登录 Cookie 也 403。
// 但抖音页面自己发的接口请求已经带好签名，返回里就有各档画质的无水印直链（10-29 实测）。
// 这里在页面最开始挂上，记下页面自己拿到的视频信息；签名始终由抖音自己算，改算法也不受影响。
// 扩展自己去调这个接口会返回空内容，所以只能记页面的返回。
(() => {
  const store = (window.__shandianAweme = window.__shandianAweme || {});
  
  // 同一条视频会在多个接口里出现（详情、相关推荐……），有的只带一个低画质地址：只在更好时才替换
  // （10-29 实测：先记下 1080P H.264，随后「相关推荐」里的 576P HEVC 把它覆盖了）
  const score = (c) => (c.h265 ? 0 : 1e8) + c.height * 1e4 + c.rate / 1e3;

  function remember(a) {
    if (!a || !a.aweme_id || !a.video) return;
    const v = a.video;
    const cands = (v.bit_rate || []).map((r) => ({ addr: r.play_addr, h265: !!(r.is_h265 || r.is_bytevc1), height: r.play_addr?.height || 0, rate: r.bit_rate || 0 }));
    if (v.play_addr) cands.push({ addr: v.play_addr, h265: !!v.is_h265, height: v.play_addr.height || v.height || 0, rate: 0 });
    let best = null;
    for (const c of cands) {
      const list = c.addr?.url_list || [];
      c.url = list.find((u) => u.startsWith("https:")) || list[0];
      if (c.url && (!best || score(c) > score(best))) best = c;
    }
    if (!best) return;
    const old = store[a.aweme_id];
    if (old && score(old) >= score(best)) return;
    store[a.aweme_id] = { url: best.url, h265: best.h265, height: best.height, rate: best.rate, title: a.desc || "" };
  }

  function scan(json) {
    if (!json || typeof json !== "object") return;
    if (json.aweme_detail) remember(json.aweme_detail);
    for (const k of ["aweme_list", "data"]) {
      const arr = json[k];
      if (Array.isArray(arr)) for (const it of arr) remember(it.aweme_info || it.aweme || it);
    }
  }

  // 不碰 fetch / XMLHttpRequest：抖音的安全 SDK 加载后会把它们换成自己的包装（10-29 实测 4 次里 3 次钩子被挤掉），
  // 硬抢最外层又会和它的防篡改检查死循环、页面卡死。改为在解析 JSON 时看一眼：页面拿到接口返回总要解析
  const parse = JSON.parse;
  JSON.parse = function (...args) {
    const r = parse.apply(this, args);
    try { if (r && typeof r === "object" && (r.aweme_detail || r.aweme_list || Array.isArray(r.data))) scan(r); } catch (_) {}
    return r;
  };
  const json = Response.prototype.json;
  Response.prototype.json = function (...args) {
    return json.apply(this, args).then((r) => {
      try { if (r && typeof r === "object" && (r.aweme_detail || r.aweme_list)) scan(r); } catch (_) {}
      return r;
    });
  };
})();
