/* AI Render Result window */
(function () {
  'use strict';
  var $ = function (s) { return document.querySelector(s); };
  var T = function (k, v) { return window.ARSi18n.t(k, v); };
  function call(name) {
    var a = [].slice.call(arguments, 1);
    if (window.sketchup && typeof window.sketchup[name] === 'function') window.sketchup[name].apply(window.sketchup, a);
  }

  window.ARS = { fromRuby: function (ch, p) { try { handle(ch, p); } catch (e) {} } };

  function handle(ch, p) {
    switch (ch) {
      case 'setLang':
        if (p && p.lang) { window.ARSi18n.set(p.lang); }
        break;
      case 'resultImage':
        hideProgress();
        if (p.ok && p.data_uri) {
          $('#img-after').src = p.data_uri;
          if (p.before_data_uri) {
            $('#img-before').src = p.before_data_uri;
            $('#img-before').classList.remove('hidden');
            $('#compare-handle').classList.remove('hidden');
            $('#label-before').classList.remove('hidden');
            $('#label-after').classList.remove('hidden');
            setComparePos(50);
          } else {
            $('#img-before').classList.add('hidden');
            $('#compare-handle').classList.add('hidden');
            $('#label-before').classList.add('hidden');
            $('#label-after').classList.add('hidden');
          }
        }
        break;
      case 'gradeProgress':
        showProgress((p.mode === 'enhance' ? T('enhancing') : T('grading')) + ' ' + Math.round((p.pct || 0) * 100) + '%');
        break;
      case 'gradeError':
        hideProgress();
        toast(T('error_prefix') + (p.message || ''), true);
        break;
      case 'saved':
        toast(T('saved_to', { path: p.path }));
        break;
    }
  }

  /* ---------- 滑动对比条 ---------- */
  var comparePos = 50;
  function setComparePos(pct) {
    comparePos = Math.max(0, Math.min(100, pct));
    $('#compare-handle').style.left = comparePos + '%';
    $('#img-before').style.clipPath = 'inset(0 ' + (100 - comparePos) + '% 0 0)';
  }
  function sizeCompare() {
    var el = $('#compare'), after = $('#img-after');
    if (!after.naturalWidth) return;
    var maxW = window.innerWidth - 32, maxH = window.innerHeight - 56;
    var ar = after.naturalWidth / after.naturalHeight;
    var w = maxW, h = w / ar;
    if (h > maxH) { h = maxH; w = h * ar; }
    el.style.width = Math.round(w) + 'px';
    el.style.height = Math.round(h) + 'px';
    el.classList.add('ready');
    setComparePos(comparePos);
  }
  $('#img-after').addEventListener('load', sizeCompare);
  window.addEventListener('resize', sizeCompare);

  var dragging = false;
  function pctFromEvent(e) {
    var rect = $('#compare').getBoundingClientRect();
    return (e.clientX - rect.left) / rect.width * 100;
  }
  $('#compare').addEventListener('pointerdown', function (e) {
    if (!$('#compare').classList.contains('ready')) return;
    dragging = true;
    try { $('#compare').setPointerCapture(e.pointerId); } catch (err) {}
    setComparePos(pctFromEvent(e));
  });
  $('#compare').addEventListener('pointermove', function (e) { if (dragging) setComparePos(pctFromEvent(e)); });
  ['pointerup', 'pointercancel'].forEach(function (ev) { $('#compare').addEventListener(ev, function () { dragging = false; }); });

  window.ARSi18n.apply();

  var menu = $('#menu');
  document.addEventListener('contextmenu', function (e) {
    e.preventDefault();
    menu.style.left = Math.min(e.clientX, window.innerWidth - 180) + 'px';
    menu.style.top = Math.min(e.clientY, window.innerHeight - 200) + 'px';
    menu.classList.remove('hidden');
  });
  document.addEventListener('click', function (e) { if (!menu.contains(e.target)) menu.classList.add('hidden'); });

  document.addEventListener('click', function (e) {
    var t = e.target.closest('button');
    if (!t) return;
    var act = t.dataset.act;
    if (act === 'save') { call('save_local'); menu.classList.add('hidden'); }
    else if (act === 'rerender') { call('rerender'); menu.classList.add('hidden'); }
    else if (act === 'folder') { call('open_folder'); menu.classList.add('hidden'); }
    else if (act === 'grade') {
      menu.classList.add('hidden'); $('#enhance-box').classList.add('hidden');
      $('#grade-box').classList.remove('hidden'); $('#grade-text').focus();
    }
    else if (act === 'grade-cancel') { $('#grade-box').classList.add('hidden'); }
    else if (act === 'enhance') {
      menu.classList.add('hidden'); $('#grade-box').classList.add('hidden');
      $('#enhance-box').classList.remove('hidden');
    }
    else if (act === 'enhance-cancel') { $('#enhance-box').classList.add('hidden'); }
    else if (t.id === 'grade-go') {
      var txt = $('#grade-text').value.trim();
      if (!txt) { $('#grade-text').focus(); return; }
      $('#grade-box').classList.add('hidden');
      showProgress(T('grading'));
      call('ai_grade', txt);
    }
    else if (t.id === 'enhance-go') {
      if (!enhanceDataUri) { $('#enhance-drop').click(); return; }
      $('#enhance-box').classList.add('hidden');
      showProgress(T('enhancing'));
      call('enhance_upload', enhanceDataUri, parseInt($('#enhance-strength').value, 10));
    }
  });

  $('#enhance-strength').addEventListener('input', function () { $('#enhance-val').textContent = this.value; });

  /* ---------- 上传图片增强真实感 ---------- */
  var enhanceDataUri = null;
  var edrop = $('#enhance-drop');
  edrop.addEventListener('click', function () { $('#enhance-file').click(); });
  edrop.addEventListener('dragover', function (e) { e.preventDefault(); edrop.classList.add('drag'); });
  edrop.addEventListener('dragleave', function () { edrop.classList.remove('drag'); });
  edrop.addEventListener('drop', function (e) {
    e.preventDefault(); edrop.classList.remove('drag');
    if (e.dataTransfer.files[0]) readEnhanceFile(e.dataTransfer.files[0]);
  });
  $('#enhance-file').addEventListener('change', function () { if (this.files[0]) readEnhanceFile(this.files[0]); });
  function readEnhanceFile(file) {
    var fr = new FileReader();
    fr.onload = function () {
      enhanceDataUri = fr.result;
      $('#enhance-preview').src = fr.result;
      $('#enhance-preview').classList.remove('hidden');
    };
    fr.readAsDataURL(file);
  }

  function showProgress(msg) { $('#progress-note').textContent = msg; $('#progress').classList.remove('hidden'); }
  function hideProgress() { $('#progress').classList.add('hidden'); }

  var toastTimer = 0;
  function toast(msg, isErr) {
    var el = $('#toast');
    el.textContent = msg;
    el.classList.toggle('err', !!isErr);
    el.classList.remove('hidden');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { el.classList.add('hidden'); }, 4500);
  }

  call('result_ready');
})();
