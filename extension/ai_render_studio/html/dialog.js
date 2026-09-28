/* AI Render Studio — main panel. Camera is set in SketchUp; here: snapshot + frame + settings. */
(function () {
  'use strict';

  var ASPECT_RATIO = { 'window': 0, '16:9': 16 / 9, '9:16': 9 / 16, '4:3': 4 / 3, '3:4': 3 / 4 };
  var RES_SHORT = { '240p': 240, '360p': 360, '480p': 480, '720p': 720, '1080p': 1080, '1440p': 1440, '2160p': 2160 };
  var T = function (k, v) { return window.ARSi18n.t(k, v); };

  var state = {
    kind: 'exterior', mode: 'day', presetKey: '',
    aspect: 'window', resolution: '1080p',
    presets: { day: [], night: [] },
    snapNatural: null,
    comfyOnline: false, comfyBase: '',
    refDataUri: null, rendering: false,
    settings: { auto_retry: true }, models: null
  };

  var $ = function (s, r) { return (r || document).querySelector(s); };
  var $all = function (s, r) { return Array.prototype.slice.call((r || document).querySelectorAll(s)); };

  function call(name) {
    var a = Array.prototype.slice.call(arguments, 1);
    doCall(name, a, 0);
  }
  function doCall(name, a, tries) {
    if (window.sketchup && typeof window.sketchup[name] === 'function') {
      window.sketchup[name].apply(window.sketchup, a);
    } else if (tries < 100) {
      // window.sketchup 由 SketchUp 异步注入，页面脚本可能跑得比它快，重试到它出现为止
      setTimeout(function () { doCall(name, a, tries + 1); }, 50);
    } else if (window.console) {
      console.error('[ARS] window.sketchup 桥一直没出现，放弃调用 ' + name);
    }
  }
  function log(m) { call('log', String(m)); }

  window.ARS = { fromRuby: function (ch, p) { try { handle(ch, p); } catch (e) { log('handle ' + ch + ': ' + e.message); } } };

  function handle(ch, p) {
    switch (ch) {
      case 'init':
        state.presets = p.presets || { day: [], night: [] };
        if (p.aspect) state.aspect = p.aspect;
        renderPresets();
        if (p.settings) applySettings(p.settings);
        setComfy(p.comfy && p.comfy.online, p.comfy && p.comfy.base);
        updateResHint();
        break;
      case 'settings':
        applySettings(p);
        break;
      case 'models':
        state.models = p;
        renderModelStatus();
        break;
      case 'download':
        state.download = p;
        renderDownload();
        break;
      case 'comfy':
        setComfy(p.online, p.base);
        break;
      case 'snapshot':
        if (p.ok && p.data_uri) {
          var img = $('#snap');
          img.onload = function () {
            state.snapNatural = { w: img.naturalWidth, h: img.naturalHeight };
            drawFrame();
          };
          img.src = p.data_uri;
          img.hidden = false;
          $('#snap-msg').hidden = true;
        } else {
          $('#snap').hidden = true;
          $('#snap-msg').hidden = false;
        }
        break;
      case 'aspect':
        state.aspect = p.aspect;
        drawFrame();
        updateResHint();
        break;
      case 'analysis':
        $('#analysis').textContent = pretty(p);
        $('#analysis-box').open = true;
        break;
      case 'renderProgress':
        showProgress(true);
        $('#progress-note').textContent = p.note || T('preparing');
        $('#progress-fill').style.width = Math.max(2, Math.round((p.pct || 0) * 100)) + '%';
        break;
      case 'renderDone':
        state.rendering = false; showProgress(false); resetBtn();
        break;
      case 'renderCancelled':
        state.rendering = false; showProgress(false); resetBtn();
        break;
      case 'renderError':
        state.rendering = false;
        $('#progress').classList.add('hidden');
        $('#err-text').textContent = p.message || T('render_error');
        $('#err-box').classList.remove('hidden');
        resetBtn();
        break;
    }
  }

  function pretty(o) { try { return JSON.stringify(o, null, 2); } catch (e) { return String(o); } }
  /* ---------- 引擎 ---------- */
  function applySettings(s) {
    state.settings = s || state.settings;
    $('#auto-retry').checked = state.settings.auto_retry !== false;
    $('#struct-lora').checked = state.settings.struct_lora !== false;
    refreshEngineUi();
  }
  function refreshEngineUi() {
    $('#geom-note').textContent = T('geom_note_flux');
    $('#render-note').textContent = T('render_note_flux');
    renderModelStatus();
  }
  function esc(t) { return String(t).replace(/[&<>]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]; }); }
  function renderModelStatus() {
    var box = $('#model-status'), m = state.models;
    if (!m) { box.innerHTML = ''; return; }
    var html = m.ok ? '<span class="ok">' + esc(T('models_ok')) + '</span>'
      : '<span class="err">' + esc(T('models_missing')) + '</span>\n' + esc((m.missing || []).join('\n'));
    html += '\n' + (m.struct_lora ? '<span class="ok">' + esc(T('lora_ok')) + '</span>'
      : '<span class="warn">' + esc(T('lora_missing')) + '</span>');
    var btns = '';
    if (m.dl_required && m.dl_required.count) btns += '<button class="small" data-dl="required">' + esc(T('dl_required', { n: m.dl_required.count, gb: m.dl_required.gb })) + '</button>';
    if (m.dl_lora) btns += '<button class="small ghost" data-dl="lora">' + esc(T('dl_lora')) + '</button>';
    if (btns) html += '\n<span class="dl-btns">' + btns + '</span>';
    html += '<div id="dl-progress"></div>';
    box.innerHTML = html;
    renderDownload();
  }
  function renderDownload() {
    var el = $('#dl-progress'), d = state.download;
    if (!el || !d) return;
    var busy = d.active && !d.done;
    Array.prototype.forEach.call(document.querySelectorAll('[data-dl]'), function (b) { b.disabled = busy; });
    if (d.error) { el.innerHTML = '<span class="err">' + esc(T('dl_error') + d.error) + '</span>'; return; }
    if (d.done && d.cancelled) { el.innerHTML = '<span class="warn">' + esc(T('dl_cancelled')) + '</span>'; return; }
    if (d.done) { el.innerHTML = '<span class="ok">' + esc(T('dl_done')) + '</span>'; return; }
    var pct = d.total_mb ? Math.min(100, Math.round(d.got_mb / d.total_mb * 100)) : null;
    el.innerHTML = esc(T('dl_progress', { i: d.index || 1, n: d.count || 1, file: d.file || '', got: d.got_mb || 0,
      total: d.total_mb ? d.total_mb : '?', host: d.host || '…' })) +
      '<div class="dl-track"><div class="dl-fill" style="width:' + (pct == null ? 3 : pct) + '%"></div></div>' +
      '<button class="small ghost" data-act="cancel_download">' + esc(T('cancel')) + '</button>';
  }
  function saveSettings() {
    state.settings = { auto_retry: $('#auto-retry').checked, struct_lora: $('#struct-lora').checked };
    call('save_settings', JSON.stringify(state.settings));
    refreshEngineUi();
  }
  $('#auto-retry').addEventListener('change', saveSettings);
  $('#struct-lora').addEventListener('change', saveSettings);

  function resetBtn() { var b = $('#render-btn'); b.disabled = !state.comfyOnline; b.textContent = T('render_btn'); }

  /* ---------- 取景框遮罩 ---------- */
  function drawFrame() {
    var box = $('#snap-box'), hole = $('#frame-hole'), label = $('#frame-label');
    if (!state.snapNatural || $('#snap').hidden) { hole.style.display = 'none'; label.style.display = 'none'; return; }
    var W = box.clientWidth, H = box.clientHeight;
    if (!W || !H) return;
    var boxAr = W / H;
    var ra = ASPECT_RATIO[state.aspect] || boxAr;
    var w, h;
    if (ra >= boxAr) { w = W; h = W / ra; } else { h = H; w = H * ra; }
    hole.style.display = 'block';
    hole.style.width = w + 'px';
    hole.style.height = h + 'px';
    hole.style.left = ((W - w) / 2) + 'px';
    hole.style.top = ((H - h) / 2) + 'px';
    label.style.display = 'block';
    label.textContent = T('frame_label', { aspect: state.aspect === 'window' ? T('frame_full') : state.aspect });
  }
  window.addEventListener('resize', drawFrame);

  /* ---------- UI ---------- */
  function setComfy(online, base) {
    if (base != null) state.comfyBase = base;
    state.comfyOnline = !!online;
    $('#comfy-dot').className = 'dot ' + (online ? 'ok' : 'err');
    $('#comfy-text').textContent = online ? (T('comfy_online') + ' · ' + (state.comfyBase || '')) : T('comfy_offline');
    $('#render-btn').disabled = !online || state.rendering;
  }

  function renderPresets() {
    var list = state.presets[state.mode] || [];
    var box = $('#presets'); box.innerHTML = '';
    list.forEach(function (en) {
      var b = document.createElement('button');
      b.textContent = T('preset_' + en.key);
      b.dataset.preset = en.key;
      if (en.key === state.presetKey) b.classList.add('active');
      b.addEventListener('click', function () {
        state.presetKey = (state.presetKey === en.key) ? '' : en.key;
        renderPresets();
      });
      box.appendChild(b);
    });
  }

  function showProgress(on) {
    $('#progress').classList.toggle('hidden', !on);
    if (on) $('#err-box').classList.add('hidden');
  }

  function outputDims() {
    var p = RES_SHORT[state.resolution] || 1080;
    var ar = ASPECT_RATIO[state.aspect] || (16 / 9);
    var w, h;
    if (ar >= 1) { w = Math.round(p * ar); h = p; } else { w = p; h = Math.round(p / ar); }
    w -= w % 8; h -= h % 8;
    return { w: w, h: h };
  }

  function needsUpscale() {
    var d = outputDims();
    return Math.max(d.w, d.h) >= 1600;
  }

  function updateResHint() {
    state.resolution = $('#resolution').value;
    var d = outputDims();
    var tail = needsUpscale() ? T('res_hint_upscale') : '';
    $('#res-hint').textContent = T('res_hint', { w: d.w, h: d.h, tail: tail });
  }

  function setSeg(sel, btn) {
    $all(sel + ' button').forEach(function (b) { b.classList.remove('on'); });
    btn.classList.add('on');
  }

  document.addEventListener('click', function (ev) {
    var t = ev.target.closest('button');
    if (!t) return;
    if (t.id === 'refresh-btn') call('refresh_view');
    else if (t.dataset.aspect) {
      state.aspect = t.dataset.aspect;
      setSeg('#aspect', t);
      call('set_aspect', state.aspect, ASPECT_RATIO[state.aspect] || 0);
      drawFrame(); updateResHint();
    }
    else if (t.dataset.kind) { state.kind = t.dataset.kind; setSeg('#kind', t); }
    else if (t.dataset.mode) { state.mode = t.dataset.mode; state.presetKey = ''; setSeg('#mode', t); renderPresets(); }
    else if (t.dataset.act === 'cancel_render') call('cancel_render');
    else if (t.dataset.dl) { state.download = { active: true, index: 1, count: 1, got_mb: 0 }; renderDownload(); call('download_models', t.dataset.dl); }
    else if (t.dataset.act === 'cancel_download') call('cancel_download');
    else if (t.dataset.act === 'open_log') call('open_log');
    else if (t.dataset.act === 'err-close') $('#err-box').classList.add('hidden');
    else if (t.id === 'analyze-btn') { ev.preventDefault(); $('#analysis').textContent = T('analyzing'); call('analyze'); }
  });

  $('#ai-strength').addEventListener('input', function () { $('#ai-val').textContent = this.value; });
  $('#resolution').addEventListener('change', updateResHint);

  function submitRender() {
    state.rendering = true;
    var btn = $('#render-btn');
    btn.disabled = true; btn.textContent = T('render_btn_busy');
    showProgress(true);
    $('#progress-note').textContent = T('start');
    $('#progress-fill').style.width = '2%';
    call('render', JSON.stringify({
      kind: state.kind, mode: state.mode, preset_key: state.presetKey,
      user_prompt: $('#prompt').value || '',
      ai_strength: parseInt($('#ai-strength').value, 10),
      resolution: state.resolution,
      shadows: $('#shadows').checked,
      seed: $('#seed').value ? parseInt($('#seed').value, 10) : null,
      ref_data_uri: state.refDataUri
    }));
  }

  $('#render-btn').addEventListener('click', function () {
    if (state.rendering) return;
    submitRender();
  });

  /* 参考图 */
  var drop = $('#ref-drop');
  drop.addEventListener('click', function () { $('#ref-file').click(); });
  drop.addEventListener('dragover', function (e) { e.preventDefault(); drop.classList.add('drag'); });
  drop.addEventListener('dragleave', function () { drop.classList.remove('drag'); });
  drop.addEventListener('drop', function (e) {
    e.preventDefault(); drop.classList.remove('drag');
    if (e.dataTransfer.files[0]) readRef(e.dataTransfer.files[0]);
  });
  $('#ref-file').addEventListener('change', function () { if (this.files[0]) readRef(this.files[0]); });
  $('#ref-clear').addEventListener('click', function () {
    state.refDataUri = null;
    $('#ref-preview').classList.add('hidden'); $('#ref-drop').classList.remove('hidden');
  });
  function readRef(file) {
    var fr = new FileReader();
    fr.onload = function () {
      state.refDataUri = fr.result;
      $('#ref-img').src = fr.result;
      $('#ref-preview').classList.remove('hidden'); $('#ref-drop').classList.add('hidden');
    };
    fr.readAsDataURL(file);
  }

  /* ---------- 语言 ---------- */
  (function initLang() {
    var sel = $('#lang');
    window.ARSi18n.langs.forEach(function (l) {
      var o = document.createElement('option');
      o.value = l.code; o.textContent = l.name;
      sel.appendChild(o);
    });
    sel.value = window.ARSi18n.lang;
    window.ARSi18n.apply();
    sel.addEventListener('change', function () {
      window.ARSi18n.set(this.value);
      renderPresets();
      updateResHint();
      drawFrame();
      setComfy(state.comfyOnline, state.comfyBase);
      refreshEngineUi();
      if (!state.rendering) resetBtn();
      call('set_lang', this.value);
    });
  })();

  call('ready');
})();
