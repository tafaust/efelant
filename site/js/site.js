(function () {
  const menu = document.querySelector("[data-menu]");
  const nav = document.querySelector("[data-nav]");
  function setMenu(open) {
    if (!menu || !nav) {
      return;
    }
    nav.classList.toggle("open", open);
    menu.setAttribute("aria-expanded", String(open));
    menu.setAttribute("aria-label", open ? "Close menu" : "Open menu");
  }
  if (menu && nav) {
    menu.addEventListener("click", (event) => {
      event.stopPropagation();
      setMenu(!nav.classList.contains("open"));
    });
    nav.querySelectorAll("a").forEach((link) => {
      link.addEventListener("click", () => setMenu(false));
    });
    document.addEventListener("click", (event) => {
      if (!nav.classList.contains("open")) {
        return;
      }
      if (nav.contains(event.target) || menu.contains(event.target)) {
        return;
      }
      setMenu(false);
    });
    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        setMenu(false);
      }
    });
  }

  document.querySelectorAll("[data-tabs]").forEach((box) => {
    const buttons = [...box.querySelectorAll("[data-tab]")];
    const panes = [...box.querySelectorAll("[data-pane]")];
    buttons.forEach((button) => {
      button.addEventListener("click", () => {
        const id = button.getAttribute("data-tab");
        buttons.forEach((item) =>
          item.setAttribute("aria-selected", String(item === button))
        );
        panes.forEach((pane) => {
          pane.hidden = pane.getAttribute("data-pane") !== id;
        });
      });
    });
  });

  document.querySelectorAll("pre").forEach((pre) => {
    if (pre.parentElement?.classList.contains("code")) {
      return;
    }
    const wrap = document.createElement("div");
    wrap.className = "code";
    pre.replaceWith(wrap);
    const button = document.createElement("button");
    button.type = "button";
    button.className = "copy";
    button.textContent = "Copy";
    wrap.append(button, pre);
    button.addEventListener("click", async () => {
      await navigator.clipboard.writeText(pre.innerText);
      button.textContent = "Copied";
      setTimeout(() => {
        button.textContent = "Copy";
      }, 1200);
    });
  });

  function escapeHtml(value) {
    return value
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;");
  }

  function paint(source, rules) {
    let parts = [{ text: source, cls: null }];
    for (const { re, cls } of rules) {
      const next = [];
      const flags = re.flags.includes("g") ? re.flags : `${re.flags}g`;
      for (const part of parts) {
        if (part.cls) {
          next.push(part);
          continue;
        }
        const global = new RegExp(re.source, flags);
        let last = 0;
        let match = global.exec(part.text);
        while (match) {
          if (match.index > last) {
            next.push({ text: part.text.slice(last, match.index), cls: null });
          }
          next.push({ text: match[0], cls });
          last = match.index + match[0].length;
          if (match[0].length === 0) {
            global.lastIndex += 1;
          }
          match = global.exec(part.text);
        }
        if (last < part.text.length) {
          next.push({ text: part.text.slice(last), cls: null });
        }
      }
      parts = next;
    }
    return parts
      .map((part) =>
        part.cls
          ? `<span class="tok ${part.cls}">${escapeHtml(part.text)}</span>`
          : escapeHtml(part.text)
      )
      .join("");
  }

  const BASH = [
    { re: /#[^\n]*/, cls: "tok-cm" },
    { re: /"[^"]+"(?=\s*:)/, cls: "tok-key" },
    { re: /\$[A-Za-z_][A-Za-z0-9_]*/, cls: "tok-var" },
    { re: /'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\$])*"/, cls: "tok-str" },
    { re: /"[^"\n$\\]+/, cls: "tok-str" },
    { re: /["']/, cls: "tok-str" },
    { re: /-[A-Za-z][\w-]*/, cls: "tok-flag" },
    {
      re: /\b(?:cp|curl|echo|export|cd|mkdir|docker|compose|kubectl|git)\b/,
      cls: "tok-kw",
    },
    { re: /\bhttps?:\/\/\S+/, cls: "tok-url" },
    { re: /\.\/[\w./-]+/, cls: "tok-fn" },
    { re: /(?<=^|\s)\.[\w.]+/, cls: "tok-str" },
  ];

  const SQL = [
    { re: /--[^\n]*/, cls: "tok-cm" },
    { re: /'(?:''|[^'])*'/, cls: "tok-str" },
    { re: /:[A-Za-z_]\w*/, cls: "tok-var" },
    { re: /\bp_[A-Za-z_]\w*/, cls: "tok-key" },
    { re: /=>/, cls: "tok-flag" },
    { re: /\b\d+\b/, cls: "tok-num" },
    {
      re: /\b(?:SELECT|FROM|WHERE|AND|OR|AS|JOIN|ON|INSERT|INTO|VALUES|UPDATE|SET|DELETE|CREATE|TABLE|FUNCTION|RETURNS|BEGIN|COMMIT|END|NULL|TRUE|FALSE)\b/i,
      cls: "tok-kw",
    },
    { re: /\b[A-Za-z_][\w.]*(?=\s*\()/, cls: "tok-fn" },
  ];

  const TS = [
    { re: /\/\/[^\n]*/, cls: "tok-cm" },
    { re: /\/\*[\s\S]*?\*\//, cls: "tok-cm" },
    {
      re: /'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"|`(?:\\.|[^`\\])*`/,
      cls: "tok-str",
    },
    {
      re: /\b(?:import|from|const|let|var|new|await|async|return|export|function|class|type|interface|typeof|void)\b/,
      cls: "tok-kw",
    },
    { re: /\b\d+\b/, cls: "tok-num" },
    { re: /\b[A-Za-z_][\w.]*(?=\s*[\(<])/, cls: "tok-fn" },
  ];

  const HTML = [
    { re: /<!--[\s\S]*?-->/, cls: "tok-cm" },
    { re: /<\/?[A-Za-z][\w:-]*/, cls: "tok-kw" },
    { re: /\/?>/, cls: "tok-kw" },
    { re: /(?<=\s)[A-Za-z_:][\w:-]*(?==)/, cls: "tok-key" },
    { re: /"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'/, cls: "tok-str" },
  ];

  const DART = [
    { re: /\/\/[^\n]*/, cls: "tok-cm" },
    { re: /'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"/, cls: "tok-str" },
    {
      re: /\b(?:final|const|var|new|return|class|this|required|late)\b/,
      cls: "tok-kw",
    },
    { re: /\b[A-Za-z_]\w*(?=\s*:)/, cls: "tok-key" },
    { re: /\b[A-Z][A-Za-z0-9_]*(?=\s*[\(<])/, cls: "tok-fn" },
  ];

  const HTTP = [
    { re: /^[A-Za-z-]+:/m, cls: "tok-key" },
    { re: /\bBearer\b/, cls: "tok-kw" },
    { re: /<[^>\n]+>/, cls: "tok-var" },
  ];

  const PROTO = [
    { re: /\/\/[^\n]*/, cls: "tok-cm" },
    { re: /"(?:\\.|[^"\\])*"/, cls: "tok-str" },
    {
      re: /\b(?:syntax|package|service|rpc|message|returns|repeated|optional|string|int32|int64|bool|bytes)\b/,
      cls: "tok-kw",
    },
    { re: /\b[A-Za-z_][\w.]*(?=\s*[\({])/, cls: "tok-fn" },
  ];

  function highlight(lang, source) {
    switch (lang) {
      case "bash":
      case "shell":
        return paint(source, BASH);
      case "sql":
        return paint(source, SQL);
      case "ts":
      case "js":
      case "javascript":
      case "typescript":
        return paint(source, TS);
      case "html":
        return paint(source, HTML);
      case "dart":
        return paint(source, DART);
      case "http":
        return paint(source, HTTP);
      case "proto":
        return paint(source, PROTO);
      case "text":
        return escapeHtml(source);
      default:
        return escapeHtml(source);
    }
  }

  function guessLang(source) {
    const text = source.trim();
    if (!text) {
      return "";
    }
    if (/^(syntax\s*=|service |message |package )/.test(text)) {
      return "proto";
    }
    if (/^(SELECT|BEGIN|UPDATE|INSERT|COMMIT|CREATE)\b/i.test(text)) {
      return "sql";
    }
    if (/^(import |export |const |let |await |async )/.test(text)) {
      return "ts";
    }
    if (text.startsWith("<")) {
      return "html";
    }
    if (/^(Authorization:|GET |POST |PUT |DELETE )/.test(text)) {
      return "http";
    }
    if (/^(cp |curl |docker |\.\/)/.test(text)) {
      return "bash";
    }
    if (/^[A-Z][A-Za-z0-9_]*\(/.test(text)) {
      return "dart";
    }
    return "text";
  }

  function colorPre(pre) {
    const target = pre.querySelector("code") ?? pre;
    const source = target.textContent ?? "";
    if (target.hasAttribute("data-api-proto") && !source.trim()) {
      return;
    }
    const lang = pre.getAttribute("data-lang") || guessLang(source);
    if (!lang) {
      return;
    }
    target.innerHTML = highlight(lang, source);
  }

  function colorAll() {
    document.querySelectorAll("pre").forEach(colorPre);
  }

  colorAll();
  window.efelantHighlight = colorAll;

  function tocDepth(heading) {
    const level = Number(heading.tagName.slice(1));
    return Number.isFinite(level) ? level : 2;
  }

  function tocBranchX(depth) {
    return 8.5 + (depth - 2) * 12;
  }

  function drawTocBranch(link, items, index) {
    const NS = "http://www.w3.org/2000/svg";
    const depth = items[index].depth;
    const prev = items[index - 1];
    const x = tocBranchX(depth);
    const svg = document.createElementNS(NS, "svg");
    svg.setAttribute("class", "toc-branch");
    svg.setAttribute("aria-hidden", "true");
    svg.style.width = `${Math.round(x + 8)}px`;
    function line(x1, y1, x2, y2) {
      const el = document.createElementNS(NS, "line");
      el.setAttribute("x1", String(x1));
      el.setAttribute("y1", String(y1));
      el.setAttribute("x2", String(x2));
      el.setAttribute("y2", String(y2));
      el.setAttribute("stroke-width", "1");
      svg.append(el);
    }
    function elbow(fromX, toX) {
      const el = document.createElementNS(NS, "path");
      el.setAttribute("d", `M ${fromX} 0 L ${fromX} 0 ${toX} 12`);
      el.setAttribute("fill", "none");
      el.setAttribute("stroke-width", "1");
      svg.append(el);
    }
    if (depth <= 2) {
      line(8.5, 6, 8.5, "100%");
    } else if (prev && prev.depth !== depth) {
      elbow(tocBranchX(prev.depth), x);
      line(x, 12, x, "100%");
    } else {
      line(x, 6, x, "100%");
    }
    link.prepend(svg);
  }

  function initToc() {
    const toc = document.querySelector(".toc");
    const article = document.querySelector("article.prose");
    if (!toc || !article) {
      return;
    }
    const headings = [...article.querySelectorAll("h2[id], h3[id]")].filter(
      (heading) => heading instanceof HTMLElement && !heading.closest(".card")
    );
    toc.querySelectorAll("a").forEach((link) => link.remove());
    if (headings.length === 0) {
      toc.hidden = true;
      return;
    }
    const list = document.createElement("div");
    list.className = "toc-list";
    const thumb = document.createElement("div");
    thumb.className = "toc-thumb";
    thumb.setAttribute("aria-hidden", "true");
    list.append(thumb);
    const items = headings.map((heading) => ({
      heading,
      depth: Math.min(3, Math.max(2, tocDepth(heading))),
    }));
    const links = items.map((item, index) => {
      const link = document.createElement("a");
      link.href = `#${item.heading.id}`;
      link.textContent = item.heading.textContent ?? item.heading.id;
      link.dataset.depth = String(item.depth);
      drawTocBranch(link, items, index);
      list.append(link);
      return link;
    });
    toc.append(list);

    function headerOffset() {
      const mast = document.querySelector(".mast");
      return (mast?.getBoundingClientRect().height ?? 64) + 16;
    }

    function scroller() {
      return document.scrollingElement ?? document.documentElement;
    }

    function atPageEnd() {
      const root = scroller();
      return root.scrollTop + root.clientHeight >= root.scrollHeight - 48;
    }

    function currentHeading() {
      if (headings.length === 0) {
        return null;
      }
      const root = scroller();
      if (atPageEnd() && root.scrollTop > 0) {
        return headings[headings.length - 1];
      }
      if (root.scrollTop <= 0) {
        return headings[0];
      }
      const y = headerOffset();
      let current = headings[0];
      for (const heading of headings) {
        if (heading.getBoundingClientRect().top - y <= 0) {
          current = heading;
        }
      }
      return current;
    }

    function paint(activeLink) {
      if (!(activeLink instanceof HTMLElement)) {
        return;
      }
      for (const link of links) {
        link.setAttribute("data-active", String(link === activeLink));
      }
      const depth = Number(activeLink.dataset.depth || "2");
      thumb.style.setProperty("--toc-top", `${activeLink.offsetTop}px`);
      thumb.style.setProperty("--toc-height", `${activeLink.offsetHeight}px`);
      thumb.style.setProperty("--toc-left", `${tocBranchX(depth) - 1}px`);
      activeLink.scrollIntoView({ block: "nearest", inline: "nearest" });
    }

    let holdUntil = 0;

    function sync() {
      if (Date.now() < holdUntil) {
        return;
      }
      const heading = currentHeading();
      if (!heading) {
        return;
      }
      paint(links.find((link) => link.hash === `#${heading.id}`) ?? null);
    }

    let ticking = false;
    function onScroll() {
      if (ticking) {
        return;
      }
      ticking = true;
      requestAnimationFrame(() => {
        ticking = false;
        sync();
      });
    }

    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("scrollend", sync);
    window.addEventListener("resize", onScroll);
    const observer = new IntersectionObserver(onScroll, {
      rootMargin: "-80px 0% -70% 0%",
      threshold: 1,
    });
    for (const heading of headings) {
      observer.observe(heading);
    }
    for (const link of links) {
      link.addEventListener("click", () => {
        paint(link);
        holdUntil = Date.now() + 500;
      });
    }
    sync();
  }

  initToc();
})();
