/* 石割付ダイアログ。モデルへの変更はすべて Ruby 側で検証する。 */
'use strict';
(() => {
  const byId = id => document.getElementById(id);
  const KEYS = ['stone_width', 'stone_height', 'size_basis', 'min_width', 'min_height', 'max_width', 'max_height',
    'row_offset', 'align_u', 'origin_u', 'align_v', 'origin_v', 'end_mode', 'start_u', 'joint_at_corners',
    'thickness', 'reference', 'face_offset', 'direction', 'max_arc_angle', 'max_arc_error', 'material'];
  const PATTERNS = [
    { value: 'stack', label: '芋目地', note: '縦目地が通る', rows: [0, 0, 0] },
    { value: 'running', label: '馬踏み目地', note: '半分ずつずらす', rows: [0, 0.5, 0] },
    { value: 'offset', label: 'ずらし', note: 'ずらし量を指定', rows: [0, 0.33, 0.66] }
  ];
  // 平面図（上から見た出隅）。石を2枚、角で納める
  const CORNERS = [
    { value: 'miter', label: '留め', note: '斜めに合わせる',
      shapes: [[[4, 6], [44, 6], [36, 14], [4, 14]], [[48, 10], [48, 50], [40, 50], [40, 18]]] },
    { value: 'win_prev', label: '左が勝ち', note: '左の小口を見せる',
      shapes: [[[4, 6], [48, 6], [48, 14], [4, 14]], [[48, 18], [48, 50], [40, 50], [40, 18]]] },
    { value: 'win_next', label: '右が勝ち', note: '右の小口を見せる',
      shapes: [[[4, 6], [36, 6], [36, 14], [4, 14]], [[48, 6], [48, 50], [40, 50], [40, 6]]] }
  ];
  const PRESETS = [[600, 300], [600, 600], [900, 600], [1200, 600], [1200, 900]];
  let info = null, mode = 'create', timer = null;

  function notify(message, error = false) {
    byId('status').textContent = message || '';
    byId('status').classList.toggle('error', !!error);
  }

  function patternCard(p) {
    const b = document.createElement('button');
    b.type = 'button'; b.className = 'card'; b.dataset.value = p.value;
    b.setAttribute('role', 'radio'); b.setAttribute('aria-label', p.label);
    const ns = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(ns, 'svg');
    svg.setAttribute('viewBox', '0 0 60 30'); svg.setAttribute('aria-hidden', 'true');
    p.rows.forEach((shift, r) => {
      for (let i = -1; i < 4; i++) {
        const x = (i + shift) * 20 + 1, w = 18;
        const x0 = Math.max(x, 1), x1 = Math.min(x + w, 59);
        if (x1 - x0 < 2) continue;
        const rect = document.createElementNS(ns, 'rect');
        rect.setAttribute('x', x0); rect.setAttribute('y', r * 10 + 1); rect.setAttribute('width', x1 - x0); rect.setAttribute('height', 8);
        rect.setAttribute('fill', 'var(--fill)'); rect.setAttribute('stroke', 'var(--outline)'); rect.setAttribute('stroke-width', '0.6');
        svg.appendChild(rect);
      }
    });
    b.appendChild(svg);
    const t = document.createElement('strong'); t.textContent = p.label; b.appendChild(t);
    const s = document.createElement('small'); s.textContent = p.note; b.appendChild(s);
    b.addEventListener('click', () => { choose(p.value); changed(); });
    return b;
  }

  function cornerCard(c) {
    const b = document.createElement('button');
    b.type = 'button'; b.className = 'card corner'; b.dataset.value = c.value;
    b.setAttribute('role', 'radio'); b.setAttribute('aria-label', c.label);
    const ns = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(ns, 'svg');
    svg.setAttribute('viewBox', '0 0 56 56'); svg.setAttribute('aria-hidden', 'true');
    c.shapes.forEach(pts => {
      const pg = document.createElementNS(ns, 'polygon');
      pg.setAttribute('points', pts.map(p => p.join(',')).join(' '));
      pg.setAttribute('fill', 'var(--fill)'); pg.setAttribute('stroke', 'var(--outline)'); pg.setAttribute('stroke-width', '1');
      svg.appendChild(pg);
    });
    b.appendChild(svg);
    const t = document.createElement('strong'); t.textContent = c.label; b.appendChild(t);
    const s = document.createElement('small'); s.textContent = c.note; b.appendChild(s);
    b.addEventListener('click', () => { chooseCorner(c.value); changed(); });
    return b;
  }

  function chooseCorner(value) {
    document.querySelectorAll('.card.corner').forEach(c => c.setAttribute('aria-checked', String(c.dataset.value === value)));
    byId('corners').dataset.value = value;
  }

  function choose(value) {
    document.querySelectorAll('.card:not(.corner)').forEach(c => c.setAttribute('aria-checked', String(c.dataset.value === value)));
    byId('patterns').dataset.value = value;
    sync();
  }

  function renderPresets() {
    byId('presets').replaceChildren(...PRESETS.map(([w, h]) => {
      const b = document.createElement('button');
      b.type = 'button'; b.textContent = `${w} × ${h}`;
      b.addEventListener('click', () => { byId('stone_width').value = w; byId('stone_height').value = h; sync(); changed(); });
      b.dataset.w = w; b.dataset.h = h;
      return b;
    }));
  }

  // 状況に関係のない項目は隠す
  function sync() {
    const s = info ? info.surface : {};
    byId('row-offset-field').hidden = byId('patterns').dataset.value !== 'offset';
    byId('origin-u-field').hidden = byId('align_u').value !== 'custom';
    byId('origin-v-field').hidden = byId('align_v').value !== 'custom';
    byId('start-u-field').hidden = !s.periodic;
    byId('corner-field').hidden = !s.has_corners;
    byId('corner-box').hidden = !s.has_corners || !byId('joint_at_corners').checked;
    byId('arc-options').hidden = !(s.has_arcs || s.periodic);
    byId('offset-field').hidden = byId('reference').value !== 'substrate';
    const split = byId('split_joint').checked;
    byId('joint-split').hidden = !split;
    byId('joint').disabled = split;
    byId('basis-hint').textContent = byId('size_basis').value === 'pitch'
      ? '石の幅・高さは目地の芯から芯までの寸法です（実際の石は目地幅の分だけ小さくなります）。'
      : '石の幅・高さは石そのものの大きさです（割付のピッチは目地幅の分だけ大きくなります）。';
    document.querySelectorAll('#presets button').forEach(b => {
      b.setAttribute('aria-pressed', String(Number(b.dataset.w) === Number(byId('stone_width').value) &&
        Number(b.dataset.h) === Number(byId('stone_height').value)));
    });
  }

  function num(id) {
    const v = byId(id).value;
    return v === '' ? null : Number(v);
  }

  function collect() {
    const o = {};
    KEYS.forEach(k => {
      const el = byId(k);
      if (el.type === 'checkbox') o[k] = el.checked;
      else if (el.type === 'number') o[k] = num(k);
      else o[k] = el.value === '' ? null : el.value;
    });
    o.pattern = byId('patterns').dataset.value || 'stack';
    o.corner_mode = byId('corners').dataset.value || 'miter';
    if (byId('split_joint').checked) { o.joint_v = num('joint_v'); o.joint_h = num('joint_h'); }
    else { o.joint_v = num('joint'); o.joint_h = num('joint'); }
    return JSON.stringify(o);
  }

  function changed() {
    if (mode !== 'create') return;
    clearTimeout(timer);
    timer = setTimeout(() => sketchup.preview(collect()), 250);
  }

  function renderPreview(p) {
    const svg = byId('preview-svg');
    svg.replaceChildren();
    if (!p) { byId('preview').hidden = mode === 'edit'; return; }
    byId('preview').hidden = false;
    const [x0, y0, x1, y1] = p.bbox;
    const W = 480, H = 150, pad = 8;
    const k = Math.min((W - pad * 2) / Math.max(x1 - x0, 1), (H - pad * 2) / Math.max(y1 - y0, 1));
    const ox = (W - (x1 - x0) * k) / 2, oy = (H - (y1 - y0) * k) / 2;
    const X = x => ox + (x - x0) * k, Y = y => H - oy - (y - y0) * k;
    const ns = 'http://www.w3.org/2000/svg';
    const add = (tag, attrs) => { const n = document.createElementNS(ns, tag); Object.entries(attrs).forEach(([a, v]) => n.setAttribute(a, v)); svg.appendChild(n); return n; };
    add('polygon', { points: p.boundary.map(([x, y]) => `${X(x)},${Y(y)}`).join(' '), fill: 'var(--stone)', stroke: 'var(--outline)', 'stroke-width': 1.2 });
    const d = p.lines.map(([ax, ay, bx, by]) => `M${X(ax).toFixed(1)},${Y(ay).toFixed(1)}L${X(bx).toFixed(1)},${Y(by).toFixed(1)}`).join('');
    add('path', { d, stroke: 'var(--accent)', 'stroke-width': Math.max(0.6, Math.min(1.6, k * 8)), fill: 'none' });
  }

  function renderStats(st) {
    if (!st) return;
    const parts = [`<b>${st.stones}</b> 枚`];
    if (st.row_count) parts.push(`<b>${st.row_count}</b> 段`);
    if (st.rows && st.rows.length) parts.push(`端の石 左 ${st.rows[0].first} mm ／ 右 ${st.rows[0].last} mm`);
    byId('stats').innerHTML = parts.join('　·　');
  }

  window.init = data => {
    info = data; mode = data.mode;
    const s = data.settings, sf = data.surface;
    renderPresets();
    byId('patterns').replaceChildren(...PATTERNS.map(patternCard));
    KEYS.forEach(k => {
      const el = byId(k), v = s[k];
      if (el.type === 'checkbox') el.checked = !!v; else el.value = v === null || v === undefined ? '' : v;
    });
    byId('joint').value = s.joint_v;
    byId('joint_v').value = s.joint_v; byId('joint_h').value = s.joint_h;
    byId('split_joint').checked = Number(s.joint_v) !== Number(s.joint_h);
    choose(s.pattern);
    byId('corners').replaceChildren(...CORNERS.map(cornerCard));
    chooseCorner(s.corner_mode || 'miter');
    const size = `${Math.round(sf.length).toLocaleString()} × ${Math.round(sf.height).toLocaleString()} mm`;
    if (mode === 'edit') {
      byId('mode').textContent = `編集中 · ${sf.kind} ${size}${data.manual ? ' · 手で調整した目地あり' : ''}`;
      byId('primary').textContent = '反映する（目地の位置はそのまま）';
      byId('relayout-box').hidden = false;
      byId('relayout-slot').append(byId('layout-basic'), byId('layout-advanced'));
      renderPreview(data.preview);
      renderStats(data.stats);
    } else {
      byId('mode').textContent = `${sf.kind} · ${sf.periodic ? '一周 ' : ''}${size}`;
    }
    sync();
    if (data.warnings && data.warnings.length) notify('注意: ' + data.warnings.join('\n'));
    if (mode === 'create') sketchup.preview(collect());
  };

  window.report = r => {
    if (r.error) notify([].concat(r.error).join('\n'), true);
    else notify(r.message || (r.warnings && r.warnings.length ? '注意: ' + r.warnings.join('\n') : ''));
    if (r.preview !== undefined) renderPreview(r.preview);
    if (r.stats) renderStats(r.stats);
  };
  window.showError = m => notify(m, true);

  byId('form').addEventListener('input', () => { sync(); changed(); });
  byId('form').addEventListener('change', () => { sync(); changed(); });
  byId('form').addEventListener('submit', e => { e.preventDefault(); sketchup.apply(collect()); });
  byId('relayout').addEventListener('click', () => sketchup.relayout(collect()));
  byId('close').addEventListener('click', () => sketchup.close());
  window.addEventListener('load', () => sketchup.ready());
})();
