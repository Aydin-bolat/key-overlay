# frozen_string_literal: true

require 'fileutils'
require 'json'

module AydinCreative
  module AiRenderStudio
    # 一键下载缺失的模型到 ComfyUI 对应的 models 子文件夹。
    #
    # 2026-09-28 第二版：下载放进一个独立的后台 PowerShell 进程里跑，插件只读它写的进度文件。
    # 第一版用 SketchUp 里的 Ruby 线程——真实踩坑：SketchUp 空闲时 Ruby 后台线程几乎分不到
    # 运行时间，下载卡在"0 / ? MB"不动。独立进程完全不受影响，关掉面板/SketchUp 也照样下完。
    #
    # 脚本里做的事：
    #   - 读 Windows 系统代理（Clash/V2Ray 设的就是这个；curl 默认不会用它）
    #   - curl.exe 加 --ssl-revoke-best-effort：Windows 版 curl 在代理/公司网络下常因
    #     "证书吊销检查不可用"失败，这个参数只放宽吊销检查，证书本身照样严格校验
    #   - huggingface.co 连得上就用它，否则换 hf-mirror.com；某个文件在主站失败也会再试镜像
    #   - 断点续传(-C -)，失败自动重试，下完从 .part 改名成正式文件名
    # 目标文件夹问 ComfyUI 要(/internal/folder_paths)，放到你其它模型实际所在的 models 根目录。
    module Downloader
      MIRROR = 'hf-mirror.com'

      module_function

      def status_path(work_dir)
        File.join(work_dir, 'download_status.json')
      end

      # items: [{ folder:, name:, url:, gb: }]；返回后台进程 pid
      def start(items, client, work_dir)
        paths = client.folder_paths
        raise 'ComfyUI 没有返回模型文件夹路径（/internal/folder_paths），请把 ComfyUI 更新到最新版' if paths.empty?

        jobs = items.map do |it|
          dir = target_dir(paths, it[:folder])
          raise "ComfyUI 里没有 #{it[:folder]} 这个模型文件夹，请把 ComfyUI 更新到最新版" unless dir
          { folder: it[:folder], name: it[:name], url: it[:url], dest: File.join(dir, it[:name]) }
        end

        status = status_path(work_dir)
        # 每次下载一个独立的 run 号：取消标记按 run 号区分；旧进程万一没被杀掉，
        # 看到状态文件里已经是新的 run 号就自己退出，不会跟新一轮抢同一个 .part 文件
        run = "#{Time.now.strftime('%H%M%S')}#{rand(1000..9999)}"
        cancel = File.join(work_dir, "download_cancel_#{run}.flag")
        log = File.join(work_dir, 'download.log')
        Dir.glob(File.join(work_dir, 'download_cancel_*.flag')).each { |f| File.delete(f) rescue nil }
        File.write(status, JSON.generate(state: 'starting', index: 0, count: jobs.size, run: run))

        ps1 = File.join(work_dir, 'download_models.ps1')
        # Windows PowerShell 5.1 读脚本时，没有 BOM 会按本地代码页解析，中文路径会乱码
        File.write(ps1, "\uFEFF" + script(jobs, status, cancel, log, run), encoding: 'utf-8')
        # 进程自己的 stdout/stderr 单独一个文件：跟脚本里 Add-Content 写的 download.log 分开，
        # 否则 Windows 上同一个文件被两边同时打开会报"文件被占用"
        ps_out = File.join(work_dir, 'download_ps.log')
        pid = Process.spawn('powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                            '-File', ps1, out: [ps_out, 'w'], err: [ps_out, 'w'])
        Process.detach(pid)
        # 先把进程号记下来：万一 PowerShell 根本没跑起来(被安全软件拦截等)，面板能马上看出来，
        # 而不是永远显示"下载中"
        File.write(status, JSON.generate(state: 'starting', index: 0, count: jobs.size, pid: pid, run: run))
        pid
      end

      def read_status(work_dir)
        path = status_path(work_dir)
        return nil unless File.exist?(path)
        JSON.parse(File.read(path, encoding: 'bom|utf-8'))
      rescue StandardError
        nil
      end

      def running?(work_dir)
        st = read_status(work_dir)
        return false unless st && %w[starting running].include?(st['state'])
        pid = st['pid'].to_i
        return true if pid.zero? # 刚启动，脚本还没写 pid
        alive?(pid)
      end

      def alive?(pid)
        Process.kill(0, pid)
        true
      rescue StandardError
        false
      end

      def cancel(work_dir)
        st = read_status(work_dir)
        File.write(File.join(work_dir, "download_cancel_#{st['run']}.flag"), '1') if st && st['run']
        pid = st && st['pid'].to_i
        if pid && pid.positive?
          # /T 连同它启动的 curl.exe 一起结束
          killed = system('taskkill', '/PID', pid.to_s, '/T', '/F', out: File::NULL, err: File::NULL)
          (Process.kill('KILL', pid) rescue nil) unless killed
        end
        st ||= {}
        File.write(status_path(work_dir), JSON.generate(st.merge('state' => 'cancelled')))
      rescue StandardError
        nil
      end

      # 给面板的进度快照
      def snapshot(work_dir)
        st = read_status(work_dir) || { 'state' => 'starting' }
        part = st['part'].to_s
        got = !part.empty? && File.exist?(part) ? File.size(part) : 0
        total = st['total'].to_i
        state = st['state']
        state = 'error' if %w[starting running].include?(state) && st['pid'].to_i.positive? && !alive?(st['pid'].to_i)
        { active: %w[starting running].include?(state), done: %w[done error cancelled].include?(state),
          error: state == 'error' ? (st['error'] || '下载进程意外退出，详见 download.log') : nil,
          cancelled: state == 'cancelled', index: st['index'], count: st['count'], file: st['file'],
          host: st['host'], got_mb: (got / 1_048_576.0).round, total_mb: total.positive? ? (total / 1_048_576.0).round : nil }
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

      def ps_str(s)
        "'" + s.to_s.gsub("'", "''") + "'"
      end

      # 兼容 Windows PowerShell 5.1（不用 ?: / ?? / && 这些 7.x 语法）
      def script(jobs, status, cancel, log, run)
        items = jobs.map do |j|
          "  @{ folder = #{ps_str(j[:folder])}; name = #{ps_str(j[:name])}; url = #{ps_str(j[:url])}; dest = #{ps_str(j[:dest])} }"
        end.join(",\n")

        <<~PS
          $ErrorActionPreference = 'Continue'
          $StatusFile = #{ps_str(status)}
          $CancelFile = #{ps_str(cancel)}
          $LogFile = #{ps_str(log)}
          $Items = @(
          #{items}
          )
          $Mirror = '#{MIRROR}'
          $Run = '#{run}'
          $St = @{ state = 'running'; pid = $PID; run = $Run; index = 0; count = $Items.Count; file = ''; part = ''; total = 0; host = ''; error = '' }

          # 状态文件里已经是别的 run 号 = 用户重新点了下载，这个旧进程直接退出
          function Assert-Current {
            try {
              $cur = Get-Content -LiteralPath $StatusFile -Raw -Encoding UTF8 | ConvertFrom-Json
              if ($cur.run -and $cur.run -ne $Run) { exit 0 }
            } catch { }
          }
          function Save-Status { Assert-Current; ($St | ConvertTo-Json -Compress) | Set-Content -LiteralPath $StatusFile -Encoding UTF8 }
          function Log($m) { Add-Content -LiteralPath $LogFile -Value ((Get-Date -Format 'HH:mm:ss') + '  ' + $m) -Encoding UTF8 }
          function Fail($m) { $St.state = 'error'; $St.error = $m; Save-Status; Log ('ERROR ' + $m); exit 1 }

          Save-Status
          Log ('download start, ' + $Items.Count + ' file(s)')

          # ---- 代理：环境变量优先，否则读 Windows 系统代理（Clash / V2Ray "系统代理"模式） ----
          $Common = @('-L', '--fail', '--retry', '5', '--retry-delay', '3', '--connect-timeout', '20')
          if (-not ($env:HTTPS_PROXY -or $env:https_proxy -or $env:ALL_PROXY)) {
            try {
              $is = Get-ItemProperty 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings' -ErrorAction Stop
              if ($is.ProxyEnable -eq 1 -and $is.ProxyServer) {
                $p = [string]$is.ProxyServer
                if ($p -match 'https=([^;]+)') { $p = $Matches[1] } elseif ($p -match 'http=([^;]+)') { $p = $Matches[1] }
                if ($p -notmatch '://') { $p = 'http://' + $p }
                $Common += @('--proxy', $p)
                Log ('using system proxy ' + $p)
              }
            } catch { }
          }

          # 老版本 curl 不认识 --ssl-revoke-best-effort 时(退出码 2)就不加
          & curl.exe --ssl-revoke-best-effort -s -o NUL --max-time 5 'https://127.0.0.1:9' 2>$null
          if ($LASTEXITCODE -ne 2) { $Common += '--ssl-revoke-best-effort' }

          function Test-Host($h) {
            $code = & curl.exe @Common -s -I -o NUL --max-time 12 -w '%{http_code}' ('https://' + $h + '/') 2>$null
            return ([int]("0" + ($code -replace '[^0-9]', ''))) -in 200..399
          }

          function Get-Size($url) {
            $lines = & curl.exe @Common -s -I --max-time 40 $url 2>$null
            $linked = 0; $len = 0
            foreach ($l in $lines) {
              if ($l -match '^x-linked-size:\\s*(\\d+)') { $linked = [int64]$Matches[1] }
              if ($l -match '^content-length:\\s*(\\d+)') { $len = [int64]$Matches[1] }
            }
            if ($linked -gt 0) { return $linked }
            return $len
          }

          if (Test-Host 'huggingface.co') { $Hosts = @('huggingface.co', $Mirror) }
          elseif (Test-Host $Mirror) { $Hosts = @($Mirror) }
          else { Fail '连不上 huggingface.co，也连不上 hf-mirror.com。请检查网络/代理（开了 Clash 的话打开"系统代理"）' }
          Log ('hosts: ' + ($Hosts -join ', '))

          $i = 0
          foreach ($it in $Items) {
            $i++
            if (Test-Path -LiteralPath $CancelFile) { $St.state = 'cancelled'; Save-Status; exit 0 }
            $St.index = $i; $St.file = $it.folder + '/' + $it.name
            if (Test-Path -LiteralPath $it.dest) { Log ('exists ' + $it.dest); continue }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $it.dest) | Out-Null
            $part = $it.dest + '.part'
            $St.part = $part
            $ok = $false
            foreach ($h in $Hosts) {
              $url = $it.url.Replace('huggingface.co', $h)
              $St.host = $h; $St.total = Get-Size $url; Save-Status
              Log ('GET ' + $url + '  total=' + $St.total)
              $out = & curl.exe @Common -C - -sS -o $part $url 2>&1
              $code = $LASTEXITCODE
              if ($out) { Log ('curl: ' + (($out | ForEach-Object { [string]$_ }) -join ' ')) }
              if (Test-Path -LiteralPath $CancelFile) { $St.state = 'cancelled'; Save-Status; exit 0 }
              Assert-Current
              $size = 0; if (Test-Path -LiteralPath $part) { $size = (Get-Item -LiteralPath $part).Length }
              Log ('curl exit ' + $code + '  size=' + $size)
              if ($St.total -gt 0 -and $size -eq $St.total) { $ok = $true; break }
              if ($code -eq 0 -and $St.total -le 0 -and $size -gt 0) { $ok = $true; break }
            }
            if (-not $ok) { Fail ('下载失败：' + $it.name + '（再点一次下载会从断点接着下，详见 download.log）') }
            Move-Item -LiteralPath $part -Destination $it.dest -Force
            Log ('saved ' + $it.dest)
          }
          $St.state = 'done'; $St.part = ''; Save-Status
          Log 'all done'
        PS
      end
    end
  end
end
