# frozen_string_literal: true

module AydinCreative
  module MaterialPainter
    # 旋转/缩放/XY 方向移动，本质都是对每个面当前的 UV 坐标做一次 2D 仿射变换，
    # 再用 Face#position_material 把新的 (3D点, UV点) 对写回模型。
    #
    # 用 face.mesh(0) 而不是假设四边形：SketchUp 会自动把任意多边形（凹多边形/多于4边）
    # 三角化，position_material 每次只接受 3 个或 4 个点对，所以统一按三角形逐个提交最稳妥。
    module TextureTransform
      module_function

      # 记录选中面"编辑前"的几何 + 原始 UV，作为后续变换的基准（也用于"重置"）。
      def capture_state(faces)
        state = {}
        faces.each do |face|
          next unless face.valid?

          uvh = face.get_UVHelper(true, false)
          mesh = face.mesh(0)
          pts = (1..mesh.count_points).map { |i| mesh.point_at(i) }
          orig_uv = pts.map do |pt|
            uvq = uvh.get_front_UVQ(pt)
            q = uvq.z.zero? ? 1.0 : uvq.z
            [uvq.x / q, uvq.y / q]
          end
          polys = mesh.polygons.map { |poly| poly.map { |i| i.abs - 1 } }
          state[face.entityID] = { face: face, points: pts, orig_uv: orig_uv, polys: polys }
        end
        state
      end

      SHARED_MODES = %w[planar cylindrical].freeze

      # opts: mode('perface'|'planar'|'cylindrical'), angle_deg, scale_x, scale_y,
      #       offset_u, offset_v, shared_uv (仅 planar/cylindrical 模式需要，
      #       Projection.planar_uv_for_faces / cylindrical_uv_for_faces 的返回值)
      #
      # 关键点：贴图在面上是按"瓷砖"平铺的——UV 的 1.0 不是"这个面"的宽度，而是材质自己的
      # 物理平铺尺寸（Texture#width/#height），一个面可能横跨十几个瓷砖，UV 数值可以远大于 1。
      # 所以旋转/缩放的支点绝不能固定写死在 (0.5, 0.5)（那只是第一块瓷砖的中心），必须用
      # "这个面原本的 UV 中心"当支点——否则一转就把贴图整个甩飞到面外面去了（实测复现过一次）。
      # 平面投影/圆柱投影模式的支点则用整个选区共用的 UV 包围盒中心，让拼起来的一整片曲面
      # 当成一个整体转。
      def apply(state, material, opts)
        angle = opts[:angle_deg].to_f * Math::PI / 180.0
        cos_a = Math.cos(angle)
        sin_a = Math.sin(angle)
        sx = opts[:scale_x].to_f
        sy = opts[:scale_y].to_f
        ou = opts[:offset_u].to_f
        ov = opts[:offset_v].to_f
        shared = SHARED_MODES.include?(opts[:mode])
        shared_pivot = shared ? shared_pivot_of(state, opts[:shared_uv]) : nil

        state.each do |entity_id, data|
          face = data[:face]
          next unless face.valid?

          src_uv =
            if shared
              (0...data[:points].size).map { |i| opts[:shared_uv][[entity_id, i + 1]] || data[:orig_uv][i] }
            else
              data[:orig_uv]
            end
          cx, cy = shared_pivot || centroid(src_uv)
          new_uv = src_uv.map do |uv|
            dx = uv[0] - cx
            dy = uv[1] - cy
            rx = (dx * cos_a) - (dy * sin_a)
            ry = (dx * sin_a) + (dy * cos_a)
            [cx + (rx * sx) + ou, cy + (ry * sy) + ov]
          end
          data[:polys].each do |poly_idx|
            seq = []
            poly_idx.each { |i| seq.push(data[:points][i], new_uv[i]) }
            face.position_material(material, seq, true)
          end
        end
      end

      def centroid(uv_list)
        n = uv_list.size
        [uv_list.sum { |uv| uv[0] } / n, uv_list.sum { |uv| uv[1] } / n]
      end

      def reset(state, material)
        apply(state, material, mode: 'perface', angle_deg: 0, scale_x: 1, scale_y: 1, offset_u: 0, offset_v: 0)
      end

      # 平面投影/圆柱投影模式下，旋转/缩放围绕整个选区 UV 包围盒的中心转，而不是某一个面
      # 自己的中心，这样多面拼成的整片弯曲表面会当成一个整体来调，观感才是"转/缩一整片"
      # 而不是"每片各转各的"。
      def shared_pivot_of(state, shared_uv)
        xs = []
        ys = []
        state.each do |entity_id, data|
          (0...data[:points].size).each do |i|
            uv = shared_uv[[entity_id, i + 1]]
            next unless uv

            xs << uv[0]
            ys << uv[1]
          end
        end
        return [0.5, 0.5] if xs.empty?

        [(xs.min + xs.max) / 2.0, (ys.min + ys.max) / 2.0]
      end
    end
  end
end
