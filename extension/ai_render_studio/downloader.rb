# frozen_string_literal: true

require 'fileutils'

module AydinCreative
  module AiRenderStudio
    # 一键下载缺失的模型到 ComfyUI 对应的 models 子文件夹。
    #
    # 用 Windows 10+ 自带的 curl.exe 而不是 Ruby 的 Net::HTTP：
    #   - 断点续传(-C -)，几个 GB 的文件断了能接着下；
    #   - 走 Windows 自己的证书库，没有 SketchUp 内置 Ruby 常见的 SSL 证书问题；
    #   - 跟随 HuggingFace 的 CDN 重定向(-L)。
    # 连不上 huggingface.co 就自动换国内镜像 hf-mirror.com（路径完全一样）。
    # 目标文件夹问 ComfyUI 要(/internal/folder_paths)，所以装在哪个盘、用没用共享模型目录都对得上。
    # 全部在后台线程里跑；state 哈希由主线程的定时器读取、推给面板显示进度。
    module Downloader
      MIRROR = 'hf-mirror.com'

      module_function

      # items: [{ folder:, name:, url:, gb: }]
      def start(items, client, log_path)
        paths = client.folder_paths
        state = { active: true, done: false, error: nil, index: 0, count: items.size, file: nil,
                  part: nil, total: nil, pid: nil, host: nil, finished: [] }
        state[:thread] = Thread.new do
          begin
            host = reachable?('https://huggingface.co') ? 'huggingface.co' : MIRROR
            state[:host] = host
            items.each_with_index do |it, i|
              break if state[:cancel]
              dir = target_dir(paths, it[:folder])
              raise "ComfyUI 没有告诉我 #{it[:folder]} 文件夹在哪（/internal/folder_paths 为空）" unless dir
              dest = File.join(dir, it[:name])
              state[:index] = i + 1
              state[:file] = "#{it[:folder]}/#{it[:name]}"
              next state[:finished] << dest if File.exist?(dest)

              url = it[:url].sub('huggingface.co', host)
              part = "#{dest}.part"
              state[:part] = part
              state[:total] = head_size(url)
              ok = fetch(url, part, log_path, state)
              if !ok && host != MIRROR && !state[:cancel]
                url = it[:url].sub('huggingface.co', MIRROR)
                state[:host] = MIRROR
                ok = fetch(url, part, log_path, state)
              end
              break if state[:cancel]
              # 上次已经下完、只是没来得及改名时，续传会被服务器拒绝(416)，按大小判断就行
              ok ||= state[:total] && File.exist?(part) && File.size(part) == state[:total]
              raise "下载失败：#{it[:name]}（详见 #{log_path}）" unless ok
              if state[:total] && File.size(part) < state[:total]
                raise "下载不完整：#{it[:name]}（#{File.size(part)}/#{state[:total]} 字节），再点一次会接着下"
              end
              File.rename(part, dest)
              state[:finished] << dest
            end
          rescue StandardError => e
            state[:error] = e.message
          ensure
            state[:active] = false
            state[:done] = true
          end
        end
        state
      end

      def cancel(state)
        return unless state
        state[:cancel] = true
        pid = state[:pid]
        return unless pid
        begin
          Process.kill('KILL', pid)
        rescue StandardError
          nil
        end
      end

      # ComfyUI Desktop 常同时列出"默认 models 目录"和"共享 models 目录"(ComfyUI 两边都会扫)。
      # 放到你其它模型实际所在的那个 models 根目录下，哪怕这个子文件夹还不存在(比如从没用过
      # model_patches)——而不是列表里第一个可能根本没人用的路径。
      def target_dir(paths, folder)
        list = Array(paths[folder])
        return nil if list.empty?
        root = models_root(paths)
        dir = list.find { |d| File.dirname(d) == root } || list.find { |d| File.directory?(d) } ||
              list.find { |d| File.directory?(File.dirname(d)) } || list.first
        FileUtils.mkdir_p(dir)
        dir
      end

      # 哪个目录下面装着最多"非空的模型子文件夹" → 那就是真正在用的 models 根目录
      def models_root(paths)
        roots = Hash.new(0)
        paths.each_value do |dirs|
          Array(dirs).each do |d|
            next unless File.directory?(d) && !(Dir.children(d) rescue []).empty?
            roots[File.dirname(d)] += 1
          end
        end
        roots.max_by { |_r, n| n }&.first
      end

      def fetch(url, part, log_path, state)
        pid = Process.spawn('curl.exe', '-L', '--fail', '-C', '-', '--retry', '5', '--retry-delay', '3',
                            '--connect-timeout', '20', '-sS', '-o', part, url,
                            out: [log_path, 'a'], err: [log_path, 'a'])
        state[:pid] = pid
        _, status = Process.wait2(pid)
        state[:pid] = nil
        status.success?
      rescue Errno::ENOENT
        raise '系统里没有 curl.exe（Windows 10 1803 以上自带）。请按面板上的地址手动下载'
      end

      # 最终文件大小（跟随重定向后最后一个 content-length）
      def head_size(url)
        out = IO.popen(['curl.exe', '-sIL', '--max-time', '25', url], err: File::NULL, &:read).to_s
        sizes = out.scan(/^content-length:\s*(\d+)/i).flatten.map(&:to_i)
        linked = out[/^x-linked-size:\s*(\d+)/i, 1]
        (linked || sizes.last).to_i.positive? ? (linked || sizes.last).to_i : nil
      rescue StandardError
        nil
      end

      def reachable?(url)
        IO.popen(['curl.exe', '-sI', '--max-time', '8', '-o', File::NULL.to_s, '-w', '%{http_code}', url],
                 err: File::NULL, &:read).to_s.strip.to_i.between?(200, 399)
      rescue StandardError
        false
      end

      # 给面板的进度快照
      def snapshot(state)
        got = state[:part] && File.exist?(state[:part].to_s) ? File.size(state[:part]) : 0
        { active: state[:active], done: state[:done], error: state[:error], cancelled: state[:cancel] ? true : false, index: state[:index], count: state[:count],
          file: state[:file], host: state[:host], got_mb: (got / 1_048_576.0).round,
          total_mb: state[:total] ? (state[:total] / 1_048_576.0).round : nil }
      end
    end
  end
end
