# frozen_string_literal: true

module AydinCreative
  module AiRenderStudio
    # 结构吻合度检查：AI 出图后，拿它的边缘跟 SketchUp 从真实 3D 模型渲出的线稿(Capture.lines)对比，
    # 算"模型里的棱边有多少在照片里还在原位"。云端模型没有 ControlNet 那种数学硬约束，
    # 这是它的兜底——分数低于阈值就自动换种子重出，最后保留分数最高的一张，并把分数显示给用户。
    #
    # 算法（全部纯 Ruby，只用 Sketchup::ImageRep 读像素，无外部库）：
    #   1. 两张图都缩到同一个小网格(长边 192)：线稿用"最小值池化"(1px 细黑线不会被平均掉)，
    #      照片用均值池化(顺便当模糊，压掉木纹/织物这种细纹理)；
    #   2. Sobel 求边缘强度；线稿用固定阈值，照片用自适应阈值(前 20% 最强边)；
    #   3. 照片边缘膨胀 2 格(≈1% 画宽的容差)，统计线稿边缘被覆盖的比例 = recall；
    #   4. 扣掉"随机也能碰上"的部分：score = (recall - 覆盖率) / (1 - 覆盖率)。
    #      照片边缘越密，随机碰上的越多，这一步防止"满屏纹理"骗高分。
    # 分数只用来比较/兜底，不是精确的几何误差。
    module GeometryCheck
      GRID_LONG = 192
      REF_THRESHOLD = 40.0     # 线稿：黑线 vs 白底/色块，边缘非常干脆
      RES_PERCENTILE = 0.80
      RES_MIN_THRESHOLD = 10.0
      DILATE = 2
      MIN_REF_EDGES = 40

      module_function

      # 返回 0.0-1.0，或者 nil(读不了图 / 线稿几乎是空的，没法判断)
      def score_files(lines_path, result_path)
        return nil unless lines_path && result_path && File.exist?(lines_path) && File.exist?(result_path)
        ref = load_gray(lines_path, :min)
        return nil unless ref
        gw, gh = ref[:w], ref[:h]
        res = load_gray(result_path, :mean, gw, gh)
        return nil unless res
        score(ref[:g], res[:g], gw, gh)
      rescue StandardError => e
        warn "[ARS] geometry check failed: #{e.class}: #{e.message}"
        nil
      end

      # ---- 读图 → 网格灰度 --------------------------------------------------
      # mode :min  逐像素全覆盖取最小亮度（线稿）
      # mode :mean 每格采 3x3 个点取平均（照片，可能是 4K，不能逐像素）
      def load_gray(path, mode, gw = nil, gh = nil)
        rep = Sketchup::ImageRep.new(path)
        w = rep.width
        h = rep.height
        return nil if w.to_i < 8 || h.to_i < 8

        if gw.nil?
          if w >= h
            gw = GRID_LONG
            gh = [(GRID_LONG * h.to_f / w).round, 8].max
          else
            gh = GRID_LONG
            gw = [(GRID_LONG * w.to_f / h).round, 8].max
          end
        end

        bpp = rep.bits_per_pixel / 8
        stride = w * bpp + rep.row_padding.to_i
        data = rep.data
        row_bytes = w * bpp

        g = mode == :min ? Array.new(gw * gh, 255.0) : Array.new(gw * gh, 0.0)
        cnt = mode == :min ? nil : Array.new(gw * gh, 0)

        rows =
          if mode == :min
            (0...h).to_a
          else
            (0...gh).flat_map { |cy| [0.17, 0.5, 0.83].map { |f| (((cy + f) * h) / gh).floor.clamp(0, h - 1) } }.uniq
          end
        cols_mean = (0...gw).flat_map { |cx| [0.17, 0.5, 0.83].map { |f| (((cx + f) * w) / gw).floor.clamp(0, w - 1) } }.uniq

        rows.each do |y|
          line = data.byteslice(y * stride, row_bytes).unpack('C*')
          cy = (y * gh / h).clamp(0, gh - 1)
          base = cy * gw
          if mode == :min
            x = 0
            while x < w
              o = x * bpp
              lum = (line[o] + line[o + 1] + line[o + 2]) / 3.0
              i = base + (x * gw / w)
              g[i] = lum if lum < g[i]
              x += 1
            end
          else
            cols_mean.each do |xx|
              o = xx * bpp
              i = base + (xx * gw / w).clamp(0, gw - 1)
              g[i] += (line[o] + line[o + 1] + line[o + 2]) / 3.0
              cnt[i] += 1
            end
          end
        end
        if cnt
          g.each_index { |i| g[i] = cnt[i].positive? ? g[i] / cnt[i] : 0.0 }
        end
        { g: g, w: gw, h: gh }
      end

      # ---- 纯计算部分（不依赖 SketchUp，可单独测试）--------------------------
      def score(ref_gray, res_gray, w, h)
        rm = sobel(ref_gray, w, h)
        em = sobel(res_gray, w, h)
        ref_e = rm.map { |m| m > REF_THRESHOLD }
        n_ref = ref_e.count(true)
        return nil if n_ref < MIN_REF_EDGES

        thr = [percentile(em, RES_PERCENTILE), RES_MIN_THRESHOLD].max
        res_d = dilate(em.map { |m| m > thr }, w, h, DILATE)
        hit = 0
        ref_e.each_with_index { |e, i| hit += 1 if e && res_d[i] }
        recall = hit.to_f / n_ref
        chance = res_d.count(true).to_f / (w * h)
        return recall if chance >= 0.999
        ((recall - chance) / (1.0 - chance)).clamp(0.0, 1.0)
      end

      def sobel(g, w, h)
        out = Array.new(w * h, 0.0)
        (1...(h - 1)).each do |y|
          r0 = (y - 1) * w
          r1 = y * w
          r2 = (y + 1) * w
          (1...(w - 1)).each do |x|
            gx = (g[r0 + x + 1] + 2 * g[r1 + x + 1] + g[r2 + x + 1]) - (g[r0 + x - 1] + 2 * g[r1 + x - 1] + g[r2 + x - 1])
            gy = (g[r2 + x - 1] + 2 * g[r2 + x] + g[r2 + x + 1]) - (g[r0 + x - 1] + 2 * g[r0 + x] + g[r0 + x + 1])
            out[r1 + x] = Math.sqrt(gx * gx + gy * gy) / 4.0
          end
        end
        out
      end

      def percentile(arr, p)
        s = arr.sort
        s[((s.size - 1) * p).round]
      end

      # 方形膨胀（先横后竖，O(n·r)）
      def dilate(bits, w, h, r)
        tmp = Array.new(w * h, false)
        h.times do |y|
          row = y * w
          w.times do |x|
            next unless bits[row + x]
            ((x - r).clamp(0, w - 1)..(x + r).clamp(0, w - 1)).each { |xx| tmp[row + xx] = true }
          end
        end
        out = Array.new(w * h, false)
        h.times do |y|
          w.times do |x|
            next unless tmp[y * w + x]
            ((y - r).clamp(0, h - 1)..(y + r).clamp(0, h - 1)).each { |yy| out[yy * w + x] = true }
          end
        end
        out
      end
    end
  end
end
