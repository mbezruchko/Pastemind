// Pastemind's site: the hero's panel replaying real searches, the kinds of clips, reveals as you scroll, the scan's
// marker, the film playing while it's in view, and a phone-friendly "download".
(() => {
  const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  // MARK: Navigation: a hairline once the page has scrolled.

  const nav = document.querySelector(".nav");
  const onScroll = () => nav.classList.toggle("scrolled", scrollY > 8);
  addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  // MARK: Reveals, and the scanned page marked once it's in view.

  const reveal = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      entry.target.classList.add("in");
      reveal.unobserve(entry.target);
    }
  }, { rootMargin: "0px 0px -12% 0px" });
  document.querySelectorAll(".reveal").forEach((node) => reveal.observe(node));

  const marking = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      setTimeout(() => entry.target.classList.add("marked"), 500);
      marking.unobserve(entry.target);
    }
  }, { threshold: 0.6 });
  document.querySelectorAll(".sense-scan .scan").forEach((node) => marking.observe(node));

  // MARK: The film plays (muted) while it's on screen, unless motion is reduced.

  const video = document.querySelector(".film video");
  const saving = navigator.connection?.saveData || matchMedia("(max-width: 700px)").matches;
  if (video && !reduced && !saving) {
    new IntersectionObserver(([entry]) => {
      if (entry.isIntersecting) video.play().catch(() => {});
      else video.pause();
    }, { threshold: 0.55 }).observe(video);
  }

  // MARK: Kinds of clips: each word shows its own capture.

  const shot = document.getElementById("kind-shot");
  const tabs = [...document.querySelectorAll(".kind-tabs [role=tab]")];
  for (const tab of tabs) {
    const preload = new Image();
    preload.src = `/media/${tab.dataset.shot}.webp`;
    tab.addEventListener("click", () => select(tab));
    tab.addEventListener("keydown", (event) => {
      const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[event.key];
      if (!step) return;
      event.preventDefault();
      const next = tabs[(tabs.indexOf(tab) + step + tabs.length) % tabs.length];
      next.focus();
      select(next);
    });
  }
  tabs.forEach((tab) => (tab.tabIndex = tab.getAttribute("aria-selected") === "true" ? 0 : -1));

  function select(tab) {
    if (tab.getAttribute("aria-selected") === "true") return;
    for (const other of tabs) {
      const on = other === tab;
      other.setAttribute("aria-selected", String(on));
      other.tabIndex = on ? 0 : -1;
    }
    shot.classList.add("swapping");
    setTimeout(() => {
      shot.src = `/media/${tab.dataset.shot}.webp`;
      shot.alt = tab.dataset.alt;
      shot.parentElement.setAttribute("aria-label", tab.textContent);
      shot.classList.remove("swapping");
    }, reduced ? 0 : 180);
  }

  // MARK: The hero's panel: real searches and what the app found for them.

  const owl = { tile: "image", title: "Image: 512×512", sub: "Safari · Tue", preview: "image", found: "a photo of an owl",
    meta: "Image · Safari · Tuesday at 19:52 · 512×512" };
  const scenes = [
    { q: "when does my plane leave", tile: "text", title: "Flight LH 2412 · MUC → BER · Gate K12", sub: "Mail · 2h",
      preview: "text", found: "the flight confirmation", text: "Flight LH 2412 · MUC → BER · Gate K12 · boards 18:40", meta: "Text · Mail · Today at 16:41 · 52 characters" },
    { q: "owl", ...owl },
    { q: "when is the rent due", tile: "file", title: "Scan 2026-09-14.pdf", sub: "Finder · Oct 8", preview: "scan", found: "the scanned lease, at the line about rent",
      meta: "File · Finder · Thursday, October 8" },
    { q: "call the dentist", tile: "audio", title: "File: New Recording 12.m4a", sub: "Voice Memos · Sun", preview: "audio", found: "a voice memo",
      meta: "File · Voice Memos · Sunday at 20:23" },
    { q: "orange color", tile: "color", title: "#F2A22A", sub: "Figma · Yesterday", preview: "color", found: "the color #F2A22A",
      meta: "Color · Figma · Yesterday at 11:05" },
  ];

  const panel = document.querySelector(".panel");
  const query = panel.querySelector(".query");
  const pane = panel.querySelector(".pane");
  const chips = [...document.querySelectorAll(".tries button")];
  const status = document.getElementById("demo-status");

  function tile(scene) {
    const node = el("span", `tile tile-${scene.tile}`);
    node.setAttribute("aria-hidden", "true");
    if (scene.tile === "image") {
      const img = el("img");
      img.src = "/media/owl.webp";
      img.alt = "";
      node.append(img);
    } else if (scene.tile === "color") {
      node.style.background = "#f2a22a";
    }
    return node;
  }

  function row(scene) {
    const item = el("li", "row selected");
    const text = el("span", "row-text");
    text.append(el("span", "row-title", scene.title), el("span", "row-sub", scene.sub));
    const key = el("span", "row-key", "⌘1");
    key.setAttribute("aria-hidden", "true");
    item.append(tile(scene), text, key);
    return item;
  }

  function scanPage() {
    const figure = el("div", "scan");
    const img = el("img");
    img.src = "/media/scan-page.webp";
    img.alt = "The scanned lease, with the line about when rent is due marked";
    figure.append(img, el("span", "ink ink-1"), el("span", "ink ink-2"));
    setTimeout(() => figure.classList.add("marked"), reduced ? 0 : 450);
    return figure;
  }

  function preview(scene) {
    const box = el("div", "preview");
    if (scene.preview === "text") {
      box.append(el("p", "preview-text", scene.text));
    } else if (scene.preview === "image") {
      const wrap = el("div", "preview-image");
      const img = el("img");
      img.src = "/media/owl.webp";
      img.alt = "A photo of an owl";
      img.width = 480;
      img.height = 480;
      wrap.append(img);
      box.append(wrap);
    } else if (scene.preview === "scan") {
      const wrap = el("div", "preview-scan");
      wrap.append(scanPage());
      box.append(wrap);
    } else if (scene.preview === "audio") {
      const wrap = el("div", "preview-audio");
      const wave = el("div", "wave");
      wave.setAttribute("aria-hidden", "true");
      for (let i = 0; i < 26; i++) {
        const bar = el("span");
        bar.style.height = `${18 + Math.round(Math.abs(Math.sin(i * 1.7) * 62 + Math.sin(i * 0.6) * 10))}px`;
        bar.style.animationDelay = `${(i % 7) * 90}ms`;
        wave.append(bar);
      }
      wrap.append(wave, el("p", null, "New Recording 12.m4a · 0:06"));
      box.append(wrap);
    } else if (scene.preview === "color") {
      const wrap = el("div", "preview-color");
      const strong = el("strong", null, "#F2A22A");
      const line = el("p");
      line.append(strong, document.createTextNode("  ·  RGB 242 162 42"));
      wrap.append(el("div", "swatch swatch-a"), line);
      box.append(wrap);
    }
    box.append(el("p", "preview-meta", scene.meta));
    return box;
  }

  // `announce`: say the result for screen readers (a search asked for, not the replay running by itself).
  function show(scene, announce) {
    const rows = el("ul", "rows");
    rows.append(row(scene));
    pane.replaceChildren(rows, preview(scene));
    if (announce) status.textContent = `Searched “${scene.q}”: found ${scene.found}, from ${scene.sub.split(" · ")[0]}.`;
  }

  function clear() {
    const rows = el("ul", "rows");
    pane.replaceChildren(rows, el("div", "preview"));
  }

  function press(index) {
    chips.forEach((chip, i) => chip.setAttribute("aria-pressed", String(i === index)));
  }

  let run = 0;          // each new search cancels the one being typed
  let current = 0;
  let auto = !reduced;  // replays on its own until a chip is clicked
  let visible = true;

  async function play(index, quick) {
    const mine = ++run;
    const scene = scenes[index];
    current = index;
    press(index);
    if (reduced) {
      query.textContent = scene.q;
      show(scene, true);
      return true;
    }
    clear();
    query.textContent = "";
    for (let n = 1; n <= scene.q.length; n++) {
      if (mine !== run) return false;
      query.textContent = scene.q.slice(0, n);
      const pause = quick ? 24 : 42 + Math.random() * 46 + (scene.q[n - 1] === " " ? 50 : 0);
      await sleep(pause);
    }
    await sleep(quick ? 120 : 260);
    if (mine !== run) return false;
    show(scene, quick);
    return true;
  }

  async function replay() {
    press(0);
    await sleep(3200);
    while (auto) {
      while (!visible || document.hidden) await sleep(400);
      if (!auto) return;
      const done = await play((current + 1) % scenes.length, false);
      if (!done || !auto) return;
      await sleep(3000);
    }
  }

  chips.forEach((chip, index) => chip.addEventListener("click", () => {
    auto = false;
    play(index, true);
  }));

  new IntersectionObserver(([entry]) => (visible = entry.isIntersecting), { threshold: 0.25 }).observe(panel);
  if (auto) replay();
  else press(0);

  // MARK: On a phone a DMG is no use: the buttons copy the link for the Mac instead.

  const ua = navigator.userAgent;
  const phone = /iPhone|iPod|Android/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1);

  async function copyLink(label, done) {
    try {
      await navigator.clipboard.writeText(`${location.origin}/`);
      label.textContent = done;
    } catch {
      label.textContent = location.host;
    }
  }

  if (phone) {
    for (const link of document.querySelectorAll("a.download")) {
      const label = link.querySelector(".download-label") || link;
      label.textContent = link.classList.contains("btn-small") ? "Copy link" : "Copy the link for your Mac";
      link.addEventListener("click", (event) => {
        event.preventDefault();
        copyLink(label, "Copied. Open it on your Mac.");
      });
    }
  }

})();
