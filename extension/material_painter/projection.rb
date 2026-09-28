# frozen_string_literal: true

module AydinCreative
  module MaterialPainter
    # 给"弯曲/多面物体"（比如床品褶皱、沙发靠垫，由很多小面拼成）算一个共享的贴图平面。
    # 用最小二乘拟合出一张最贴合所有选中面顶点的平面，再把每个顶点投影到这张平面上、
    # 换算成以"一整张贴图"为单位的 UV 坐标——这样所有小面用的是同一套 UV 参考系，
    # 贴图能连续盖过去，不会因为面被拆得很碎而各画各的、接缝对不上。
    module Projection
      module_function

      # 返回 { [face.entityID, point_index] => [u, v] }，point_index 对应
      # TextureTransform.capture_state 里 face.mesh(0) 的 1-based 点序号。
      def planar_uv_for_faces(faces, tile_w, tile_h)
        pts3d = []
        faces.each { |f| f.vertices.each { |v| pts3d << v.position } }
        raise 'no points' if pts3d.empty?

        plane = Geom.fit_plane_to_points(pts3d)
        normal = Geom::Vector3d.new(plane[0], plane[1], plane[2])
        normal.normalize!
        ref = normal.parallel?(Z_AXIS) ? X_AXIS : Z_AXIS
        right = normal.cross(ref)
        right.normalize!
        up = right.cross(normal)
        up.normalize!
        origin = pts3d[0].project_to_plane(plane)

        tw = tile_w.zero? ? 1.0 : tile_w
        th = tile_h.zero? ? 1.0 : tile_h

        raw = {}
        faces.each do |face|
          mesh = face.mesh(0)
          (1..mesh.count_points).each do |i|
            pt = mesh.point_at(i)
            proj = pt.project_to_plane(plane)
            vec = proj - origin
            x = vec.dot(right)
            y = vec.dot(up)
            raw[[face.entityID, i]] = [x / tw, y / th]
          end
        end
        raw
      end

      # 给"完整/接近完整圆柱体侧面"用的投影——共享平面投影对这种形状会失败：侧面绕一圈
      # 360°，总有几块小面几乎是"侧对着"那张拟合出来的平面，投影下去整块面挤成一条线，
      # SketchUp 的 position_material 算不出有效映射，直接抛 ArgumentError（实测复现过）。
      # 圆柱投影不用平面，而是把每个点分解成"沿轴高度(v)"+"绕轴角度换算成弧长(u)"，
      # 侧面 360° 展开成一个矩形，跟卷纸筒展开是一个道理，数学上不会有退化的情况。
      def cylindrical_uv_for_faces(faces, tile_w, tile_h)
        raise 'no points' if faces.empty?

        not_cylinder_msg = "所选的面不像是圆柱侧面（数量太少，或法线方向不够丰富，拟合不出" \
                           '一条圆柱轴）——圆柱投影需要沿圆周分布的一整圈侧面，请改用「跟随' \
                           '每个面」或「共享平面投影」。'

        # 侧面各小面的法线都垂直于圆柱轴、绕轴呈放射状分布，正好都落在"垂直于轴"的
        # 那张平面里——对这些法线本身做一次最佳拟合平面，拟合出来的平面法线就是圆柱轴向。
        # fit_plane_to_points 至少需要 3 个点；只选中 1-2 个面（比如圆柱的上下两个圆盘）
        # 时点数不够，或者法线方向本身就共线/退化，SketchUp 会直接抛 ArgumentError——
        # 这里统一捕获，换成能看懂的提示。
        normal_pts = faces.map { |f| Geom::Point3d.new(f.normal.x, f.normal.y, f.normal.z) }
        begin
          raise ArgumentError if normal_pts.size < 3

          axis_plane = Geom.fit_plane_to_points(normal_pts)
        rescue ArgumentError
          raise not_cylinder_msg
        end
        axis = Geom::Vector3d.new(axis_plane[0], axis_plane[1], axis_plane[2])
        axis.normalize!

        # 真正的圆柱侧面法线应该都（近似）垂直于轴——如果选中的其实是顶/底这种平面
        # （法线几乎平行于拟合出来的"轴"），上面这套按角度展开的算法在数学上是退化的，
        # 算出来的 UV 没有意义（不会报错，但整片贴图会乱套）。这里提前挡住，报清楚的错误，
        # 而不是让用户拿到一个看起来能用、实际是垃圾的结果。
        avg_perp = faces.sum { |f| f.normal.normalize.dot(axis).abs } / faces.size.to_f
        if avg_perp > 0.5
          raise not_cylinder_msg
        end

        pts3d = []
        faces.each { |f| f.vertices.each { |v| pts3d << v.position } }
        ox = pts3d.sum(&:x) / pts3d.size.to_f
        oy = pts3d.sum(&:y) / pts3d.size.to_f
        oz = pts3d.sum(&:z) / pts3d.size.to_f
        origin = Geom::Point3d.new(ox, oy, oz)

        ref = axis.parallel?(Z_AXIS) ? X_AXIS : Z_AXIS
        right = axis.cross(ref)
        right.normalize!
        up = axis.cross(right)
        up.normalize!

        radial_component = lambda do |vec|
          h = vec.dot(axis)
          [vec - Geom::Vector3d.new(axis.x * h, axis.y * h, axis.z * h), h]
        end

        # 整片选区共用一个平均半径来换算弧长，不用每个点自己的半径——避免网格本身的
        # 微小误差让相邻面的贴图缩放对不上（跟共享平面投影"整片共用一套坐标"是同一个考虑）。
        radii = pts3d.map { |p| radial_component.call(p - origin).first.length }
        avg_radius = radii.sum / radii.size.to_f
        avg_radius = 1.0 if avg_radius.zero?

        tw = tile_w.zero? ? 1.0 : tile_w
        th = tile_h.zero? ? 1.0 : tile_h

        raw = {}
        faces.each do |face|
          mesh = face.mesh(0)
          idxs = (1..mesh.count_points).to_a
          angles = {}
          heights = {}
          idxs.each do |i|
            radial, h = radial_component.call(mesh.point_at(i) - origin)
            angles[i] = Math.atan2(radial.dot(up), radial.dot(right))
            heights[i] = h
          end
          # 用这个面第一个点的角度当基准，把其它点的角度解卷绕到同一圈里——不然正好
          # 卡在 -180°/180° 接缝上的那一块面会被撕裂成两半（角度差一圈但数值上差 360°）。
          ref_angle = angles[idxs.first]
          idxs.each do |i|
            a = angles[i]
            a -= (2 * Math::PI) while a - ref_angle > Math::PI
            a += (2 * Math::PI) while a - ref_angle < -Math::PI
            raw[[face.entityID, i]] = [(a * avg_radius) / tw, heights[i] / th]
          end
        end
        raw
      end
    end
  end
end
