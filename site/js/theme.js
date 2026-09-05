(function () {
  const KEY = "efelant-theme";
  const DARK = "primary";
  const LIGHT = "secondary";

  function read() {
    return localStorage.getItem(KEY) === LIGHT ? LIGHT : DARK;
  }

  function dirOf(value) {
    const slash = value.lastIndexOf("/");
    return slash === -1 ? "" : value.slice(0, slash + 1);
  }

  function apply(theme) {
    document.documentElement.setAttribute("data-efelant-theme", theme);
    if (document.body) {
      document.body.setAttribute("data-efelant-theme", theme);
    }
    const next = theme === LIGHT ? DARK : LIGHT;
    document.querySelectorAll("[data-theme-toggle]").forEach((button) => {
      button.setAttribute("aria-label", next === LIGHT ? "Switch to light theme" : "Switch to dark theme");
      button.setAttribute("aria-pressed", String(theme === LIGHT));
      button.textContent = theme === LIGHT ? "Dark" : "Light";
    });
    const dark = theme !== LIGHT;
    document.querySelectorAll("[data-brand-icon]").forEach((img) => {
      img.src = `${dirOf(img.getAttribute("src") || "")}${dark ? "icon-dark.svg" : "icon-light.svg"}`;
    });
    document.querySelectorAll("link[data-favicon]").forEach((link) => {
      link.href = `${dirOf(link.getAttribute("href") || "")}${dark ? "favicon-dark.svg" : "favicon-light.svg"}`;
    });
    document.querySelectorAll("link[data-favicon-png]").forEach((link) => {
      link.href = `${dirOf(link.getAttribute("href") || "")}${dark ? "favicon-32-dark.png" : "favicon-32-light.png"}`;
    });
  }

  apply(read());

  document.addEventListener("DOMContentLoaded", () => {
    apply(read());
    const host = document.querySelector(".mast-inner");
    if (!host || host.querySelector("[data-theme-toggle]")) {
      return;
    }
    const button = document.createElement("button");
    button.type = "button";
    button.className = "theme-toggle";
    button.setAttribute("data-theme-toggle", "");
    button.addEventListener("click", () => {
      const theme = read() === LIGHT ? DARK : LIGHT;
      localStorage.setItem(KEY, theme);
      apply(theme);
    });
    const menu = host.querySelector(".menu");
    host.insertBefore(button, menu);
    apply(read());
  });
})();
