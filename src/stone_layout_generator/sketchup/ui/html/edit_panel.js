/* 目地編集の補助パネル。操作の主役は 3D ビュー上の直接操作。 */
'use strict';
(() => {
  const byId = id => document.getElementById(id);
  let state = null;
  const fmt = n => Number(n).toLocaleString(undefined, { minimumFractionDigits: 1, maximumFractionDigits: 1 });

  window.update = info => {
    state = info;
    const st = info.stats;
    const extra = [st.manual_joints ? `手動 ${st.manual_joints}` : null, st.locked_joints ? `ロック ${st.locked_joints}` : null].filter(Boolean);
    byId('summary').textContent = [`石 ${st.stones} 枚`, `${st.face_area_m2} m²`, ...extra].join(' · ');
    const through = info.mode === 'through';
    byId('mode-partial').setAttribute('aria-pressed', String(!through));
    byId('mode-through').setAttribute('aria-pressed', String(through));

    const s = info.selection;
    byId('empty').hidden = !!s;
    byId('detail').hidden = !s;
    if (s) {
      const vertical = s.orient === 'v';
      byId('kind').textContent = `${s.mode} · ${s.orientation}${s.count > 1 ? `（${s.count}辺）` : ''}`;
      const badge = byId('badge');
      badge.textContent = { auto: '自動', manual: '手動', locked: 'ロック' }[s.status] || s.status;
      badge.className = `badge ${s.status}`;
      byId('pos').innerHTML = `${fmt(s.position)} <small>mm ${vertical ? '（左端から）' : '（下端から）'}</small>`;
      byId('minus').textContent = vertical ? '← 左' : '↓ 下';
      byId('plus').textContent = vertical ? '右 →' : '上 ↑';
      const locked = s.status === 'locked';
      byId('lock').textContent = locked ? '🔓 ロック解除' : '🔒 ロック';
      ['minus', 'plus', 'remove'].forEach(id => { byId(id).disabled = locked; });
    }
    if (document.activeElement !== byId('thickness')) byId('thickness').value = info.settings.thickness;
    const sameJoint = Number(info.settings.joint_v) === Number(info.settings.joint_h);
    byId('joint').disabled = !sameJoint;
    byId('joint').title = sameJoint ? '' : '縦横で目地幅が違います。「割付の設定…」で変更してください';
    if (document.activeElement !== byId('joint')) byId('joint').value = sameJoint ? info.settings.joint_v : '';
    byId('status').textContent = info.message || '';
  };
  window.showError = m => { byId('status').textContent = m; };

  const move = sign => {
    const v = String(byId('delta').value).trim().replace(/^[+-]/, '');
    if (!v) return;
    sketchup.move((sign < 0 ? '-' : '') + v);
  };
  byId('minus').addEventListener('click', () => move(-1));
  byId('plus').addEventListener('click', () => move(1));
  byId('delta').addEventListener('keydown', e => { if (e.key === 'Enter') move(e.shiftKey ? -1 : 1); });
  byId('lock').addEventListener('click', () => sketchup.lock(!(state && state.selection && state.selection.status === 'locked')));
  byId('remove').addEventListener('click', () => sketchup.remove());
  const setMode = m => { if (state && state.mode !== m) sketchup.mode(); };
  byId('mode-partial').addEventListener('click', () => setMode('partial'));
  byId('mode-through').addEventListener('click', () => setMode('through'));
  byId('apply').addEventListener('click', () => {
    const j = Number(byId('joint').value);
    const o = { thickness: Number(byId('thickness').value) };
    if (!byId('joint').disabled) { o.joint_v = j; o.joint_h = j; }
    sketchup.settings(JSON.stringify(o));
  });
  byId('dialog').addEventListener('click', () => sketchup.dialog());
  byId('schedule').addEventListener('click', () => sketchup.schedule());
  byId('finish').addEventListener('click', () => sketchup.finish());
  window.addEventListener('load', () => sketchup.ready());
})();
