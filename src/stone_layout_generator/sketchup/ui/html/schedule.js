/* 石寸法一覧ダイアログ */
'use strict';
(() => {
  const byId = id => document.getElementById(id);
  const num = (v, d = 1) => Number(v).toLocaleString(undefined, { minimumFractionDigits: d, maximumFractionDigits: d });
  const int = v => Number(v).toLocaleString(undefined, { maximumFractionDigits: 1 });
  const td = (text, cls) => { const c = document.createElement('td'); c.textContent = text; if (cls) c.className = cls; return c; };

  function notify(msg, error = false) {
    byId('status').textContent = msg || '';
    byId('status').classList.toggle('error', !!error);
  }

  window.render = data => {
    const t = data.totals;
    byId('sub').textContent = `${data.title} · ${t.count} 枚 · ${t.types} 種別 · 石厚 ${int(t.thickness)} mm` +
      (data.detached ? ` · 切り離した石 ${data.detached} 枚は対象外` : '');
    byId('t-count').textContent = `${t.count} 枚`;
    byId('t-area').textContent = `${num(t.area, 2)} m²`;
    byId('t-volume').textContent = `${num(t.volume, 3)} m³`;
    byId('t-weight').textContent = t.weight >= 1000 ? `${num(t.weight / 1000, 2)} t` : `${num(t.weight, 0)} kg`;
    if (document.activeElement !== byId('density')) byId('density').value = t.density;

    byId('types').tBodies[0].replaceChildren(...data.types.map(ty => {
      const tr = document.createElement('tr');
      tr.tabIndex = 0;
      tr.title = ty.labels.join(' ');
      const code = td(ty.code, 'l code');
      tr.append(code, td(ty.shape, 'l'), td(int(ty.width)), td(int(ty.height)), td(int(ty.thickness)), td(`${ty.count}`),
        td(num(ty.area, 3)), td(num(ty.weight, 1)), td(ty.note || '', 'l'));
      const pick = () => sketchup.select(ty.code);
      tr.addEventListener('click', pick);
      tr.addEventListener('keydown', e => { if (e.key === 'Enter') pick(); });
      return tr;
    }));
    byId('rows').tBodies[0].replaceChildren(...data.rows.map(r => {
      const tr = document.createElement('tr');
      tr.append(td(r.label, 'l'), td(r.type, 'l code'), td(r.shape, 'l'), td(int(r.width)), td(int(r.height)), td(int(r.thickness)),
        td(num(r.area, 4)), td(num(r.volume, 5)), td(num(r.weight, 1)), td(`${int(r.u0)}–${int(r.u1)}`), td(`${int(r.v0)}–${int(r.v1)}`),
        td(r.note || '', 'l'));
      return tr;
    }));
    if (data.errors && data.errors.length) notify('形状を作れなかった石があります:\n' + data.errors.join('\n'), true);
  };

  window.report = r => notify(r.error || r.message, !!r.error);

  byId('density').addEventListener('change', () => {
    const v = Number(byId('density').value);
    if (v > 0) sketchup.density(String(v)); else notify('比重は正の数で入力してください', true);
  });
  byId('export').addEventListener('click', () => sketchup.export());
  byId('close').addEventListener('click', () => sketchup.close());
  window.addEventListener('load', () => sketchup.ready());
})();
