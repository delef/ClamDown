// ClamDown landing page: latest-release details, the lid demo and the fan-curve chart.
(() => {
  "use strict";

  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];

  /* ---------- Latest release from GitHub ----------
     The download links already point at releases/latest/download/ClamDown.dmg, so they work
     without this. The API only adds the version and size, and the exact asset URL. */
  async function loadRelease() {
    try {
      const response = await fetch("https://api.github.com/repos/delef/ClamDown/releases/latest", {
        headers: { Accept: "application/vnd.github+json" },
      });
      if (!response.ok) return;
      const release = await response.json();
      const asset = (release.assets || []).find((a) => a.name.endsWith(".dmg"));
      const version = String(release.tag_name || "").replace(/^v/, "");
      if (asset) {
        $$("[data-download]").forEach((a) => { a.href = asset.browser_download_url; });
        $$("[data-asset-name]").forEach((el) => { el.textContent = asset.name; });
        const size = $("[data-release-size]");
        if (size) {
          size.textContent = `${(asset.size / 1e6).toFixed(1)} MB`;
          size.hidden = false;
        }
      }
      if (version) {
        const label = $("[data-release-version]");
        if (label) label.textContent = `Version ${version}`;
        const line = $("[data-release-line]");
        if (line) line.textContent = `Version ${version}. Free, for macOS 13 or later.`;
      }
    } catch {
      // Offline or rate-limited: the static links and text stay as they are.
    }
  }

  /* ---------- Fan curve (shared by the demo and the chart) ---------- */
  const CURVE = { low: 60, high: 85 };
  const fanShare = (t) => Math.min(1, Math.max(0, (t - CURVE.low) / (CURVE.high - CURVE.low)));

  /* ---------- The lid demo ---------- */
  function initDemo() {
    const stage = $(".stage");
    if (!stage) return;
    const term = $("[data-term]", stage);
    const elapsedEl = $("[data-elapsed]", stage);
    const toggle = $("[data-switch]", stage);
    const lidButton = $("[data-lid]", stage);
    const caption = $("[data-caption]", stage);
    const r = {
      mac: $("[data-r-mac]", stage),
      screen: $("[data-r-screen]", stage),
      cpu: $("[data-r-cpu]", stage),
      fans: $("[data-r-fans]", stage),
    };

    const FAN_MIN = 1300;
    const FAN_MAX = 4900;
    const state = { on: true, closed: false, temp: 58, fan: FAN_MIN, elapsed: 1 * 3600 + 42 * 60 + 7, touched: false };
    const awake = () => !state.closed || state.on;

    // An autonomous coding agent working through a task list: read, edit, test, fix, commit, next task.
    const tasks = [
      { title: "Move invoices to the new payments API", files: ["src/billing/invoice.ts", "src/billing/refund.ts"] },
      { title: "Retry failed webhook deliveries", files: ["src/webhooks/deliver.ts", "src/webhooks/queue.ts"] },
      { title: "Add rate limits to the public API", files: ["src/api/limits.ts", "src/api/router.ts"] },
      { title: "Fix the flaky checkout test", files: ["test/checkout.spec.ts", "src/cart/total.ts"] },
      { title: "Cache exchange rates for an hour", files: ["src/fx/rates.ts", "src/fx/cache.ts"] },
    ];
    const TOTAL = 12;
    let taskIndex = 3;
    let stepIndex = 0;
    let testCount = 1184;
    const script = (task, n) => [
      { text: `› Task ${n} of ${TOTAL}: ${task.title}`, cls: "event" },
      { text: `  Read ${task.files[0]}`, cls: "dim" },
      { text: `  Edit ${task.files[0]}  +38 −12` },
      { text: `  Edit ${task.files[1]}  +9 −4` },
      { text: "  Run npm test", cls: "dim" },
      { text: `  ${testCount} passed, 1 failed`, cls: "warn" },
      { text: `  Edit ${task.files[1]}  +3 −1` },
      { text: "  Run npm test", cls: "dim" },
      { text: `  ${testCount + 1} passed`, cls: "ok" },
      { text: `  Commit “${task.title}”`, cls: "ok" },
    ];
    const nextLine = () => {
      const task = tasks[taskIndex % tasks.length];
      const lines = script(task, (taskIndex % TOTAL) + 1);
      const line = lines[stepIndex];
      stepIndex += 1;
      if (stepIndex >= lines.length) {
        stepIndex = 0;
        taskIndex += 1;
        testCount += 1;
      }
      return line;
    };

    const MAX_LINES = 7;
    const print = ({ text, cls }) => {
      const li = document.createElement("li");
      li.textContent = text;
      if (cls) li.className = cls;
      term.append(li);
      while (term.children.length > MAX_LINES) term.firstElementChild.remove();
    };

    for (let i = 0; i < 6; i += 1) print(nextLine());

    const formatElapsed = (s) => {
      const h = Math.floor(s / 3600);
      const m = String(Math.floor((s % 3600) / 60)).padStart(2, "0");
      const sec = String(s % 60).padStart(2, "0");
      return `${h}:${m}:${sec}`;
    };

    const captions = {
      "open-on": "ClamDown is on. Close the lid to see what changes.",
      "open-off": "ClamDown is off. Close the lid and the Mac sleeps.",
      "closed-on": "Lid closed, still working. The screen is locked and the fans follow the temperature.",
      "closed-off": "Lid closed, Mac asleep. The job stopped where it was.",
    };

    const render = () => {
      stage.dataset.lid = state.closed ? "closed" : "open";
      stage.dataset.awake = String(awake());
      lidButton.textContent = state.closed ? "Open the lid" : "Close the lid";
      lidButton.setAttribute("aria-pressed", String(state.closed));
      // With the lid closed there is no menu bar to reach, so the switch waits for the lid to open.
      toggle.disabled = state.closed;
      toggle.closest(".switch").title = state.closed ? "Open the lid to reach the menu bar" : "";

      r.mac.textContent = awake() ? "Awake" : "Asleep";
      r.mac.classList.toggle("is-on", state.closed && awake());
      r.screen.textContent = state.closed ? "Locked" : "Unlocked";
      r.cpu.textContent = `${Math.round(state.temp)} °C`;
      if (!awake()) {
        r.fans.textContent = "Off";
        r.fans.classList.remove("is-on");
      } else {
        const rpm = Math.round(state.fan / 10) * 10;
        r.fans.textContent = `${rpm.toLocaleString("en-US")} rpm`;
        r.fans.classList.toggle("is-on", state.closed && state.on);
      }
    };

    const setCaption = () => {
      caption.textContent = captions[`${state.closed ? "closed" : "open"}-${state.on ? "on" : "off"}`];
    };

    const setLid = (closed) => {
      state.closed = closed;
      if (closed) {
        print(state.on
          ? { text: "Lid closed. Screen locked, Mac stays awake.", cls: "event" }
          : { text: "Lid closed. Mac went to sleep.", cls: "event" });
      } else {
        print(state.on || !term.lastElementChild?.textContent.includes("sleep")
          ? { text: "Lid opened.", cls: "event" }
          : { text: "Woke from sleep.", cls: "event" });
      }
      setCaption();
      render();
    };

    lidButton.addEventListener("click", () => {
      state.touched = true;
      setLid(!state.closed);
    });
    toggle.addEventListener("change", () => {
      state.touched = true;
      state.on = toggle.checked;
      print({ text: state.on ? "ClamDown turned on." : "ClamDown turned off.", cls: "event" });
      setCaption();
      render();
    });

    // Simulation: temperature drifts toward a target, the fans follow the curve while ClamDown holds them.
    let last = 0;
    let lineClock = 0;
    let secondClock = 0;
    const step = (now) => {
      const dt = Math.min(0.25, (now - (last || now)) / 1000);
      last = now;
      const target = !awake() ? 41 : state.closed ? 77 : 58;
      state.temp += (target - state.temp) * Math.min(1, dt * 0.35);

      let fanTarget = FAN_MIN;
      if (awake() && state.closed && state.on) fanTarget = FAN_MIN + fanShare(state.temp) * (FAN_MAX - FAN_MIN);
      if (fanTarget >= state.fan) state.fan = fanTarget;               // rises at once
      else state.fan = Math.max(fanTarget, state.fan - 50 * dt);      // falls by at most 150 rpm per 3 s

      if (awake()) {
        lineClock += dt;
        secondClock += dt;
        if (lineClock > 1.1) { lineClock = 0; print(nextLine()); }
        if (secondClock >= 1) { secondClock -= 1; state.elapsed += 1; elapsedEl.textContent = formatElapsed(state.elapsed); }
      }
      render();
      requestAnimationFrame(step);
    };

    render();
    if (reducedMotion) {
      // No streaming, no autoplay: the demo still answers clicks, and the readouts jump to their targets.
      const settle = () => {
        state.temp = !awake() ? 41 : state.closed ? 77 : 58;
        state.fan = awake() && state.closed && state.on ? FAN_MIN + fanShare(state.temp) * (FAN_MAX - FAN_MIN) : FAN_MIN;
        render();
      };
      lidButton.addEventListener("click", settle);
      toggle.addEventListener("change", settle);
      return;
    }
    requestAnimationFrame(step);

    // The page's one orchestrated moment: once the stage is in view, the lid closes by itself.
    const io = new IntersectionObserver((entries) => {
      if (!entries.some((e) => e.isIntersecting)) return;
      io.disconnect();
      setTimeout(() => { if (!state.touched) setLid(true); }, 1600);
    }, { threshold: 0.6 });
    io.observe(stage);
  }

  /* ---------- Fan-curve chart ---------- */
  function initChart() {
    const plot = $("[data-chart]");
    if (!plot) return;
    const svg = $("svg", plot);
    const X0 = 56, X1 = 540, Y_LOW = 240, Y_FULL = 40;
    const T0 = 40, T1 = 95;
    const x = (t) => X0 + ((t - T0) / (T1 - T0)) * (X1 - X0);
    const y = (share) => Y_LOW - share * (Y_LOW - Y_FULL);
    const ns = "http://www.w3.org/2000/svg";
    const make = (tag, attrs, parent) => {
      const el = document.createElementNS(ns, tag);
      Object.entries(attrs).forEach(([k, v]) => el.setAttribute(k, v));
      parent.append(el);
      return el;
    };

    const points = [[T0, 0], [CURVE.low, 0], [CURVE.high, 1], [T1, 1]];
    const d = points.map(([t, s], i) => `${i ? "L" : "M"}${x(t)},${y(s)}`).join(" ");
    $(".chart__line", svg).setAttribute("d", d);
    $(".chart__area", svg).setAttribute("d", `${d} L${x(T1)},${Y_LOW} L${x(T0)},${Y_LOW} Z`);

    const xl = $(".chart__xlabels", svg);
    for (let t = 40; t <= 90; t += 10) make("text", { x: x(t), y: 266 }, xl).textContent = `${t} °C`;

    const knees = $(".chart__knees", svg);
    make("circle", { cx: x(CURVE.low), cy: y(0), r: 5 }, knees);
    make("circle", { cx: x(CURVE.high), cy: y(1), r: 5 }, knees);
    make("text", { x: x(CURVE.low) - 8, y: y(0) - 14, "text-anchor": "end" }, knees).textContent = "60 °C: starts rising";
    make("text", { x: x(CURVE.high) - 10, y: y(1) - 14, "text-anchor": "end" }, knees).textContent = "85 °C: full speed";

    const cursor = $(".chart__cursor", svg);
    const cross = $(".chart__crosshair", svg);
    const dot = $(".chart__dot", svg);
    const tip = $(".chart__tip", plot);

    const show = (t) => {
      t = Math.round(Math.min(T1, Math.max(T0, t)));
      const share = fanShare(t);
      const px = x(t);
      cursor.removeAttribute("hidden");
      cross.setAttribute("x1", px);
      cross.setAttribute("x2", px);
      dot.setAttribute("cx", px);
      dot.setAttribute("cy", y(share));
      const speed = share === 0 ? "Lowest speed" : share === 1 ? "Full speed" : `${Math.round(share * 100)}% of the fan’s range`;
      tip.innerHTML = `<strong>${t} °C</strong><br>${speed}`;
      const box = svg.getBoundingClientRect();
      tip.style.left = `${(px / 560) * box.width}px`;
      tip.style.top = `${(y(share) / 300) * box.height - 10}px`;
      tip.hidden = false;
      current = t;
    };
    const hide = () => { cursor.setAttribute("hidden", ""); tip.hidden = true; };
    let current = 72;

    svg.addEventListener("pointermove", (e) => {
      const box = svg.getBoundingClientRect();
      const px = ((e.clientX - box.left) / box.width) * 560;
      show(T0 + ((px - X0) / (X1 - X0)) * (T1 - T0));
    });
    svg.addEventListener("pointerleave", hide);

    // Keyboard: focus the plot and use the arrow keys to step through temperatures.
    plot.tabIndex = 0;
    plot.setAttribute("aria-label", "Fan curve. Use the left and right arrow keys to read the fan speed at each temperature.");
    plot.addEventListener("focus", () => show(current));
    plot.addEventListener("blur", hide);
    plot.addEventListener("keydown", (e) => {
      if (e.key === "ArrowRight" || e.key === "ArrowLeft") {
        e.preventDefault();
        show(current + (e.key === "ArrowRight" ? 1 : -1) * (e.shiftKey ? 5 : 1));
      }
    });
  }

  loadRelease();
  initDemo();
  initChart();
})();
