# frozen_string_literal: true

require 'json'
require 'sketchup.rb'

require File.join(__dir__, 'presets')
require File.join(__dir__, 'model_extractor')
require File.join(__dir__, 'capture')
require File.join(__dir__, 'comfy_client')
require File.join(__dir__, 'flux_builder')
require File.join(__dir__, 'geometry_check')
require File.join(__dir__, 'downloader')

module AydinCreative
  module AiRenderStudio
    WORK_DIR = File.join(ENV['TEMP'] || Dir.tmpdir, 'ai_render_studio')
    Dir.mkdir(WORK_DIR) unless Dir.exist?(WORK_DIR)
    RENDER_LOG = File.join(WORK_DIR, 'render.log')
    begin
      File.open(RENDER_LOG, 'a:utf-8') { |f| f.puts "#{Time.now.strftime('%H:%M:%S')}  [module] main.rb (re)loaded"; f.flush }
    rescue StandardError
      nil
    end

    @dialog = nil
    @result_dialog = nil
    @render_thread = nil
    @render_state = nil
    @poll_timer = nil
    @comfy_watch = nil
    @view_watch = nil
    @last_cam_fp = nil
    @comfy_launch_started = false
    @aspect = 'window'
    @aspect_ratio = 0.0
    @last_opts = {}          # 上次渲染设置，供"重新渲染"用
    @last_result = nil       # { local:, comfy_path:, filename: }
    @job = nil               # Flux 管线的多次尝试/择优/放大状态，见 on_render_flux
    @last_source_path = nil  # 当前结果对应的"渲染前"图（SketchUp 结构图，或"增强真实感"里用户上传的原图）——给结果窗口的滑动对比条用

    # ---- Ruby 侧界面文字（菜单 / 弹窗 / 保存对话框 / 错误）------------
    STRINGS = {
      'zh' => {
        s_probe: '检查本地模型…', s_attempt: 'Flux 照片级出图（第 %d/%d 张）…', s_retry: '结构吻合度 %d%%，换种子重出…', s_upscale: '放大到目标分辨率…', s_resize: '放大到目标分辨率…',
        s_extract: '提取模型信息…（大模型可能要几秒）', s_capture: '截取当前视角…', s_connect: '连接 ComfyUI…', s_upload: '上传结构图…', s_upref: '上传参考图…', s_build: '生成工作流…', s_submit: '提交到 ComfyUI…', s_processing: 'ComfyUI 处理中',
        menu_open: '打开渲染面板', menu_reload: '重新加载插件（开发）', menu_log: '打开日志文件夹',
        cmd_name: 'AI 渲染', cmd_tip: 'AI 渲染工作室',
        reloaded: 'AI 渲染工作室：已重新加载。请重新打开渲染面板。',
        reload_fail: '重新加载失败：', save_title: '保存渲染图', result_title: 'AI 渲染结果',
        err_busy: '已有渲染任务在进行中。', err_no_result: '没有可调色的结果。',
        err_comfy: 'ComfyUI 未响应（%s）。请确认 ComfyUI 在运行。',
        err_capture: '截图失败：view.write_image 没有产出文件（模型可能过大 / 显卡渲染卡住）',
        err_seealso: '（%s）— 详见 render.log', save_fail: '保存失败：'
      },
      'en' => {
        s_probe: 'Checking local models…', s_attempt: 'Flux photoreal pass (%d/%d)…', s_retry: 'Structure match %d%%, re-rendering with a new seed…', s_upscale: 'Upscaling to target resolution…', s_resize: 'Upscaling to target resolution…',
        s_extract: 'Reading model info… (a few seconds on big models)', s_capture: 'Capturing the view…', s_connect: 'Connecting to ComfyUI…', s_upload: 'Uploading structure image…', s_upref: 'Uploading reference image…', s_build: 'Building workflow…', s_submit: 'Submitting to ComfyUI…', s_processing: 'ComfyUI is working',
        menu_open: 'Open render panel', menu_reload: 'Reload plugin (dev)', menu_log: 'Open log folder',
        cmd_name: 'AI Render', cmd_tip: 'AI Render Studio',
        reloaded: 'AI Render Studio: reloaded. Please reopen the render panel.',
        reload_fail: 'Reload failed: ', save_title: 'Save render', result_title: 'AI Render Result',
        err_busy: 'A render is already running.', err_no_result: 'No render to grade.',
        err_comfy: 'ComfyUI is not responding (%s). Make sure ComfyUI is running.',
        err_capture: 'Capture failed: view.write_image produced no file (model may be too heavy / GPU stalled)',
        err_seealso: '(%s) — see render.log', save_fail: 'Save failed: '
      },
      'ru' => {
        s_probe: 'Проверка локальных моделей…', s_attempt: 'Flux фотореализм (%d/%d)…', s_retry: 'Совпадение структуры %d%%, повтор с новым seed…', s_upscale: 'Upscaling…', s_resize: 'Upscaling…',
        s_extract: 'Чтение данных модели… (несколько секунд для больших)', s_capture: 'Снимок вида…', s_connect: 'Подключение к ComfyUI…', s_upload: 'Загрузка структурного изображения…', s_upref: 'Загрузка референса…', s_build: 'Сборка воркфлоу…', s_submit: 'Отправка в ComfyUI…', s_processing: 'ComfyUI обрабатывает',
        menu_open: 'Открыть панель рендеринга', menu_reload: 'Перезагрузить плагин (разр.)', menu_log: 'Открыть папку логов',
        cmd_name: 'AI Рендер', cmd_tip: 'AI Студия рендеринга',
        reloaded: 'AI Студия рендеринга: перезагружено. Откройте панель заново.',
        reload_fail: 'Ошибка перезагрузки: ', save_title: 'Сохранить рендер', result_title: 'Результат рендеринга',
        err_busy: 'Рендеринг уже выполняется.', err_no_result: 'Нет рендера для цветокоррекции.',
        err_comfy: 'ComfyUI не отвечает (%s). Убедитесь, что ComfyUI запущен.',
        err_capture: 'Не удалось сделать снимок: view.write_image не создал файл (модель слишком тяжёлая / GPU завис)',
        err_seealso: '(%s) — см. render.log', save_fail: 'Ошибка сохранения: '
      },
      'kk' => {
        s_probe: 'Жергілікті модельдерді тексеру…', s_attempt: 'Flux фотошынайы рендер (%d/%d)…', s_retry: 'Құрылым сәйкестігі %d%%, жаңа seed-пен қайта…', s_upscale: 'Upscaling…', s_resize: 'Upscaling…',
        s_extract: 'Модель ақпаратын оқу… (үлкен модельдерде бірнеше секунд)', s_capture: 'Көріністі түсіру…', s_connect: 'ComfyUI-ге қосылу…', s_upload: 'Құрылым суретін жүктеу…', s_upref: 'Үлгі суретті жүктеу…', s_build: 'Воркфлоу құру…', s_submit: 'ComfyUI-ге жіберу…', s_processing: 'ComfyUI жұмыс істеуде',
        menu_open: 'Рендер панелін ашу', menu_reload: 'Плагинді қайта жүктеу (әзірлеу)', menu_log: 'Журнал қалтасын ашу',
        cmd_name: 'AI Рендер', cmd_tip: 'AI Рендер студиясы',
        reloaded: 'AI Рендер студиясы: қайта жүктелді. Панельді қайта ашыңыз.',
        reload_fail: 'Қайта жүктеу қатесі: ', save_title: 'Рендерді сақтау', result_title: 'Рендеринг нәтижесі',
        err_busy: 'Рендеринг қазірдің өзінде орындалуда.', err_no_result: 'Түс түзетуге рендер жоқ.',
        err_comfy: 'ComfyUI жауап бермейді (%s). ComfyUI іске қосылғанын тексеріңіз.',
        err_capture: 'Түсіру сәтсіз: view.write_image файл жасамады (модель тым ауыр / GPU қатып қалды)',
        err_seealso: '(%s) — render.log қараңыз', save_fail: 'Сақтау қатесі: '
      }
    }.freeze

    @lang = (Sketchup.read_default('ars_render_studio', 'lang', 'zh') rescue 'zh')

    module_function

    def tr(key, *args)
      s = (STRINGS[@lang] || STRINGS['zh'])[key] || STRINGS['zh'][key] || key.to_s
      args.empty? ? s : format(s, *args)
    end

    # ================= 设置 =================
    # 渲染引擎：Flux.2 Klein 9B（最初的 Flux 管线，见 flux_builder.rb）。中间试过的 RealVisXL、Z-Image
    # 实测都不如它，已删除。可调的只剩"自动择优"开关。
    SETTINGS_SECTION = 'ars_render_studio'
    MAX_ATTEMPTS = 3            # 开"自动择优"时一次渲染最多出几张（本地出图不花钱，只花时间）
    GEOMETRY_PASS_SCORE = 0.55  # 结构吻合度低于这个就换种子重出（合成测试：对齐≈0.95，错位/丢物体≈0.3-0.4）

    def load_settings
      retry_v = (Sketchup.read_default(SETTINGS_SECTION, 'cfg_auto_retry', true) rescue true)
      { auto_retry: retry_v == true || retry_v.to_s == 'true' }
    end

    def save_settings(json)
      data = JSON.parse(json.to_s)
      Sketchup.write_default(SETTINGS_SECTION, 'cfg_auto_retry', data['auto_retry'] ? true : false) if data.key?('auto_retry')
      rlog "settings saved: #{load_settings}"
      to_js('settings', load_settings)
    rescue StandardError => e
      rlog "save_settings ERROR: #{e.class}: #{e.message}"
    end

    # 告诉面板：Flux 需要的模型齐不齐、缺什么
    def push_model_status
      client = ComfyClient.new
      return unless client.online?
      r = FluxBuilder.resolve(client)
      rlog "  models ok=#{r[:ok]} #{r[:models]}"
      log_model_folders(r) unless r[:ok]
      @last_resolve = r
      dl = ->(list) { { count: list.size, gb: list.sum { |x| x[:gb].to_f }.round(1) } }
      to_js('models', { ok: r[:ok], missing: r[:missing], dl_required: dl.call(r[:downloads] || []),
                        downloading: Downloader.running?(WORK_DIR) })
      watch_download if Downloader.running?(WORK_DIR)
    rescue StandardError => e
      rlog "push_model_status ERROR: #{e.class}: #{e.message}"
    end

    # ---- 一键下载缺失模型 ----
    def start_download(which)
      return watch_download if Downloader.running?(WORK_DIR) # 已经在下（比如关了面板又打开）
      r = @last_resolve || FluxBuilder.resolve(ComfyClient.new)
      items = Array(r[:downloads])
      _ = which
      return to_js('download', { error: '没有需要下载的文件', done: true }) if items.empty?
      rlog "download start (#{which}): #{items.map { |x| "#{x[:folder]}/#{x[:name]}" }.join(', ')}"
      pid = Downloader.start(items, ComfyClient.new, WORK_DIR)
      rlog "  download process pid=#{pid}"
      watch_download
    rescue StandardError => e
      rlog "start_download ERROR: #{e.class}: #{e.message}"
      to_js('download', { error: e.message, done: true })
    end

    # 下载在独立进程里跑；这里只是每秒读一次它的进度文件推给面板
    def watch_download
      return if @download_timer
      @download_timer = UI.start_timer(1.0, true) do
        snap = Downloader.snapshot(WORK_DIR)
        to_js('download', snap)
        if snap[:done]
          UI.stop_timer(@download_timer)
          @download_timer = nil
          rlog "download finished: #{snap}"
          push_model_status # ComfyUI 按目录修改时间刷新文件列表，下完不用重启
        end
      end
    end

    # 找不到模型时，把 ComfyUI 各模型文件夹里实际有什么全部写进 render.log，方便对照排查
    def log_model_folders(res)
      rlog '  ---- Flux 模型检测没通过，ComfyUI 各文件夹实际内容：'
      res[:missing].each { |line| rlog "  #{line.gsub("\n", ' ')}" }
      (res[:found] || {}).each do |folder, files|
        rlog "  [#{folder}] (#{files.size}) #{files.first(60).join(' | ')}"
      end
    end

    # ================= 主面板 =================

    def show_dialog
      if @dialog&.visible?
        @dialog.bring_to_front
        return
      end
      @dialog = UI::HtmlDialog.new(
        dialog_title: tr(:cmd_tip),
        preferences_key: 'com.aydincreative.ai_render_studio',
        scrollable: true, resizable: true,
        width: 1180, height: 820, min_width: 900, min_height: 620,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      @dialog.set_file(dev_asset('dialog.html'))
      register_callbacks(@dialog)
      @dialog.set_on_closed { stop_render; stop_comfy_watch; stop_view_watch }
      @dialog.show
      # 网页里 window.sketchup 桥接对象由 SketchUp 异步注入，时机不保证；
      # 不完全依赖网页主动调用 'ready'，Ruby 这边显示后也主动推一次初始状态。
      # on_ready 内部幂等（重复调用最多多刷一次截图/init，无副作用），两边谁先到都行。
      UI.start_timer(0.5, false) { on_ready }
    end

    def register_callbacks(dlg)
      dlg.add_action_callback('ready')            { |_c| on_ready }
      dlg.add_action_callback('refresh_view')     { |_c| push_snapshot }
      dlg.add_action_callback('recheck_comfy')    { |_c| push_comfy_status }
      dlg.add_action_callback('set_lang')         { |_c, l| set_lang(l) }
      dlg.add_action_callback('set_aspect')       { |_c, name, ratio| on_set_aspect(name, ratio) }
      dlg.add_action_callback('analyze')          { |_c| on_analyze }
      dlg.add_action_callback('render')           { |_c, json| on_render(json) }
      dlg.add_action_callback('cancel_render')    { |_c| stop_render; to_js('renderCancelled', {}) }
      dlg.add_action_callback('open_log')         { |_c| open_folder(WORK_DIR) }
      dlg.add_action_callback('log')              { |_c, m| rlog "[js] #{m}" }
      dlg.add_action_callback('save_settings')    { |_c, json| save_settings(json) }
      dlg.add_action_callback('download_models')  { |_c, which| start_download(which) }
      dlg.add_action_callback('cancel_download')  { |_c| Downloader.cancel(WORK_DIR) }
    end

    def on_ready
      rlog "\n===== dialog ready ====="
      client = ComfyClient.new
      online = client.online?
      rlog "  comfy online=#{online} base=#{client.base}"
      presets = Presets.all
      rlog "  presets day=#{presets[:day].size} night=#{presets[:night].size}"
      to_js('init', { presets: presets, comfy: { online: online, base: client.base }, aspect: @aspect,
                      settings: load_settings })
      UI.start_timer(0.8, false) { push_model_status } if online
      rlog '  init sent to dialog'
      UI.start_timer(0.35, false) { push_snapshot }   # 自动截一次当前相机视图
      start_view_watch   # 面板开着期间持续跟着相机刷新取景框预览，防止预览和实际渲染对不上
      # ComfyUI 没连上就每 4 秒自动重查一次，用户开着面板去启动 ComfyUI 也不用手动刷新
      unless online
        start_comfy_watch
        auto_launch_comfy
      end
    rescue StandardError => e
      rlog "on_ready ERROR: #{e.class}: #{e.message}\n#{Array(e.backtrace).first(10).join("\n")}"
      to_js('renderError', { message: "on_ready: #{e.class}: #{e.message}" })
    end

    def push_comfy_status
      client = ComfyClient.new
      online = client.online?
      rlog "recheck comfy: online=#{online}"
      to_js('comfy', { online: online, base: client.base })
      if online
        stop_comfy_watch
        push_model_status
      end
    rescue StandardError => e
      rlog "push_comfy_status ERROR: #{e.class}: #{e.message}"
    end

    def start_comfy_watch
      stop_comfy_watch
      @comfy_watch = UI.start_timer(4.0, true) { push_comfy_status }
    end

    def stop_comfy_watch
      UI.stop_timer(@comfy_watch) if @comfy_watch
      @comfy_watch = nil
    end

    # 面板里"取景框"预览用的截图只在用户点「刷新相机视图」或渲染前才会更新；
    # 真实踩过的坑——用户选完 16:9 后又在 SketchUp 里接着转/缩视角，预览没跟着动，
    # 取景框叠加层还是按旧相机画的，跟实际渲染出来的(永远是点渲染那一刻的相机)对不上，
    # 造成"预览说窗户/椅子在框里，出图却没有"。这里用一个轻量定时器比对相机指纹，
    # 变了才真的重截一次预览图，没变就什么也不做，避免每 tick 都截屏浪费。
    def start_view_watch
      stop_view_watch
      @view_watch = UI.start_timer(1.0, true) { push_snapshot_if_view_changed }
    end

    def stop_view_watch
      UI.stop_timer(@view_watch) if @view_watch
      @view_watch = nil
    end

    def cam_fingerprint
      c = view.camera
      [c.eye.to_a, c.direction.to_a, c.up.to_a, c.fov, c.aspect_ratio, view.vpwidth, view.vpheight]
    rescue StandardError
      nil
    end

    def push_snapshot_if_view_changed
      return if @render_thread&.alive?
      fp = cam_fingerprint
      return if fp.nil? || fp == @last_cam_fp
      @last_cam_fp = fp
      push_snapshot
    end

    # ComfyUI 没在跑就自动无窗口拉起来（带 --disable-cuda-graphs，见 comfy_headless.ps1 里的
    # RTX 5070 Ti 崩溃修复），不用每次都手动开 Comfy Desktop。每次重载/重启插件只自动尝试一次，
    # 脚本自己会先查一遍是不是已经在跑，重复调用是安全的。
    def auto_launch_comfy
      return if @comfy_launch_started
      @comfy_launch_started = true
      script = File.expand_path(File.join(__dir__, '..', '..', 'dev', 'comfy_headless.ps1'))
      unless File.exist?(script)
        rlog "auto_launch_comfy: script not found at #{script}"
        return
      end
      rlog '  ComfyUI offline, auto-launching headless…'
      log_path = File.join(WORK_DIR, 'comfy_autolaunch.log')
      pid = Process.spawn(
        'powershell', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', script,
        out: log_path, err: log_path
      )
      Process.detach(pid)
      rlog "  comfy_headless.ps1 spawned pid=#{pid}, log=#{log_path}"
    rescue StandardError => e
      rlog "auto_launch_comfy ERROR: #{e.class}: #{e.message}"
    end

    def set_lang(l)
      @lang = %w[zh en ru kk].include?(l.to_s) ? l.to_s : 'zh'
      Sketchup.write_default('ars_render_studio', 'lang', @lang) rescue nil
      to_result_js('setLang', { lang: @lang })
    end

    def on_set_aspect(name, ratio)
      @aspect = name.to_s
      @aspect_ratio = ratio.to_f
      # 真实踩过的坑：以前这里会 CameraControl.set_aspect 锁 camera.aspect_ratio，
      # 结果不只是让 SketchUp 视口画出取景框那么简单——锁上之后 view.write_image
      # 用同样的目标宽高截出来的画面会明显比"不锁、直接传宽高"更"拉近"（实测 16:9/4:3
      # 都复现），这正是"选完比例出图却离谱紧贴床头"那个 bug 的真正根因（不是预览过期）。
      # 现在完全不锁实时相机：比例只存状态，真正影响画面比例的是 Capture.* 传给
      # write_image 的显式宽高，取景框预览也纯前端算(drawFrame())，不碰真实相机。
      # 好处是选比例这一下也不会再让 SketchUp 里正在操作的视角跟着"变焦"。
      to_js('aspect', { aspect: @aspect })
    end

    def push_snapshot
      return if @render_thread&.alive?
      @last_cam_fp = cam_fingerprint
      snap = Capture.snapshot(view)
      to_js('snapshot', {
        ok: !snap.nil?,
        data_uri: snap && snap[:uri],
        w: snap && snap[:w],
        h: snap && snap[:h]
      })
    rescue StandardError => e
      rlog "push_snapshot error: #{e.class} #{e.message}"
      to_js('snapshot', { ok: false })
    end

    def on_analyze
      rlog 'analyze click'
      ctx = ModelExtractor.extract(view)
      rlog "  analyze ok rays_hit=#{ctx[:rays_hit]} mats=#{(ctx[:visible_materials] || []).size}"
      to_js('analysis', ctx)
    rescue StandardError => e
      rlog "analyze ERROR: #{e.class}: #{e.message}\n#{Array(e.backtrace).first(10).join("\n")}"
      to_js('renderError', { message: "#{e.class}: #{e.message}" })
    end

    # ================= 渲染 =================

    def rlog(msg)
      line = "#{Time.now.strftime('%H:%M:%S')}  #{msg}"
      puts "[ARS] #{line}"
      begin
        File.open(RENDER_LOG, 'a:utf-8') { |f| f.puts line; f.flush }
      rescue StandardError => e
        puts "[ARS] rlog write failed: #{e.message}"
      end
    end

    def step(label, pct)
      to_js('renderProgress', { pct: pct, note: label })
      rlog "step: #{label}"
      yield
    rescue StandardError, ScriptError => e
      rlog "STEP FAILED [#{label}]: #{e.class}: #{e.message}\n#{Array(e.backtrace).first(8).join("\n")}"
      raise
    end

    # opts: { kind, mode, preset_key, user_prompt, ai_strength, resolution, shadows, seed }
    def on_render(json)
      if @render_thread&.alive?
        return to_js('renderError', { message: tr(:err_busy) })
      end
      rlog "\n===== render click ====="

      begin
        opts = JSON.parse(json, symbolize_names: true)
        @last_opts = opts
        @job = nil
        v = view
        strength = (opts[:ai_strength].nil? ? 25 : opts[:ai_strength].to_i)
        strength = 0 if strength < 0
        strength = 100 if strength > 100
        settings = load_settings
        rlog "opts: aspect=#{@aspect} res=#{opts[:resolution]} ai=#{strength} kind=#{opts[:kind]} preset=#{opts[:preset_key]}"
        on_render_flux(opts, v, strength, settings)
      rescue StandardError, ScriptError => e
        rlog "on_render ABORTED: #{e.class}: #{e.message}"
        to_js('renderError', { message: "#{e.message}\n\n" + tr(:err_seealso, e.class) })
      end
    end

    # ================= Flux 照片级管线 =================
    # 1. ModelExtractor 提取视角里每个物体的形状/位置/尺寸/颜色/材质 → GROUND TRUTH 提示词
    # 2. Flux.2 Klein：Image 1 = SketchUp 截图，Image 2/3 = 真实 3D 深度图/法线图，Image 4 = 风格参考图
    # 3. 结构吻合度检查（SketchUp 线稿 vs 成品边缘），偏了就换种子重出，最多 MAX_ATTEMPTS 张，留最好的
    # 4. 最好那张放大到目标分辨率（ESRGAN + lanczos）
    def on_render_flux(opts, v, strength, settings)
      client = ComfyClient.new
      step(tr(:s_connect), 0.03) { raise tr(:err_comfy, client.base) unless client.online? }
      res = step(tr(:s_probe), 0.04) { FluxBuilder.resolve(client) }
      log_model_folders(res) unless res[:ok]
      unless res[:ok]
        tip = (res[:downloads] || []).empty? ? '' : "\n\n→ 面板上「本地渲染引擎」下面有「一键下载」按钮。"
        raise "Flux 管线还缺东西（按下面补齐后再试）：\n\n" + res[:missing].join("\n") + tip
      end
      rlog "  models #{res[:models]}"

      ctx = step(tr(:s_extract), 0.06) { ModelExtractor.extract(v) }
      rlog "  rays_hit=#{ctx[:rays_hit]} mats=#{(ctx[:visible_materials] || []).size} objs=#{(ctx[:visible_objects] || []).size}"
      stamp = Time.now.strftime('%Y%m%d_%H%M%S')
      src = File.join(WORK_DIR, "source_#{stamp}.png")
      cap = step(tr(:s_capture), 0.08) { Capture.textured(v, src, shadows: opts[:shadows], aspect: @aspect) }
      rlog "  src #{File.size(src)} bytes #{cap[:w]}x#{cap[:h]}"
      @last_source_path = src

      # 深度图 + 法线图：真实 3D 模型射线采样（测速自适应，不会卡住 SketchUp）
      depth_path = File.join(WORK_DIR, "depth_#{stamp}.png")
      normal_path = File.join(WORK_DIR, "normal_#{stamp}.png")
      geo = (Capture.geometry_maps(v, depth_path, normal_path, aspect: @aspect) rescue { depth: nil, normal: nil })
      rlog "  geometry_maps depth=#{geo[:depth] ? 'ok' : 'skipped'} normal=#{geo[:normal] ? 'ok' : 'skipped'}"
      # 线稿只给结构吻合度检查用
      lines_path = File.join(WORK_DIR, "lines_#{stamp}.png")
      lin = (Capture.lines(v, lines_path, aspect: @aspect, clean: true) rescue nil)
      rlog "  lines #{lin ? "ok clean=#{lin[:clean]}" : 'skipped'}"

      images = step(tr(:s_upload), 0.10) do
        list = [client.stage_input(src)]
        list << client.stage_input(depth_path) if geo[:depth]
        list << client.stage_input(normal_path) if geo[:normal]
        list
      end
      ref_index = nil
      if opts[:ref_data_uri].to_s.start_with?('data:image')
        ext = opts[:ref_data_uri] =~ %r{\Adata:image/jpe?g} ? '.jpg' : '.png'
        ref_path = File.join(WORK_DIR, "ref_#{stamp}#{ext}")
        File.binwrite(ref_path, opts[:ref_data_uri].sub(%r{\Adata:image/[^;]+;base64,}, '').unpack1('m'))
        images << client.stage_input(ref_path)
        ref_index = images.size
      end

      vlm = client.node?('TextGenerate') && client.models('text_encoders').include?(FluxBuilder::VISION_CLIP) ? FluxBuilder::VISION_CLIP : nil
      preset_text = opts[:preset_key].to_s.empty? ? nil : Presets.text_for(opts[:mode], opts[:preset_key], opts[:kind])
      kind = opts[:kind] || 'exterior'
      prompt = FluxBuilder.render_prompt(kind: kind, ctx: ctx, strength: strength, preset: preset_text,
                                         user_prompt: opts[:user_prompt], has_depth: !geo[:depth].nil?,
                                         has_normal: !geo[:normal].nil?, reference_index: ref_index)
      File.write(File.join(WORK_DIR, 'last_prompt.txt'), prompt) rescue nil
      w, h = FluxBuilder.output_dims(Capture.aspect_value(v, @aspect), opts[:resolution])
      rlog "  vlm=#{vlm || 'off'} images=#{images.size} ref=#{ref_index || 'none'} target=#{w}x#{h} prompt=#{prompt.size}ch"

      @job = {
        stage: :attempt, attempts: 0, max: settings[:auto_retry] && lin ? MAX_ATTEMPTS : 1, best: nil,
        lines_path: lin ? lines_path : nil, user_seed: opts[:seed], w: w, h: h,
        build: lambda do |seed, tag|
          FluxBuilder.build_edit(images: images, models: res[:models], prompt_text: prompt, seed: seed, tag: tag,
                                 vlm: vlm, vlm_lead: FluxBuilder.vision_lead_in(kind))
        end
      }
      start_flux_attempt
    end

    def start_flux_attempt
      job = @job
      job[:attempts] += 1
      n = job[:attempts]
      seed = n == 1 && job[:user_seed].to_i.positive? ? job[:user_seed].to_i : rand(1..2_147_483_646)
      graph = job[:build].call(seed, "flux_a#{n}")
      File.write(File.join(WORK_DIR, 'last_graph.json'), JSON.pretty_generate(graph)) rescue nil
      pid = ComfyClient.new.queue(graph)
      rlog "  attempt #{n}/#{job[:max]} queued #{pid} seed=#{seed}"
      span = 0.7 / job[:max]
      a = 0.12 + span * (n - 1)
      run_job(phase: 'render', note: format(tr(:s_attempt), n, job[:max])) do |state|
        wait_and_fetch(pid) { |q| state[:pct] = a + q.to_f * span }
      end
    end

    # 主线程：一个任务结束后决定下一步。返回最终结果；返回 nil 表示已经提交了下一个任务。
    def flux_job_step(image)
      job = @job
      if job[:stage] == :attempt
        score = job[:lines_path] ? GeometryCheck.score_files(job[:lines_path], image[:local]) : nil
        image[:score] = score
        rlog "  attempt #{job[:attempts]} structure score=#{score ? score.round(3) : 'n/a'}"
        best = job[:best]
        job[:best] = image if best.nil? || (score && (best[:score].nil? || score > best[:score]))
        if score && score < GEOMETRY_PASS_SCORE && job[:attempts] < job[:max]
          to_js('renderProgress', { pct: 0.12, note: format(tr(:s_retry), (score * 100).round) })
          start_flux_attempt
        else
          start_flux_finish
        end
        return nil
      end
      image[:score] = job[:best][:score]
      @job = nil
      image
    end

    def start_flux_finish
      job = @job
      job[:stage] = :finish
      client = ComfyClient.new
      name = client.stage_input(job[:best][:local])
      esr = client.models('upscale_models').find { |f| f =~ /esrgan|4x/i }
      graph = FluxBuilder.build_upscale(input_filename: name, width: job[:w], height: job[:h], esrgan: esr)
      File.write(File.join(WORK_DIR, 'last_finish_graph.json'), JSON.pretty_generate(graph)) rescue nil
      pid = client.queue(graph)
      rlog "  upscale queued #{pid} #{job[:w]}x#{job[:h]} esrgan=#{esr || 'none'}"
      run_job(phase: 'render', note: tr(:s_upscale)) do |state|
        wait_and_fetch(pid) { |q| state[:pct] = 0.84 + q.to_f * 0.14 }
      end
    end

    # 后台线程跑一个任务（块里等 ComfyUI 出图并取回），结果交给轮询定时器。
    def run_job(phase:, note:, mode: nil)
      @render_state = { pct: 0.15, note: note, done: false, error: nil, image: nil, phase: phase, mode: mode }
      state = @render_state
      @render_thread = Thread.new do
        begin
          state[:image] = yield(state)
          state[:done] = true
        rescue StandardError => e
          state[:error] = "#{e.class}: #{e.message}"
          state[:done] = true
          rlog "JOB THREAD FAILED: #{e.class}: #{e.message}\n#{Array(e.backtrace).first(5).join("\n")}"
        end
      end
      start_poll_timer
    end

    # 等一个 ComfyUI 任务出图并取回 → { local:, comfy_path:, filename: }
    def wait_and_fetch(pid, &progress)
      client = ComfyClient.new
      started = Time.now
      begin
        images = client.wait(pid, timeout: 1800, &progress)
        final = images.find { |im| im['filename'].to_s.include?('_final') } || images.last
        comfy_path = client.output_path(final)
        filename = final['filename']
      rescue StandardError => e
        rlog "wait() failed (#{e.class}: #{e.message}) — disk scan"
        comfy_path = client.newest_final_since(started)
        filename = comfy_path && File.basename(comfy_path)
        raise e unless comfy_path && File.exist?(comfy_path)
      end

      bytes = client.fetch({ 'filename' => filename, 'subfolder' => 'SU_AI_Render', 'type' => 'output' })
      out = File.join(WORK_DIR, "result_#{Time.now.strftime('%Y%m%d_%H%M%S')}_#{rand(1000)}.png")
      if bytes && bytes.bytesize > 200
        File.binwrite(out, bytes)
      elsif comfy_path && File.exist?(comfy_path)
        out = comfy_path
      else
        raise "取回渲染结果失败（#{comfy_path}）"
      end
      rlog "RESULT: #{out} (#{File.exist?(out) ? File.size(out) : 0} bytes)"
      { local: out, comfy_path: comfy_path, filename: filename }
    end

    def start_poll_timer
      stop_poll_timer
      @poll_timer = UI.start_timer(0.6, true) do
        st = @render_state
        next unless st

        if st[:done]
          stop_poll_timer
          # 管线里某一步失败了，但手里已经有能用的图 → 用它，不整单报错
          if st[:error] && st[:phase] == 'render' && @job && @job[:best]
            rlog "  job step failed (#{st[:error]}), continuing with best image so far"
            st[:error] = nil
            if @job[:stage] == :attempt
              begin
                start_flux_finish
                next
              rescue StandardError => e
                rlog "  finish could not start: #{e.message}"
              end
            end
            st[:image] = @job[:best]
            @job = nil
          end

          if st[:error]
            @job = nil if st[:phase] == 'render'
            to_js('renderError', { message: st[:error] })
            to_result_js('gradeError', { message: st[:error] }) if st[:phase] == 'grade'
          else
            if st[:phase] == 'render' && @job
              begin
                final = flux_job_step(st[:image])
              rescue StandardError => e
                rlog "flux_job_step ERROR: #{e.class}: #{e.message}"
                final = @job && @job[:best] ? @job[:best] : st[:image]
                @job = nil
              end
              next if final.nil? # 已经提交了下一个任务，@render_state 换成了新的
              st[:image] = final
            end
            @last_result = st[:image]
            if st[:phase] == 'grade'
              to_result_js('resultImage', result_payload)
            else
              to_js('renderDone', {})
              open_result_window
            end
          end
          @render_state = nil
        elsif st[:phase] == 'grade'
          to_result_js('gradeProgress', { pct: st[:pct], mode: st[:mode] })
        else
          to_js('renderProgress', { pct: st[:pct], note: st[:note] })
        end
      end
    end

    def stop_poll_timer
      UI.stop_timer(@poll_timer) if @poll_timer
      @poll_timer = nil
    end

    def stop_render
      stop_poll_timer
      @job = nil
      @render_thread.kill if @render_thread&.alive?
      @render_thread = nil
      @render_state = nil
    end

    # ================= 结果窗口 =================

    def open_result_window
      if @result_dialog&.visible?
        @result_dialog.bring_to_front
      else
        @result_dialog = UI::HtmlDialog.new(
          dialog_title: tr(:result_title),
          preferences_key: 'com.aydincreative.ai_render_studio.result',
          scrollable: true, resizable: true,
          width: 1100, height: 760, min_width: 640, min_height: 480,
          style: UI::HtmlDialog::STYLE_DIALOG
        )
        @result_dialog.set_file(dev_asset('result.html'))
        @result_dialog.add_action_callback('result_ready') { |_c| to_result_js('setLang', { lang: @lang }); to_result_js('resultImage', result_payload) }
        @result_dialog.add_action_callback('save_local')   { |_c| save_result_local }
        @result_dialog.add_action_callback('rerender')     { |_c| rerender_from_result }
        @result_dialog.add_action_callback('ai_grade')     { |_c, txt| ai_grade(txt) }
        @result_dialog.add_action_callback('enhance_upload') { |_c, data_uri, strength| enhance_upload(data_uri, strength) }
        @result_dialog.add_action_callback('open_folder')  { |_c| open_folder(File.dirname(@last_result[:comfy_path])) if @last_result }
        @result_dialog.set_on_closed { }
        @result_dialog.show
      end
    end

    def result_payload
      return { ok: false } unless @last_result && File.exist?(@last_result[:local])
      payload = {
        ok: true,
        data_uri: "data:image/png;base64,#{[File.binread(@last_result[:local])].pack('m0')}",
        filename: @last_result[:filename],
        score: @last_result[:score] && (@last_result[:score] * 100).round
      }
      if @last_source_path && File.exist?(@last_source_path)
        mime = %w[.jpg .jpeg].include?(File.extname(@last_source_path).downcase) ? 'image/jpeg' : 'image/png'
        payload[:before_data_uri] = "data:#{mime};base64,#{[File.binread(@last_source_path)].pack('m0')}"
      end
      payload
    end

    def save_result_local
      return unless @last_result && File.exist?(@last_result[:local])
      default = @last_result[:filename] || 'ai_render.png'
      path = UI.savepanel(tr(:save_title), ENV['USERPROFILE'] || Dir.home, default)
      return unless path
      path += '.png' unless path.downcase.end_with?('.png', '.jpg', '.jpeg')
      File.binwrite(path, File.binread(@last_result[:local]))
      to_result_js('saved', { path: path })
      rlog "saved to #{path}"
    rescue StandardError => e
      to_result_js('gradeError', { message: tr(:save_fail) + e.message })
    end

    def rerender_from_result
      return if @render_thread&.alive?
      opts = @last_opts.dup
      opts[:seed] = nil # 换个种子
      @result_dialog&.close
      @result_dialog = nil
      show_dialog
      UI.start_timer(0.5, false) { on_render(JSON.generate(opts)) }
    end

    # AI 调色 / 上传图片增强真实感：都用 Flux.2 Klein 图像编辑，Image 1 = 要处理的图。
    def ai_grade(instruction)
      return to_result_js('gradeError', { message: tr(:err_no_result) }) unless @last_result && File.exist?(@last_result[:local])
      return to_result_js('gradeError', { message: tr(:err_busy) }) if @render_thread&.alive?

      rlog "\n===== AI grade: #{instruction} ====="
      touchup(@last_result[:local], mode: 'grade', prompt: FluxBuilder.grade_prompt(instruction))
    end

    # 不需要已有渲染结果——随手拖一张别的渲染软件（Vray/Corona/Enscape/Lumion/D5…）出的图进来也能用。
    # 成品顶替 @last_result，上传的原图顶替 @last_source_path，保存/调色/滑动对比都照常复用。
    def enhance_upload(data_uri, strength)
      return to_result_js('gradeError', { message: tr(:err_busy) }) if @render_thread&.alive?
      rlog "\n===== enhance upload (strength=#{strength}) ====="
      raise '没有收到图片数据' unless data_uri.to_s.start_with?('data:image')
      ext = data_uri =~ %r{\Adata:image/jpe?g} ? '.jpg' : '.png'
      up_path = File.join(WORK_DIR, "upload_#{Time.now.strftime('%Y%m%d_%H%M%S')}#{ext}")
      File.binwrite(up_path, data_uri.sub(%r{\Adata:image/[^;]+;base64,}, '').unpack1('m'))
      @last_source_path = up_path
      touchup(up_path, mode: 'enhance', prompt: FluxBuilder.enhance_prompt(strength))
    rescue StandardError => e
      rlog "enhance_upload ABORTED: #{e.class}: #{e.message}"
      to_result_js('gradeError', { message: e.message })
    end

    def touchup(path, mode:, prompt:)
      client = ComfyClient.new
      raise tr(:err_comfy, client.base) unless client.online?
      res = FluxBuilder.resolve(client)
      raise "Flux 模型不齐：\n#{res[:missing].join("\n")}" unless res[:ok]

      # 输出尺寸 = 原图尺寸（8 的倍数，长边最多 3840）
      rep = Sketchup::ImageRep.new(path)
      k = [3840.0 / [rep.width, rep.height].max, 1.0].min
      w = (rep.width * k).round / 8 * 8
      h = (rep.height * k).round / 8 * 8
      name = client.stage_input(path)
      esr = client.models('upscale_models').find { |f| f =~ /esrgan|4x/i }
      graph = FluxBuilder.build_edit(images: [name], models: res[:models], prompt_text: prompt, seed: rand(1..2_147_483_646),
                                     tag: "#{mode}_final", final_size: [w, h], esrgan: esr)
      File.write(File.join(WORK_DIR, "last_#{mode}_graph.json"), JSON.pretty_generate(graph)) rescue nil
      pid = client.queue(graph)
      rlog "  #{mode} queued #{pid} #{w}x#{h}"
      to_result_js('gradeProgress', { pct: 0.1, mode: mode })
      run_job(phase: 'grade', mode: mode, note: mode) do |state|
        wait_and_fetch(pid) { |q| state[:pct] = 0.1 + q.to_f * 0.85 }
      end
    rescue StandardError => e
      rlog "#{mode} ABORTED: #{e.class}: #{e.message}"
      to_result_js('gradeError', { message: e.message })
    end

    # ================= 工具 =================

    def view
      Sketchup.active_model.active_view
    end

    def to_js(channel, payload)
      return unless @dialog&.visible?
      @dialog.execute_script("window.ARS && window.ARS.fromRuby(#{JSON.generate(channel)}, #{JSON.generate(payload)});")
    end

    def to_result_js(channel, payload)
      return unless @result_dialog&.visible?
      @result_dialog.execute_script("window.ARS && window.ARS.fromRuby(#{JSON.generate(channel)}, #{JSON.generate(payload)});")
    end

    def open_folder(path)
      UI.openURL("file:///#{path.to_s.tr('\\', '/')}") unless path.nil?
    end

    # SketchUp 内置浏览器加载本地 <script src> 外部文件时，执行顺序不像普通浏览器那样可靠
    # （i18n.js 有时会晚于 dialog.js 执行完，导致 dialog.js 读 window.ARSi18n 时报
    # "Cannot read properties of undefined (reading 't')"），且会缓存本地 js/css 文件。
    # 干脆把引用的 .js/.css 内容直接内联进 html，彻底消除加载顺序和缓存的不确定性。
    def dev_asset(html_name)
      dir = File.join(__dir__, 'html')
      html = File.read(File.join(dir, html_name), encoding: 'utf-8')
      html = html.gsub(/<script src="([a-zA-Z0-9_.\-]+\.js)"><\/script>/) do
        %(<script>\n#{File.read(File.join(dir, Regexp.last_match(1)), encoding: 'utf-8')}\n</script>)
      end
      html = html.gsub(/<link rel="stylesheet" href="([a-zA-Z0-9_.\-]+\.css)">/) do
        %(<style>\n#{File.read(File.join(dir, Regexp.last_match(1)), encoding: 'utf-8')}\n</style>)
      end
      # 文件名固定的话 SketchUp 内置浏览器可能按 URL 缓存整个页面，内容变了也不重新读；
      # 每次用带时间戳的新文件名，逼它当成一个从没见过的全新页面加载。
      Dir.glob(File.join(dir, "_dev_#{html_name.sub(/\.html\z/, '')}_*.html")).each { |f| File.delete(f) rescue nil }
      out = File.join(dir, "_dev_#{html_name.sub(/\.html\z/, '')}_#{Time.now.to_i}#{Time.now.usec}.html")
      # 没有 BOM 时 CEF 对本地 file:// 页面的编码嗅探不可靠，中/俄/哈文本里的多字节序列
      # 可能被当成别的编码解析，偶然拼出类似 "</script>" 的字节导致内联脚本被提前截断
      # （i18n.js 的 kk/ru 文本刚好在 window.ARSi18n 赋值之前，一截断赋值就丢了）。
      # 显式写 BOM 让浏览器无歧义地按 UTF-8 解析。
      File.write(out, "﻿#{html}", encoding: 'utf-8')
      out
    end

    # ================= 菜单 / 工具栏 =================

    unless defined?(@ui_built) && @ui_built
      cmd = UI::Command.new(tr(:cmd_name)) { show_dialog }
      cmd.tooltip = 'AI 渲染工作室'
      cmd.status_bar_text = '打开 AI 超写实渲染面板'
      svg = File.join(__dir__, 'html', 'icon.svg')
      if File.exist?(svg)
        cmd.small_icon = svg
        cmd.large_icon = svg
      end
      toolbar = UI::Toolbar.new('AI 渲染工作室')
      toolbar.add_item(cmd)
      toolbar.restore

      menu = UI.menu('Plugins').add_submenu(tr(:cmd_tip))
      menu.add_item(tr(:menu_open)) { show_dialog }
      menu.add_item(tr(:menu_reload)) { reload_dev }
      menu.add_item(tr(:menu_log)) { open_folder(WORK_DIR) }
      @ui_built = true
    end

    def reload_dev
      begin
        @dialog&.close
        @result_dialog&.close
      rescue StandardError
        nil
      end
      %w[presets model_extractor capture comfy_client geometry_check downloader flux_builder main].each do |f|
        load File.join(__dir__, "#{f}.rb")
      end
      UI.messagebox(tr(:reloaded))
    rescue StandardError => e
      UI.messagebox(tr(:reload_fail) + "#{e.class} #{e.message}")
    end
  end
end
