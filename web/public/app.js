/* Home heating front end: overview of all zones, or a single zone with
 * target, outdoor temperature and the same period in past years. */
(function () {
  'use strict';

  const SPANS = { day: 'Last 24 hours', week: 'Last 7 days', month: 'Last month' };
  const REFRESH_MS = 5 * 60 * 1000;
  const STALE_SECS = 30 * 60;
  const MAX_FILL_SECS = 30 * 60; // bridge missing readings up to this long
  const FAULT_NAMES = {
    TempZoneSensorLowBattery: 'sensor',
    TempZoneActuatorLowBattery: 'radiator valve',
  };

  const $ = (id) => document.getElementById(id);
  const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

  const ICON_BATTERY = '<svg class="icon" viewBox="0 0 16 16" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="1.5" y="4.5" width="11" height="7" rx="1.5"/><path d="M14.5 7v2"/><path d="M4 7v2" stroke-width="2"/></svg>';
  const ICON_WARN = '<svg class="icon" viewBox="0 0 16 16" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M8 1.8 15 14H1z" stroke-linejoin="round"/><path d="M8 6v4M8 11.6v.4"/></svg>';

  // ---- state & URL ---------------------------------------------------------

  let state = readUrl();
  let summary = null;
  let data = null;
  let chart = null;
  let rawCols = null; // un-filled columns, for the data table
  let loadSeq = 0;

  function readUrl() {
    const p = new URLSearchParams(location.search);
    const span = SPANS[p.get('span')] ? p.get('span') : 'day';
    const end = p.get('end') ? new Date(p.get('end')) : null;
    return {
      zone: /^\d+$/.test(p.get('zone') || '') ? p.get('zone') : null,
      location: p.get('location'),
      span,
      end: end && !isNaN(end) ? end : null,
    };
  }

  function writeUrl(push) {
    const p = new URLSearchParams();
    if (state.location) p.set('location', state.location);
    if (state.zone) p.set('zone', state.zone);
    if (state.span !== 'day') p.set('span', state.span);
    if (state.end) p.set('end', localIso(state.end));
    const url = location.pathname + (p.toString() ? '?' + p : '');
    (push ? history.pushState : history.replaceState).call(history, null, '', url);
  }

  function navigate(patch) {
    Object.assign(state, patch);
    writeUrl(true);
    render();
  }

  window.addEventListener('popstate', () => { state = readUrl(); render(); });

  // ---- time windows --------------------------------------------------------

  function shift(date, span, dir) {
    const d = new Date(date);
    if (span === 'day') d.setDate(d.getDate() + dir);
    else if (span === 'week') d.setDate(d.getDate() + 7 * dir);
    else d.setMonth(d.getMonth() + dir);
    return d;
  }

  function currentWindow() {
    const end = state.end || new Date();
    return { from: shift(end, state.span, -1), to: end };
  }

  function localIso(d) {
    const z = (n) => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${z(d.getMonth() + 1)}-${z(d.getDate())}T${z(d.getHours())}:${z(d.getMinutes())}`;
  }

  const fmtDayTime = new Intl.DateTimeFormat('en-GB', { weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
  const fmtDay = new Intl.DateTimeFormat('en-GB', { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' });
  const fmtShort = new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
  const fmtTime = new Intl.DateTimeFormat('en-GB', { hour: '2-digit', minute: '2-digit' });

  function rangeLabel(w) {
    if (!state.end) return SPANS[state.span];
    const midnight = (d) => d.getHours() === 0 && d.getMinutes() === 0;
    if (midnight(w.from) && midnight(w.to)) {
      const last = new Date(w.to - 1);
      return state.span === 'day' ? fmtDay.format(w.from) : `${fmtDay.format(w.from)} – ${fmtDay.format(last)}`;
    }
    return `${fmtDayTime.format(w.from)} – ${fmtDayTime.format(w.to)}`;
  }

  function ago(secs) {
    if (secs < 90) return 'just now';
    if (secs < 5400) return Math.round(secs / 60) + ' min ago';
    if (secs < 172800) return Math.round(secs / 3600) + ' hours ago';
    return Math.round(secs / 86400) + ' days ago';
  }

  // ---- data ----------------------------------------------------------------

  async function getJson(url) {
    const r = await fetch(url, { headers: { Accept: 'application/json' } });
    const body = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(body.error || `HTTP ${r.status}`);
    return body;
  }

  function locParam() {
    return state.location ? `&location=${encodeURIComponent(state.location)}` : '';
  }

  async function loadSummary() {
    summary = await getJson('api/summary?' + locParam().slice(1));
  }

  async function loadData() {
    const w = currentWindow();
    const q = `from=${Math.floor(w.from / 1000)}&to=${Math.ceil(w.to / 1000)}`;
    const url = state.zone ? `api/zone/${state.zone}?${q}` : `api/overview?${q}${locParam()}`;
    return getJson(url);
  }

  // ---- colours -------------------------------------------------------------

  // Colour follows the zone (by zone id order), never its position on screen.
  // Nine zones but eight validated hues: the ninth re-uses slot 1, dashed.
  function zoneStyle(zoneId) {
    const ids = (summary ? summary.zones : []).map((z) => String(z.id)).sort((a, b) => a - b);
    const i = Math.max(0, ids.indexOf(String(zoneId)));
    return { stroke: css(`--series-${(i % 8) + 1}`), dash: i >= 8 ? [6, 4] : undefined };
  }

  // ---- rendering: header, alerts, cards -------------------------------------

  function renderHeader() {
    const zone = state.zone && summary && summary.zones.find((z) => String(z.id) === state.zone);
    $('home-link').hidden = !state.zone;
    $('home-link').href = '?' + new URLSearchParams({ ...(state.location ? { location: state.location } : {}), ...(state.span !== 'day' ? { span: state.span } : {}), ...(state.end ? { end: localIso(state.end) } : {}) });
    $('page-title').textContent = zone ? zone.name : (summary ? `Home heating · ${summary.location.name}` : 'Home heating');
    document.title = zone ? `${zone.name} · Home Heating` : 'Home Heating';

    if (!summary) return;
    const w = summary.weather;
    const latest = Math.max(...summary.zones.map((z) => z.time));
    const parts = [];
    if (w) parts.push(`Outside <strong>${w.temperature.toFixed(1)}°</strong>${w.condition ? ' ' + escapeHtml(w.condition.toLowerCase()) : ''}`);
    if (isFinite(latest)) parts.push(`updated ${fmtTime.format(new Date(latest * 1000))}`);
    $('now-summary').innerHTML = parts.join(' · ');
  }

  function renderAlerts() {
    const out = [];
    if (summary) {
      const latest = Math.max(...summary.zones.map((z) => z.time));
      const age = summary.now - latest;
      if (age > STALE_SECS) {
        out.push(`<div class="alert warning">${ICON_WARN}<div><strong>No new readings since ${fmtShort.format(new Date(latest * 1000))}</strong> (${ago(age)}). Check the tcc-db-logger service on the server.</div></div>`);
      }
      for (const z of summary.zones) {
        if (!z.faults.length) continue;
        const kinds = [...new Set(z.faults.map((f) => faultName(f.type)))].join(' and ');
        const since = z.faults.map((f) => f.since).filter(Boolean).sort()[0];
        const sinceTxt = since ? ` since ${fmtShort.format(new Date(since + 'Z'))}` : '';
        out.push(`<div class="alert critical">${ICON_BATTERY}<div><strong>Low battery: <a href="${zoneHref(z.id)}" data-zone="${z.id}">${escapeHtml(z.name)}</a></strong> ${escapeHtml(kinds)}${sinceTxt}</div></div>`);
      }
    }
    $('alerts').innerHTML = out.join('');
  }

  function renderCards() {
    if (!summary) return;
    $('zone-cards').innerHTML = summary.zones.map((z) => {
      const s = zoneStyle(z.id);
      const heating = z.target != null && z.temperature != null && z.target > z.temperature;
      const current = state.zone === String(z.id);
      const batt = z.faults.length ? `<span class="batt" title="Low battery">${ICON_BATTERY}</span>` : '';
      return `<a class="zone-card" href="${zoneHref(z.id)}" data-zone="${z.id}" ${current ? 'aria-current="page" style="border-color:var(--accent)"' : ''}>
        ${batt}
        <span class="name"><span class="swatch${s.dash ? ' dashed' : ''}" style="background:${s.stroke};border-color:${s.stroke}"></span>${escapeHtml(z.name)}</span>
        <span class="temp">${z.temperature != null ? z.temperature.toFixed(1) + '°' : '–'}</span>
        <span class="target${heating ? ' heating' : ''}">target ${z.target != null ? z.target.toFixed(1) + '°' : '–'}${heating ? ' · heating' : ''}</span>
      </a>`;
    }).join('');
  }

  function zoneHref(id) {
    const p = new URLSearchParams();
    if (state.location) p.set('location', state.location);
    p.set('zone', id);
    if (state.span !== 'day') p.set('span', state.span);
    if (state.end) p.set('end', localIso(state.end));
    return '?' + p;
  }

  function faultName(type) {
    return FAULT_NAMES[type] || type.replace(/^TempZone/, '').replace(/([a-z])([A-Z])/g, '$1 $2').toLowerCase();
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }

  // Intercept in-page links so navigation keeps state without a reload.
  document.addEventListener('click', (e) => {
    const a = e.target.closest('a[data-zone], #home-link');
    if (!a || e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) return;
    e.preventDefault();
    navigate({ zone: a.id === 'home-link' ? null : a.dataset.zone });
    window.scrollTo({ top: 0 });
  });

  // ---- controls ------------------------------------------------------------

  function renderControls() {
    for (const b of document.querySelectorAll('.seg button')) {
      b.setAttribute('aria-pressed', String(b.dataset.span === state.span));
    }
    const w = currentWindow();
    $('range-label').textContent = rangeLabel(w);
    $('next').disabled = !state.end;
    $('now-btn').disabled = !state.end;
    if (summary && summary.first) {
      $('prev').disabled = w.from.getTime() / 1000 <= summary.first;
      $('goto-date').min = localIso(new Date(summary.first * 1000)).slice(0, 10);
    }
    $('goto-date').max = localIso(new Date()).slice(0, 10);
  }

  for (const b of document.querySelectorAll('.seg button')) {
    b.addEventListener('click', () => navigate({ span: b.dataset.span }));
  }
  $('prev').addEventListener('click', () => navigate({ end: currentWindow().from }));
  $('next').addEventListener('click', () => {
    const end = shift(currentWindow().to, state.span, 1);
    navigate({ end: end >= new Date() ? null : end });
  });
  $('now-btn').addEventListener('click', () => navigate({ end: null }));
  $('goto-date').addEventListener('change', (e) => {
    if (!e.target.value) return;
    const [y, m, d] = e.target.value.split('-').map(Number);
    const end = new Date(y, m - 1, d + 1); // end of the chosen day, local time
    navigate({ end: end >= new Date() ? null : end });
  });

  // ---- chart ---------------------------------------------------------------

  const fmtTemp = (u, v) => (v == null ? '–' : v.toFixed(1) + '°');

  function buildSeries() {
    const series = [{ label: 'Time', value: (u, v) => (v == null ? '–' : fmtDayTime.format(new Date(v * 1000))) }];
    const cols = [data.times];
    const outdoor = { label: 'Outside', stroke: css('--outdoor'), width: 1.5, dash: [3, 4], value: fmtTemp };

    if (!state.zone) {
      for (const z of data.zones) {
        const s = zoneStyle(z.id);
        series.push({ label: z.name, stroke: s.stroke, dash: s.dash, width: state.span === 'month' ? 1.25 : 2, value: fmtTemp, zoneId: z.id });
        cols.push(z.temperature);
      }
      series.push(outdoor);
      cols.push(data.outdoor);
    } else {
      // uPlot draws series in order, so the zone temperature goes last to sit
      // on top; legendOrder keeps the legend reading Temperature, Target, ...
      const n = data.years.length;
      series.push({ ...outdoor, legendOrder: n + 3 });
      cols.push(data.outdoor);
      for (let i = n - 1; i >= 0; i--) { // oldest first, so recent years sit above
        const y = data.years[i];
        series.push({ label: y.label, stroke: css(`--year-${Math.min(i + 1, 3)}`), width: 1.25, value: fmtTemp, legendOrder: i + 3 });
        cols.push(y.temperature);
      }
      series.push({ label: 'Target', role: 'target', stroke: css('--target'), width: 1.5, paths: uPlot.paths.stepped({ align: 1 }), value: fmtTemp, legendOrder: 2 });
      cols.push(data.target);
      cols.stepCol = cols.length - 1;
      series.push({ label: 'Temperature', role: 'temp', stroke: css('--series-1'), width: 3, value: fmtTemp, legendOrder: 1 });
      cols.push(data.temperature);
    }
    return { series, cols };
  }

  // Fill runs of missing buckets no longer than MAX_FILL_SECS: linear
  // interpolation, or carry-forward for stepped series such as targets.
  function fillGaps(times, col, step, stepped) {
    const out = col.slice();
    let prev = -1;
    for (let i = 0; i < col.length; i++) {
      if (col[i] == null) continue;
      if (prev >= 0 && i - prev > 1 && times[i] - times[prev] - step <= MAX_FILL_SECS) {
        for (let j = prev + 1; j < i; j++) {
          out[j] = stepped ? col[prev]
            : col[prev] + (col[i] - col[prev]) * (times[j] - times[prev]) / (times[i] - times[prev]);
        }
      }
      prev = i;
    }
    return out;
  }

  // Shade periods where the zone's target is above its temperature.
  function demandPlugin() {
    return {
      hooks: {
        drawAxes: (u) => {
          if (!state.zone) return;
          const idx = (role) => u.series.findIndex((s) => s.role === role);
          const t = u.data[0], temp = u.data[idx('temp')], target = u.data[idx('target')];
          const { top, height } = u.bbox;
          const ctx = u.ctx;
          ctx.save();
          ctx.fillStyle = css('--demand');
          let runStart = null;
          for (let i = 0; i <= t.length; i++) {
            const on = i < t.length && temp[i] != null && target[i] != null && target[i] > temp[i];
            if (on && runStart == null) runStart = i;
            if (!on && runStart != null) {
              const x0 = u.valToPos(t[runStart], 'x', true);
              const x1 = u.valToPos(i < t.length ? t[i] : t[t.length - 1] + data.step, 'x', true);
              ctx.fillRect(x0, top, Math.max(1, x1 - x0), height);
              runStart = null;
            }
          }
          ctx.restore();
        },
      },
    };
  }

  // A red strip along the bottom of the plot where a battery fault was reported.
  function faultPlugin() {
    return {
      hooks: {
        draw: (u) => {
          if (!data.faults.length) return;
          const { left, top, width, height } = u.bbox;
          const h = Math.round(5 * devicePixelRatio);
          const ctx = u.ctx;
          ctx.save();
          ctx.fillStyle = css('--critical');
          for (const f of data.faults) {
            const x0 = Math.max(left, u.valToPos(f.start, 'x', true));
            const x1 = Math.min(left + width, u.valToPos(f.end, 'x', true));
            if (x1 > x0) ctx.fillRect(x0, top + height - h, Math.max(2, x1 - x0), h);
          }
          ctx.restore();
        },
      },
    };
  }

  function chartSize() {
    const el = $('chart');
    const w = el.clientWidth || 800;
    return { width: w, height: Math.max(260, Math.min(460, Math.round(w * 0.45))) };
  }

  function renderChart() {
    const el = $('chart');
    if (chart) { chart.destroy(); chart = null; }
    if (!data) return;

    const { series, cols } = buildSeries();
    rawCols = cols;
    const filled = cols.map((c, i) => (i === 0 ? c : fillGaps(data.times, c, data.step, i === cols.stepCol)));
    const hasData = cols.slice(1).some((c) => c.some((v) => v != null));
    $('chart-empty').hidden = hasData;

    const axisStyle = {
      stroke: css('--text-secondary'),
      grid: { stroke: css('--grid'), width: 1 },
      ticks: { stroke: css('--grid'), width: 1 },
      font: '12px system-ui, sans-serif',
    };
    // en-GB, 24-hour axis labels; second line marks a new day/year.
    const timeAxis = {
      ...axisStyle,
      values: [
        [3600 * 24 * 365, '{YYYY}', null, null, null, null, null, null, 1],
        [3600 * 24 * 28, '{MMM}', '\n{YYYY}', null, null, null, null, null, 1],
        [3600 * 24, '{D} {MMM}', '\n{YYYY}', null, null, null, null, null, 1],
        [3600, '{HH}:{mm}', '\n{D} {MMM} {YYYY}', null, '\n{D} {MMM}', null, null, null, 1],
        [60, '{HH}:{mm}', '\n{D} {MMM} {YYYY}', null, '\n{D} {MMM}', null, null, null, 1],
      ],
    };
    chart = new uPlot({
      ...chartSize(),
      scales: { x: { time: true, range: [data.from, data.to] } },
      series,
      axes: [timeAxis, { ...axisStyle, values: (u, vals) => vals.map((v) => v + '°'), size: 44 }],
      cursor: { focus: { prox: 24 } },
      focus: { alpha: 0.25 },
      legend: { live: true },
      plugins: [demandPlugin(), faultPlugin()],
    }, filled, el);

    // Show legend entries in reading order rather than drawing order.
    chart.root.querySelectorAll('.u-legend .u-series').forEach((tr, i) => {
      const o = chart.series[i].legendOrder;
      if (o != null) tr.style.order = o;
    });

    renderKey();
  }

  function renderKey() {
    const bits = [];
    if (state.zone) bits.push('<span><i class="key-demand"></i>Shaded: target above temperature (calling for heat)</span>');
    if (data.faults.length) bits.push('<span><i class="key-fault"></i>Low battery reported</span>');
    if (state.zone && data.years.length) bits.push('<span>Past years are drawn on this period\'s dates</span>');
    bits.push('<span>Gaps of up to 30 minutes are filled in; longer gaps are left blank</span>');
    bits.push('<span>Click a legend entry to hide it</span>');
    $('chart-key').innerHTML = bits.join('');
  }

  new ResizeObserver(() => { if (chart) chart.setSize(chartSize()); }).observe($('chart'));
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { renderCards(); renderChart(); });

  // ---- faults list -----------------------------------------------------------

  function renderFaults() {
    const faults = data ? data.faults : [];
    $('fault-panel').hidden = !faults.length;
    if (!faults.length) return;

    // Group per zone: which kinds, how many separate episodes, first and last.
    const byZone = new Map();
    for (const f of faults) {
      const g = byZone.get(f.zone_id) || { zone_id: f.zone_id, zone: f.zone, kinds: new Set(), spans: [] };
      g.kinds.add(faultName(f.type));
      g.spans.push([f.start, f.end]);
      byZone.set(f.zone_id, g);
    }
    const now = Date.now() / 1000;
    const items = [...byZone.values()].map((g) => {
      g.spans.sort((a, b) => a[0] - b[0]);
      let episodes = 0, lastEnd = -Infinity;
      for (const [s, e] of g.spans) { if (s > lastEnd) episodes++; lastEnd = Math.max(lastEnd, e); }
      const first = g.spans[0][0];
      const ongoing = lastEnd >= now - 20 * 60;
      const name = state.zone ? escapeHtml(g.zone) : `<a href="${zoneHref(g.zone_id)}" data-zone="${g.zone_id}">${escapeHtml(g.zone)}</a>`;
      const when = `${fmtShort.format(new Date(first * 1000))} – ${ongoing ? 'now' : fmtShort.format(new Date(lastEnd * 1000))}`;
      const reps = episodes > 1 ? ` <span class="muted">(${episodes} separate reports — likely needs new batteries)</span>` : '';
      return `<li>${ICON_BATTERY}<div><strong>${name}</strong>: ${escapeHtml([...g.kinds].join(' and '))} low battery, ${when}${reps}</div></li>`;
    });
    $('fault-list').innerHTML = items.join('');
  }

  // ---- data table ------------------------------------------------------------

  function renderTable() {
    const details = $('table-details');
    if (!details.open || !chart) { $('data-table').innerHTML = ''; return; }
    // Columns in legend order (Time first), not drawing order.
    const order = chart.series.map((s, i) => i)
      .sort((a, b) => (a === 0 ? -1 : b === 0 ? 1 : (chart.series[a].legendOrder ?? a) - (chart.series[b].legendOrder ?? b)));
    const labels = order.map((i) => chart.series[i].label);
    const rows = [];
    for (let i = data.times.length - 1; i >= 0; i--) {
      const cells = order.slice(1).map((k) => rawCols[k]).map((c) => (c[i] == null ? '' : c[i].toFixed(1)));
      if (cells.every((c) => c === '')) continue;
      rows.push(`<tr><td>${fmtDayTime.format(new Date(data.times[i] * 1000))}</td>${cells.map((c) => `<td>${c}</td>`).join('')}</tr>`);
    }
    $('data-table').innerHTML = `<thead><tr>${labels.map((l) => `<th>${escapeHtml(l)}</th>`).join('')}</tr></thead><tbody>${rows.join('')}</tbody>`;
  }
  $('table-details').addEventListener('toggle', renderTable);

  // ---- main ----------------------------------------------------------------

  async function render() {
    const seq = ++loadSeq;
    renderControls();
    renderHeader();
    $('chart').classList.add('loading');
    try {
      const [, d] = await Promise.all([summary ? null : loadSummary(), loadData()]);
      if (seq !== loadSeq) return;
      data = d;
      renderHeader();
      renderAlerts();
      renderCards();
      renderControls();
      renderChart();
      renderFaults();
      renderTable();
    } catch (err) {
      if (seq !== loadSeq) return;
      $('alerts').innerHTML = `<div class="alert critical">${ICON_WARN}<div><strong>Could not load data:</strong> ${escapeHtml(err.message)}</div></div>`;
    } finally {
      if (seq === loadSeq) $('chart').classList.remove('loading');
    }
  }

  // Keep the live view current.
  setInterval(async () => {
    if (document.hidden) return;
    try { await loadSummary(); } catch (e) { return; }
    if (!state.end) render(); else { renderHeader(); renderAlerts(); renderCards(); }
  }, REFRESH_MS);

  writeUrl(false);
  render();
})();
