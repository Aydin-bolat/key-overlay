(function () {
  'use strict';

  // ---------- 小工具 ----------
  function $(id) { return document.getElementById(id); }
  function call(name, arg) {
    if (!window.sketchup) { return; }
    try {
      if (arg === undefined) { window.sketchup[name](); }
      else { window.sketchup[name](arg); }
    } catch (e) {
      showMsg('桥接调用失败: ' + name + ' ' + e.message, true);
    }
  }

  var msgTimer = null;
  function showMsg(text, isError) {
    var box = $('msg-box');
    box.textContent = text;
    box.className = isError ? 'error' : '';
    if (msgTimer) { clearTimeout(msgTimer); }
    msgTimer = setTimeout(function () { box.className = 'hidden'; }, isError ? 5500 : 3000);
  }

  // ---------- 标签页切换 ----------
  var tabButtons = document.querySelectorAll('.tab-btn');
  tabButtons.forEach(function (btn) {
    btn.addEventListener('click', function () {
      tabButtons.forEach(function (b) { b.classList.remove('active'); });
      document.querySelectorAll('.tab-panel').forEach(function (p) { p.classList.remove('active'); });
      btn.classList.add('active');
      $('tab-' + btn.dataset.tab).classList.add('active');
    });
  });

  // ---------- 顶部按钮 ----------
  $('btn-import').addEventListener('click', function () { call('import_texture'); });
  $('btn-apply-mat').addEventListener('click', function () { call('apply_material'); });
  $('btn-eyedrop').addEventListener('click', function () {
    call('pick_material');
    showMsg('请在 SketchUp 模型里点一下要吸取的面（Esc 取消）', false);
  });

  // ---------- 贴图变换 ----------
  var rot = $('rot'), sx = $('sx'), sy = $('sy'), ou = $('ou'), ov = $('ov');
  var lockAspect = $('lock-aspect');
  var modeSelect = $('mode-select');

  function syncLabels() {
    $('val-rot').textContent = rot.value;
    $('val-sx').textContent = sx.value;
    $('val-sy').textContent = sy.value;
    $('val-ou').textContent = ou.value;
    $('val-ov').textContent = ov.value;
  }

  function currentTransformPayload() {
    return JSON.stringify({
      mode: modeSelect.value,
      angle_deg: parseFloat(rot.value),
      scale_x: parseFloat(sx.value),
      scale_y: parseFloat(sy.value),
      offset_u: parseFloat(ou.value),
      offset_v: parseFloat(ov.value)
    });
  }

  function sendTransform() { call('apply_transform', currentTransformPayload()); }

  rot.addEventListener('input', syncLabels);
  ou.addEventListener('input', syncLabels);
  ov.addEventListener('input', syncLabels);
  sx.addEventListener('input', function () {
    if (lockAspect.checked) { sy.value = sx.value; }
    syncLabels();
  });
  sy.addEventListener('input', function () {
    if (lockAspect.checked) { sx.value = sy.value; }
    syncLabels();
  });

  // 拖动滑块松手（change）时才真正提交给 SketchUp——避免拖动过程中疯狂重算几何。
  [rot, sx, sy, ou, ov].forEach(function (el) {
    el.addEventListener('change', sendTransform);
  });
  modeSelect.addEventListener('change', sendTransform);

  $('btn-apply').addEventListener('click', sendTransform);
  $('btn-reset').addEventListener('click', function () {
    rot.value = 0; sx.value = 100; sy.value = 100; ou.value = 0; ov.value = 0;
    syncLabels();
    call('reset_transform');
  });

  // ---------- 画笔 ----------
  var paintCanvas = $('paint-canvas');
  var uvCanvas = $('uv-canvas');
  var cursorCanvas = $('cursor-canvas');
  var tileBgCanvas = $('tile-bg-canvas');
  var handlesCanvas = $('handles-canvas');
  var pctx = paintCanvas.getContext('2d');
  var uctx = uvCanvas.getContext('2d');
  var cctx = cursorCanvas.getContext('2d');
  var tctx = tileBgCanvas.getContext('2d');
  var hctx = handlesCanvas.getContext('2d');
  var canvasViewport = $('canvas-viewport');
  var canvasStage = $('canvas-stage');
  var canvasEmpty = $('canvas-empty');

  // 贴图平铺布局：texW/texH 是贴图本体(可画的那一张)像素尺寸；tileOriginU/tileOriginVTop
  // 是"大画布"左上角对应的 UV 坐标（贴图会在很多面上重复贴很多遍，UV 经常跑到 0~1 以外，
  // 这两个值 + stageWpx/stageHpx 就是自动算出来的、刚好包住所有用到这个材质的面的整张平铺范围）；
  // paintLeft/paintTop 是贴图本体在这张大画布里的像素偏移。
  var texW = 0, texH = 0, tileOriginU = 0, tileOriginVTop = 1;
  var paintLeft = 0, paintTop = 0, stageWpx = 0, stageHpx = 0;
  var lastUvMeta = []; // [{id, pxPts:[[x,y],...]}]，供 UV 参考线绘制 + Ctrl+点选命中测试共用
  var selectedFaceIds = []; // 当前"贴图变换"编辑对象的面 id 列表，决定手柄画在哪几个轮廓周围

  var brushColor = $('brush-color');
  var brushOpacity = $('brush-opacity');
  var brushSize = $('brush-size');
  var brushHardness = $('brush-hardness');
  var eraserBtn = $('btn-eraser');
  var showUv = $('show-uv');

  var eraserOn = false;
  var undoStack = [];
  var lastUvPolys = [];
  var drawing = false;
  var lastX = 0, lastY = 0;
  var hasImage = false;
  var suppressFitOnNextLoad = false; // 手柄拖完提交后的刷新只要真实轮廓，不重置视角
  var pendingDragReload = false; // 手柄拖完提交后，只有确认 apply_transform 成功才刷新画布

  // ---------- 画布缩放 / 平移 ----------
  // #canvas-stage 用 CSS transform 做缩放/平移，canvas 内部像素分辨率不变。
  // 之前加过一版"视图整体旋转"，被 Ayden 明确否掉了——他要的是"材质预览不动，
  // 只有选中的那几个面的轮廓能被直接拖动/缩放/旋转"，那是另一套机制（见下面的
  // "拖动手柄"部分），不是转整个取景视角。这里只保留缩放和平移。
  var zoom = 1, panX = 0, panY = 0;
  var ZOOM_MIN = 0.02, ZOOM_MAX = 8;
  var panning = false, panStartX = 0, panStartY = 0, panOrigX = 0, panOrigY = 0;

  function currentStageMatrix() {
    var cs = getComputedStyle(canvasStage).transform;
    try {
      return (cs && cs !== 'none') ? new DOMMatrix(cs) : new DOMMatrix();
    } catch (e) {
      return new DOMMatrix();
    }
  }

  // 把"鼠标在浏览器窗口里的位置"(clientX/Y) 换成 canvas-stage 变换前的本地坐标。
  function stagePointFromClient(clientX, clientY) {
    var vpRect = canvasViewport.getBoundingClientRect();
    var inv = currentStageMatrix().inverse();
    var pt = inv.transformPoint(new DOMPoint(clientX - vpRect.left, clientY - vpRect.top));
    return { x: pt.x, y: pt.y };
  }

  function applyStageTransform() {
    canvasStage.style.transform = 'translate(' + panX + 'px,' + panY + 'px) scale(' + zoom + ')';
    $('zoom-level').textContent = Math.round(zoom * 100) + '%';
  }

  // 缩放/平移到能看见整张平铺范围——一打开就是刚好能看全的状态，不用自己摸索。
  // ZOOM_MIN 得给得足够低：真实模型里一个小贴图铺满一整面大墙，UV 范围能轻松需要
  // 缩到 20% 以下才装得下，卡在固定下限只会让"重置视图"名不副实。
  function fitView() {
    var vw = canvasViewport.clientWidth || 1;
    var vh = canvasViewport.clientHeight || 1;
    var sw = stageWpx || vw;
    var sh = stageHpx || vh;
    zoom = Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, Math.min(vw / sw, vh / sh) * 0.96));
    panX = (vw - (sw * zoom)) / 2;
    panY = (vh - (sh * zoom)) / 2;
    applyStageTransform();
  }

  // 以某个屏幕点(clientX/Y)为锚点缩放：先用当前变换反推出这个点对应的 stage 本地坐标，
  // 换新 zoom 后重新算 pan，让那个点缩放前后停在屏幕同一位置。
  function zoomAt(clientX, clientY, factor) {
    var newZoom = Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, zoom * factor));
    if (newZoom === zoom) { return; }
    var vpRect = canvasViewport.getBoundingClientRect();
    var localX = clientX - vpRect.left;
    var localY = clientY - vpRect.top;
    var p = stagePointFromClient(clientX, clientY);
    zoom = newZoom;
    panX = localX - (p.x * zoom);
    panY = localY - (p.y * zoom);
    applyStageTransform();
  }

  canvasViewport.addEventListener('wheel', function (evt) {
    if (!hasImage) { return; }
    evt.preventDefault();
    zoomAt(evt.clientX, evt.clientY, evt.deltaY < 0 ? 1.15 : 1 / 1.15);
  }, { passive: false });

  $('btn-zoom-in').addEventListener('click', function () {
    var r = canvasViewport.getBoundingClientRect();
    zoomAt(r.left + (r.width / 2), r.top + (r.height / 2), 1.25);
  });
  $('btn-zoom-out').addEventListener('click', function () {
    var r = canvasViewport.getBoundingClientRect();
    zoomAt(r.left + (r.width / 2), r.top + (r.height / 2), 1 / 1.25);
  });
  $('btn-zoom-reset').addEventListener('click', fitView);

  // 平移的触发条件放宽：中键/右键随便按哪都能拖，左键只有落在"灰白虚影"预览区（不是
  // 落在贴图本体 paint-canvas 上）才触发——paint-canvas 自己的 pointerdown 处理器会在
  // 真正开始画笔时 stopPropagation，两者不会打架。因为 translate 是最外层的变换，
  // 拖动的像素差直接加到 panX/panY 上就行，跟当前缩放/旋转角度无关，不用跟着换算。
  function isPanTrigger(evt) {
    if (evt.button === 1 || evt.button === 2) { return true; }
    return evt.button === 0 && !evt.ctrlKey && !evt.metaKey;
  }
  canvasViewport.addEventListener('contextmenu', function (evt) { evt.preventDefault(); });
  canvasViewport.addEventListener('pointerdown', function (evt) {
    if (!hasImage || !isPanTrigger(evt)) { return; }
    evt.preventDefault();
    panStartX = evt.clientX; panStartY = evt.clientY;
    panOrigX = panX; panOrigY = panY;
    try { canvasViewport.setPointerCapture(evt.pointerId); } catch (e) { /* 捕获失败不影响继续平移 */ }
    panning = true;
    canvasViewport.style.cursor = 'grabbing';
  });
  canvasViewport.addEventListener('pointermove', function (evt) {
    if (!panning) { return; }
    panX = panOrigX + (evt.clientX - panStartX);
    panY = panOrigY + (evt.clientY - panStartY);
    applyStageTransform();
  });
  ['pointerup', 'pointercancel', 'pointerleave'].forEach(function (ev) {
    canvasViewport.addEventListener(ev, function () {
      if (!panning) { return; }
      panning = false;
      canvasViewport.style.cursor = '';
    });
  });

  function pointInPolygon(x, y, pts) {
    var inside = false;
    for (var i = 0, j = pts.length - 1; i < pts.length; j = i++) {
      var xi = pts[i][0], yi = pts[i][1], xj = pts[j][0], yj = pts[j][1];
      var intersect = ((yi > y) !== (yj > y)) && (x < ((xj - xi) * (y - yi) / (yj - yi)) + xi);
      if (intersect) { inside = !inside; }
    }
    return inside;
  }

  // Ctrl/Cmd + 左键在 UV 参考线上操作 -> 把贴图变换面板的编辑对象切到选中的面，不用回
  // SketchUp 里重新选。单击 = 只选点中的那一个（不按 Shift 会替换掉之前的选择）；
  // Shift+Ctrl+点 = 在现有选择基础上加选一个；Ctrl+拖拽 = 框选范围内的所有面（Shift 一起按
  // 就是加选一片而不是替换）。这样才能做到"哪几个面单独调、哪几个面一起调都随便挑"，
  // 而不是只能整个材质一起变。
  var uvSelecting = false, uvSelectStart = null, uvSelectAdditive = false;
  var UV_DRAG_THRESHOLD = 4;

  function uvPolyCentroid(pxPts) {
    var sx = 0, sy = 0;
    pxPts.forEach(function (p) { sx += p[0]; sy += p[1]; });
    return [sx / pxPts.length, sy / pxPts.length];
  }

  function drawSelectionRect(x0, y0, x1, y1) {
    cctx.clearRect(0, 0, cursorCanvas.width, cursorCanvas.height);
    cctx.save();
    cctx.strokeStyle = 'rgba(255,200,50,0.95)';
    cctx.lineWidth = Math.max(1, cursorCanvas.width / 700);
    cctx.setLineDash([8, 5]);
    cctx.strokeRect(Math.min(x0, x1), Math.min(y0, y1), Math.abs(x1 - x0), Math.abs(y1 - y0));
    cctx.restore();
  }

  canvasViewport.addEventListener('pointerdown', function (evt) {
    if (!hasImage || evt.button !== 0 || !(evt.ctrlKey || evt.metaKey)) { return; }
    evt.preventDefault();
    uvSelecting = true;
    uvSelectAdditive = evt.shiftKey;
    uvSelectStart = stagePointFromClient(evt.clientX, evt.clientY);
    uvSelectStart.clientX = evt.clientX; uvSelectStart.clientY = evt.clientY;
    try { canvasViewport.setPointerCapture(evt.pointerId); } catch (e) { /* 捕获失败不影响后续 */ }
  });
  canvasViewport.addEventListener('pointermove', function (evt) {
    if (!uvSelecting) { return; }
    var p = stagePointFromClient(evt.clientX, evt.clientY);
    drawSelectionRect(uvSelectStart.x, uvSelectStart.y, p.x, p.y);
  });
  canvasViewport.addEventListener('pointerup', function (evt) {
    if (!uvSelecting) { return; }
    uvSelecting = false;
    cctx.clearRect(0, 0, cursorCanvas.width, cursorCanvas.height);
    var p = stagePointFromClient(evt.clientX, evt.clientY);
    var dragged = Math.hypot(evt.clientX - uvSelectStart.clientX, evt.clientY - uvSelectStart.clientY) > UV_DRAG_THRESHOLD;
    var ids = [];
    if (dragged) {
      var x0 = Math.min(uvSelectStart.x, p.x), x1 = Math.max(uvSelectStart.x, p.x);
      var y0 = Math.min(uvSelectStart.y, p.y), y1 = Math.max(uvSelectStart.y, p.y);
      lastUvMeta.forEach(function (m) {
        var c = uvPolyCentroid(m.pxPts);
        if (c[0] >= x0 && c[0] <= x1 && c[1] >= y0 && c[1] <= y1) { ids.push(m.id); }
      });
    } else {
      for (var i = lastUvMeta.length - 1; i >= 0; i--) {
        if (pointInPolygon(p.x, p.y, lastUvMeta[i].pxPts)) { ids.push(lastUvMeta[i].id); break; }
      }
    }
    if (ids.length) {
      call('select_faces_for_edit', JSON.stringify({ ids: ids, additive: uvSelectAdditive }));
    } else {
      showMsg('这里没有面的 UV 区域，换个地方试试', true);
    }
  });

  brushOpacity.addEventListener('input', function () { $('val-opacity').textContent = brushOpacity.value; });
  brushSize.addEventListener('input', function () { $('val-size').textContent = brushSize.value; });
  brushHardness.addEventListener('input', function () { $('val-hardness').textContent = brushHardness.value; });
  eraserBtn.addEventListener('click', function () {
    eraserOn = !eraserOn;
    eraserBtn.classList.toggle('active', eraserOn);
  });
  showUv.addEventListener('change', function () {
    uvCanvas.style.display = showUv.checked ? 'block' : 'none';
  });

  $('btn-load-paint').addEventListener('click', function () { call('load_paint'); });

  function undoPaintStroke() {
    if (undoStack.length === 0) { return false; }
    var snap = undoStack.pop();
    pctx.putImageData(snap, 0, 0);
    refreshTileBackground();
    call('live_preview', paintCanvas.toDataURL('image/png'));
    return true;
  }
  $('btn-undo').addEventListener('click', undoPaintStroke);

  // Ctrl+Z 在这个面板窗口里默认什么也不做——HtmlDialog 是独立于 SketchUp 主窗口的
  // CEF 页面，键盘事件不会自动转发给 SketchUp 的撤销栈。这里手动接管：画布还有笔刷
  // 撤销历史就先撤那个（等价于点"撤销"按钮）；没有的话（比如刚拖完手柄改了贴图位置，
  // 画布本身没画什么）转去撤销 SketchUp 模型里的上一步操作。
  document.addEventListener('keydown', function (evt) {
    var isUndo = (evt.ctrlKey || evt.metaKey) && !evt.shiftKey && (evt.key === 'z' || evt.key === 'Z');
    if (!isUndo) { return; }
    evt.preventDefault();
    if (!undoPaintStroke()) { call('undo_model'); }
  });

  $('btn-save-paint').addEventListener('click', function () {
    if (!hasImage) { showMsg('还没有载入贴图。', true); return; }
    call('save_paint', paintCanvas.toDataURL('image/png'));
  });

  function pushUndoSnapshot() {
    undoStack.push(pctx.getImageData(0, 0, paintCanvas.width, paintCanvas.height));
    if (undoStack.length > 25) { undoStack.shift(); }
  }

  // 用 stage 的真实 CSS 矩阵求逆换算，而不是 paint-canvas 自己的 getBoundingClientRect
  // 比例——视图旋转之后外接矩形跟真实形状对不上，比例除法会算错落点。
  // stagePointFromClient 给的是"缩小后的 stage 像素"坐标，画笔要落在 paint-canvas
  // 原始分辨率上，减掉偏移后还要再除一次 dispScale 换算回真实贴图像素。
  function canvasPoint(evt) {
    var sp = stagePointFromClient(evt.clientX, evt.clientY);
    return { x: (sp.x - paintLeft) / dispScale, y: (sp.y - paintTop) / dispScale };
  }

  function hexToRgb(hex) {
    var m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex);
    return m ? [parseInt(m[1], 16), parseInt(m[2], 16), parseInt(m[3], 16)] : [0, 0, 0];
  }

  // 软笔刷：用径向渐变盖一个圆，硬度决定"实心核心"占半径的比例，往外线性淡到 0——
  // 硬度 100% 就是老的硬边圆；硬度越低边缘越柔。橡皮擦用同一套逻辑，只是合成模式换成
  // destination-out，渐变的透明度分布决定每个像素被擦掉多少，天然支持柔边擦除。
  function stampAt(x, y) {
    var r = parseFloat(brushSize.value) / 2;
    if (r <= 0) { return; }
    var hardness = parseFloat(brushHardness.value) / 100;
    var alpha = parseFloat(brushOpacity.value) / 100;
    var rgb = hexToRgb(brushColor.value);
    var coreR = Math.max(0, r * hardness);

    pctx.save();
    pctx.globalCompositeOperation = eraserOn ? 'destination-out' : 'source-over';
    var grad = pctx.createRadialGradient(x, y, coreR, x, y, r);
    grad.addColorStop(0, 'rgba(' + rgb[0] + ',' + rgb[1] + ',' + rgb[2] + ',' + alpha + ')');
    grad.addColorStop(1, 'rgba(' + rgb[0] + ',' + rgb[1] + ',' + rgb[2] + ',0)');
    pctx.fillStyle = grad;
    pctx.beginPath();
    pctx.arc(x, y, r, 0, Math.PI * 2);
    pctx.fill();
    pctx.restore();
  }

  // 两点之间按间距补插盖章，避免鼠标移动快时中间露出一段段空隙。
  function stampLine(x0, y0, x1, y1) {
    var r = Math.max(1, parseFloat(brushSize.value) / 2);
    var spacing = Math.max(1, r / 4);
    var dist = Math.hypot(x1 - x0, y1 - y0);
    var steps = Math.max(1, Math.ceil(dist / spacing));
    for (var i = 0; i <= steps; i++) {
      var t = i / steps;
      stampAt(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t);
    }
  }

  // 传进来的 (x,y) 是 paint-canvas 原始像素坐标（跟 stampAt 一致），但光标画在
  // cursor-canvas 上，跟 uv-canvas 共用缩小后的 stage 坐标系，得先换算过去。
  function drawBrushCursor(nativeX, nativeY) {
    var r = Math.max(1, parseFloat(brushSize.value) / 2) * dispScale;
    var x = paintLeft + (nativeX * dispScale);
    var y = paintTop + (nativeY * dispScale);
    cctx.clearRect(0, 0, cursorCanvas.width, cursorCanvas.height);
    cctx.save();
    cctx.lineWidth = Math.max(1, cursorCanvas.width / 500);
    cctx.strokeStyle = 'rgba(0,0,0,0.85)';
    cctx.beginPath();
    cctx.arc(x, y, r, 0, Math.PI * 2);
    cctx.stroke();
    cctx.strokeStyle = 'rgba(255,255,255,0.85)';
    cctx.lineWidth = Math.max(0.5, cursorCanvas.width / 900);
    cctx.beginPath();
    cctx.arc(x, y, r, 0, Math.PI * 2);
    cctx.stroke();
    cctx.restore();
  }

  paintCanvas.addEventListener('pointerdown', function (evt) {
    if (!hasImage || evt.button !== 0 || evt.ctrlKey || evt.metaKey) { return; }
    // 双重保险：手柄的命中检测理论上应该在 capture 阶段就先拦下这次点击（见下面
    // canvasViewport 那个 capture:true 的监听器），但不同环境对 capture/冒泡顺序、
    // setPointerCapture 的处理可能有细微差异——这里独立再判一次，点在手柄上就直接
    // 不进入画笔逻辑，不完全依赖事件传播顺序这一条路径。
    if (hitTestHandle(stagePointFromClient(evt.clientX, evt.clientY))) { return; }
    // 挡住冒泡：不然 canvasViewport 那个"空白区域左键也能平移"的处理器会同时把这次
    // 点击也当成拖动平移的起点，画笔和平移会一起触发。
    evt.stopPropagation();
    var p = canvasPoint(evt);
    lastX = p.x; lastY = p.y;
    try { paintCanvas.setPointerCapture(evt.pointerId); } catch (e) { /* 捕获失败不影响继续画 */ }
    pushUndoSnapshot();
    drawing = true;
    stampAt(p.x, p.y);
  });
  paintCanvas.addEventListener('pointermove', function (evt) {
    var p = canvasPoint(evt);
    drawBrushCursor(p.x, p.y);
    if (!drawing) { return; }
    stampLine(lastX, lastY, p.x, p.y);
    lastX = p.x; lastY = p.y;
  });
  paintCanvas.addEventListener('pointerleave', function () {
    cctx.clearRect(0, 0, cursorCanvas.width, cursorCanvas.height);
  });
  // 一笔画完（松开/移出/取消）才刷新平铺预览 + 推给 SketchUp 做实时预览——按 Ayden 的原话
  // "松开鼠标那一瞬间"，不是拖动过程中连续推（那样又变回逐帧刷新贴图的老问题）。
  ['pointerup', 'pointerleave', 'pointercancel'].forEach(function (ev) {
    paintCanvas.addEventListener(ev, function () {
      if (!drawing) { return; }
      drawing = false;
      refreshTileBackground();
      call('live_preview', paintCanvas.toDataURL('image/png'));
    });
  });

  // 真实模型里一个可平铺小贴图铺满一整面大墙、或者圆柱侧面按弧长展开，UV 范围都能
  // 轻松跨十几格。第一版做法是"超预算就以贴图本体为中心砍掉多余范围"——结果圆柱这种
  // 横向铺得很宽的情况，26 块面里大部分的 UV 落在砍掉的范围外，参考线直接消失了大半，
  // 完全不是"完整展开"。改成"超预算就整体等比缩小分辨率"，绝不砍内容：先按 UV 真实
  // 范围（不设上限）算出总面积，超过像素预算就求一个缩放系数把三张预览画布(平铺/UV/
  // 光标)的分辨率一起降下来——画布还是完整盖住整个 UV 范围，只是精细度变低。
  // paint-canvas(真正能画、能存盘的那张)例外：它的内部像素分辨率永远保持贴图原始
  // 大小不缩水，只是显示尺寸跟着一起缩小，画笔坐标换算时按 dispScale 换算回真实像素。
  var STAGE_PX_BUDGET = 3072 * 3072;
  var dispScale = 1;

  function computeLayout(polys, imgW, imgH) {
    texW = imgW; texH = imgH;
    var minU = 0, maxU = 1, minV = 0, maxV = 1;
    polys.forEach(function (p) {
      p.pts.forEach(function (uv) {
        if (uv[0] < minU) { minU = uv[0]; }
        if (uv[0] > maxU) { maxU = uv[0]; }
        if (uv[1] < minV) { minV = uv[1]; }
        if (uv[1] > maxV) { maxV = uv[1]; }
      });
    });
    var floorMinU = Math.floor(minU);
    var ceilMaxU = Math.ceil(maxU);
    var floorMinV = Math.floor(minV);
    var ceilMaxV = Math.ceil(maxV);
    var tilesX = Math.max(1, ceilMaxU - floorMinU);
    var tilesY = Math.max(1, ceilMaxV - floorMinV);

    var naturalW = tilesX * texW;
    var naturalH = tilesY * texH;
    dispScale = Math.min(1, Math.sqrt(STAGE_PX_BUDGET / (naturalW * naturalH)));

    tileOriginU = floorMinU;
    tileOriginVTop = ceilMaxV;
    stageWpx = naturalW * dispScale;
    stageHpx = naturalH * dispScale;
    paintLeft = (0 - tileOriginU) * texW * dispScale;
    paintTop = (tileOriginVTop - 1) * texH * dispScale;
  }

  function applyLayout() {
    canvasStage.style.width = stageWpx + 'px';
    canvasStage.style.height = stageHpx + 'px';

    [tileBgCanvas, uvCanvas, handlesCanvas, cursorCanvas].forEach(function (c) {
      c.width = stageWpx; c.height = stageHpx;
      c.style.width = stageWpx + 'px'; c.style.height = stageHpx + 'px';
      c.style.left = '0px'; c.style.top = '0px';
    });

    // paint-canvas 的内部分辨率(能画的真实像素)不受 dispScale 影响，只有显示尺寸/
    // 位置跟着整个 stage 一起缩放，这样存盘的还是贴图原始清晰度。
    paintCanvas.width = texW; paintCanvas.height = texH;
    paintCanvas.style.width = (texW * dispScale) + 'px';
    paintCanvas.style.height = (texH * dispScale) + 'px';
    paintCanvas.style.left = paintLeft + 'px'; paintCanvas.style.top = paintTop + 'px';
  }

  // 贴图本体(paint-canvas)按平铺关系重复贴满整张大画布，当"这个材质铺满模型后大概
  // 长什么样"的预览——直接拿 paint-canvas 当 pattern 源，画完一笔就能重新铺一次，
  // 画布内容和预览天然同步，不用单独维护一份图像数据。pattern 本身按 paint-canvas
  // 的原始分辨率平铺，这里用 setTransform 把平铺间距缩到 dispScale，跟画布其它内容
  // 用同一套缩小后的尺度对齐。
  function refreshTileBackground() {
    tctx.clearRect(0, 0, tileBgCanvas.width, tileBgCanvas.height);
    var pattern = tctx.createPattern(paintCanvas, 'repeat');
    if (pattern.setTransform) { pattern.setTransform(new DOMMatrix().scale(dispScale)); }
    tctx.save();
    tctx.translate(paintLeft, paintTop);
    tctx.fillStyle = pattern;
    tctx.fillRect(-paintLeft, -paintTop, tileBgCanvas.width, tileBgCanvas.height);
    tctx.restore();
  }

  function uvToPx(uv) {
    return [(uv[0] - tileOriginU) * texW * dispScale, (tileOriginVTop - uv[1]) * texH * dispScale];
  }

  function drawUvOverlay() {
    uctx.clearRect(0, 0, uvCanvas.width, uvCanvas.height);
    lastUvMeta = lastUvPolys.map(function (poly) {
      return { id: poly.id, pxPts: poly.pts.map(uvToPx) };
    });
    if (!showUv.checked) { return; }
    uctx.strokeStyle = 'rgba(80,220,255,0.9)';
    uctx.lineWidth = Math.max(1, uvCanvas.width / 800);
    lastUvMeta.forEach(function (m) {
      if (m.pxPts.length < 2) { return; }
      uctx.beginPath();
      m.pxPts.forEach(function (pt, i) {
        if (i === 0) { uctx.moveTo(pt[0], pt[1]); } else { uctx.lineTo(pt[0], pt[1]); }
      });
      uctx.closePath();
      uctx.stroke();
    });
  }

  // ---------- 拖动手柄：直接在 2D 画布上移动/缩放/旋转选中的面 ----------
  // Ayden 明确要的行为："材质预览不动，只有选中的这几个面的轮廓能被直接拖动"——
  // 不是转整个取景视角（那个已经删掉了），是给选中的轮廓单独配一套可拖拽的控制点，
  // 拖动结果最终还是走"贴图变换"标签页那几个滑块 + apply_transform 同一条路，
  // 只是这里用鼠标手势代替了拖滑块。
  var HANDLE_SCREEN_SIZE = 9;
  var ROTATE_HANDLE_SCREEN_OFFSET = 28;
  var dmDrag = null;

  function selectionBounds() {
    var pts = [];
    lastUvMeta.forEach(function (m) {
      if (selectedFaceIds.indexOf(m.id) === -1) { return; }
      m.pxPts.forEach(function (p) { pts.push(p); });
    });
    if (!pts.length) { return null; }
    var minX = pts[0][0], maxX = pts[0][0], minY = pts[0][1], maxY = pts[0][1];
    pts.forEach(function (p) {
      if (p[0] < minX) { minX = p[0]; }
      if (p[0] > maxX) { maxX = p[0]; }
      if (p[1] < minY) { minY = p[1]; }
      if (p[1] > maxY) { maxY = p[1]; }
    });
    return { minX: minX, maxX: maxX, minY: minY, maxY: maxY, cx: (minX + maxX) / 2, cy: (minY + maxY) / 2 };
  }

  // 手柄的"视觉大小"跟当前 zoom 无关（除以 zoom 换算回 stage 坐标），不然缩得很小时
  // 手柄会小到点不中，放得很大时又占掉一大片画面——专业软件的控制点都是固定屏幕大小。
  function handleGeometry() {
    var b = selectionBounds();
    if (!b) { return null; }
    var hs = HANDLE_SCREEN_SIZE / zoom;
    // 旋转手柄伸出去的距离用"选区自身高度的一个比例"而不是固定屏幕像素——固定屏幕像素
    // 换算回 stage 坐标要除以 zoom，取景很宽（比如圆柱展开后 zoom 常常缩到 10% 以下）时
    // 这个距离会变得很大，选区一旦靠近整张平铺画布的边缘，手柄会被顶到画布外面、
    // 既看不见也点不到（实测复现过：单个面默认贴图，UV 顶到画布上边缘，手柄直接消失）。
    // 改成跟选区自己的高度成比例，不管缩放倍数多少，手柄永远落在选区附近的画布范围内。
    var ro = Math.max((b.maxY - b.minY) * 0.25, HANDLE_SCREEN_SIZE * 3 / zoom);
    // 再兜底一层：就算选区顶边正好贴着整张画布的边缘（比如单独一个面默认贴图时很常见），
    // 手柄圆点本身也至少要完整落在画布范围内，不然连兜底的比例算法都可能被顶出界。
    var rotY = Math.max(hs * 1.2, b.minY - ro);
    return {
      bounds: b,
      handleRadius: hs,
      corners: [[b.minX, b.minY], [b.maxX, b.minY], [b.maxX, b.maxY], [b.minX, b.maxY]],
      rotateHandle: [b.cx, rotY]
    };
  }

  function drawHandles() {
    hctx.clearRect(0, 0, handlesCanvas.width, handlesCanvas.height);
    var g = handleGeometry();
    if (!g) { return; }
    var b = g.bounds;
    hctx.save();
    hctx.strokeStyle = 'rgba(255,180,40,0.95)';
    hctx.lineWidth = Math.max(1, 1.5 / zoom);
    hctx.strokeRect(b.minX, b.minY, b.maxX - b.minX, b.maxY - b.minY);
    hctx.beginPath();
    hctx.moveTo(b.cx, b.minY);
    hctx.lineTo(g.rotateHandle[0], g.rotateHandle[1]);
    hctx.stroke();
    hctx.fillStyle = '#ffb428';
    g.corners.forEach(function (c) {
      hctx.beginPath();
      hctx.arc(c[0], c[1], g.handleRadius, 0, Math.PI * 2);
      hctx.fill();
    });
    hctx.fillStyle = '#4fd0ff';
    hctx.beginPath();
    hctx.arc(g.rotateHandle[0], g.rotateHandle[1], g.handleRadius, 0, Math.PI * 2);
    hctx.fill();
    // 中心的移动手柄，用绿色方块区分——只有点这个方块才会触发移动，框内其它地方留给画笔。
    hctx.fillStyle = '#8bd450';
    hctx.fillRect(b.cx - g.handleRadius, b.cy - g.handleRadius, g.handleRadius * 2, g.handleRadius * 2);
    hctx.restore();
  }

  // 拖拽过程中只在客户端画一个跟着走的预览框（相对这次拖拽开始时的形状算增量），
  // 不没拖一下都去改真实模型——跟"滑块拖动松手才提交"是同一个道理，也避免拖动
  // 中疯狂调 position_material。真正的轮廓形状等松手提交、Ruby 那边确认过再刷新。
  function drawDmPreview(d) {
    hctx.clearRect(0, 0, handlesCanvas.width, handlesCanvas.height);
    var b = d.bounds;
    var hw = (b.maxX - b.minX) / 2, hh = (b.maxY - b.minY) / 2;
    var rad = (d.deltaDeg || 0) * Math.PI / 180;
    var cosA = Math.cos(rad), sinA = Math.sin(rad);
    var fx = (d.factorX != null ? d.factorX : d.factor) || 1;
    var fy = (d.factorY != null ? d.factorY : d.factor) || 1;
    var ox = d.duPx || 0, oy = d.dvPx || 0;
    var local = [[-hw, -hh], [hw, -hh], [hw, hh], [-hw, hh]];
    var corners = local.map(function (lc) {
      var sxp = lc[0] * fx, syp = lc[1] * fy;
      var rx = (sxp * cosA) - (syp * sinA);
      var ry = (sxp * sinA) + (syp * cosA);
      return [b.cx + rx + ox, b.cy + ry + oy];
    });
    hctx.save();
    hctx.strokeStyle = 'rgba(255,180,40,0.95)';
    hctx.setLineDash([6, 4]);
    hctx.lineWidth = Math.max(1, 1.5 / zoom);
    hctx.beginPath();
    corners.forEach(function (c, i) { if (i === 0) { hctx.moveTo(c[0], c[1]); } else { hctx.lineTo(c[0], c[1]); } });
    hctx.closePath();
    hctx.stroke();
    hctx.restore();
  }

  // 只认手柄本身，不认"框内任意位置"——早期版本把整个包围盒内部都当成"移动"手势，
  // 结果选中的面积经常跟贴图本体差不多大，一旦选中就等于整块贴图再也点不了画笔了。
  // 移动单独给一个中心的绿色小方块当专属手柄，跟角上的缩放点、上面的旋转点一视同仁，
  // 框内其余地方保持能正常画笔。
  function hitTestHandle(p) {
    var g = handleGeometry();
    if (!g) { return null; }
    var r = g.handleRadius * 1.5;
    for (var i = 0; i < g.corners.length; i++) {
      var c = g.corners[i];
      if (Math.hypot(p.x - c[0], p.y - c[1]) <= r) { return { type: 'scale' }; }
    }
    if (Math.hypot(p.x - g.rotateHandle[0], p.y - g.rotateHandle[1]) <= r) { return { type: 'rotate' }; }
    var b = g.bounds;
    if (Math.hypot(p.x - b.cx, p.y - b.cy) <= r) { return { type: 'move' }; }
    return null;
  }

  // 抢在其它所有 pointerdown 处理器之前（capture 阶段）判断有没有点中手柄——点中了就
  // 整个手势归这里管，画笔/框选/平移都不应该同时触发。
  canvasViewport.addEventListener('pointerdown', function (evt) {
    if (!hasImage || evt.button !== 0 || evt.ctrlKey || evt.metaKey) { return; }
    var p = stagePointFromClient(evt.clientX, evt.clientY);
    var hit = hitTestHandle(p);
    if (!hit) { return; }
    evt.preventDefault();
    evt.stopImmediatePropagation();
    dmDrag = {
      type: hit.type,
      startPoint: p,
      bounds: selectionBounds(),
      baseAngle: parseFloat(rot.value),
      baseScaleX: parseFloat(sx.value),
      baseScaleY: parseFloat(sy.value),
      baseOffsetU: parseFloat(ou.value),
      baseOffsetV: parseFloat(ov.value),
      deltaDeg: 0, factor: 1, factorX: 1, factorY: 1, duPx: 0, dvPx: 0
    };
    try { canvasViewport.setPointerCapture(evt.pointerId); } catch (e) { /* 捕获失败不影响继续拖动 */ }
  }, true);

  canvasViewport.addEventListener('pointermove', function (evt) {
    if (!dmDrag) { return; }
    var p = stagePointFromClient(evt.clientX, evt.clientY);
    var b = dmDrag.bounds;
    if (dmDrag.type === 'move') {
      dmDrag.duPx = p.x - dmDrag.startPoint.x;
      dmDrag.dvPx = p.y - dmDrag.startPoint.y;
    } else if (dmDrag.type === 'scale') {
      // 不按 Shift：整体等比缩放（沿"中心->角点"方向的距离比）。
      // 按住 Shift：X/Y 各自独立缩放（角点在各自轴上离中心的距离比），不保持比例。
      if (evt.shiftKey) {
        var dxStart = dmDrag.startPoint.x - b.cx, dyStart = dmDrag.startPoint.y - b.cy;
        var dxCur = p.x - b.cx, dyCur = p.y - b.cy;
        dmDrag.factorX = dxStart !== 0 ? (dxCur / dxStart) : 1;
        dmDrag.factorY = dyStart !== 0 ? (dyCur / dyStart) : 1;
        dmDrag.factor = null;
      } else {
        var startDist = Math.hypot(dmDrag.startPoint.x - b.cx, dmDrag.startPoint.y - b.cy) || 1;
        var curDist = Math.hypot(p.x - b.cx, p.y - b.cy);
        dmDrag.factor = curDist / startDist;
        dmDrag.factorX = dmDrag.factorY = dmDrag.factor;
      }
    } else if (dmDrag.type === 'rotate') {
      var startAngle = Math.atan2(dmDrag.startPoint.y - b.cy, dmDrag.startPoint.x - b.cx);
      var curAngle = Math.atan2(p.y - b.cy, p.x - b.cx);
      dmDrag.deltaDeg = (curAngle - startAngle) * 180 / Math.PI;
    }
    drawDmPreview(dmDrag);
  });

  ['pointerup', 'pointercancel'].forEach(function (ev) {
    canvasViewport.addEventListener(ev, function () {
      if (!dmDrag) { return; }
      var d = dmDrag;
      dmDrag = null;
      if (d.type === 'move') {
        var duSlider = (d.duPx / (texW * dispScale)) * 100;
        var dvSlider = -(d.dvPx / (texH * dispScale)) * 100; // 屏幕 Y 往下，UV 的 v 往上，符号相反
        ou.value = d.baseOffsetU + duSlider;
        ov.value = d.baseOffsetV + dvSlider;
      } else if (d.type === 'scale') {
        sx.value = d.baseScaleX * (d.factorX != null ? d.factorX : d.factor);
        sy.value = d.baseScaleY * (d.factorY != null ? d.factorY : d.factor);
      } else if (d.type === 'rotate') {
        var newAngle = d.baseAngle + d.deltaDeg;
        while (newAngle > 180) { newAngle -= 360; }
        while (newAngle < -180) { newAngle += 360; }
        rot.value = newAngle;
      }
      syncLabels();
      // 拖完只有在 apply_transform 真的成功了才刷新画布——不然选区/模式不满足要求时
      // (比如单独一个面套了"圆柱投影"，压根凑不出一条轴) Ruby 会报错，但这里如果照样
      // 无条件紧跟着调 load_paint，onError 刚显示出来的错误提示会被 load_paint 成功后
      // 那条"UV 参考线：..."的普通提示立刻覆盖掉——用户根本来不及看到报错，只会觉得
      // "拖了但什么反应都没有"（实测复现过）。改成等 onInfo('已更新') 真正回来了再刷新，
      // 收到 onError 就不刷新，让报错老老实实留在提示条上。
      suppressFitOnNextLoad = true; // 拖完刷新只是要真实轮廓，不该把用户正看着的视角重置掉
      pendingDragReload = true;
      sendTransform();
    });
  });

  // ---------- 来自 Ruby 的回调 ----------
  window.MP = {
    onInit: function () {},
    onSelection: function (data) {
      var t = data.count === 0
        ? '未选中任何面'
        : ('已选中 ' + data.count + ' 个面' + (data.materialName ? '　材质: ' + data.materialName : '') +
           (data.hasTexture ? '' : '　(无贴图)'));
      $('sel-info').textContent = t;
      selectedFaceIds = data.selectedIds || [];
      drawHandles();
    },
    onInfo: function (data) {
      showMsg(data.message, false);
      if (pendingDragReload) { pendingDragReload = false; call('load_paint'); }
    },
    onError: function (data) {
      showMsg(data.message, true);
      pendingDragReload = false;
    },
    onPaintImage: function (data) {
      var img = new Image();
      img.onload = function () {
        lastUvPolys = data.uvPolys || [];
        computeLayout(lastUvPolys, data.width, data.height);
        applyLayout();
        pctx.clearRect(0, 0, paintCanvas.width, paintCanvas.height);
        pctx.drawImage(img, 0, 0, data.width, data.height);
        undoStack = [];
        drawUvOverlay();
        drawHandles();
        refreshTileBackground();
        canvasEmpty.style.display = 'none';
        hasImage = true;
        if (suppressFitOnNextLoad) { suppressFitOnNextLoad = false; } else { fitView(); }
        if (data.uvFaceCount !== undefined) {
          var note = 'UV 参考线：整个模型里用这个材质的面共 ' + data.uvFaceCount + ' 个';
          if (data.uvTimedOut) { note += '（模型较大，只显示了一部分）'; }
          if (dispScale < 0.999) { note += '；范围较大，预览分辨率自动降到了 ' + Math.round(dispScale * 100) + '% 换取完整显示（不影响实际贴图清晰度，只是这块预览变糊）'; }
          showMsg(note, false);
        }
      };
      img.src = data.dataUrl;
    }
  };

  syncLabels();
  call('ready');
})();
