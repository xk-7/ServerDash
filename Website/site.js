(() => {
  "use strict";

  const RELEASE_API = "https://api.github.com/repos/xk-7/ServerDash/releases/latest";
  const FALLBACK_VERSION = "v1.0.4";
  const THEME_KEY = "serverdash-theme";
  const languageButtons = [...document.querySelectorAll("[data-set-lang]")];
  const status = document.querySelector("#release-status");
  const pageData = document.documentElement.dataset;
  let activeTheme = "light";

  const copy = {
    "zh-CN": {
      checking: "正在核对最新版本…",
      ready: (version) => `已连接 GitHub Release · ${version}`,
      fallback: `暂时无法核对 GitHub，当前使用已验证的 ${FALLBACK_VERSION} 下载地址`
    },
    en: {
      checking: "Checking latest release…",
      ready: (version) => `Connected to GitHub Releases · ${version}`,
      fallback: `GitHub check unavailable; using verified ${FALLBACK_VERSION} download links`
    }
  };

  function preferredLanguage() {
    try {
      const saved = localStorage.getItem("serverdash-language");
      if (saved === "zh-CN" || saved === "en") return saved;
    } catch {
      // Storage can be unavailable in private browsing or hardened contexts.
    }
    return navigator.language.toLowerCase().startsWith("zh") ? "zh-CN" : "en";
  }

  function preferredTheme() {
    try {
      const saved = localStorage.getItem(THEME_KEY);
      if (saved === "light" || saved === "dark") return saved;
    } catch {
      // System theme remains available when storage is unavailable.
    }
    return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }

  function updateThemeButton() {
    const button = document.querySelector("[data-theme-toggle]");
    if (!button) return;
    const language = document.documentElement.lang === "en" ? "en" : "zh-CN";
    const switchesToDark = activeTheme === "light";
    const label = switchesToDark
      ? { "zh-CN": "切换到暗黑模式", en: "Switch to dark mode" }
      : { "zh-CN": "切换到浅色模式", en: "Switch to light mode" };
    button.setAttribute("aria-label", label[language]);
    button.title = label[language];
    button.setAttribute("aria-pressed", String(activeTheme === "dark"));
    button.textContent = switchesToDark ? "☾" : "☀";
  }

  function applyTheme(theme, persist = true) {
    activeTheme = theme === "dark" ? "dark" : "light";
    document.documentElement.dataset.theme = activeTheme;
    document.documentElement.style.colorScheme = activeTheme;
    const themeColor = document.querySelector('meta[name="theme-color"]');
    if (themeColor) themeColor.content = activeTheme === "dark" ? "#0d1523" : "#f7f9fc";
    if (persist) {
      try {
        localStorage.setItem(THEME_KEY, activeTheme);
      } catch {
        // Theme switching still works without persistence.
      }
    }
    updateThemeButton();
  }

  function setStatus(message, className) {
    if (!status) return;
    status.classList.remove("is-ready", "is-fallback");
    if (className) status.classList.add(className);
    const textNodes = status.querySelectorAll(".lang-zh, .lang-en");
    textNodes.forEach((node) => {
      node.textContent = message[node.classList.contains("lang-en") ? "en" : "zh-CN"];
    });
  }

  function applyLanguage(language, persist = true) {
    const selected = language === "en" ? "en" : "zh-CN";
    const dataSuffix = selected === "en" ? "En" : "Zh";
    const title = pageData[`title${dataSuffix}`];
    const pageDescription = pageData[`description${dataSuffix}`];
    document.documentElement.lang = selected;
    if (title) document.title = title;

    const description = document.querySelector('meta[name="description"]');
    const openGraphTitle = document.querySelector('meta[property="og:title"]');
    const openGraphDescription = document.querySelector('meta[property="og:description"]');
    if (description && pageDescription) description.content = pageDescription;
    if (openGraphTitle && title) openGraphTitle.content = title;
    if (openGraphDescription && pageDescription) openGraphDescription.content = pageDescription;

    languageButtons.forEach((button) => {
      button.setAttribute("aria-pressed", String(button.dataset.setLang === selected));
    });

    document.querySelectorAll("[data-aria-zh][data-aria-en]").forEach((element) => {
      element.setAttribute("aria-label", element.dataset[selected === "en" ? "ariaEn" : "ariaZh"]);
    });

    document.querySelectorAll("[data-placeholder-zh][data-placeholder-en]").forEach((element) => {
      element.placeholder = element.dataset[selected === "en" ? "placeholderEn" : "placeholderZh"];
    });
    updateThemeButton();

    if (persist) {
      try {
        localStorage.setItem("serverdash-language", selected);
      } catch {
        // Language switching still works without persistence.
      }
    }

    document.dispatchEvent(new CustomEvent("serverdash:language", { detail: selected }));
  }

  languageButtons.forEach((button) => {
    button.addEventListener("click", () => applyLanguage(button.dataset.setLang));
  });

  function createBilingualLink(href, chinese, english, className = "") {
    const link = document.createElement("a");
    link.href = href;
    if (className) link.className = className;
    const zh = document.createElement("span");
    zh.className = "lang-zh";
    zh.textContent = chinese;
    const en = document.createElement("span");
    en.className = "lang-en";
    en.lang = "en";
    en.textContent = english;
    link.append(zh, en);
    return link;
  }

  const topLinks = document.querySelector(".nav-links");
  if (topLinks) {
    const inDocs = location.pathname.includes("/docs/");
    const onReleasePage = location.pathname.endsWith("/releases.html") && !inDocs;
    const onHomePage = !inDocs && !onReleasePage;
    const entries = [
      { href: inDocs ? "../" : onHomePage ? "#top" : "./", zh: "首页", en: "Home", current: onHomePage },
      { href: inDocs ? "./" : "docs/", zh: "文档", en: "Docs", current: inDocs },
      { href: inDocs ? "../releases.html" : "releases.html", zh: "更新日志", en: "Releases", current: onReleasePage },
      { href: inDocs ? "../#download" : onHomePage ? "#download" : "./#download", zh: "下载", en: "Download" }
    ];
    topLinks.replaceChildren(...entries.map((entry) => {
      const link = createBilingualLink(entry.href, entry.zh, entry.en);
      if (entry.current) link.setAttribute("aria-current", "page");
      return link;
    }));

    const navActions = document.querySelector(".nav-actions");
    if (navActions) {
      navActions.querySelectorAll(".mobile-docs-link, .mobile-nav-link, .github-link").forEach((node) => node.remove());
      const languageSwitch = navActions.querySelector(".language-switch");
      const themeToggle = navActions.querySelector("[data-theme-toggle]");
      const insertBefore = themeToggle || languageSwitch;
      const docsLink = createBilingualLink(inDocs ? "./" : "docs/", "文档", "Docs", "mobile-nav-link");
      const releaseLink = createBilingualLink(inDocs ? "../releases.html" : "releases.html", "更新", "Releases", "mobile-nav-link");
      navActions.insertBefore(docsLink, insertBefore);
      navActions.insertBefore(releaseLink, insertBefore);
    }
  }

  const themeActions = document.querySelector(".nav-actions");
  let themeButton = document.querySelector("[data-theme-toggle]");
  if (!themeButton && themeActions) {
    themeButton = document.createElement("button");
    themeButton.type = "button";
    themeButton.className = "theme-switch";
    themeButton.dataset.themeToggle = "";
    themeActions.insertBefore(themeButton, themeActions.querySelector(".language-switch"));
  }
  if (themeButton) {
    themeButton.addEventListener("click", () => {
      applyTheme(activeTheme === "dark" ? "light" : "dark");
    });
  }

  document.querySelectorAll(".docs-sidebar").forEach((sidebar) => {
    if (sidebar.querySelector("[data-doc-search]")) return;
    const label = document.createElement("label");
    label.className = "docs-search";
    label.innerHTML = '<span aria-hidden="true">⌕</span><input type="search" data-doc-search data-placeholder-zh="搜索文档…" data-placeholder-en="Search docs…" placeholder="搜索文档…" aria-label="搜索文档" data-aria-zh="搜索文档" data-aria-en="Search documentation">';
    sidebar.prepend(label);
  });

  document.querySelectorAll("[data-doc-search]").forEach((input) => {
    const links = [...input.closest(".docs-sidebar").querySelectorAll("nav a")];
    input.addEventListener("input", () => {
      const query = input.value.trim().toLocaleLowerCase();
      links.forEach((link) => {
        link.hidden = Boolean(query) && !link.textContent.toLocaleLowerCase().includes(query);
      });
    });
  });

  function findAsset(assets, expression) {
    return assets.find((asset) => expression.test(asset.name));
  }

  function updateLink(selector, asset) {
    const link = document.querySelector(selector);
    if (link && asset?.browser_download_url) link.href = asset.browser_download_url;
  }

  async function loadLatestRelease() {
    setStatus({ "zh-CN": copy["zh-CN"].checking, en: copy.en.checking });
    const controller = new AbortController();
    const timeout = window.setTimeout(() => controller.abort(), 5000);

    try {
      const response = await fetch(RELEASE_API, {
        headers: { Accept: "application/vnd.github+json" },
        signal: controller.signal
      });
      if (!response.ok) throw new Error(`GitHub API returned ${response.status}`);

      const release = await response.json();
      const assets = Array.isArray(release.assets) ? release.assets : [];
      const version = release.tag_name || FALLBACK_VERSION;
      const macOS = findAsset(assets, /-macOS\.dmg$/i);
      const iPhone = findAsset(assets, /-iPhone-Simulator\.zip$/i);
      const iPad = findAsset(assets, /-iPad-Simulator\.zip$/i);
      const checksums = findAsset(assets, /-SHA256SUMS\.txt$/i);

      updateLink("#hero-download", macOS);
      updateLink("#download-macos", macOS);
      updateLink("#download-iphone", iPhone);
      updateLink("#download-ipad", iPad);
      updateLink("#download-checksums", checksums);

      const releasePage = document.querySelector("#release-page");
      if (releasePage && release.html_url) releasePage.href = release.html_url;
      document.querySelectorAll("[data-release-version]").forEach((node) => {
        node.textContent = version;
      });

      setStatus(
        {
          "zh-CN": copy["zh-CN"].ready(version),
          en: copy.en.ready(version)
        },
        "is-ready"
      );
    } catch {
      setStatus(
        {
          "zh-CN": copy["zh-CN"].fallback,
          en: copy.en.fallback
        },
        "is-fallback"
      );
    } finally {
      window.clearTimeout(timeout);
    }
  }

  applyTheme(preferredTheme(), false);
  applyLanguage(preferredLanguage(), false);
  const year = document.querySelector("#copyright-year");
  if (year) year.textContent = String(new Date().getFullYear());
  if (status) loadLatestRelease();

  window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", (event) => {
    try {
      if (localStorage.getItem(THEME_KEY)) return;
    } catch {
      // Apply the system change when storage cannot be read.
    }
    applyTheme(event.matches ? "dark" : "light", false);
  });
})();
