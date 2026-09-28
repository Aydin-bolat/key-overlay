# frozen_string_literal: true

require 'net/http'
require 'json'
require 'securerandom'
require 'uri'

module AydinCreative
  module AiRenderStudio
    # 本地 ComfyUI HTTP 客户端。
    # 输入图直接拷贝到 ComfyUI-Shared/input（避免 multipart 上传），
    # 见 memory: comfyui-archviz-render-pipeline "How to run headless"。
    class ComfyClient
      DEFAULT_HOST = '127.0.0.1'
      DEFAULT_PORT = 8188
      INPUT_DIR    = 'F:/Comfy-Desktop/ComfyUI-Shared/input'
      OUTPUT_DIR   = 'F:/Comfy-Desktop/ComfyUI-Shared/output'

      attr_reader :host, :port, :client_id

      def initialize(host: DEFAULT_HOST, port: DEFAULT_PORT)
        @host = host
        @port = port
        @client_id = SecureRandom.uuid
      end

      def base
        "http://#{host}:#{port}"
      end

      # ComfyUI 是否在运行
      def online?
        res = get('/system_stats', timeout: 3)
        res.is_a?(Net::HTTPSuccess)
      rescue StandardError
        false
      end

      def stats
        res = get('/system_stats', timeout: 3)
        res.is_a?(Net::HTTPSuccess) ? JSON.parse(res.body) : nil
      rescue StandardError
        nil
      end

      # 这个 ComfyUI 里有没有某个节点（老版本 ComfyUI 可能还没有 SeedVR2 / Z-Image 控制节点）
      def node?(class_type)
        @node_cache ||= {}
        return @node_cache[class_type] if @node_cache.key?(class_type)
        res = get("/object_info/#{class_type}", timeout: 10)
        ok = res.is_a?(Net::HTTPSuccess) && JSON.parse(res.body).key?(class_type)
        @node_cache[class_type] = ok
      rescue StandardError
        false
      end

      # 某个模型文件夹里的文件列表（diffusion_models / text_encoders / vae / model_patches ...）
      def models(folder)
        @model_cache ||= {}
        return @model_cache[folder] if @model_cache.key?(folder)
        res = get("/models/#{folder}", timeout: 10)
        list = res.is_a?(Net::HTTPSuccess) ? Array(JSON.parse(res.body)) : []
        @model_cache[folder] = list
      rescue StandardError
        []
      end

      # 把本地图片放进 ComfyUI 输入目录，返回它在 LoadImage 里用的文件名
      def stage_input(local_path)
        raise "输入图不存在: #{local_path}" unless File.exist?(local_path)

        Dir.mkdir(INPUT_DIR) unless Dir.exist?(INPUT_DIR)
        name = "ars_#{Time.now.strftime('%Y%m%d_%H%M%S')}_#{SecureRandom.hex(3)}#{File.extname(local_path)}"
        dest = File.join(INPUT_DIR, name)
        File.binwrite(dest, File.binread(local_path))
        name
      end

      # 提交工作流图，返回 prompt_id
      def queue(graph)
        body = JSON.generate(prompt: graph, client_id: client_id)
        res = post('/prompt', body)
        unless res.is_a?(Net::HTTPSuccess)
          detail = begin
            JSON.parse(res.body)
          rescue StandardError
            res.body.to_s[0, 800]
          end
          raise "ComfyUI 拒绝了工作流 (HTTP #{res.code}): #{detail}"
        end
        JSON.parse(res.body)['prompt_id']
      end

      # 轮询直到出图。block 收到 0.0-1.0 进度（估算）。
      def wait(prompt_id, timeout: 900, poll: 2.0)
        deadline = Time.now + timeout
        loop do
          hist = history(prompt_id)
          if hist && hist[prompt_id]
            entry = hist[prompt_id]
            status = entry.dig('status', 'status_str')
            raise "ComfyUI 执行失败: #{extract_error(entry)}" if status == 'error'

            outs = entry['outputs']
            return collect_images(outs) if outs && !outs.empty?
          end

          # 队列位置 → 粗略进度
          if block_given?
            q = queue_state(prompt_id)
            yield q
          end

          raise '等待 ComfyUI 出图超时' if Time.now > deadline
          sleep poll
        end
      end

      # 取回成品字节。优先从本地共享输出目录直接读盘（ComfyUI 出图慢时
      # HTTP 端口可能几秒内拒接，读盘不受影响）；读不到再退回 HTTP。
      def fetch(image_ref)
        path = output_path(image_ref)
        20.times do
          return File.binread(path) if File.exist?(path) && File.size(path) > 200
          sleep 0.5
        end
        q = URI.encode_www_form(
          filename: image_ref['filename'],
          subfolder: image_ref['subfolder'].to_s,
          type: image_ref['type'] || 'output'
        )
        res = get("/view?#{q}", timeout: 60)
        res.is_a?(Net::HTTPSuccess) ? res.body : nil
      rescue StandardError => e
        warn "[ARS] fetch failed: #{e.message}"
        nil
      end

      def output_path(image_ref)
        parts = [OUTPUT_DIR]
        parts << image_ref['subfolder'] unless image_ref['subfolder'].to_s.empty?
        parts << image_ref['filename']
        File.join(*parts)
      end

      # 兜底：/history 拿不到时，直接扫输出目录里 since 之后出现的最新 *_final*.png
      def newest_final_since(since_time)
        dir = File.join(OUTPUT_DIR, 'SU_AI_Render')
        return nil unless Dir.exist?(dir)
        files = Dir.glob(File.join(dir, '*_final*.png'))
                   .select { |f| File.mtime(f) >= since_time - 5 }
        files.max_by { |f| File.mtime(f) }
      rescue StandardError
        nil
      end

      private

      def history(prompt_id)
        res = get("/history/#{prompt_id}", timeout: 15)
        res.is_a?(Net::HTTPSuccess) ? JSON.parse(res.body) : nil
      rescue StandardError
        nil
      end

      def queue_state(prompt_id)
        res = get('/queue', timeout: 5)
        return 0.05 unless res.is_a?(Net::HTTPSuccess)
        data = JSON.parse(res.body)
        running = data['queue_running'] || []
        pending = data['queue_pending'] || []
        return 0.6 if running.any? { |item| item[1] == prompt_id }
        idx = pending.index { |item| item[1] == prompt_id }
        return 0.15 if idx.nil?
        [0.1, 0.5 - idx * 0.1].max
      rescue StandardError
        0.1
      end

      def collect_images(outputs)
        images = []
        outputs.each_value do |node_out|
          next unless node_out['images']
          node_out['images'].each { |img| images << img }
        end
        images
      end

      def extract_error(entry)
        msgs = entry.dig('status', 'messages') || []
        err = msgs.find { |m| m[0] == 'execution_error' }
        return entry.dig('status', 'status_str') unless err
        info = err[1] || {}
        "#{info['node_type']} — #{info['exception_message']}"
      end

      # 连接建立失败（重试安全）
      DIAL_ERRORS = [Net::OpenTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET,
                     Errno::ETIMEDOUT, Errno::EHOSTUNREACH, SocketError, EOFError].freeze
      # GET 还可以在读超时时重试（幂等）
      GET_ERRORS  = (DIAL_ERRORS + [Net::ReadTimeout, IOError]).freeze

      # ComfyUI 出图时 GPU 卡住会让 HTTP 端口几秒内不接受连接 → 连接错误重试几次
      def get(path, timeout: 30, tries: 3)
        attempt(tries, GET_ERRORS) do
          h = fresh_http(timeout)
          begin
            h.get(path)
          ensure
            h.finish if h.started?
          end
        end
      end

      def post(path, body, timeout: 90, tries: 2)
        attempt(tries, DIAL_ERRORS) do
          h = fresh_http(timeout)
          req = Net::HTTP::Post.new(path, 'Content-Type' => 'application/json')
          req.body = body
          begin
            h.request(req)
          ensure
            h.finish if h.started?
          end
        end
      end

      def attempt(tries, errors)
        last = nil
        tries.times do |i|
          return yield
        rescue *errors => e
          last = e
          sleep(1.5 * (i + 1))
        end
        raise last if last
      end

      # 每次用新连接（长时间渲染中复用连接容易被对端悄悄断掉）。
      # 第 3 参数 nil = 禁用代理（本地服务不该走 Clash/V2Ray）。
      def fresh_http(read_timeout)
        h = Net::HTTP.new(host, port, nil)
        h.open_timeout = 20
        h.read_timeout = read_timeout
        h.start
        h
      end
    end
  end
end
