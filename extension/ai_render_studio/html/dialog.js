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
    settings: { engine: 'gemini' }
  };
  var DEFAULT_MODEL = { gemini: 'gemini-3-pro-image-preview', seedream: 'doubao-seedream-4-5-251128' };

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
        $('#cfg-saved').textContent = T('cfg_saved');
        setTimeout(function () { $('#cfg-saved').textContent = ''; }, 2500);
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
  function isCloud() { return state.settings.engine === 'gemini' || state.settings.engine === 'seedream'; }
  function canRender() { return isCloud() ? true : state.comfyOnline; }
  function resetBtn() { var b = $('#render-btn'); b.disabled = !canRender(); b.textContent = T('render_btn'); }

  /* ---------- 渲染引擎设置 ---------- */
  function applySettings(s) {
    state.settings = s || { engine: 'gemini' };
    if (!state.settings.engine) state.settings.engine = 'gemini';
    $('#engine').value = state.settings.engine;
    $('#auto-retry').checked = state.settings.auto_retry !== false;
    $('#proxy').value = state.settings.proxy || '';
    refreshEngineUi();
  }

  function refreshEngineUi() {
    var eng = $('#engine').value;
    var cloud = eng !== 'local';
    $('#cloud-cfg').hidden = !cloud;
    $('#api-key').value = '';
    if (cloud) {
      var isSet = !!state.settings[eng + '_key_set'];
      $('#key-label').textContent = T(eng === 'gemini' ? 'key_label_gemini' : 'key_label_seedream');
      $('#api-key').placeholder = isSet ? ('•••• ' + (state.settings[eng + '_key_tail'] || '')) : T('key_ph');
      var ks = $('#key-state');
      ks.textContent = isSet ? T('key_ok') : T('key_missing');
      ks.className = 'muted tiny ' + (isSet ? 'key-ok' : 'key-missing');
      $('#model-id').value = state.settings[eng + '_model'] || '';
      $('#model-id').placeholder = DEFAULT_MODEL[eng];
    }
    $('#engine-note').textContent = T('engine_note_' + eng);
    $('#geom-note').textContent = T(cloud ? 'geom_note_cloud' : 'geom_note');
    $('#render-note').textContent = T(cloud ? 'render_note_cloud' : 'render_note');
    setComfy(state.comfyOnline, state.comfyBase);
    updateResHint();
  }

  function saveSettings() {
    var eng = $('#engine').value;
    var data = { engine: eng, auto_retry: $('#auto-retry').checked, proxy: $('#proxy').value.trim() };
    if (eng !== 'local') {
      data[eng + '_key'] = $('#api-key').value.trim();
      data[eng + '_model'] = $('#model-id').value.trim();
    }
    state.settings.engine = eng;
    call('save_settings', JSON.stringify(data));
  }

  $('#engine').addEventListener('change', function () {
    state.settings.engine = this.value;
    refreshEngineUi();
    saveSettings(); // 切换引擎立即生效（Key 为空 = 不修改已保存的 Key）
  });

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
    $('#comfy-dot').className = 'dot ' + (online ? 'ok' : (isCloud() ? '' : 'err'));
    $('#comfy-text').textContent = online ? (T('comfy_online') + ' · ' + (state.comfyBase || ''))
      : (isCloud() ? T('comfy_offline_cloud') : T('comfy_offline'));
    $('#render-btn').disabled = !canRender() || state.rendering;
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

  var CLOUD_TIER = { '240p': '1K', '360p': '1K', '480p': '1K', '720p': '1K', '1080p': '2K', '1440p': '2K', '2160p': '4K' };
  function updateResHint() {
    state.resolution = $('#resolution').value;
    if (isCloud()) { $('#res-hint').textContent = T('res_hint_cloud', { tier: CLOUD_TIER[state.resolution] || '2K' }); return; }
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
    else if (t.id === 'save-cfg') saveSettings();
    else if (t.dataset.aspect) {
      state.aspect = t.dataset.aspect;
      setSeg('#aspect', t);
      call('set_aspect', state.aspect, ASPECT_RATIO[state.aspect] || 0);
      drawFrame(); updateResHint();
    }
    else if (t.dataset.kind) { state.kind = t.dataset.kind; setSeg('#kind', t); }
    else if (t.dataset.mode) { state.mode = t.dataset.mode; state.presetKey = ''; setSeg('#mode', t); renderPresets(); }
    else if (t.dataset.act === 'cancel_render') call('cancel_render');
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
      refreshEngineUi();
      if (!state.rendering) resetBtn();
      call('set_lang', this.value);
    });
  })();

  call('ready');
})();
