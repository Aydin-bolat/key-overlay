# frozen_string_literal: true

module AydinCreative
  module AiRenderStudio
    # 从当前相机视角提取 3D 模型的"真实信息"，喂给 AI 写提示词的 VLM 阶段。
    #
    # 关键点（见 memory: comfyui-archviz-render-pipeline）：
    #   - 只提取"当前视锥内可见"的内容，用相机射线网格采样，不全量 dump。
    #   - 材质名 / 构件名是作者标注的 ground truth，比 VLM 看灰模图猜的准。
    #   - 命名质量差时（Material1 / Color_03 / 组#12）要标记，让下游回退到 VLM 描述。
    module ModelExtractor
      module_function

      # 射线采样网格密度（列 x 行）。重模型下 raytest 也可能很慢，
      # 所以再加一个总时间预算（TIME_BUDGET 秒）到点就停，用已采到的数据。
      RAY_COLS = 96
      RAY_ROWS = 60
      TIME_BUDGET = 6.0

      # 被视为"无意义/自动生成"的材质 & 构件名
      JUNK_NAME_RX = /\A(?:material|color|colour|材质|颜色|group|组|component|组件|instance|层|layer|tag|默认|default)?[\s_\-#]*\d*\z/i

      def extract(view)
        model = view.model
        t0 = Time.now

        hits = sample_rays(view)
        materials = tally_materials(hits)
        components = tally_components(hits)
        objects = cluster_objects(hits, view.vpwidth, view.vpheight)

        {
          schema: 'ai_render_studio.model_context/2',
          captured_at: Time.now.strftime('%Y-%m-%dT%H:%M:%S'),
          elapsed_ms: ((Time.now - t0) * 1000).round,
          rays_cast: RAY_COLS * RAY_ROWS,
          rays_hit: hits.length,
          model: model_metadata(model),
          camera: camera_metadata(view),
          sun: sun_metadata(model),
          visible_materials: materials,
          visible_components: components,
          visible_objects: objects,
          naming_quality: naming_quality(materials, components)
        }
      end

      # ---- 按具体实例聚类 --------------------------------------------------
      # 跟 tally_components 的区别：tally_components 按"名字"汇总（同名的两个实例
      # 会被合并成一条），这里按"具体是哪一个实例"聚类，各自算出屏幕位置/占比/远近，
      # 这样画面里的每个独立物体（哪怕离得很远、只占几个像素）都能被单独点名、
      # 单独标注位置，喂给 AI 当"这里确实有一个独立物体，形状/位置别弄丢"的锚点。
      def cluster_objects(hits, vpw, vph)
        groups = Hash.new do |h, k|
          h[k] = {
            name: nil, xs: [], ys: [], nearest: Float::INFINITY, farthest: 0.0, count: 0,
            wx: [], wy: [], wz: [], colors: Hash.new(0)
          }
        end
        hits.each do |hit|
          obj = hit[:object]
          # 没有 Group/ComponentInstance 包裹的散装几何体（比如随手画的、没编组的小物件）
          # 用它的材质名当聚类 key 兜底——否则这类物体会被 cluster_objects 完全漏掉，
          # 哪怕它在画面上清清楚楚（比如水槽里随手摆的几个橘子没编组）。
          key = obj ? obj[:id] : "mat:#{hit[:material] && hit[:material][:name]}"

          g = groups[key]
          g[:name] ||= (obj && obj[:name]) || (hit[:material] && hit[:material][:name])
          g[:xs] << hit[:x]
          g[:ys] << hit[:y]
          g[:nearest] = hit[:distance] if hit[:distance] < g[:nearest]
          g[:farthest] = hit[:distance] if hit[:distance] > g[:farthest]
          g[:count] += 1
          pt = hit[:point]
          if pt
            g[:wx] << pt.x
            g[:wy] << pt.y
            g[:wz] << pt.z
          end
          hex = hit[:material] && hit[:material][:color_hex]
          g[:colors][hex] += 1 if hex
        end

        total = hits.length.to_f
        groups.map do |_id, g|
          cx = g[:xs].sum / g[:xs].length.to_f
          cy = g[:ys].sum / g[:ys].length.to_f
          size = if g[:wx].length >= 2
                   {
                     w: to_m(g[:wx].max - g[:wx].min),
                     d: to_m(g[:wy].max - g[:wy].min),
                     h: to_m(g[:wz].max - g[:wz].min)
                   }
                 end
          ranked_colors = g[:colors].sort_by { |_hex, n| -n }
          dominant_hex = ranked_colors.first&.first
          # 一个"物体"(比如带沥水架的水槽)里经常混了好几种材质(金属架+橘子)，只报
          # 主色会把少数材质完全盖掉。这里不是简单取"第二多"或"RGB 距离最远"的颜色——
          # 深灰/浅灰/白这种同为无彩色的明暗变化太常见（多半只是同一种材质的光影），
          # 真正值得单独点名的是命中数够多、且**有彩度**（不是灰/白/黑）的颜色，
          # 这样才能把"橘子藏在灰色沥水架里"这种真正不同的材质揪出来，而不是被
          # "反光稍亮的金属"这种伪信号带偏。
          secondary = ranked_colors[1..].to_a
                                        .select { |_hex, n| n >= 6 && n >= g[:count] * 0.04 }
                                        .select { |hex, _n| saturation(hex) >= 40 }
                                        .max_by { |hex, _n| saturation(hex) }
          {
            name: g[:name],
            hit_count: g[:count],
            screen_fraction: total.zero? ? 0.0 : (g[:count] / total).round(3),
            screen_zone: zone_label(cx, cy, vpw, vph),
            nearest_m: g[:nearest].finite? ? to_m(g[:nearest]).round(1) : nil,
            farthest_m: to_m(g[:farthest]).round(1),
            size_m: size,
            color_hex: dominant_hex,
            color_name: dominant_hex && nearest_color_name(dominant_hex),
            secondary_color_name: secondary && nearest_color_name(secondary.first)
          }
          # 用绝对命中数当噪声门槛（不是占比）：小而扎堆的物体（比如水槽里几个橘子）
          # 命中数本来就少，用占比卡反而先把它们卡掉；只要有 3 条射线真的打中就算数。
        end.select { |o| o[:hit_count] >= 3 }
          .sort_by { |o| -o[:screen_fraction] }
          .first(10) # 列太多小物件反而会稀释提示词、拖累整体连贯性——只挑画面里最突出的十个
      end

      # 把十六进制颜色粗分成几个常见色系名字——小物体常常没命名，颜色是 AI 能不能猜对
      # 它是什么（比如"橙色圆球堆"更容易读成橘子）的关键线索之一。
      COLOR_NAMES = {
        '红色' => [255, 0, 0], '橙色' => [255, 140, 0], '黄色' => [255, 220, 0],
        '绿色' => [0, 150, 60], '青色' => [0, 180, 180], '蓝色' => [0, 90, 200],
        '紫色' => [140, 60, 200], '粉色' => [230, 130, 180], '棕色' => [120, 80, 50],
        '黑色' => [20, 20, 20], '白色' => [245, 245, 245], '灰色' => [130, 130, 130]
      }.freeze

      # 简单饱和度（0-255）：越接近灰/白/黑（无彩色）越低，越"鲜艳"越高。
      def saturation(hex)
        return 0 unless hex.is_a?(String) && hex.length == 7
        r, g, b = hex[1..2].to_i(16), hex[3..4].to_i(16), hex[5..6].to_i(16)
        [r, g, b].max - [r, g, b].min
      end

      def nearest_color_name(hex)
        return nil unless hex.is_a?(String) && hex.start_with?('#') && hex.length == 7
        r = hex[1..2].to_i(16); g = hex[3..4].to_i(16); b = hex[5..6].to_i(16)
        COLOR_NAMES.min_by { |_name, (cr, cg, cb)| (r - cr)**2 + (g - cg)**2 + (b - cb)**2 }&.first
      end

      # 把屏幕位置粗分成 3x3 九宫格，用方位词描述（AI 读文字用，不是给代码用的像素坐标）
      def zone_label(cx, cy, vpw, vph)
        col = (cx / vpw.to_f * 3).floor.clamp(0, 2)
        row = (cy / vph.to_f * 3).floor.clamp(0, 2)
        cols = %w[left center right]
        rows = %w[upper middle lower]
        "#{rows[row]}-#{cols[col]}"
      end

      # ---- 射线采样 -------------------------------------------------------------

      def sample_rays(view)
        vpw = view.vpwidth
        vph = view.vpheight
        model = view.model
        eye = view.camera.eye
        hits = []
        deadline = Time.now + TIME_BUDGET

        # 真实踩过的坑：raytest 单条耗时因模型复杂度差异极大(同代码换个模型能差 70 倍)，
        # 只在每"行"开头查一次超时的话，重模型上一整行(RAY_COLS 条)都卡在里面出不来，
        # 真实导致过 SketchUp 主线程卡死几分钟、被迫强制关闭。改成每条射线都查一次。
        catch(:rays_deadline) do
          RAY_ROWS.times do |r|
            y = ((r + 0.5) / RAY_ROWS * vph).to_i
            RAY_COLS.times do |c|
              throw :rays_deadline if Time.now > deadline

              x = ((c + 0.5) / RAY_COLS * vpw).to_i
              ray = view.pickray(x, y)
              next unless ray

              result = model.raytest(ray, true) # true = 遵循隐藏/图层可见性
              next unless result

              point, path = result
              next unless path && !path.empty?

              leaf = path.last
              next unless leaf.is_a?(Sketchup::Face)

              hits << {
                x: x, y: y,
                point: point,
                distance: eye.distance(point),
                material: resolve_material(leaf, path),
                component: resolve_component(path),
                object: resolve_top_object(path)
              }
            end
          end
        end

        hits
      end

      # path 里最外层（离 model.entities 最近）的 Group/ComponentInstance —— 代表
      # 建模时的"一个独立物体"（比如整个圆顶，而不是它内部某个窗框子构件），
      # 用来把射线按"具体实例"聚类，而不是按名字（同名构件的两个不同实例要能分开）。
      def resolve_top_object(path)
        path.each do |ent|
          next unless ent.is_a?(Sketchup::ComponentInstance) || ent.is_a?(Sketchup::Group)

          name = ent.name.to_s.strip
          name = ent.definition.name.to_s if name.empty? && ent.respond_to?(:definition) && ent.definition
          return { id: ent.entityID, name: name.empty? ? nil : name }
        end
        nil
      end

      # 面自身材质优先；否则向上找被"整体上色"的 group/instance 材质
      def resolve_material(face, path)
        mat = face.material
        unless mat
          path.reverse_each do |ent|
            if ent.respond_to?(:material) && ent.material
              mat = ent.material
              break
            end
          end
        end
        return nil unless mat

        tex = mat.texture
        {
          name: mat.display_name.to_s,
          color_hex: color_hex(mat.color),
          has_texture: !tex.nil?,
          texture_file: tex ? File.basename(tex.filename.to_s) : nil,
          texture_path: tex ? tex.filename.to_s : nil
        }
      end

      # path 里最靠近叶子的 ComponentInstance / Group 的名字
      def resolve_component(path)
        path.reverse_each do |ent|
          if ent.is_a?(Sketchup::ComponentInstance)
            name = ent.name.to_s.strip
            name = ent.definition.name.to_s if name.empty?
            return name unless name.empty?
          elsif ent.is_a?(Sketchup::Group)
            name = ent.name.to_s.strip
            return name unless name.empty?
          end
        end
        nil
      end

      # ---- 汇总 ---------------------------------------------------------------

      def tally_materials(hits)
        groups = Hash.new { |h, k| h[k] = { count: 0, nearest: Float::INFINITY, info: nil } }
        hits.each do |hit|
          m = hit[:material]
          key = m ? m[:name] : '(未上色 / 默认)'
          g = groups[key]
          g[:count] += 1
          g[:nearest] = hit[:distance] if hit[:distance] < g[:nearest]
          g[:info] ||= m
        end
        total = hits.length.to_f
        groups.map do |name, g|
          {
            name: name,
            screen_fraction: total.zero? ? 0.0 : (g[:count] / total).round(3),
            nearest_m: g[:nearest].finite? ? to_m(g[:nearest]).round(2) : nil,
            color_hex: g[:info] && g[:info][:color_hex],
            texture_file: g[:info] && g[:info][:texture_file],
            texture_path: g[:info] && g[:info][:texture_path]
          }
        end.sort_by { |m| -m[:screen_fraction] }
      end

      def tally_components(hits)
        counts = Hash.new(0)
        hits.each do |hit|
          name = hit[:component]
          counts[name] += 1 if name && !name.empty?
        end
        total = hits.length.to_f
        counts.sort_by { |_, c| -c }.first(25).map do |name, c|
          { name: name, screen_fraction: total.zero? ? 0.0 : (c / total).round(3) }
        end
      end

      # ---- 元数据 -----------------------------------------------------------

      def model_metadata(model)
        b = model.bounds
        {
          title: model.title.to_s,
          units: unit_label(model),
          bbox_m: {
            x: to_m(b.width).round(2),
            y: to_m(b.height).round(2),
            z: to_m(b.depth).round(2)
          },
          approx_storeys: [(to_m(b.depth) / 3.2).round, 1].max,
          material_defs: model.materials.count,
          component_defs: model.definitions.reject(&:image?).count
        }
      end

      def camera_metadata(view)
        cam = view.camera
        {
          perspective: cam.perspective?,
          fov_deg: cam.perspective? ? cam.fov.round(1) : nil,
          focal_length_mm: (cam.perspective? && cam.respond_to?(:focal_length) ? cam.focal_length.round : nil),
          eye_height_m: to_m(cam.eye.z).round(2),
          aspect_ratio: view.vpwidth.to_f.zero? ? nil : (view.vpwidth.to_f / view.vpheight).round(3),
          looking_direction: cardinal_direction(cam.direction)
        }
      end

      def sun_metadata(model)
        si = model.shadow_info
        dir = si['SunDirection'] # Vector3d，从太阳指向场景
        return { available: false } unless dir

        # 太阳位置 = -SunDirection
        sx, sy, sz = -dir.x, -dir.y, -dir.z
        elevation = Math.asin(sz.clamp(-1.0, 1.0)) * 180.0 / Math::PI
        azimuth = (Math.atan2(sx, sy) * 180.0 / Math::PI) % 360.0
        {
          available: true,
          shadows_on: si['DisplayShadows'],
          date_time: si['ShadowTime'].respond_to?(:strftime) ? si['ShadowTime'].strftime('%Y-%m-%d %H:%M') : si['ShadowTime'].to_s,
          city: si['City'].to_s,
          country: si['Country'].to_s,
          latitude: si['Latitude'],
          longitude: si['Longitude'],
          north_angle_deg: si['NorthAngle'],
          sun_elevation_deg: elevation.round(1),
          sun_azimuth_deg: azimuth.round(1),
          sun_description: describe_sun(elevation, azimuth)
        }
      end

      # ---- 命名质量判断 ----------------------------------------------------

      def naming_quality(materials, components)
        mat_names = materials.map { |m| m[:name] }.reject { |n| n.start_with?('(') }
        comp_names = components.map { |c| c[:name] }
        all = mat_names + comp_names
        return { verdict: 'unknown', note: '当前视角没有可用的命名信息，下游将完全依赖 VLM 看图描述。' } if all.empty?

        junk = all.count { |n| n =~ JUNK_NAME_RX }
        ratio = junk.to_f / all.length
        verdict =
          if ratio >= 0.6 then 'poor'
          elsif ratio >= 0.3 then 'mixed'
          else 'good'
          end
        note =
          case verdict
          when 'good'  then '模型命名良好，材质/构件名可直接作为 AI 提示词的事实依据。'
          when 'mixed' then '命名部分有效；有意义的名字会用作事实依据，其余回退到 VLM 描述。'
          else '命名多为自动生成（Material1 等），下游主要依赖 VLM 看图，仅用几何/尺寸/太阳数据作锚点。'
          end
        { verdict: verdict, junk_ratio: ratio.round(2), sample_names: all.first(8), note: note }
      end

      # ---- 小工具 ---------------------------------------------------------

      def to_m(inches)
        inches.to_f * 0.0254
      end

      def unit_label(model)
        opts = model.options['UnitsOptions']
        %w[英寸 英尺 毫米 厘米 米][opts['LengthUnit']] || '未知'
      rescue StandardError
        '未知'
      end

      def color_hex(color)
        return nil unless color
        format('#%02X%02X%02X', color.red, color.green, color.blue)
      end

      def cardinal_direction(vec)
        deg = (Math.atan2(vec.x, vec.y) * 180.0 / Math::PI) % 360.0
        dirs = %w[北 东北 东 东南 南 西南 西 西北]
        dirs[((deg + 22.5) / 45).floor % 8]
      end

      def describe_sun(elev, azi)
        return '太阳在地平线以下（夜晚 / 无直射阳光）' if elev <= 0
        h =
          if elev < 12 then '很低（日出/日落时分，长影）'
          elsif elev < 30 then '较低（清晨/傍晚，斜射暖光）'
          elsif elev < 55 then '中等（上午/下午）'
          else '很高（接近正午，短硬影）'
          end
        compass = %w[北 东北 东 东南 南 西南 西 西北][((azi + 22.5) / 45).floor % 8]
        "太阳高度角 #{elev.round}°（#{h}），方位在#{compass}侧"
      end
    end
  end
end
