# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

module AydinCreative
  module MaterialPainter
    # 画布 <-> 磁盘贴图文件 之间的桥。
    module ImageBridge
      module_function

      def work_dir
        dir = File.join(ENV['TEMP'] || Dir.tmpdir, 'material_painter')
        FileUtils.mkdir_p(dir) unless Dir.exist?(dir)
        dir
      end

      # 导出材质"当前实际在用"的像素数据（不是它最初导入时的原图——用 image_rep 拿到的是
      # SketchUp 内部真正渲染用的那份数据，哪怕原始文件已经被移动/删除也不受影响）。
      # 返回 nil 表示这个材质没有贴图（纯色材质）。
      def export_current(material)
        tex = material.texture
        return nil unless tex

        path = File.join(work_dir, "src_#{material.entityID}_#{Time.now.to_i}#{Time.now.usec}.png")
        tex.image_rep.save_file(path)
        {
          path: path,
          image_width: tex.image_width,
          image_height: tex.image_height,
          tile_w: tex.width,
          tile_h: tex.height
        }
      end

      # 建议一个默认保存目录，给 UI.savepanel 当起始位置用——优先"上次保存到的目录"，
      # 其次"这张贴图原始文件所在目录"，都不存在（比如原图在一个现在没插上的移动盘/网络盘，
      # 这是实测踩到的真实情况：原图路径是 P:\...，那个盘当时没连，直接覆盖原图会因为
      # 目录都建不出来而失败）就退回插件自己的工作目录，保证 savepanel 总有个能打开的起点。
      # fallback_dir：调用方可以传一个"更早、更可信"的原始目录快照——比如画笔的实时预览
      # 会不断把 material.texture 指向临时文件，这时 material.texture.filename 已经不是
      # 真正的原始路径了，直接读它会建议错目录。
      def suggest_save_dir(material, fallback_dir = nil)
        last = Sketchup.read_default('material_painter', 'last_save_dir', '')
        return last if !last.to_s.empty? && Dir.exist?(last)
        return fallback_dir if fallback_dir && !fallback_dir.empty? && Dir.exist?(fallback_dir)

        orig = (material.texture&.filename).to_s
        orig_dir = orig.empty? ? nil : File.dirname(orig)
        return orig_dir if orig_dir && Dir.exist?(orig_dir)

        work_dir
      end

      # 把网页画布导出的 PNG 字节写到用户指定的路径，并让材质重新指向它。
      def write_and_apply(material, path, png_bytes)
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, 'wb') { |f| f.write(png_bytes) }
        material.texture = path
        Sketchup.write_default('material_painter', 'last_save_dir', File.dirname(path))
        path
      end
    end
  end
end
