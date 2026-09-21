(() => {
  "use strict";

  const API_URL = "https://api.github.com/repos/xk-7/ServerDash/releases?per_page=100";
  const CACHE_KEY = "serverdash-stable-releases-v2";
  const CACHE_MAX_AGE = 60 * 60 * 1000;
  const list = document.querySelector("#release-list");
  const status = document.querySelector("#release-feed-status");
  const filter = document.querySelector("#release-filter");
  const empty = document.querySelector("#release-empty");
  if (!list || !status) return;

  const messages = {
    "zh-CN": {
      loading: "正在读取 GitHub 正式版本…",
      live: (count) => `已连接 GitHub · ${count} 个正式版本`,
      cached: (count) => `已从本地缓存加载 · ${count} 个正式版本`,
      fallback: "GitHub 暂不可用 · 显示仓库内置摘要",
      latest: "最新稳定版",
      source: "GitHub 原文 ↗",
      assets: (count) => `下载附件（${count}）`,
      noBody: "该 Release 没有提供正文。"
    },
    en: {
      loading: "Loading stable releases from GitHub…",
      live: (count) => `Connected to GitHub · ${count} stable releases`,
      cached: (count) => `Loaded from local cache · ${count} stable releases`,
      fallback: "GitHub unavailable · showing built-in summaries",
      latest: "Latest stable",
      source: "View on GitHub ↗",
      assets: (count) => `Assets (${count})`,
      noBody: "This release has no description."
    }
  };

  let sourceState = { kind: "loading", count: 0 };

  function currentLanguage() {
    return document.documentElement.lang === "en" ? "en" : "zh-CN";
  }

  function setStatus(kind, count = 0) {
    sourceState = { kind, count };
    const zh = messages["zh-CN"];
    const en = messages.en;
    const values = {
      loading: { "zh-CN": zh.loading, en: en.loading },
      live: { "zh-CN": zh.live(count), en: en.live(count) },
      cached: { "zh-CN": zh.cached(count), en: en.cached(count) },
      fallback: { "zh-CN": zh.fallback, en: en.fallback }
    }[kind];
    status.classList.toggle("is-live", kind === "live");
    status.classList.toggle("is-cached", kind === "cached");
    status.classList.toggle("is-fallback", kind === "fallback" || kind === "loading");
    status.querySelectorAll(".lang-zh, .lang-en").forEach((node) => {
      node.textContent = values[node.classList.contains("lang-en") ? "en" : "zh-CN"];
    });
  }

  function readCache() {
    try {
      const value = JSON.parse(localStorage.getItem(CACHE_KEY));
      if (!value || !Array.isArray(value.releases) || !Number.isFinite(value.savedAt)) return null;
      return value;
    } catch {
      return null;
    }
  }

  function writeCache(releases) {
    try {
      localStorage.setItem(CACHE_KEY, JSON.stringify({ savedAt: Date.now(), releases }));
    } catch {
      // Public release history still works when storage is unavailable.
    }
  }

  function nextPage(linkHeader) {
    if (!linkHeader) return null;
    const match = linkHeader.match(/<([^>]+)>;\s*rel="next"/);
    return match?.[1] || null;
  }

  async function fetchAllReleases() {
    const all = [];
    let url = API_URL;
    let page = 0;
    while (url && page < 5) {
      const response = await fetch(url, {
        headers: { Accept: "application/vnd.github+json" }
      });
      if (!response.ok) throw new Error(`GitHub API returned ${response.status}`);
      const batch = await response.json();
      if (!Array.isArray(batch)) throw new Error("GitHub API returned an invalid payload");
      all.push(...batch);
      url = nextPage(response.headers.get("Link"));
      page += 1;
    }
    return all
      .filter((release) => !release.draft && !release.prerelease && release.published_at)
      .sort((a, b) => Date.parse(b.published_at) - Date.parse(a.published_at));
  }

  function appendInline(parent, value) {
    const expression = /(`[^`]+`|\[[^\]]+\]\(https?:\/\/[^)\s]+\))/g;
    let cursor = 0;
    for (const match of value.matchAll(expression)) {
      if (match.index > cursor) parent.append(document.createTextNode(value.slice(cursor, match.index)));
      const token = match[0];
      if (token.startsWith("`")) {
        const code = document.createElement("code");
        code.textContent = token.slice(1, -1);
        parent.append(code);
      } else {
        const parts = token.match(/^\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)$/);
        const link = document.createElement("a");
        link.textContent = parts[1];
        link.href = parts[2];
        link.rel = "noreferrer";
        parent.append(link);
      }
      cursor = match.index + token.length;
    }
    if (cursor < value.length) parent.append(document.createTextNode(value.slice(cursor)));
  }

  function renderMarkdown(markdown) {
    const container = document.createElement("div");
    container.className = "release-markdown";
    const lines = String(markdown || "").replace(/\r\n?/g, "\n").split("\n");
    let paragraph = [];
    let listElement = null;
    let codeLines = null;

    const flushParagraph = () => {
      if (!paragraph.length) return;
      const node = document.createElement("p");
      appendInline(node, paragraph.join(" "));
      container.append(node);
      paragraph = [];
    };
    const flushList = () => {
      listElement = null;
    };
    const flushCode = () => {
      if (codeLines === null) return;
      const pre = document.createElement("pre");
      const code = document.createElement("code");
      code.textContent = codeLines.join("\n");
      pre.append(code);
      container.append(pre);
      codeLines = null;
    };

    for (const line of lines) {
      if (line.trim().startsWith("```")) {
        if (codeLines === null) {
          flushParagraph();
          flushList();
          codeLines = [];
        } else {
          flushCode();
        }
        continue;
      }
      if (codeLines !== null) {
        codeLines.push(line);
        continue;
      }
      if (!line.trim()) {
        flushParagraph();
        flushList();
        continue;
      }
      const heading = line.match(/^(#{1,4})\s+(.+)$/);
      if (heading) {
        flushParagraph();
        flushList();
        const node = document.createElement(heading[1].length <= 2 ? "h3" : "h4");
        appendInline(node, heading[2]);
        container.append(node);
        continue;
      }
      if (/^\s*([-*_])(?:\s*\1){2,}\s*$/.test(line)) {
        flushParagraph();
        flushList();
        container.append(document.createElement("hr"));
        continue;
      }
      const item = line.match(/^\s*(?:[-*+]|\d+\.)\s+(.+)$/);
      if (item) {
        flushParagraph();
        const ordered = /^\s*\d+\./.test(line);
        const tag = ordered ? "ol" : "ul";
        if (!listElement || listElement.tagName.toLowerCase() !== tag) {
          listElement = document.createElement(tag);
          container.append(listElement);
        }
        const node = document.createElement("li");
        appendInline(node, item[1]);
        listElement.append(node);
        continue;
      }
      paragraph.push(line.trim());
    }
    flushParagraph();
    flushCode();
    return container;
  }

  function formatBytes(bytes) {
    if (!Number.isFinite(bytes) || bytes <= 0) return "";
    const units = ["B", "KB", "MB", "GB"];
    const index = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
    return `${(bytes / 1024 ** index).toFixed(index > 1 ? 1 : 0)} ${units[index]}`;
  }

  function buildRelease(release, index) {
    const article = document.createElement("article");
    article.className = "release-entry";
    article.dataset.releaseSearch = [
      release.name,
      release.tag_name,
      release.body
    ].filter(Boolean).join(" ").toLocaleLowerCase();

    const rail = document.createElement("div");
    rail.className = "release-rail";
    rail.append(document.createElement("span"));

    const content = document.createElement("div");
    content.className = "release-content";
    const header = document.createElement("header");
    header.className = "release-header";
    const headingGroup = document.createElement("div");
    if (index === 0) {
      const badge = document.createElement("span");
      badge.className = "release-badge";
      badge.dataset.releaseLatest = "";
      badge.textContent = messages[currentLanguage()].latest;
      headingGroup.append(badge);
    }
    const heading = document.createElement("h2");
    heading.textContent = release.name || release.tag_name || "ServerDash";
    const meta = document.createElement("p");
    const time = document.createElement("time");
    time.dateTime = release.published_at;
    time.dataset.releaseDate = release.published_at;
    meta.append(time);
    if (release.tag_name && release.name !== release.tag_name) {
      meta.append(document.createTextNode(` · ${release.tag_name}`));
    }
    headingGroup.append(heading, meta);

    const source = document.createElement("a");
    source.href = release.html_url;
    source.rel = "noreferrer";
    source.dataset.releaseSource = "";
    source.textContent = messages[currentLanguage()].source;
    header.append(headingGroup, source);
    content.append(header);

    if (release.body?.trim()) {
      content.append(renderMarkdown(release.body));
    } else {
      const noBody = document.createElement("p");
      noBody.className = "release-no-body";
      noBody.dataset.releaseNoBody = "";
      noBody.textContent = messages[currentLanguage()].noBody;
      content.append(noBody);
    }

    const assets = Array.isArray(release.assets) ? release.assets : [];
    if (assets.length) {
      const details = document.createElement("details");
      details.className = "release-assets";
      const summary = document.createElement("summary");
      summary.dataset.releaseAssets = String(assets.length);
      summary.textContent = messages[currentLanguage()].assets(assets.length);
      const assetList = document.createElement("ul");
      assets.forEach((asset) => {
        const item = document.createElement("li");
        const link = document.createElement("a");
        link.href = asset.browser_download_url;
        link.textContent = asset.name || "Download";
        link.rel = "noreferrer";
        item.append(link);
        const size = formatBytes(asset.size);
        if (size) item.append(document.createTextNode(` · ${size}`));
        assetList.append(item);
      });
      details.append(summary, assetList);
      content.append(details);
    }
    article.append(rail, content);
    return article;
  }

  function updateLocalizedNodes() {
    const language = currentLanguage();
    document.querySelectorAll("[data-release-date]").forEach((time) => {
      time.textContent = new Intl.DateTimeFormat(language, {
        year: "numeric",
        month: "short",
        day: "numeric"
      }).format(new Date(time.dataset.releaseDate));
    });
    document.querySelectorAll("[data-release-latest]").forEach((node) => {
      node.textContent = messages[language].latest;
    });
    document.querySelectorAll("[data-release-source]").forEach((node) => {
      node.textContent = messages[language].source;
    });
    document.querySelectorAll("[data-release-assets]").forEach((node) => {
      node.textContent = messages[language].assets(Number(node.dataset.releaseAssets));
    });
    document.querySelectorAll("[data-release-no-body]").forEach((node) => {
      node.textContent = messages[language].noBody;
    });
    setStatus(sourceState.kind, sourceState.count);
  }

  function renderReleases(releases) {
    list.replaceChildren(...releases.map(buildRelease));
    applyFilter();
    updateLocalizedNodes();
  }

  function applyFilter() {
    const query = filter?.value.trim().toLocaleLowerCase() || "";
    const entries = [...list.querySelectorAll(".release-entry")];
    let visible = 0;
    entries.forEach((entry) => {
      const value = entry.dataset.releaseSearch || entry.textContent.toLocaleLowerCase();
      entry.hidden = Boolean(query) && !value.includes(query);
      if (!entry.hidden) visible += 1;
    });
    if (empty) empty.hidden = visible !== 0;
  }

  async function load() {
    const cached = readCache();
    if (cached?.releases.length) {
      renderReleases(cached.releases);
      setStatus("cached", cached.releases.length);
      if (Date.now() - cached.savedAt < CACHE_MAX_AGE) return;
    } else {
      setStatus("loading");
    }
    try {
      const releases = await fetchAllReleases();
      if (!releases.length) throw new Error("No stable releases returned");
      renderReleases(releases);
      writeCache(releases);
      setStatus("live", releases.length);
    } catch {
      if (cached?.releases.length) {
        setStatus("cached", cached.releases.length);
      } else {
        setStatus("fallback");
        applyFilter();
      }
    }
  }

  filter?.addEventListener("input", applyFilter);
  document.addEventListener("serverdash:language", updateLocalizedNodes);
  load();
})();
