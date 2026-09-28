# frozen_string_literal: true

require 'timeout'

module AydinCreative
  module AiRenderStudio
    # 视口截图。只有两处会截图：
    #   1) snapshot  —— 对话框里显示的"当前 SketchUp 相机视图"（用户点刷新时）
    #   2) textured  —— 渲染时按选定比例截一次结构图
    # 都是用户主动触发的单次调用，不再有任何"实时/导航中"截图。
    module Capture
      module_function

      ASPECTS = {
        '16:9' => 16.0 / 9.0, '9:16' => 9.0 / 16.0,
        '4:3'  => 4.0 / 3.0,  '3:4'  => 3.0 / 4.0
      }.freeze

      SNAPSHOT_LONG_EDGE = 1280
      SOURCE_LONG_EDGE   = 2048   # 截图 ≈2.4MP：Flux 按 2MP 出图，石膏线、拱形这种细线在截图里要有足够像素

      LOG_PATH = File.join(ENV['TEMP'] || Dir.tmpdir, 'ai_render_studio', 'render.log')

      def clog(msg)
        puts "[ARS] [capture] #{msg}"
        File.open(LOG_PATH, 'a:utf-8') { |f| f.puts "#{Time.now.strftime('%H:%M:%S')}  [capture] #{msg}"; f.flush }
      rescue StandardError
        nil
      end

      def aspect_value(view, aspect)
        return ASPECTS[aspect] if ASPECTS.key?(aspect)
        vw = view.vpwidth.to_f
        vh = view.vpheight.to_f
        vh <= 0 ? 1.5 : vw / vh
      end

      def dims_for(ar, long_edge)
        w, h =
          if ar >= 1.0
            [long_edge, [(long_edge / ar).round, 2].max]
          else
            [[(long_edge * ar).round, 2].max, long_edge]
          end
        [even(w), even(h)]
      end

      def even(n)
        n = n.to_i
        n.odd? ? n + 1 : n
      end

      def bad?(path)
        !File.exist?(path) || File.size(path) < 200
      end

      # ---- 边线图：把模型里每一条边（线脚/石膏线/绗缝/凹槽）都描出来 ----
      # 给 ControlNet 和结构吻合度检查用，锁住细节几何。默认不动 RenderMode（以前改它报过错），
      # 只是关纹理 + 打开所有边线 + 关阴影 —— 得到"带全部黑边的模型图"，Canny 能提取每一条。
      def lines(view, path, opts = {})
        model = view.model
        ro = model.rendering_options
        si = model.shadow_info
        ar = aspect_value(view, opts[:aspect] || 'window')
        w, h = dims_for(ar, SOURCE_LONG_EDGE)

        # clean: 真正的线稿——"消隐线"模式(RenderMode 1)：所有面画成白色、只剩黑色细线，
        # 跟材质颜色无关（黑衣柜不会变成一大块"边"）。给 Z-Image 的 ControlNet 用：
        # 反相后直接就是单像素白线，不用再过 Canny（Canny 会把每条黑线拆成两条平行边，
        # 9-28 实测成品每个棱边都出现黑色描边，像线稿上色的插画）。
        # RenderMode 设不上（老版本曾报错）就退回原来的"色块+黑线"，返回值里 clean: false。
        clean = opts[:clean] ? true : false
        keys = %w[Texture DisplayEdges DisplayProfiles DisplaySketchEdges DrawDepthQue
                  DisplayColorByLayer EdgeColorMode DisplayInstanceAxes DrawSilhouettes]
        keys += %w[RenderMode ForegroundColor BackgroundColor DrawHorizon DrawGround DisplayWatermarks] if clean
        saved = {}
        keys.each { |k| saved[k] = (ro[k] rescue nil) }
        saved_shadows = si['DisplayShadows']
        clean_ok = false

        begin
          set_ro(ro, 'Texture', false)
          set_ro(ro, 'DisplayColorByLayer', false)
          set_ro(ro, 'DisplayInstanceAxes', false)
          set_ro(ro, 'DisplayEdges', true)
          set_ro(ro, 'DisplayProfiles', true)
          set_ro(ro, 'DrawSilhouettes', true)
          set_ro(ro, 'DisplaySketchEdges', false)
          set_ro(ro, 'DrawDepthQue', false)
          set_ro(ro, 'EdgeColorMode', 0)       # 全黑边
          si['DisplayShadows'] = false
          if clean
            set_ro(ro, 'DisplayProfiles', false) # 轮廓粗线关掉，所有线一样细
            set_ro(ro, 'DrawSilhouettes', false)
            set_ro(ro, 'ForegroundColor', Sketchup::Color.new(0, 0, 0))
            set_ro(ro, 'BackgroundColor', Sketchup::Color.new(255, 255, 255))
            set_ro(ro, 'DrawHorizon', false)
            set_ro(ro, 'DrawGround', false)
            set_ro(ro, 'DisplayWatermarks', false)
            set_ro(ro, 'RenderMode', 1)
            clean_ok = (ro['RenderMode'].to_i == 1 rescue false)
            clog "lines: clean hidden-line mode #{clean_ok ? 'on' : 'NOT available, fallback to shaded+edges'}"
          end

          ok = timed(50, "lines #{w}x#{h}") { view.write_image(filename: path, width: w, height: h, antialias: true) }
          ok = timed(40, 'lines(wh)') { view.write_image(filename: path, width: w, height: h) } if !ok || bad?(path)
        ensure
          saved.each { |k, val| set_ro(ro, k, val) unless val.nil? }
          si['DisplayShadows'] = saved_shadows unless saved_shadows.nil?
          view.invalidate
        end

        return nil if bad?(path)
        clog "lines: ok #{File.size(path)} bytes"
        { path: path, w: w, h: h, clean: clean_ok }
      end

      def timed(sec, label)
        t0 = Time.now
        Timeout.timeout(sec) { yield }
        clog "#{label} ok in #{(Time.now - t0).round(2)}s"
        true
      rescue Timeout::Error
        clog "#{label} TIMEOUT after #{sec}s"
        false
      rescue StandardError => e
        clog "#{label} ERROR #{e.class}: #{e.message}"
        false
      end

      # ---- 对话框里的"当前相机视图" ----------------------------------
      # 按视口真实比例截一张，无抗锯齿。返回 { uri, w, h } 或 nil。
      def snapshot(view)
        ar = aspect_value(view, 'window')
        w, h = dims_for(ar, SNAPSHOT_LONG_EDGE)
        tmp = File.join(temp_dir, "ars_snap_#{Time.now.to_f}.jpg")

        ok = timed(15, 'snapshot') { view.write_image(filename: tmp, width: w, height: h, antialias: false) }
        ok = timed(15, 'snapshot(bare)') { view.write_image(tmp) } if !ok || bad?(tmp)
        return nil if bad?(tmp)

        data = File.binread(tmp)
        File.delete(tmp) rescue nil
        { uri: "data:image/jpeg;base64,#{[data].pack('m0')}", w: w, h: h }
      rescue StandardError => e
        clog "snapshot EXCEPTION #{e.class}: #{e.message}"
        nil
      end

      # ---- 对比用的"SketchUp 原图" -----------------------------------------
      # 完全按用户当前的 SketchUp 显示样式截（不改任何显示设置：边线、阴影、材质都跟视口一样），
      # 比例/尺寸跟渲染输入图一致。只给结果窗口的滑动对比条用——喂给 AI 的是下面 textured()
      # 那张关掉边线的图，那张不适合拿来对比（线脚/角线这类靠边线显示的细节在里面几乎看不见）。
      def as_is(view, path, opts = {})
        ar = aspect_value(view, opts[:aspect] || 'window')
        w, h = dims_for(ar, SOURCE_LONG_EDGE)
        ok = timed(60, "as_is #{w}x#{h}") { view.write_image(filename: path, width: w, height: h, antialias: true) }
        ok = timed(60, 'as_is(wh)') { view.write_image(filename: path, width: w, height: h) } if !ok || bad?(path)
        return nil if bad?(path)
        clog "as_is: ok #{File.size(path)} bytes"
        { path: path, w: w, h: h }
      end

      # ---- 渲染的结构输入图 -----------------------------------------
      # 关掉黑色描边/轮廓线，打开材质，按选定比例截一次。
      # AI 会把 SketchUp 的黑线原样保留 → 出图很"CG"，所以截图前必须去掉。
      def textured(view, path, opts = {})
        model = view.model
        ro = model.rendering_options
        si = model.shadow_info
        ar = aspect_value(view, opts[:aspect] || 'window')
        w, h = dims_for(ar, SOURCE_LONG_EDGE)
        want_shadows = opts.fetch(:shadows, true) ? true : false

        keys = %w[DisplayEdges DisplayProfiles DrawDepthQue DisplaySketchEdges Texture
                  DisplayColorByLayer EdgeDisplayMode DisplayInstanceAxes]
        saved = {}
        keys.each { |k| saved[k] = ro[k] rescue nil }
        saved_shadows = si['DisplayShadows']
        # bright: 给 Z-Image 管线用——img2img 会继承截图的明暗，SketchUp 默认的暗面+阴影会让成品
        # 整体灰暗(实测)。截图时临时把面的明暗调亮、关掉 SketchUp 阴影，光照交给 AI 重新打。
        bright = opts[:bright] ? true : false
        saved_si = %w[Light Dark UseSunForAllShading].map { |k| [k, (si[k] rescue nil)] }.to_h if bright

        begin
          set_ro(ro, 'DisplayEdges', false)
          set_ro(ro, 'DisplayProfiles', false)
          set_ro(ro, 'DisplaySketchEdges', false)
          set_ro(ro, 'DrawDepthQue', false)
          set_ro(ro, 'DisplayColorByLayer', false)
          set_ro(ro, 'DisplayInstanceAxes', false)
          set_ro(ro, 'Texture', true)
          set_ro(ro, 'EdgeDisplayMode', 0)
          si['DisplayShadows'] = want_shadows
          if bright
            si['DisplayShadows'] = false
            set_ro(si, 'UseSunForAllShading', false)
            # 接近 SketchUp 默认(80/45)，只是略提暗面——9-28 实测 85/60 太平，成品像平涂插画
            set_ro(si, 'Light', 80)
            set_ro(si, 'Dark', 50)
          end

          ok = timed(60, "textured #{w}x#{h}") do
            view.write_image(filename: path, width: w, height: h, antialias: false)
          end
          ok = timed(60, 'textured(wh)') { view.write_image(filename: path, width: w, height: h) } if !ok || bad?(path)
          ok = timed(60, 'textured(bare)') { view.write_image(path) } if !ok || bad?(path)
        ensure
          saved.each { |k, val| set_ro(ro, k, val) unless val.nil? }
          si['DisplayShadows'] = saved_shadows unless saved_shadows.nil?
          saved_si&.each { |k, val| set_ro(si, k, val) unless val.nil? }
          view.invalidate
        end

        raise '截图失败：view.write_image 没有产出文件' if bad?(path)
        clog "textured: ok #{File.size(path)} bytes  (edges off)"
        { path: path, w: w, h: h }
      end

      # ---- 深度图 + 法线图：一遍射线采样，两张图都出 -----------------------
      # 深度：近=白、远=黑（没命中/背景=纯黑，当"无穷远"）。
      # 法线：相机空间编码（R=右, G=上, B=朝向相机），朝相机的平面大致是浅蓝紫色，
      # 是法线图最常见的视觉习惯，圆顶/坡地这类曲面靠它能明显减少被 AI 改形状。
      # 两张都是喂给 Flux.2 Klein 当额外参考图用的空间线索，不是视觉效果图，分辨率
      # 不用很高——后面 ImageScaleToTotalPixels 还会再缩放一次。
      # 用 Sketchup::ImageRep#set_data 直接从像素字节生成 PNG，不依赖任何外部库。
      #
      # 真实踩过的坑：raytest 每条射线的耗时因模型复杂度差异极大——同一份代码在一个模型上
      # 每条 ~0.06ms，换一个重一点的模型能到 ~4ms（70 倍差距）。固定分辨率(=固定射线数)
      # 在重模型上会让 SketchUp 主线程卡死几分钟（真实复现过一次，被迫强制关闭 SketchUp）。
      # 所以先拿一小撮射线校准这台机器/这个模型的真实速度，据此决定用多大的采样网格；
      # 正式采样时也是每条射线都检查一次截止时间（不是每行才查一次），保证绝不会失控。
      # 9-28：深度图从"软参考图"变成了 ControlNet 硬约束的输入之一，分辨率太粗(实测
      # 48x32 这种)会让吊灯这类细节丢形状——原来 240 长边上限是给"软提示"够用的档位，
      # 现在得给够，时间预算和长边上限都调高(仍然是"先测速再定网格+每条射线查超时"，
      # 不会因为调大就有卡死风险)。
      GEOM_TIME_BUDGET = 8.0
      GEOM_MAX_LONG_EDGE = 400
      GEOM_MIN_LONG_EDGE = 48
      GEOM_CALIBRATION_RAYS = 12

      def geometry_maps(view, depth_path, normal_path, opts = {})
        model = view.model
        eye = view.camera.eye
        vpw = view.vpwidth
        vph = view.vpheight
        ar = aspect_value(view, opts[:aspect] || 'window')

        forward = view.camera.direction.normalize
        up_axis = view.camera.up.normalize
        right_axis = forward.cross(up_axis).normalize

        per_ray = calibrate_ray_cost(view, model)
        budget_rays = (GEOM_TIME_BUDGET / per_ray).floor
        long_edge = Math.sqrt(budget_rays * (ar >= 1.0 ? ar : 1.0 / ar)).round
        long_edge = long_edge.clamp(GEOM_MIN_LONG_EDGE, GEOM_MAX_LONG_EDGE)
        cols, rows = dims_for(ar, long_edge)
        clog "geometry_maps: calibrated #{(per_ray * 1000).round(3)}ms/ray -> grid #{cols}x#{rows}"

        deadline = Time.now + GEOM_TIME_BUDGET
        dists = Array.new(rows * cols)
        norms = Array.new(rows * cols)
        near = Float::INFINITY
        far = 0.0

        catch(:geom_deadline) do
          rows.times do |r|
            y = ((r + 0.5) / rows * vph).to_i
            cols.times do |c|
              throw :geom_deadline if Time.now > deadline

              x = ((c + 0.5) / cols * vpw).to_i
              ray = view.pickray(x, y)
              next unless ray

              result = model.raytest(ray, true)
              next unless result

              point, hit_path = result
              idx = r * cols + c
              d = eye.distance(point)
              dists[idx] = d
              near = d if d < near
              far = d if d > far

              leaf = hit_path.last
              next unless leaf.is_a?(Sketchup::Face)

              n = leaf.normal
              hit_path[0...-1].each { |ent| n = ent.transformation * n if ent.respond_to?(:transformation) }
              n = n.normalize
              norms[idx] = [n.dot(right_axis), n.dot(up_axis), -n.dot(forward)]
            end
          end
        end

        near = 0.0 if near.infinite?
        far = near + 1.0 if far <= near
        span = far - near

        depth_px = String.new(capacity: rows * cols * 3)
        normal_px = String.new(capacity: rows * cols * 3)
        (rows * cols).times do |i|
          d = dists[i]
          v = d ? (255 - ((d - near) / span * 255).clamp(0, 255).round) : 0
          depth_px << v.chr << v.chr << v.chr

          n = norms[i]
          if n
            normal_px << ((n[0] * 0.5 + 0.5) * 255).round.clamp(0, 255).chr
            normal_px << ((n[1] * 0.5 + 0.5) * 255).round.clamp(0, 255).chr
            normal_px << ((n[2] * 0.5 + 0.5) * 255).round.clamp(0, 255).chr
          else
            normal_px << 128.chr << 128.chr << 255.chr # 没命中：占位成"朝相机"的中性蓝
          end
        end

        di = Sketchup::ImageRep.new
        di.set_data(cols, rows, 24, 0, depth_px)
        di.save_file(depth_path)
        ni = Sketchup::ImageRep.new
        ni.set_data(cols, rows, 24, 0, normal_px)
        ni.save_file(normal_path)

        d_ok = !bad?(depth_path)
        n_ok = !bad?(normal_path)
        clog "geometry_maps: depth=#{d_ok} normal=#{n_ok} #{cols}x#{rows} near=#{near.round(2)}in far=#{far.round(2)}in"
        {
          depth: d_ok ? { path: depth_path, w: cols, h: rows } : nil,
          normal: n_ok ? { path: normal_path, w: cols, h: rows } : nil
        }
      rescue StandardError => e
        clog "geometry_maps EXCEPTION #{e.class}: #{e.message}"
        { depth: nil, normal: nil }
      end

      # 拿一小撮随机射线量一下这台机器/这个模型 raytest 的真实速度（每条射线的秒数），
      # 供 geometry_maps() 据此决定采样网格大小，不管模型多重都不会失控。
      def calibrate_ray_cost(view, model)
        vpw = view.vpwidth
        vph = view.vpheight
        t0 = Time.now
        GEOM_CALIBRATION_RAYS.times do
          ray = view.pickray(rand(vpw), rand(vph))
          ray && model.raytest(ray, true)
        end
        elapsed = Time.now - t0
        [elapsed / GEOM_CALIBRATION_RAYS, 0.00002].max
      end

      def set_ro(ro, key, val)
        ro[key] = val
      rescue StandardError
        nil
      end

      def temp_dir
        d = File.join(ENV['TEMP'] || Dir.tmpdir, 'ai_render_studio')
        Dir.mkdir(d) unless Dir.exist?(d)
        d
      end
    end
  end
end
