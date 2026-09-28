# frozen_string_literal: true

module AydinCreative
  module MaterialPainter
    # 吸管：激活后在 SketchUp 视口里点一个面，把它当前用的材质"吸"进材质工坊继续编辑。
    #
    # 用 PickHelper#leaf_at/#path_at 而不是 picked_face——实测 picked_face 在某些时机会
    # 返回 nil（怀疑跟 pick 缓存刷新时机有关），leaf_at(0) + 类型判断更可靠。
    # 拿到的 path 是从最外层群组/组件一路到那个面的完整路径：无论这个面藏在多少层
    # 群组/组件里面，都要先把 model.active_path 设成 path[0..-2] 真正"进入"那些层，
    # 再选中最后的面——这样效果才跟"双击进入群组再点面"一致，而不是选中了最外层的整个群组。
    class EyedropperTool
      def activate
        Sketchup.set_status_text('吸管：点一下模型里的任意一个面来吸取它的材质（Esc 取消）')
      end

      def onLButtonDown(_flags, x, y, view)
        ph = view.pick_helper
        ph.do_pick(x, y)
        # 点在共享边/顶点的像素上时，索引 0 经常是 Edge 不是 Face（实测确认过）；
        # 扫一遍所有命中结果找第一个 Face，跟 SketchUp 原生吸管点边缘附近也能选中面的手感一致。
        index = (0...ph.count).find { |i| ph.leaf_at(i).is_a?(Sketchup::Face) }
        if index.nil?
          UI.beep
          return
        end
        path = ph.path_at(index) || [ph.leaf_at(index)]
        view.model.select_tool(nil)
        MaterialPainter.eyedropper_picked(path)
      end

      def onCancel(_reason, view)
        view.model.select_tool(nil)
      end

      def onKeyDown(key, _repeat, _flags, view)
        view.model.select_tool(nil) if key == VK_ESCAPE
      end

      def onRButtonDown(_flags, _x, _y, view)
        view.model.select_tool(nil)
      end

      def deactivate(view)
        Sketchup.set_status_text('')
        view.invalidate
      end
    end
  end
end
