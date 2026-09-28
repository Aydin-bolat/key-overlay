# frozen_string_literal: true

require 'json'
require 'sketchup.rb'

require File.join(__dir__, 'presets')
require File.join(__dir__, 'model_extractor')
require File.join(__dir__, 'capture')
require File.join(__dir__, 'comfy_client')
require File.join(__dir__, 'workflow_builder')
require File.join(__dir__, 'photo_builder')
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
    STAGE2_REFINE_STRENGTH = 100 # build_enhance 的强度(不暴露给用户)，映射到它的 denoise 上限 0.45——参考真实发布过的 archviz ComfyUI 工作流"材质精修遍"用的就是这个档位（0.30 那档是给"外部图/没有 ControlNet 兜底"场景留的保守值，这里结构已经在第一阶段被 ControlNet 锁死了，可以给够材质自由度）
    @last_opts = {}          # 上次渲染设置，供"重新渲染"用
    @last_result = nil       # { local:, comfy_path:, filename: }
    @job = nil               # Z-Image 管线的多次尝试/择优/放大状态，见 on_render_zimage
    @last_source_path = nil  # 当前结果对应的"渲染前"图（SketchUp 结构图，或"增强真实感"里用户上传的原图）——给结果窗口的滑动对比条用

    # ---- Ruby 侧界面文字（菜单 / 弹窗 / 保存对话框 / 错误）------------
    STRINGS = {
      'zh' => {
        s_probe: '检查本地模型…', s_attempt: 'Z-Image 照片级出图（第 %d/%d 张）…', s_retry: '结构吻合度 %d%%，换种子重出…', s_upscale: '高分辨率细化 + SeedVR2 精修放大…', s_resize: '高分辨率细化 + 放大（未安装 SeedVR2）…',
        s_extract: '提取模型信息…（大模型可能要几秒）', s_capture: '截取当前视角…', s_connect: '连接 ComfyUI…', s_upload: '上传结构图…', s_upref: '上传参考图…', s_build: '生成工作流…', s_submit: '提交到 ComfyUI…', s_detail: '细节锁：补回线脚/绗缝等细节…', s_processing: 'ComfyUI 处理中',
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
        s_probe: 'Checking local models…', s_attempt: 'Z-Image photoreal pass (%d/%d)…', s_retry: 'Structure match %d%%, re-rendering with a new seed…', s_upscale: 'High-res refine + SeedVR2 detail upscale…', s_resize: 'High-res refine + resize (SeedVR2 not installed)…',
        s_extract: 'Reading model info… (a few seconds on big models)', s_capture: 'Capturing the view…', s_connect: 'Connecting to ComfyUI…', s_upload: 'Uploading structure image…', s_upref: 'Uploading reference image…', s_build: 'Building workflow…', s_submit: 'Submitting to ComfyUI…', s_detail: 'Detail lock: restoring mouldings and seams…', s_processing: 'ComfyUI is working',
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
        s_probe: 'Проверка локальных моделей…', s_attempt: 'Z-Image фотореализм (%d/%d)…', s_retry: 'Совпадение структуры %d%%, повтор с новым seed…', s_upscale: 'SeedVR2 апскейл деталей…', s_resize: 'Масштабирование (SeedVR2 не установлен)…',
        s_extract: 'Чтение данных модели… (несколько секунд для больших)', s_capture: 'Снимок вида…', s_connect: 'Подключение к ComfyUI…', s_upload: 'Загрузка структурного изображения…', s_upref: 'Загрузка референса…', s_build: 'Сборка воркфлоу…', s_submit: 'Отправка в ComfyUI…', s_detail: 'Фиксация деталей: восстановление профилей и швов…', s_processing: 'ComfyUI обрабатывает',
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
        s_probe: 'Жергілікті модельдерді тексеру…', s_attempt: 'Z-Image фотошынайы рендер (%d/%d)…', s_retry: 'Құрылым сәйкестігі %d%%, жаңа seed-пен қайта…', s_upscale: 'SeedVR2 бөлшектерді үлкейту…', s_resize: 'Мақсатты өлшемге үлкейту (SeedVR2 жоқ)…',
        s_extract: 'Модель ақпаратын оқу… (үлкен модельдерде бірнеше секунд)', s_capture: 'Көріністі түсіру…', s_connect: 'ComfyUI-ге қосылу…', s_upload: 'Құрылым суретін жүктеу…', s_upref: 'Үлгі суретті жүктеу…', s_build: 'Воркфлоу құру…', s_submit: 'ComfyUI-ге жіберу…', s_detail: 'Бөлшек бекіту: профильдер мен тігістерді қалпына келтіру…', s_processing: 'ComfyUI жұмыс істеуде',
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

    # ================= 引擎设置 =================
    # engine: 'zimage'(默认，Z-Image Turbo + ControlNet + SeedVR2) | 'sdxl'(旧的 RealVisXL 管线)
    SETTINGS_SECTION = 'ars_render_studio'
    ENGINES = %w[zimage sdxl].freeze
    MAX_ATTEMPTS = 3            # 开"自动择优"时一次渲染最多出几张（本地出图不花钱，只花时间）
    GEOMETRY_PASS_SCORE = 0.55  # 结构吻合度低于这个就换种子重出（合成测试：对齐≈0.95，错位/丢物体≈0.3-0.4）

    def load_settings
      engine = (Sketchup.read_default(SETTINGS_SECTION, 'cfg_engine', 'zimage') rescue 'zimage').to_s
      retry_v = (Sketchup.read_default(SETTINGS_SECTION, 'cfg_auto_retry', true) rescue true)
      { engine: ENGINES.include?(engine) ? engine : 'zimage', auto_retry: retry_v == true || retry_v.to_s == 'true' }
    end

    def save_settings(json)
      data = JSON.parse(json.to_s)
      Sketchup.write_default(SETTINGS_SECTION, 'cfg_engine', data['engine'].to_s) if ENGINES.include?(data['engine'].to_s)
      Sketchup.write_default(SETTINGS_SECTION, 'cfg_auto_retry', data['auto_retry'] ? true : false) if data.key?('auto_retry')
      rlog "settings saved: #{load_settings}"
      to_js('settings', load_settings)
      push_model_status
    rescue StandardError => e
      rlog "save_settings ERROR: #{e.class}: #{e.message}"
    end

    # 告诉面板：Z-Image 管线需要的模型齐不齐、缺什么、SeedVR2 有没有
    def push_model_status
      client = ComfyClient.new
      return unless client.online?
      r = PhotoBuilder.resolve(client)
      rlog "  models ok=#{r[:ok]} seedvr=#{!r[:seedvr].nil?} #{r[:models]}"
      log_model_folders(r) unless r[:ok]
      @last_resolve = r
      dl = ->(list) { { count: list.size, gb: list.sum { |x| x[:gb].to_f }.round(1) } }
      to_js('models', { ok: r[:ok], missing: r[:missing], seedvr: !r[:seedvr].nil?, seedvr_hint: PhotoBuilder.seedvr_hint,
                        dl_required: dl.call(r[:downloads] || []), dl_seedvr: dl.call(r[:seedvr_downloads] || []),
                        downloading: Downloader.running?(WORK_DIR) })
      watch_download if Downloader.running?(WORK_DIR)
    rescue StandardError => e
      rlog "push_model_status ERROR: #{e.class}: #{e.message}"
    end

    # ---- 一键下载缺失模型 ----
    def start_download(which)
      return watch_download if Downloader.running?(WORK_DIR) # 已经在下（比如关了面板又打开）
      r = @last_resolve || PhotoBuilder.resolve(ComfyClient.new)
      items = Array(which.to_s == 'seedvr' ? r[:seedvr_downloads] : r[:downloads])
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
      rlog '  ---- Z-Image 模型检测没通过，ComfyUI 各文件夹实际内容：'
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
        rlog "opts: engine=#{settings[:engine]} aspect=#{@aspect} res=#{opts[:resolution]} ai=#{strength} kind=#{opts[:kind]} preset=#{opts[:preset_key]}"
        return on_render_zimage(opts, v, strength, settings) if settings[:engine] == 'zimage'

        ctx = step(tr(:s_extract), 0.04) { ModelExtractor.extract(v) }
        rlog "  rays_hit=#{ctx[:rays_hit]}  mats=#{(ctx[:visible_materials] || []).size}"

        stamp = Time.now.strftime('%Y%m%d_%H%M%S')
        src = File.join(WORK_DIR, "source_#{stamp}.png")
        cap = step(tr(:s_capture), 0.08) { Capture.textured(v, src, shadows: opts[:shadows], aspect: @aspect) }
        rlog "  src #{File.exist?(src) ? File.size(src) : 'MISSING'} bytes  #{cap[:w]}x#{cap[:h]}"
        @last_source_path = src   # 结果窗口滑动对比条的"渲染前"那一半

        # 深度图 + 边线图：9-28 换引擎之后这两个不再是可选的"结构约束"开关，而是新架构里
        # ControlNet 硬约束的输入，必须有——真正保证"不改变任何物体"的就是它们 + denoise，
        # 不再是文字层面的"请模型别改"。永远生成，不再看面板上的勾选状态。
        # 边线图是 SketchUp 真实几何边线（不是图像算法检测的 Canny），比从截图里检测的准。
        # raytest 测速自适应网格，绝不会拖慢/卡住 SketchUp。
        depth_path = File.join(WORK_DIR, "depth_#{stamp}.png")
        normal_path = File.join(WORK_DIR, "normal_#{stamp}.png") # 法线图新架构暂时用不上，仍顺带生成(同一遍射线)但不接进图里
        geo = (Capture.geometry_maps(v, depth_path, normal_path, aspect: @aspect) rescue { depth: nil, normal: nil })
        rlog "  geometry_maps depth=#{geo[:depth] ? 'ok' : 'skipped'}"

        lines_path = File.join(WORK_DIR, "lines_#{stamp}.png")
        lin = (Capture.lines(v, lines_path, aspect: @aspect) rescue nil)
        rlog "  lines #{lin ? "#{File.size(lines_path)}b" : 'skipped'}"

        preset_text = opts[:preset_key].to_s.empty? ? nil : Presets.text_for(opts[:mode], opts[:preset_key], opts[:kind])

        client = ComfyClient.new
        step(tr(:s_connect), 0.10) do
          raise tr(:err_comfy, client.base) unless client.online?
        end

        input_name = step(tr(:s_upload), 0.11) { client.stage_input(src) }
        depth_name = (geo[:depth] && File.exist?(depth_path)) ? (client.stage_input(depth_path) rescue nil) : nil
        canny_name = (lin && File.exist?(lines_path)) ? (client.stage_input(lines_path) rescue nil) : nil
        rlog "  staged depth=#{depth_name} canny=#{canny_name}"
        raise '深度图/边线图都没能生成——结构约束是新引擎的硬性前提，检查 render.log 里 capture 相关报错' if depth_name.nil? && canny_name.nil?

        # 新架构里参考图不再把像素喂给模型（SDXL 单文本编码器，没有多图输入能力），只当
        # "有没有提供参考图"这个文字层面的提示用，不需要真的上传/编码，省一次 I/O。
        has_ref = opts[:ref_data_uri].to_s.start_with?('data:image')
        rlog "  reference provided=#{has_ref} (text-only hint in this architecture)"

        graph = step(tr(:s_build), 0.12) do
          WorkflowBuilder.build(
            kind: opts[:kind] || 'exterior',
            input_filename: input_name,
            reference_filename: has_ref ? 'provided' : nil,
            depth_filename: depth_name,
            canny_filename: canny_name,
            model_context: ctx,
            preset_prompt: preset_text,
            user_prompt: opts[:user_prompt],
            ai_strength: opts[:ai_strength],
            aspect_ratio: Capture.aspect_value(v, @aspect),
            resolution: opts[:resolution],
            seed: opts[:seed]
          )
        end
        File.write(File.join(WORK_DIR, 'last_graph.json'), JSON.pretty_generate(graph)) rescue nil

        pid = step(tr(:s_submit), 0.13) { client.queue(graph) }
        rlog "  queued pid=#{pid}"
        # 两阶段：结构锁定(ControlNet，上面已提交) → 精修(build_enhance，无 ControlNet，
        # 专心把材质画细 + 顺便放大到目标分辨率)。拆成两遍是实测出来的：一遍到位既要锁死
        # 结构又要出好材质，实测容易画糊/画花；分两遍各司其职效果明显更好。
        # 第二阶段也带上深度/边线 ControlNet：以前这一遍完全不带约束、denoise 0.45，
        # 正是"第一遍锁住的结构，第二遍又被画走样"的原因之一。
        run_pipeline(pid, phase: 'render', detail: {
          strength: STAGE2_REFINE_STRENGTH,
          resolution: opts[:resolution],
          aspect_ratio: Capture.aspect_value(v, @aspect),
          depth_filename: depth_name,
          canny_filename: canny_name
        })
      rescue StandardError, ScriptError => e
        rlog "on_render ABORTED: #{e.class}: #{e.message}"
        to_js('renderError', { message: "#{e.message}\n\n" + tr(:err_seealso, e.class) })
      end
    end

    # ================= Z-Image 照片级管线 =================
    # 1. Z-Image Turbo + ControlNet(SketchUp 真实边线) + img2img(SketchUp 截图) 出一张
    # 2. GeometryCheck 拿线稿给它打"结构吻合度"，低于阈值就换种子重出，最多 MAX_ATTEMPTS 张
    # 3. 最高分那张交给 SeedVR2 精修放大到目标分辨率（没装 SeedVR2 就普通放大）
    # 每一步都是 ComfyUI 里一个独立任务：等待在后台线程，打分/决定下一步在主线程(轮询定时器)里。
    def on_render_zimage(opts, v, strength, settings)
      client = ComfyClient.new
      step(tr(:s_connect), 0.03) { raise tr(:err_comfy, client.base) unless client.online? }
      res = step(tr(:s_probe), 0.04) { PhotoBuilder.resolve(client) }
      log_model_folders(res) unless res[:ok]
      unless res[:ok]
        tip = (res[:downloads] || []).empty? ? '' : "\n\n→ 面板右上「本地渲染引擎」下面有「一键下载」按钮，点它会自动下载到 ComfyUI 正确的文件夹。"
        raise "Z-Image 管线还缺东西（按下面补齐后再试；或在面板里把引擎切回 RealVisXL）：\n\n" +
              res[:missing].join("\n") + tip
      end
      rlog "  models #{res[:models]} seedvr=#{res[:seedvr] || 'none'}"

      ctx = step(tr(:s_extract), 0.06) { ModelExtractor.extract(v) }
      stamp = Time.now.strftime('%Y%m%d_%H%M%S')
      src = File.join(WORK_DIR, "source_#{stamp}.png")
      # 调亮、关阴影截图：光照交给 AI 重新打（SketchUp 的暗面+阴影会让成品整体灰暗）
      cap = step(tr(:s_capture), 0.08) { Capture.textured(v, src, shadows: false, bright: true, aspect: @aspect) }
      rlog "  src #{File.size(src)} bytes #{cap[:w]}x#{cap[:h]} (bright, no shadows)"
      @last_source_path = src
      lines_path = File.join(WORK_DIR, "lines_#{stamp}.png")
      lin = Capture.lines(v, lines_path, aspect: @aspect, clean: true)
      raise '边线图生成失败——Z-Image 管线靠它锁结构，详见 render.log' unless lin
      rlog "  lines clean=#{lin[:clean]}"

      input_name, lines_name = step(tr(:s_upload), 0.10) { [client.stage_input(src), client.stage_input(lines_path)] }
      vlm = client.node?('TextGenerate') && client.models('text_encoders').include?(WorkflowBuilder::VISION_CLIP) ? WorkflowBuilder::VISION_CLIP : nil
      ref_name = nil
      if vlm && opts[:ref_data_uri].to_s.start_with?('data:image')
        ref_path = File.join(WORK_DIR, "ref_#{stamp}.png")
        File.binwrite(ref_path, opts[:ref_data_uri].sub(%r{\Adata:image/[^;]+;base64,}, '').unpack1('m'))
        ref_name = client.stage_input(ref_path)
      end
      preset_text = opts[:preset_key].to_s.empty? ? nil : Presets.text_for(opts[:mode], opts[:preset_key], opts[:kind])
      kind = opts[:kind] || 'exterior'
      prompt = PhotoBuilder.prompt(kind: kind, ctx: ctx, preset: preset_text, user_prompt: opts[:user_prompt])
      File.write(File.join(WORK_DIR, 'last_prompt.txt'), prompt) rescue nil
      w, h = PhotoBuilder.output_dims(Capture.aspect_value(v, @aspect), opts[:resolution])
      rlog "  vlm=#{vlm || 'off'} ref=#{ref_name || 'none'} target=#{w}x#{h} prompt=#{prompt.size}ch"

      @job = {
        stage: :attempt, attempts: 0, max: settings[:auto_retry] ? MAX_ATTEMPTS : 1, best: nil,
        lines_path: lines_path, user_seed: opts[:seed], seedvr: res[:seedvr], w: w, h: h,
        models: res[:models], prompt: prompt,
        build: lambda do |seed, tag|
          PhotoBuilder.build_structure(input_filename: input_name, lines_filename: lines_name, models: res[:models],
                                       prompt: prompt, strength: strength, seed: seed, tag: tag, vlm_model: vlm, kind: kind,
                                       reference_filename: ref_name, lines_clean: lin[:clean])
        end
      }
      start_zimage_attempt
    end

    def start_zimage_attempt
      job = @job
      job[:attempts] += 1
      n = job[:attempts]
      seed = n == 1 && job[:user_seed].to_i.positive? ? job[:user_seed].to_i : rand(1..2_147_483_646)
      graph = job[:build].call(seed, "a#{n}")
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
    def zimage_job_step(image)
      job = @job
      if job[:stage] == :attempt
        score = GeometryCheck.score_files(job[:lines_path], image[:local])
        image[:score] = score
        rlog "  attempt #{job[:attempts]} structure score=#{score ? score.round(3) : 'n/a'}"
        best = job[:best]
        job[:best] = image if best.nil? || (score && (best[:score].nil? || score > best[:score]))
        if score && score < GEOMETRY_PASS_SCORE && job[:attempts] < job[:max]
          to_js('renderProgress', { pct: 0.12, note: format(tr(:s_retry), (score * 100).round) })
          start_zimage_attempt
        else
          start_zimage_finish
        end
        return nil
      end
      image[:score] = job[:best][:score]
      @job = nil
      image
    end

    def start_zimage_finish
      job = @job
      job[:stage] = :finish
      client = ComfyClient.new
      name = client.stage_input(job[:best][:local])
      esr = client.models('upscale_models').find { |f| f =~ /esrgan|4x/i }
      graph = PhotoBuilder.build_finish(input_filename: name, models: job[:models], prompt: job[:prompt],
                                        width: job[:w], height: job[:h], seed: rand(1..2_147_483_646),
                                        seedvr: job[:seedvr], esrgan: esr)
      note = tr(job[:seedvr] ? :s_upscale : :s_resize)
      File.write(File.join(WORK_DIR, 'last_finish_graph.json'), JSON.pretty_generate(graph)) rescue nil
      pid = client.queue(graph)
      rlog "  finish queued #{pid} (refine + #{job[:seedvr] ? 'seedvr2' : 'resize'}) #{job[:w]}x#{job[:h]} esrgan=#{esr || 'none'}"
      run_job(phase: 'render', note: note) do |state|
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

    # 后台线程：等主渲染 → (可选) 细节锁第二遍 → 拿最终图。渲染 / 调色 / 真实感增强共用。
    def run_pipeline(pid, phase:, detail: nil, mode: nil)
      @render_state = { pct: 0.15, note: tr(:s_processing) + " (#{pid[0, 8]})…", done: false, error: nil, image: nil, phase: phase, mode: mode }
      @render_thread = Thread.new do
        begin
          res = wait_and_fetch(pid) { |q| @render_state[:pct] = 0.15 + q.to_f * (detail ? 0.52 : 0.82) }

          if detail
            @render_state[:note] = tr(:s_detail)
            @render_state[:pct] = 0.70
            base_name = ComfyClient.new.stage_input(res[:local])
            dg = WorkflowBuilder.build_enhance(
              input_filename: base_name, strength: detail[:strength],
              resolution: detail[:resolution], aspect_ratio: detail[:aspect_ratio],
              depth_filename: detail[:depth_filename], canny_filename: detail[:canny_filename]
            )
            File.write(File.join(WORK_DIR, 'last_detail_graph.json'), JSON.pretty_generate(dg)) rescue nil
            dpid = ComfyClient.new.queue(dg)
            rlog "  stage2 refine queued #{dpid}"
            res = wait_and_fetch(dpid) { |q| @render_state[:pct] = 0.72 + q.to_f * 0.25 }
          end

          @render_state[:image] = res
          @render_state[:done] = true
        rescue StandardError => e
          @render_state[:error] = "#{e.class}: #{e.message}"
          @render_state[:done] = true
          rlog "THREAD FAILED: #{e.class}: #{e.message}\n#{Array(e.backtrace).first(5).join("\n")}"
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
          # Z-Image 管线里某一步失败了，但手里已经有能用的图 → 用它，不整单报错
          if st[:error] && st[:phase] == 'render' && @job && @job[:best]
            rlog "  job step failed (#{st[:error]}), continuing with best image so far"
            st[:error] = nil
            if @job[:stage] == :attempt
              begin
                start_zimage_finish
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
                final = zimage_job_step(st[:image])
              rescue StandardError => e
                rlog "zimage_job_step ERROR: #{e.class}: #{e.message}"
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

    # AI 调色：拿现有结果图，走一遍低降噪 RealVisXL，带用户的调色指令
    def ai_grade(instruction)
      return to_result_js('gradeError', { message: tr(:err_no_result) }) unless @last_result && File.exist?(@last_result[:local])
      return to_result_js('gradeError', { message: '已有任务在进行中。' }) if @render_thread&.alive?

      rlog "\n===== AI grade: #{instruction} ====="
      begin
        client = ComfyClient.new
        raise tr(:err_comfy, client.base) unless client.online?
        input_name = client.stage_input(@last_result[:local])
        graph = WorkflowBuilder.build_grade(input_filename: input_name, instruction: instruction.to_s)
        File.write(File.join(WORK_DIR, 'last_grade_graph.json'), JSON.pretty_generate(graph)) rescue nil
        pid = client.queue(graph)
        rlog "  grade queued pid=#{pid}"
        to_result_js('gradeProgress', { pct: 0.1, mode: 'grade' })
        run_pipeline(pid, phase: 'grade', mode: 'grade')
      rescue StandardError => e
        rlog "ai_grade ABORTED: #{e.class}: #{e.message}"
        to_result_js('gradeError', { message: "#{e.message}" })
      end
    end

    # 真实感增强：跟 ai_grade 不一样的地方是它不需要已有渲染结果——用户随手拖一张
    # 别的渲染软件（Vray/Corona/Enscape/Lumion...）出的图进来也能用。走 RealVisXL
    # 低降噪 img2img（WorkflowBuilder.build_enhance），成品直接顶替 @last_result，
    # 上传的原图顶替 @last_source_path，这样保存/AI调色/滑动对比条都能照常复用。
    def enhance_upload(data_uri, strength)
      return to_result_js('gradeError', { message: tr(:err_busy) }) if @render_thread&.alive?
      rlog "\n===== enhance upload (strength=#{strength}) ====="
      begin
        raise '没有收到图片数据' unless data_uri.to_s.start_with?('data:image')
        client = ComfyClient.new
        raise tr(:err_comfy, client.base) unless client.online?

        b64 = data_uri.sub(/\Adata:image\/[^;]+;base64,/, '')
        stamp = Time.now.strftime('%Y%m%d_%H%M%S')
        up_path = File.join(WORK_DIR, "upload_#{stamp}.png")
        File.binwrite(up_path, b64.unpack1('m'))
        @last_source_path = up_path

        input_name = client.stage_input(up_path)
        graph = WorkflowBuilder.build_enhance(input_filename: input_name, strength: strength)
        File.write(File.join(WORK_DIR, 'last_enhance_graph.json'), JSON.pretty_generate(graph)) rescue nil
        pid = client.queue(graph)
        rlog "  enhance queued pid=#{pid}"
        to_result_js('gradeProgress', { pct: 0.1, mode: 'enhance' })
        run_pipeline(pid, phase: 'grade', mode: 'enhance')
      rescue StandardError => e
        rlog "enhance_upload ABORTED: #{e.class}: #{e.message}"
        to_result_js('gradeError', { message: e.message })
      end
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
      %w[presets model_extractor capture comfy_client workflow_builder main].each do |f|
        load File.join(__dir__, "#{f}.rb")
      end
      UI.messagebox(tr(:reloaded))
    rescue StandardError => e
      UI.messagebox(tr(:reload_fail) + "#{e.class} #{e.message}")
    end
  end
end
