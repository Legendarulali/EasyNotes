// Scroll-driven product tour: a sticky stage whose "camera" zooms and pans over the real app
// screenshots while callouts point at what each part does. Boxes and camera centres are
// fractions of the 2560 × 1600 screenshots; label positions are fractions of the visible frame.
(() => {
  const track = document.querySelector('[data-tour]');
  if (!track || !document.documentElement.classList.contains('motion')) return;

  const viewport = track.querySelector('.viewport');
  const camera = track.querySelector('.camera');
  const layer = track.querySelector('.marks-layer');
  const labelBox = track.querySelector('.labels');
  const legend = track.querySelector('.legend');
  const copies = [...track.querySelectorAll('.copy')];
  const nav = [...track.querySelectorAll('[data-goto]')];
  const shots = [...camera.querySelectorAll('img')];
  const order = shots.map((img) => img.dataset.shot);
  const narrow = matchMedia('(max-width: 820px)');

  // Camera keyframes: scroll progress, screenshot, zoom, and the screenshot point to centre.
  const KEYS = [
    { p: 0, shot: 'home', z: 1, x: 0.5, y: 0.5 },
    { p: 0.17, shot: 'home', z: 1, x: 0.5, y: 0.5 },
    { p: 0.245, shot: 'home', z: 2.4, x: 0.82, y: 0.2 },
    { p: 0.27, shot: 'menu', z: 2.4, x: 0.82, y: 0.2 },
    { p: 0.36, shot: 'menu', z: 2.4, x: 0.82, y: 0.2 },
    { p: 0.41, shot: 'editor', z: 1, x: 0.5, y: 0.5 },
    { p: 0.48, shot: 'editor', z: 1, x: 0.5, y: 0.5 },
    { p: 0.51, shot: 'editor', z: 1.45, x: 0.5, y: 0.8 },
    { p: 0.555, shot: 'editor', z: 1.45, x: 0.5, y: 0.8 },
    { p: 0.58, shot: 'pin', z: 1, x: 0.5, y: 0.5 },
    { p: 0.6, shot: 'pin', z: 1.5, x: 0.67, y: 0.48 },
    { p: 0.645, shot: 'pin', z: 1.5, x: 0.67, y: 0.48 },
    { p: 0.675, shot: 'editor', z: 2.2, x: 0.3, y: 0.2 },
    { p: 0.755, shot: 'editor', z: 2.2, x: 0.3, y: 0.2 },
    { p: 0.77, shot: 'editor', z: 2.2, x: 0.68, y: 0.2 },
    { p: 0.8, shot: 'editor', z: 2.2, x: 0.68, y: 0.2 },
    { p: 0.815, shot: 'editor', z: 2.2, x: 0.8, y: 0.1 },
    { p: 0.85, shot: 'editor', z: 2.2, x: 0.8, y: 0.1 },
    { p: 0.895, shot: 'split', z: 1, x: 0.5, y: 0.5 },
    { p: 1, shot: 'split', z: 1, x: 0.5, y: 0.5 },
  ];

  // Callouts: t = title, d = detail, box = target [x, y, w, h], at = label centre, f = featured.
  const GROUPS = [
    {
      from: 0.01, to: 0.17, items: [
        { t: 'Folders & subfolders', d: 'Rename, move or delete with a right-click or long-press', box: [0.016, 0.085, 0.477, 0.323], at: [0.2, 0.875] },
        { t: 'Live thumbnails', d: 'The first page of each notebook, refreshed when you close it', box: [0.353, 0.447, 0.131, 0.233], at: [0.47, 0.875] },
        { t: 'PDFs as notebooks', d: 'Lecture slides you can write on', box: [0.68, 0.1, 0.131, 0.232], at: [0.76, 0.875] },
        { t: 'Google Drive backup', d: 'Optional. Signed in and synced', box: [0.9547, 0.0088, 0.0359, 0.0525], at: [0.56, 0.05] },
      ],
    },
    {
      from: 0.275, to: 0.36, items: [
        { t: 'Import PDF', d: 'Also one click away in the top bar', box: [0.7585, 0.015, 0.1094, 0.04], at: [0.16, 0.09] },
        { t: 'Ruled Notebook', d: 'Pages that keep coming as you write', box: [0.853, 0.068, 0.147, 0.058], at: [0.4, 0.233] },
        { t: 'Grid Notebook', d: 'For maths, graphs and diagrams', box: [0.853, 0.1292, 0.147, 0.058], at: [0.4, 0.38] },
        { t: 'Blank Whiteboard', d: 'No page edges: it grows as you draw', box: [0.853, 0.1905, 0.147, 0.058], at: [0.4, 0.527] },
        { t: 'Folders', d: 'Nest them as deep as you like', box: [0.853, 0.2617, 0.147, 0.058], at: [0.4, 0.698] },
        { t: 'Vector PDF import', d: 'Write over the pages; exported text stays selectable', box: [0.853, 0.323, 0.147, 0.058], at: [0.4, 0.86] },
      ],
    },
    {
      from: 0.415, to: 0.48, items: [
        { t: 'Tabs', d: 'Several notebooks open at once; Ctrl+Tab switches', box: [0.033, 0.008, 0.405, 0.047], at: [0.12, 0.3] },
        { t: 'Highlighter', d: 'Blends under the ink like a real marker', box: [0.413, 0.4056, 0.0585, 0.0368], at: [0.12, 0.53] },
        { t: 'Page 1 / 2', d: 'The next page appears as you scroll or write', box: [0.1225, 0.972, 0.046, 0.02], at: [0.12, 0.8] },
        { t: 'Shape snap', d: 'The magic wand: off until you turn it on', box: [0.7611, 0.0075, 0.0313, 0.05], at: [0.88, 0.24] },
        { t: 'Sticky notes', d: 'Typed notes anywhere on the page', box: [0.5765, 0.2664, 0.1535, 0.132], at: [0.88, 0.53] },
      ],
    },
    {
      from: 0.515, to: 0.555, items: [
        { t: 'Straight lines', d: 'Levelled when within 5° of horizontal', box: [0.269, 0.71, 0.062, 0.049], at: [0.14, 0.34] },
        { t: 'Circles & ellipses', d: 'Fitted to your loop, no sharp corners', box: [0.37, 0.693, 0.158, 0.082], at: [0.43, 0.34] },
        { t: 'Triangles & rectangles', d: 'Squared up on pen-up', box: [0.555, 0.69, 0.165, 0.084], at: [0.75, 0.34] },
        { t: 'Trapezoids, 5–8-gons, stars', d: 'Recognised in 3–16 µs', box: [0.269, 0.834, 0.346, 0.092], at: [0.86, 0.94] },
      ],
    },
    {
      from: 0.6, to: 0.645, items: [
        { t: 'Pin', d: 'Snapshots the selection at up to 3× screen resolution', box: [0.4422, 0.593, 0.0313, 0.05], at: [0.38, 0.555], f: true },
        { t: 'See-through · Unpin', d: '100 % or 75 % opacity, × to close', box: [0.9563, 0.1875, 0.0312, 0.0275], at: [0.47, 0.08] },
        { t: 'Floating reference card', d: 'Stays on screen while you scroll, switch tabs or go Home', box: [0.7922, 0.2215, 0.1953, 0.222], at: [0.45, 0.28], f: true },
        { t: 'Resize', d: 'Corner grip, aspect ratio locked', box: [0.9703, 0.4165, 0.0172, 0.0275], at: [0.86, 0.62] },
      ],
    },
    {
      from: 0.68, to: 0.715, items: [
        { t: 'Pen · Pencil · Highlighter', d: 'Pressure-sensitive, variable-width ink', box: [0.2074, 0.0875, 0.1047, 0.0525], at: [0.3, 0.56] },
        { t: 'Two erasers', d: 'Whole strokes, or the classic eraser that cuts exactly', box: [0.3152, 0.0875, 0.0328, 0.0525], at: [0.56, 0.76] },
        { t: 'Sticky notes', d: 'Tap to place, type, drag to move', box: [0.423, 0.0875, 0.0328, 0.0525], at: [0.82, 0.56] },
      ],
    },
    {
      from: 0.72, to: 0.755, items: [
        { t: 'Dock anywhere', d: 'Drag the grip to any edge or corner', box: [0.116, 0.0862, 0.0172, 0.055], at: [0.13, 0.56] },
        { t: 'Undo / Redo', d: '100 steps · Ctrl+Z / Ctrl+Y', box: [0.1348, 0.0912, 0.0593, 0.045], at: [0.37, 0.76] },
        { t: 'Lasso & box select', d: 'Move, resize, copy, cut, duplicate, delete', box: [0.3512, 0.0875, 0.0687, 0.0525], at: [0.7, 0.56] },
      ],
    },
    {
      from: 0.77, to: 0.8, items: [
        { t: 'Palette', d: '8 inks, plus any colour by hex code', box: [0.47, 0.09, 0.235, 0.048], at: [0.3, 0.58] },
        { t: 'Thickness', d: 'A width slider for each tool', box: [0.7215, 0.0912, 0.1031, 0.045], at: [0.68, 0.58] },
        { t: 'Collapse', d: 'Fold the toolbar into one button', box: [0.8625, 0.104, 0.012, 0.02], at: [0.86, 0.8] },
      ],
    },
    {
      from: 0.815, to: 0.85, items: [
        { t: 'Split view', d: 'Ctrl+\\ puts two panes side by side', box: [0.6571, 0.0075, 0.0313, 0.05], at: [0.17, 0.44] },
        { t: 'Shape snap', d: 'Magic wand, off by default', box: [0.7611, 0.0075, 0.0313, 0.05], at: [0.42, 0.66] },
        { t: 'Finger drawing', d: 'For when the stylus battery runs out', box: [0.7923, 0.0075, 0.0313, 0.05], at: [0.66, 0.44] },
        { t: 'Export PDF', d: 'Vector output; imported text stays selectable', box: [0.8585, 0.0125, 0.1065, 0.04], at: [0.85, 0.66] },
      ],
    },
    {
      from: 0.9, to: 1.01, items: [
        { t: 'Tabs', d: 'Ctrl+Tab cycles; the clipboard is shared', box: [0.1512, 0.01, 0.27, 0.045], at: [0.2, 0.24] },
        { t: 'Annotate PDFs', d: 'Your ink sits over the original page', box: [0.202, 0.4656, 0.093, 0.029], at: [0.38, 0.37] },
        { t: 'Focused pane', d: 'The toolbar and shortcuts follow it', box: [0.5027, 0.065, 0.4973, 0.0375], at: [0.84, 0.3] },
        { t: 'Drag the divider', d: 'Double-click for 50 / 50 again', box: [0.4973, 0.2, 0.0055, 0.7], at: [0.5, 0.88] },
        { t: 'Its own zoom & scroll', d: '62 % here, 60 % on the left', box: [0.515, 0.9625, 0.04, 0.0375], at: [0.77, 0.84] },
      ],
    },
  ];

  const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
  const lerp = (a, b, t) => a + (b - a) * t;
  const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
  const smooth = (a, b, v) => {
    const t = clamp((v - a) / (b - a), 0, 1);
    return t * t * (3 - 2 * t);
  };

  // Label elements, created once.
  for (const g of GROUPS) {
    for (const it of g.items) {
      const el = document.createElement('div');
      el.className = it.f ? 'label feature' : 'label';
      el.innerHTML = '<b></b><span></span>';
      el.firstChild.textContent = it.t;
      el.lastChild.textContent = it.d;
      el.style.visibility = 'hidden';
      labelBox.append(el);
      it.el = el;
    }
  }

  function measure() {
    for (const g of GROUPS) {
      for (const it of g.items) {
        it.w = it.el.offsetWidth;
        it.h = it.el.offsetHeight;
      }
    }
  }

  function cameraAt(p) {
    let i = 0;
    while (i < KEYS.length - 2 && p > KEYS[i + 1].p) i++;
    const a = KEYS[i];
    const b = KEYS[i + 1];
    const t = ease(clamp((p - a.p) / (b.p - a.p), 0, 1));
    const s = Math.exp(lerp(Math.log(a.z), Math.log(b.z), t));
    const cx = lerp(a.x, b.x, t);
    const cy = lerp(a.y, b.y, t);
    return {
      s,
      tx: clamp(0.5 - cx * s, 1 - s, 0),
      ty: clamp(0.5 - cy * s, 1 - s, 0),
      from: a.shot,
      to: b.shot,
      fade: smooth(0.2, 0.8, t),
    };
  }

  // The lower screenshot stays opaque while the upper one fades, so a crossfade never dims.
  function opacities(cam) {
    const o = Object.fromEntries(order.map((n) => [n, 0]));
    if (cam.from === cam.to) {
      o[cam.from] = 1;
      return o;
    }
    const fromBelow = order.indexOf(cam.from) < order.indexOf(cam.to);
    o[fromBelow ? cam.from : cam.to] = 1;
    o[fromBelow ? cam.to : cam.from] = fromBelow ? cam.fade : 1 - cam.fade;
    return o;
  }

  const nearest = (r, pt) => ({ x: clamp(pt.x, r.x, r.x + r.w), y: clamp(pt.y, r.y, r.y + r.h) });
  const f1 = (v) => v.toFixed(1);
  let legendGroup = null;

  function drawMarks(p, cam, W, H) {
    const small = narrow.matches;
    let svg = '';
    let holes = '';
    let dim = 0;
    let shown = null;
    for (const g of GROUPS) {
      const alpha = Math.min(smooth(g.from, g.from + 0.008, p), 1 - smooth(g.to - 0.008, g.to, p));
      if (alpha > 0.5) shown = g;
      dim = Math.max(dim, alpha);
      g.items.forEach((it, i) => {
        if (alpha <= 0.001) {
          if (it.el.style.visibility !== 'hidden') {
            it.el.style.visibility = 'hidden';
            it.el.style.opacity = 0;
          }
          return;
        }
        const draw = clamp((p - g.from) / 0.007 - i * 0.45, 0, 1);
        const pad = 4;
        const box = {
          x: (cam.tx + cam.s * it.box[0]) * W - pad,
          y: (cam.ty + cam.s * it.box[1]) * H - pad,
          w: cam.s * it.box[2] * W + 2 * pad,
          h: cam.s * it.box[3] * H + 2 * pad,
        };
        const kind = it.f ? ' feature' : '';
        holes += `<rect x="${f1(box.x)}" y="${f1(box.y)}" width="${f1(box.w)}" height="${f1(box.h)}" rx="8" fill="#000" fill-opacity="${draw.toFixed(3)}"/>`;
        svg += `<rect class="ring${kind}" x="${f1(box.x)}" y="${f1(box.y)}" width="${f1(box.w)}" height="${f1(box.h)}" rx="8" opacity="${(alpha * draw).toFixed(3)}"/>`;
        if (small) {
          it.el.style.visibility = 'hidden';
          // Wide targets get the number on their left edge, others on top, so neighbours don't collide.
          const wide = box.w > 3 * box.h;
          const cx = clamp(wide ? box.x : box.x + box.w / 2, 12, W - 12);
          const cy = clamp(wide ? box.y + box.h / 2 : box.y, 12, H - 12);
          svg += `<g class="num${kind}" opacity="${alpha.toFixed(3)}"><circle cx="${f1(cx)}" cy="${f1(cy)}" r="10"/><text x="${f1(cx)}" y="${f1(cy)}">${i + 1}</text></g>`;
          return;
        }
        // Labels shrink with the frame (down to 70 %) so a small window isn't buried under them.
        const ls = clamp(W / 960, 0.7, 1);
        const lw = it.w * ls;
        const lh = it.h * ls;
        const lx = clamp(it.at[0] * W, lw / 2 + 8, W - lw / 2 - 8);
        const ly = clamp(it.at[1] * H, lh / 2 + 8, H - lh / 2 - 8);
        const label = { x: lx - lw / 2, y: ly - lh / 2, w: lw, h: lh };
        it.el.style.visibility = 'visible';
        it.el.style.opacity = alpha.toFixed(3);
        it.el.style.transform = `translate(${f1(label.x)}px, ${f1(label.y)}px) scale(${ls.toFixed(3)})`;
        const start = nearest(label, { x: box.x + box.w / 2, y: box.y + box.h / 2 });
        const end = nearest(box, { x: lx, y: ly });
        const dx = end.x - start.x;
        const dy = end.y - start.y;
        if (Math.hypot(dx, dy) < 6) return;
        const qx = (start.x + end.x) / 2 - dy * 0.16;
        const qy = (start.y + end.y) / 2 + dx * 0.16;
        const done = draw > 0.95;
        const d = `M${f1(start.x)} ${f1(start.y)} Q${f1(qx)} ${f1(qy)} ${f1(end.x)} ${f1(end.y)}`;
        const common = `pathLength="1" d="${d}" stroke-dashoffset="${(1 - draw).toFixed(3)}" opacity="${alpha.toFixed(3)}"`;
        // A dark halo under each arrow keeps it visible over white paper.
        svg += `<path class="arrow-halo" ${common}${done ? ' marker-end="url(#head-halo)"' : ''}/>`;
        svg += `<path class="arrow${kind}" ${common}${done ? ` marker-end="url(#head${it.f ? '-feature' : ''})"` : ''}/>`;
      });
    }
    // Spotlight: dim the screenshot except the highlighted parts.
    const spot = dim > 0.001
      ? `<mask id="spot" maskUnits="userSpaceOnUse" x="0" y="0" width="${W}" height="${H}"><rect width="${W}" height="${H}" fill="#fff"/>${holes}</mask>` +
        `<rect class="dim" width="${W}" height="${H}" mask="url(#spot)" opacity="${(dim * 0.45).toFixed(3)}"/>`
      : '';
    layer.innerHTML = spot + svg;

    if (shown !== legendGroup) {
      legendGroup = shown;
      legend.replaceChildren(
        ...(shown ? shown.items : []).map((it, i) => {
          const li = document.createElement('li');
          if (it.f) li.className = 'feature';
          li.innerHTML = '<span class="n"></span><div><b></b> <span></span></div>';
          li.querySelector('.n').textContent = i + 1;
          li.querySelector('b').textContent = it.t;
          li.querySelector('div span').textContent = it.d;
          return li;
        }),
      );
    }
  }

  const stages = [0, 0.18, 0.37, 0.565, 0.855, 1.01];

  function progress() {
    const r = track.getBoundingClientRect();
    return clamp(-r.top / Math.max(1, r.height - window.innerHeight), 0, 1);
  }

  let queued = false;
  function render() {
    queued = false;
    const p = progress();
    const W = viewport.clientWidth;
    const H = viewport.clientHeight;
    const cam = cameraAt(p);
    camera.style.transform = `translate3d(${f1(cam.tx * W)}px, ${f1(cam.ty * H)}px, 0) scale(${cam.s.toFixed(4)})`;
    const o = opacities(cam);
    shots.forEach((img) => {
      img.style.opacity = o[img.dataset.shot];
    });
    for (const c of copies) c.classList.toggle('on', p >= +c.dataset.from && p < +c.dataset.to);
    const chapter = stages.findIndex((s, i) => p >= s && p < stages[i + 1]);
    nav.forEach((b, i) => (i === chapter ? b.setAttribute('aria-current', 'step') : b.removeAttribute('aria-current')));
    drawMarks(p, cam, W, H);
  }

  const schedule = () => {
    if (!queued) {
      queued = true;
      requestAnimationFrame(render);
    }
  };

  nav.forEach((b) =>
    b.addEventListener('click', () => {
      const top = track.getBoundingClientRect().top + window.scrollY;
      window.scrollTo({ top: top + +b.dataset.goto * (track.offsetHeight - window.innerHeight), behavior: 'smooth' });
    }),
  );

  const relayout = () => {
    measure();
    schedule();
  };
  window.addEventListener('scroll', schedule, { passive: true });
  window.addEventListener('resize', relayout);
  narrow.addEventListener('change', relayout);
  if (document.fonts) document.fonts.ready.then(relayout);
  relayout();
})();
