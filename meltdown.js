// The iPhone meltdown on the homepage, animated the way the app does it (iOS/Cadence/UI/AlertOverlay.swift
// and CadenceCore/Meltdown.swift): the glow pulses, the edges flash red, the content shakes, letters ping
// off and pile up at the bottom, and the countdown's characters rattle around inside the ring.
// Only the pieces that fell in the screenshot break: O, Y and W from the heading, e, n and w from the
// title, and the clock's "-3:". Then it settles, resets and goes again.
// Leaves the screenshot in place for reduced motion or if anything here fails.
(function () {
  "use strict";
  var img = document.querySelector('img[src^="assets/ios-meltdown"]');
  if (!img || !window.requestAnimationFrame) return;
  if (window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches) return;

  // Points on a 400 × 869 iPhone screen, like the app's own numbers.
  var W = 400, H = 869;
  var HEADING = "SERIOUSLY. JOIN. NOW.", TITLE = "Design Review";
  var BREAK_LETTERS = ["h-4", "h-8", "h-19", "t-1", "t-5", "t-12"]; // O, Y, W · e, n, w
  var BREAK_SLOTS = [4, 3, 2]; // "-", "3", ":" counted from the right of "-3:33"
  var GRAVITY = 2200, PERIOD = 0.35, SHAKE = 7, RING_R = 221 / 2 - 4;

  function el(tag, cls, parent, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    if (parent) parent.appendChild(e);
    return e;
  }

  // Draws text one character at a time, words kept together, so letters can be measured and hidden.
  function breakable(parent, text, prefix) {
    var spans = {};
    text.split(" ").reduce(function (offset, word) {
      var w = el("span", "melt-word", parent);
      for (var i = 0; i < word.length; i++) spans[prefix + "-" + (offset + i)] = el("span", "melt-ch", w, word[i]);
      return offset + word.length + 1;
    }, 0);
    return spans;
  }

  var frame = el("div", "melt-frame");
  frame.setAttribute("role", "img");
  frame.setAttribute("aria-label", img.alt);
  var stage = el("div", "melt-stage", frame);
  stage.setAttribute("aria-hidden", "true");
  el("div", "melt-bg", stage);
  var wash = el("div", "melt-wash", stage);
  var glow = el("div", "melt-glow", stage);
  var edge = el("div", "melt-edge", stage);
  el("div", "melt-island", stage);
  var content = el("div", "melt-content", stage);
  var head = el("div", "melt-head", content);
  var ring = el("div", "melt-ring", content);
  var clock = el("div", "melt-clock", ring);
  var title = el("div", "melt-title", content);
  el("div", "melt-detail", content, "23:10 – 23:40 · Zoom · 6 people");
  var join = el("div", "melt-join", content);
  join.innerHTML = '<svg viewBox="0 0 30 20" width="30" height="20"><rect x="0" y="1" width="20" height="18" rx="4" fill="#fff"/><path d="M22 7l8-5v16l-8-5z" fill="#fff"/></svg>Join Zoom';
  var btns = el("div", "melt-btns", content);
  el("div", "melt-btn", btns).innerHTML = '<span class="melt-zz">z<sup>z</sup><sup><sup>z</sup></sup></span>Snooze 1&nbsp;min';
  el("div", "melt-btn", btns).innerHTML = '<span class="melt-x">✕</span>Dismiss';
  var layer = el("div", "melt-falling", stage);

  var glyphs = {};
  var h = breakable(head, HEADING, "h"), t = breakable(title, TITLE, "t");
  for (var k in h) glyphs[k] = { span: h[k], cls: "melt-head" };
  for (k in t) glyphs[k] = { span: t[k], cls: "melt-title" };
  var digits = []; // index 0 = leftmost
  for (var i = 0; i < 5; i++) digits.push(el("span", "melt-ch", clock));

  img.style.display = "none";
  img.parentNode.insertBefore(frame, img);

  var scale = 1;
  function fit() {
    scale = frame.clientWidth / W || 1;
    stage.style.transform = "scale(" + scale + ")";
  }
  fit();
  if (window.ResizeObserver) new ResizeObserver(fit).observe(frame); else addEventListener("resize", fit);

  // Where a character sits now, in screen points.
  function centre(span) {
    var r = span.getBoundingClientRect(), s = stage.getBoundingClientRect();
    return { x: (r.left + r.width / 2 - s.left) / scale, y: (r.top + r.height / 2 - s.top) / scale };
  }

  function shuffle(a) {
    a = a.slice();
    for (var i = a.length - 1; i > 0; i--) { var j = Math.floor(Math.random() * (i + 1)); var x = a[i]; a[i] = a[j]; a[j] = x; }
    return a;
  }

  var state;
  function reset() {
    layer.innerHTML = "";
    ring.querySelectorAll(".melt-loose").forEach(function (n) { n.remove(); });
    Object.keys(glyphs).forEach(function (id) { glyphs[id].span.classList.remove("broken"); });
    digits.forEach(function (d) { d.classList.remove("broken"); });
    frame.classList.remove("settling");
    state = {
      t: 0, phase: 0, late: 198, // 3:18 late, so the clock passes 3:33 on the way
      letters: shuffle(BREAK_LETTERS), slots: shuffle(BREAK_SLOTS),
      nextLetter: 0.6, nextDigit: 1.8, falling: [], bottle: [], doneAt: null
    };
  }

  function clockText(late) {
    var s = Math.floor(late);
    return "-" + Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0");
  }

  function step(dt) {
    var s = state;
    s.t += dt;
    s.late += dt;
    s.phase += dt / PERIOD;
    var progress = Math.min(1, 0.5 + s.t / 16);

    // Pulse, red wash, edge flash and shake, all at full panic.
    var pulse = (1 - Math.cos(s.phase * 2 * Math.PI)) / 2;
    wash.style.opacity = (0.22 * pulse).toFixed(3);
    edge.style.opacity = pulse.toFixed(3);
    glow.style.transform = "translate(-50%,-50%) scale(" + (0.8 + 0.38 * pulse).toFixed(3) + ")";
    content.style.transform = "translate(" + (SHAKE * Math.sin(s.phase * 2 * Math.PI * 2.3)).toFixed(2) + "px," +
      (SHAKE * 0.4 * Math.cos(s.phase * 2 * Math.PI * 3.1)).toFixed(2) + "px)";

    var text = clockText(s.late);
    for (var i = 0; i < 5; i++) digits[i].textContent = text[i] || "";

    // Something new breaks off?
    if (s.letters.length && s.t >= s.nextLetter) {
      s.nextLetter = s.t + (4 - 2.8 * progress) * (0.6 + 0.8 * Math.random());
      var id = s.letters.shift(), g = glyphs[id], at = centre(g.span);
      var piece = el("span", "melt-piece " + g.cls, layer, g.span.textContent);
      g.span.classList.add("broken");
      s.falling.push({ el: piece, x: at.x, y: at.y, vx: (Math.random() - 0.5) * 520, vy: -(180 + Math.random() * 380),
        a: 0, spin: (Math.random() - 0.5) * 14, resting: false });
    }
    if (s.slots.length && s.t >= s.nextDigit) {
      s.nextDigit = s.t + (7 - 3.5 * progress) * (0.7 + 0.6 * Math.random());
      var slot = s.slots.shift(), d = digits[4 - slot], c = centre(d);
      var rr = ring.getBoundingClientRect(), sr = stage.getBoundingClientRect();
      var cx = (rr.left + rr.width / 2 - sr.left) / scale, cy = (rr.top + rr.height / 2 - sr.top) / scale;
      d.classList.add("broken");
      s.bottle.push({ el: el("span", "melt-loose", ring), slot: slot, x: c.x - cx, y: c.y - cy,
        vx: (Math.random() - 0.5) * 600, vy: -(150 + Math.random() * 350), a: 0, spin: (Math.random() - 0.5) * 12 });
    }

    // Letters fall, bounce off the sides and settle on the floor.
    var floor = H - 24 - 14;
    s.falling.forEach(function (p) {
      if (!p.resting) {
        p.vy += GRAVITY * dt; p.x += p.vx * dt; p.y += p.vy * dt; p.a += p.spin * dt;
        if (p.x < 14) { p.x = 14; p.vx = Math.abs(p.vx) * 0.5; }
        if (p.x > W - 14) { p.x = W - 14; p.vx = -Math.abs(p.vx) * 0.5; }
        if (p.y >= floor) {
          p.y = floor;
          if (Math.abs(p.vy) < 140) { p.resting = true; p.vx = p.vy = p.spin = 0; }
          else { p.vy = -p.vy * 0.35; p.vx *= 0.6; p.spin *= 0.5; }
        }
      }
      p.el.style.transform = "translate(" + p.x.toFixed(1) + "px," + p.y.toFixed(1) + "px) translate(-50%,-50%) rotate(" + p.a.toFixed(3) + "rad)";
    });

    // The clock's loose characters rattle around inside the ring like a shaken bottle.
    var violence = 7000 + 9000 * progress, limit = RING_R - 22;
    s.bottle.forEach(function (b) {
      b.vx += (Math.random() * 2 - 1) * violence * dt;
      b.vy += (GRAVITY * 0.45 + (Math.random() * 2 - 1) * violence) * dt;
      var drag = Math.max(0, 1 - 0.6 * dt);
      b.vx *= drag; b.vy *= drag;
      b.x += b.vx * dt; b.y += b.vy * dt; b.a += b.spin * dt;
      var dist = Math.hypot(b.x, b.y);
      if (dist > limit) {
        var nx = b.x / dist, ny = b.y / dist;
        b.x = nx * limit; b.y = ny * limit;
        var into = b.vx * nx + b.vy * ny;
        if (into > 0) {
          b.vx -= nx * into * 1.7; b.vy -= ny * into * 1.7;
          b.spin = b.spin * 0.6 + (b.vx * -ny + b.vy * nx) / 22 * 0.5;
        }
      }
      b.el.textContent = text[4 - b.slot] || "";
      b.el.style.transform = "translate(-50%,-50%) translate(" + b.x.toFixed(1) + "px," + b.y.toFixed(1) + "px) rotate(" + b.a.toFixed(3) + "rad)";
    });

    // Once everything has broken and landed, let it rattle a while, then put it back together.
    if (!s.letters.length && !s.slots.length && s.falling.every(function (p) { return p.resting; })) {
      if (s.doneAt == null) s.doneAt = s.t;
      if (s.t - s.doneAt > 4) frame.classList.add("settling");
      if (s.t - s.doneAt > 4.6) reset();
    }
  }

  var running = false, last = null;
  function loop(now) {
    if (!running) return;
    var dt = last == null ? 0 : Math.min(1 / 20, Math.max(0, (now - last) / 1000));
    last = now;
    step(dt);
    requestAnimationFrame(loop);
  }
  function setRunning(on) {
    if (on === running) return;
    running = on;
    last = null;
    if (on) requestAnimationFrame(loop);
  }

  reset();
  step(0);
  var start = function () {
    if (window.IntersectionObserver) {
      new IntersectionObserver(function (entries) { setRunning(entries[0].isIntersecting); }).observe(frame);
    } else setRunning(true);
  };
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(start); else start();
})();
