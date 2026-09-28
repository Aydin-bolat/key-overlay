# frozen_string_literal: true

require 'json'
require 'base64'
require 'fileutils'
require 'sketchup.rb'

require File.join(__dir__, 'texture_transform')
require File.join(__dir__, 'projection')
require File.join(__dir__, 'image_bridge')
require File.join(__dir__, 'eyedropper_tool')

module AydinCreative
  module MaterialPainter
    WORK_DIR = ImageBridge.work_dir

    @dialog = nil
    @state = {}          # entityID => {face:, points:, orig_uv:, polys:}
    @faces = []
    @material = nil
    @last_sel_fp = nil
    @sel_watch = nil
    @planar_uv_cache = nil
    @planar_uv_key = nil
    @paint_uv_faces = {}   # entityID => Face，供 UV 参考线点选/框选(select_faces_for_edit)反查
    @paint_orig_dir = ''   # 载入画布那一刻材质原始文件所在目录，供保存对话框兜底建议

    module_function

    # ================= 面板 =================

    def show_dialog
      if @dialog&.visible?
        @dialog.bring_to_front
        return
      end
      @dialog = UI::HtmlDialog.new(
        dialog_title: '材质工坊',
        preferences_key: 'com.aydincreative.material_painter',
        scrollable: true, resizable: true,
        width: 480, height: 820, min_width: 420, min_height: 560,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      @dialog.set_file(dev_asset('panel.html'))
      register_callbacks(@dialog)
      @dialog.set_on_closed { stop_sel_watch }
      @dialog.show
      UI.start_timer(0.4, false) { on_ready }
    end

    def register_callbacks(dlg)
      dlg.add_action_callback('ready')           { |_c| on_ready }
      dlg.add_action_callback('import_texture')  { |_c| on_import_texture }
      dlg.add_action_callback('pick_material')   { |_c| on_pick_material }
      dlg.add_action_callback('apply_material')  { |_c| on_apply_material_to_selection }
      dlg.add_action_callback('apply_transform') { |_c, json| on_apply_transform(json) }
      dlg.add_action_callback('reset_transform') { |_c| on_reset_transform }
      dlg.add_action_callback('load_paint')      { |_c| on_load_paint }
      dlg.add_action_callback('save_paint')      { |_c, data_url| on_save_paint(data_url) }
      dlg.add_action_callback('live_preview')    { |_c, data_url| on_live_preview(data_url) }
      dlg.add_action_callback('select_faces_for_edit') { |_c, json| on_select_faces_for_edit(json) }
      dlg.add_action_callback('undo_model')      { |_c| on_undo_model }
      dlg.add_action_callback('open_log')        { |_c| open_folder(WORK_DIR) }
      dlg.add_action_callback('log')             { |_c, m| puts "[material_painter/js] #{m}" }
    end

    def on_ready
      to_js('onInit', {})
      sync_selection(force: true)
      start_sel_watch
    end

    # ================= 选区跟踪 =================
    # SketchUp 没有"选区变化"事件推送给 HtmlDialog，用轻量定时器比对一次选中面的
    # entityID 指纹；变了才重新抓取 UV 基准状态，避免每次都白白重算。

    def start_sel_watch
      stop_sel_watch
      @sel_watch = UI.start_timer(0.6, true) { sync_selection }
    end

    def stop_sel_watch
      UI.stop_timer(@sel_watch) if @sel_watch
      @sel_watch = nil
    end

    def sync_selection(force: false)
      return unless @dialog&.visible?

      model = Sketchup.active_model
      raw_faces = model.selection.grep(Sketchup::Face)
      fp = raw_faces.map(&:entityID).sort.join(',')
      return if !force && fp == @last_sel_fp

      @last_sel_fp = fp
      # 只有新选区自己带材质才切换 @material；选中的是裸面(还没材质)时保留当前正在编辑的材质，
      # 这样"导入贴图 -> 换个还没贴材质的选区 -> 应用当前材质到选中面"这个顺序才不会把刚导入的
      # 材质引用弄丢。
      inferred = raw_faces.first && (raw_faces.first.material || raw_faces.first.back_material)
      @material = inferred if inferred

      # 选区里材质跟 @material 不一样的面要先排除掉，不能直接把整个选区都当编辑对象——
      # "贴图变换"最终会对 @faces 里每个面调用 position_material(@material, ...)，如果
      # 选区里混了别的材质的面，这一步会把它们的材质也悄悄换成 @material（实测复现过：
      # 两个面分别是材质 A/B，一起选中后调一下旋转滑块，A 的面直接被换成材质 B）。
      # inferred 为空（整个选区都是裸面）时不过滤，交给上面的"应用当前材质到选中面"处理。
      faces = inferred ? raw_faces.select { |f| f.material == inferred || f.back_material == inferred } : raw_faces
      dropped = raw_faces.size - faces.size

      @faces = faces
      @state = TextureTransform.capture_state(faces)
      @planar_uv_cache = nil
      @planar_uv_key = nil

      to_js('onSelection', {
        count: faces.size,
        materialName: @material&.name,
        hasTexture: !!(@material&.texture),
        selectedIds: faces.map(&:entityID)
      })
      if dropped.positive?
        to_js('onInfo', {
          message: "选区里有 #{dropped} 个面材质不一样，已跳过——只编辑材质是「#{@material.name}」的 #{faces.size} 个面（想统一材质请先点「应用当前材质到选中面」）"
        })
      end
    end

    # ================= 导入贴图 =================

    def on_import_texture
      path = UI.openpanel('选择贴图图片', '', '图片文件|*.jpg;*.jpeg;*.png;*.bmp;*.tif;*.tiff||')
      return unless path

      model = Sketchup.active_model
      name = unique_material_name(model, File.basename(path, '.*'))
      material = model.materials.add(name)
      material.texture = path
      @material = material

      model.start_operation('导入贴图', true)
      @faces.each { |f| f.material = material if f.valid? }
      model.commit_operation

      @state = TextureTransform.capture_state(@faces)
      @planar_uv_cache = nil
      to_js('onSelection', { count: @faces.size, materialName: material.name, hasTexture: true, selectedIds: @faces.map(&:entityID) })
      to_js('onInfo', { message: "已导入「#{name}」并应用到 #{@faces.size} 个面" })
    rescue StandardError => e
      to_js('onError', { message: "导入失败：#{e.message}" })
    end

    def on_apply_material_to_selection
      return to_js('onError', { message: '还没有可用的材质，请先导入贴图。' }) unless @material
      return to_js('onError', { message: '请先在 SketchUp 里选中至少一个面。' }) if @faces.empty?

      model = Sketchup.active_model
      model.start_operation('应用材质', true)
      @faces.each { |f| f.material = @material if f.valid? }
      model.commit_operation
      @state = TextureTransform.capture_state(@faces)
      @planar_uv_cache = nil
      to_js('onInfo', { message: "已应用到 #{@faces.size} 个面" })
    rescue StandardError => e
      to_js('onError', { message: "应用失败：#{e.message}" })
    end

    # ================= 吸管 =================

    def on_pick_material
      Sketchup.active_model.select_tool(EyedropperTool.new)
    end

    # 吸管点中一个面后回调到这里。path 是 PickHelper#path_at 给的完整嵌套路径
    # (...group/component 实例, face)。
    def eyedropper_picked(path)
      face = path.last
      model = Sketchup.active_model
      model.active_path = path[0..-2]
      model.selection.clear
      model.selection.add(face)
      @dialog&.bring_to_front
      sync_selection(force: true)

      if @material
        to_js('onInfo', { message: "已吸取材质「#{@material.name}」" })
      else
        to_js('onError', { message: '这个面还没有材质。' })
      end
    rescue StandardError => e
      to_js('onError', { message: "吸取失败：#{e.message}" })
    end

    def unique_material_name(model, base)
      name = base
      n = 1
      while model.materials[name]
        n += 1
        name = "#{base}_#{n}"
      end
      name
    end

    # ================= 旋转 / 缩放 / XY 移动 =================

    def on_apply_transform(json)
      return to_js('onError', { message: '请先在 SketchUp 里选中至少一个面。' }) if @faces.empty?
      return to_js('onError', { message: '选中的面还没有贴图材质，请先导入贴图。' }) unless @material&.texture

      opts = JSON.parse(json, symbolize_names: true)
      opts[:angle_deg] = opts[:angle_deg].to_f
      opts[:scale_x]   = (opts[:scale_x].to_f / 100.0)
      opts[:scale_y]   = (opts[:scale_y].to_f / 100.0)
      opts[:offset_u]  = (opts[:offset_u].to_f / 100.0)
      opts[:offset_v]  = (opts[:offset_v].to_f / 100.0)

      if TextureTransform::SHARED_MODES.include?(opts[:mode])
        opts[:shared_uv] = shared_uv_for_current_selection(opts[:mode])
      end

      model = Sketchup.active_model
      model.start_operation('调整贴图', true)
      TextureTransform.apply(@state, @material, opts)
      model.commit_operation
      to_js('onInfo', { message: '已更新' })
    rescue StandardError => e
      Sketchup.active_model.abort_operation rescue nil
      to_js('onError', { message: "调整失败：#{e.class}: #{e.message}" })
    end

    def on_reset_transform
      return if @faces.empty? || @material.nil?

      model = Sketchup.active_model
      model.start_operation('重置贴图', true)
      TextureTransform.reset(@state, @material)
      model.commit_operation
      to_js('onInfo', { message: '已重置为选中时的原始贴图状态' })
    rescue StandardError => e
      Sketchup.active_model.abort_operation rescue nil
      to_js('onError', { message: "重置失败：#{e.message}" })
    end

    # 面板这个 HtmlDialog 是独立于 SketchUp 主窗口的 CEF 页面，Ctrl+Z 在它自己的网页里
    # 按下时不会自动转发给 SketchUp 的撤销栈——JS 那边接管了 Ctrl+Z，画布自己的画笔撤销
    # 用完了(或者根本没画什么，比如刚拖完手柄)就转过来调这个，直接撤销 SketchUp 模型里
    # 真正的上一步操作(材质位置/旋转缩放/应用材质等)。
    def on_undo_model
      Sketchup.undo
      to_js('onInfo', { message: '已撤销上一步' })
      on_load_paint if @material&.texture
    rescue StandardError => e
      to_js('onError', { message: "撤销失败：#{e.message}" })
    end

    def shared_uv_for_current_selection(mode)
      tex = @material.texture
      key = "#{mode}|#{@faces.map(&:entityID).sort.join(',')}|#{tex.width}|#{tex.height}"
      return @planar_uv_cache if @planar_uv_cache && @planar_uv_key == key

      uv =
        if mode == 'cylindrical'
          Projection.cylindrical_uv_for_faces(@faces, tex.width, tex.height)
        else
          Projection.planar_uv_for_faces(@faces, tex.width, tex.height)
        end
      @planar_uv_cache = uv
      @planar_uv_key = key
      uv
    end

    # ================= 画笔 =================

    UV_SCAN_TIME_BUDGET = 3.0
    UV_SCAN_MAX_FACES = 4000

    def on_load_paint
      return to_js('onError', { message: '当前材质没有贴图（是纯色材质），请先导入贴图。' }) unless @material&.texture

      # 存一份"这一刻"材质原始文件所在目录——之后实时预览(on_live_preview)会不断把
      # material.texture 指向临时文件，texture.filename 会被临时路径覆盖掉，保存对话框
      # 的默认目录建议得靠这份提前存好的快照，不然会变成建议临时文件夹。
      orig = (@material.texture&.filename).to_s
      @paint_orig_dir = orig.empty? ? '' : File.dirname(orig)

      info = ImageBridge.export_current(@material)
      return to_js('onError', { message: '读取贴图像素失败。' }) unless info

      bytes = File.binread(info[:path])
      data_url = "data:image/png;base64,#{Base64.strict_encode64(bytes)}"

      faces, timed_out = collect_faces_with_material(Sketchup.active_model, @material)
      @paint_uv_faces = faces.each_with_object({}) { |f, h| h[f.entityID] = f }
      uv_polys = faces.filter_map do |face|
        pts = face_uv_loop(face)
        pts && { id: face.entityID, pts: pts }
      end

      to_js('onPaintImage', {
        dataUrl: data_url,
        width: info[:image_width],
        height: info[:image_height],
        uvPolys: uv_polys,
        uvFaceCount: faces.size,
        uvTimedOut: timed_out
      })
    rescue StandardError => e
      to_js('onError', { message: "载入画布失败：#{e.message}" })
    end

    def face_uv_loop(face)
      return nil unless face.valid?

      uvh = face.get_UVHelper(true, false)
      face.outer_loop.vertices.map do |v|
        uvq = uvh.get_front_UVQ(v.position)
        q = uvq.z.zero? ? 1.0 : uvq.z
        [uvq.x / q, uvq.y / q]
      end
    end

    # UV 参考线上 Ctrl+点选/框选一个或多个面的轮廓 -> 把这些面设成贴图变换面板的编辑对象，
    # 之后旋转/缩放/移动只影响这几个面，互不牵连（Ayden 明确要的：不是选中材质就整个一起变）。
    def on_select_faces_for_edit(json)
      data = JSON.parse(json, symbolize_names: true)
      picked = Array(data[:ids]).filter_map { |id| @paint_uv_faces[id.to_i] }.select(&:valid?)
      return to_js('onError', { message: '找不到这些面了，试试重新载入画布。' }) if picked.empty?

      faces = data[:additive] ? (@faces + picked).uniq(&:entityID) : picked
      apply_uv_pick(faces)
      to_js('onInfo', { message: "已选中 #{faces.size} 个面，去「贴图变换」标签页调旋转/缩放/移动" })
    rescue StandardError => e
      to_js('onError', { message: "选取失败：#{e.message}" })
    end

    # 直接把 @faces/@state 设成挑好的这一批面，不经过 sync_selection 的"从真实选区反推"
    # 那条路——群选的这几个面很可能分散在不同群组/组件里，SketchUp 的选区本来就没法
    # 同时跨多个不同上下文选中，硬要求真实选区完全镜像这批面是不现实的。改成"尽量让
    # 真实选区靠拢"（try_select_in_sketchup，能选多少选多少），但插件内部认哪些面在编辑
    # 完全以 @faces 为准；同时把 @last_sel_fp 更新成"真实选区现在的样子"，这样后台的
    # 选区监视定时器下一次轮询会认为"没变化"，不会立刻把这次群选覆盖掉。
    def apply_uv_pick(faces)
      @faces = faces
      @state = TextureTransform.capture_state(faces)
      @planar_uv_cache = nil
      @planar_uv_key = nil
      inferred = faces.first && (faces.first.material || faces.first.back_material)
      @material = inferred if inferred
      try_select_in_sketchup(faces)
      @last_sel_fp = Sketchup.active_model.selection.grep(Sketchup::Face).map(&:entityID).sort.join(',')
      to_js('onSelection', { count: @faces.size, materialName: @material&.name, hasTexture: !!(@material&.texture), selectedIds: @faces.map(&:entityID) })
    end

    def try_select_in_sketchup(faces)
      return if faces.empty?

      model = Sketchup.active_model
      first_path = find_path_to_entity(model.entities, faces.first.entityID)
      return unless first_path

      model.active_path = first_path[0..-2]
      model.selection.clear
      faces.each do |f|
        model.selection.add(f)
      rescue StandardError
        nil
      end
      @dialog&.bring_to_front
    end

    # 跟 collect_faces_with_material 的遍历逻辑基本一样，区别是这次要保留完整路径
    # （进哪些群组/组件才能找到这个面），拿第一条命中的路径就返回——同一个组件定义
    # 可能被很多个实例引用，"这个面在模型里的位置"本来就不是唯一的，找到一个能选中的就行。
    def find_path_to_entity(entities, target_id, prefix = [])
      entities.each do |e|
        next unless e.respond_to?(:entityID)

        if e.entityID == target_id
          return prefix + [e]
        elsif e.is_a?(Sketchup::Group)
          found = find_path_to_entity(e.entities, target_id, prefix + [e])
          return found if found
        elsif e.is_a?(Sketchup::ComponentInstance)
          found = find_path_to_entity(e.definition.entities, target_id, prefix + [e])
          return found if found
        end
      end
      nil
    end

    # 每画完一笔，网页把当前画布内容推过来，直接写到一个临时文件再重新指给材质——
    # 让 SketchUp 里的模型立刻跟着变，方便边画边看效果；磁盘上"真正"的文件要等用户
    # 点「保存贴图到…」才会改，这里只是临时预览。
    def on_live_preview(data_url)
      return unless @material

      b64 = data_url.sub(/\Adata:image\/png;base64,/, '')
      bytes = Base64.decode64(b64)
      path = File.join(ImageBridge.work_dir, "live_#{@material.entityID}.png")
      File.open(path, 'wb') { |f| f.write(bytes) }
      @material.texture = path
    rescue StandardError => e
      to_js('onError', { message: "实时预览失败：#{e.message}" })
    end

    # 找模型里所有用到这个材质的面（不管选没选中、也不管藏在多少层群组/组件里面），
    # 好让画笔的 UV 参考线显示"这个材质在整个模型里都贴在哪"，而不是只显示当前选区。
    # 组件定义只扫一次（同一个定义的很多个实例共享同一份几何体和 UV，没必要重复扫），
    # 但仍然可能是个大模型——用"先测速再定规模"同一套教训：给绝对时间预算 + 面数上限，
    # 每访问一个实体都检查一次，超预算就提前收手返回目前扫到的结果，绝不会卡死主线程。
    def collect_faces_with_material(model, material)
      found = []
      seen = {}
      visited_defs = {}
      deadline = Time.now + UV_SCAN_TIME_BUDGET
      timed_out = false

      walk = lambda do |entities|
        entities.each do |e|
          if found.size >= UV_SCAN_MAX_FACES || Time.now > deadline
            timed_out = true
            break
          end
          case e
          when Sketchup::Face
            next if seen[e.entityID]

            if e.material == material || e.back_material == material
              seen[e.entityID] = true
              found << e
            end
          when Sketchup::Group
            walk.call(e.entities)
          when Sketchup::ComponentInstance
            d = e.definition
            next if visited_defs[d.entityID]

            visited_defs[d.entityID] = true
            walk.call(d.entities)
          end
          break if timed_out
        end
      end
      walk.call(model.entities)
      [found, timed_out]
    end

    def on_save_paint(data_url)
      return to_js('onError', { message: '没有可保存的材质。' }) unless @material

      dir = ImageBridge.suggest_save_dir(@material, @paint_orig_dir)
      default_name = @material.name.gsub(/[\\\/:*?"<>|]/, '_')
      path = UI.savepanel('保存贴图到…', dir, "#{default_name}.png")
      return unless path # 用户取消

      path = "#{path}.png" unless File.extname(path).casecmp('.png').zero?

      b64 = data_url.sub(/\Adata:image\/png;base64,/, '')
      bytes = Base64.decode64(b64)
      target = ImageBridge.write_and_apply(@material, path, bytes)
      to_js('onInfo', { message: "已保存：#{target}" })
    rescue StandardError => e
      to_js('onError', { message: "保存失败：#{e.message}" })
    end

    # ================= 工具函数 =================

    def to_js(name, payload)
      return unless @dialog

      @dialog.execute_script("window.MP && window.MP.#{name} && window.MP.#{name}(#{payload.to_json})")
    rescue StandardError
      nil
    end

    def open_folder(dir)
      if Sketchup.platform == :platform_win
        system("explorer.exe \"#{dir.tr('/', '\\')}\"")
      else
        UI.openURL("file://#{dir}")
      end
    end

    # SketchUp 内置浏览器加载本地 <script src>/<link> 顺序不完全可靠，且按文件名缓存整页；
    # 把引用的 js/css 内联进 html、文件名带时间戳，跟 ai_render_studio 项目同一个坑同一个修法。
    def dev_asset(html_name)
      dir = File.join(__dir__, 'html')
      html = File.read(File.join(dir, html_name), encoding: 'utf-8')
      html = html.gsub(/<script src="([a-zA-Z0-9_.\-]+\.js)"><\/script>/) do
        %(<script>\n#{File.read(File.join(dir, Regexp.last_match(1)), encoding: 'utf-8')}\n</script>)
      end
      html = html.gsub(/<link rel="stylesheet" href="([a-zA-Z0-9_.\-]+\.css)">/) do
        %(<style>\n#{File.read(File.join(dir, Regexp.last_match(1)), encoding: 'utf-8')}\n</style>)
      end
      Dir.glob(File.join(dir, "_dev_#{html_name.sub(/\.html\z/, '')}_*.html")).each do |f|
        File.delete(f)
      rescue StandardError
        nil
      end
      out = File.join(dir, "_dev_#{html_name.sub(/\.html\z/, '')}_#{Time.now.to_i}#{Time.now.usec}.html")
      File.write(out, "\uFEFF#{html}", encoding: 'utf-8')
      out
    end

    # ================= 菜单 / 工具栏 =================

    unless defined?(@ui_built) && @ui_built
      cmd = UI::Command.new('材质工坊') { show_dialog }
      cmd.tooltip = '材质工坊：贴图变换 + 画笔'
      cmd.status_bar_text = '打开材质工坊面板'
      svg = File.join(__dir__, 'html', 'icon.svg')
      if File.exist?(svg)
        cmd.small_icon = svg
        cmd.large_icon = svg
      end
      toolbar = UI::Toolbar.new('材质工坊')
      toolbar.add_item(cmd)
      toolbar.restore

      menu = UI.menu('Plugins').add_submenu('材质工坊')
      menu.add_item('打开材质工坊') { show_dialog }
      menu.add_item('重新加载插件（开发）') { reload_dev }
      menu.add_item('打开工作目录') { open_folder(WORK_DIR) }
      @ui_built = true
    end

    def reload_dev
      begin
        @dialog&.close
      rescue StandardError
        nil
      end
      %w[texture_transform projection image_bridge eyedropper_tool main].each do |f|
        load File.join(__dir__, "#{f}.rb")
      end
      UI.messagebox('材质工坊：已重新加载。请重新打开面板。')
    rescue StandardError => e
      UI.messagebox("重新加载失败：#{e.class} #{e.message}")
    end
  end
end
