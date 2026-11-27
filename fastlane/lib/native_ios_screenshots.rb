# frozen_string_literal: true

require_relative "native_ios_release"

module NativeIOSScreenshots
  Release = NativeIOSRelease
  LANGUAGES = %w[zh-Hans zh-Hant en-US].freeze
  PAGES = %w[01-five-tones 02-listening 03-bedtime 04-themes 05-schedule].freeze
  RAW_PAGES = (%w[theme-moonlit theme-bamboo theme-mountain] + (PAGES - ["04-themes"])).freeze
  RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-27-2"
  DEVICE_PREFIX = "com.apple.CoreSimulator.SimDeviceType."
  BUILD_PROGRESS = {
    /Resolving Package Graph|Resolve Package Graph/ => "解析 Swift Package 依赖",
    /Fetch(?:ing|ed) |Updating from / => "获取 Swift Package 依赖",
    /CreateBuildDescription|ComputeTargetDependencyGraph/ => "准备编译目标",
    /SwiftCompile |SwiftDriver |CompileSwift/ => "正在编译 Swift",
    /LinkStoryboards |CopySwiftLibs |WriteAuxiliaryFile / => "正在处理构建产物"
  }.freeze
  DEVICES = [
    { key: "iphone", types: [/\AiPhone-17-Pro-Max\z/, /\AiPhone-18-Pro-Max\z/],
      test: "testCaptureLocalizedStoreScreenshots", size: [1320, 2868], output: "screenshots" },
    { key: "ipad", types: [/\AiPad-Pro-13-inch-M5(?:-\d+GB)?\z/],
      test: "testCaptureLocalizedStoreScreenshots", size: [2064, 2752], output: "screenshots-ipad" },
    { key: "duo", types: [/\AiPhone-Duo\z/],
      test: "testCaptureDuoStoreScreenshots", size: [2007, 2853], output: "screenshots-duo" }
  ].freeze

  module_function

  def select_simulator(device, devices)
    available = devices.fetch(RUNTIME, [])
    device.fetch(:types).each do |pattern|
      match = available.find do |item|
        item["isAvailable"] && %w[Shutdown Booted].include?(item["state"]) &&
          pattern.match?(item.fetch("deviceTypeIdentifier", "").delete_prefix(DEVICE_PREFIX))
      end
      return match if match
    end
    nil
  end

  def simulator_for!(device, devices)
    simulator = select_simulator(device, devices)
    return simulator if simulator

    types = JSON.parse(Release.capture!("xcrun", "simctl", "list", "devicetypes", "-j")).fetch("devicetypes")
    device.fetch(:types).each do |pattern|
      types.each do |type|
        identifier = type.fetch("identifier")
        next unless pattern.match?(identifier.delete_prefix(DEVICE_PREFIX))

        udid, _, status = Open3.capture3("xcrun", "simctl", "create", "Tinglan Store #{device.fetch(:key)}", identifier, RUNTIME)
        return { "udid" => udid.strip, "state" => "Shutdown" } if status.success?
      end
    end
    raise Release::Error, "未找到可用的 iOS 27.2 #{device.fetch(:key)} 模拟器"
  end

  def progress(message)
    $stdout.puts("[截图] #{message}")
    $stdout.flush
  end

  def public_progress(line)
    attachment = line.match(/Added attachment named '(#{LANGUAGES.join('|')})_(#{RAW_PAGES.join('|')})'\s*\z/)
    return "已拍摄 #{attachment[1]} / #{attachment[2]}" if attachment

    BUILD_PROGRESS.find { |pattern, _| pattern.match?(line) }&.last
  end

  def logged!(log, stage, *command, timeout: 60, heartbeat: 30)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    progress("开始 #{stage}（上限 #{timeout}s）")
    File.open(log, "a", 0o600) do |stream|
      stream.puts("\n--- #{stage} ---")
      stream.flush
      Open3.popen2e(*command, pgroup: true) do |stdin, output, child|
        stdin.close
        reader = Thread.new do
          reported = {}
          output.each_line do |line|
            stream.puts(line)
            message = public_progress(line.scrub)
            next unless message && !reported[message]

            reported[message] = true
            progress("#{stage} · #{message}")
          end
        end
        loop do
          remaining = timeout - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
          break if remaining.positive? && child.join([heartbeat, remaining].min)

          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          raise Release::Error, "#{stage}超时（#{timeout}s）" if elapsed >= timeout

          progress("#{stage}仍在运行（#{elapsed.round}s）")
        end
        unless reader.join(5)
          signal_command("KILL", child.pid)
          raise Release::Error, "#{stage}结束后仍有子进程占用日志管道"
        end
        reader.value
        unless child.value.success?
          raise Release::Error, "#{stage}失败（#{child.value.exitstatus || "信号 #{child.value.termsig}"}）"
        end
      ensure
        if child&.alive?
          signal_command("TERM", child.pid)
          unless child.join(3)
            signal_command("KILL", child.pid)
            child.join
          end
        end
        if reader&.alive?
          reader.kill
          reader.join
        end
      end
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    progress("完成 #{stage}（#{elapsed.round}s）")
  end

  def signal_command(signal, pid)
    Process.kill(signal, -pid)
  rescue Errno::ESRCH
    nil
  end

  def capture_device!(work, log, xcode, device, simulator)
    key = device.fetch(:key)
    id = simulator.fetch("udid")
    results = File.join(work, "#{key}.xcresult")
    booted_here = false
    time_overridden = false
    if simulator.fetch("state") == "Shutdown"
      logged!(log, "启动 #{key}", "xcrun", "simctl", "boot", id)
      booted_here = true
    end
    logged!(log, "等待 #{key} 启动", "xcrun", "simctl", "bootstatus", id, timeout: 180)
    logged!(log, "固定 #{key} 状态栏", "xcrun", "simctl", "status_bar", id, "override",
            "--time", "14:09", "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
            "--cellularMode", "active", "--cellularBars", "4", "--batteryState", "discharging", "--batteryLevel", "100")
    time_overridden = true
    begin
      logged!(log, "采集 #{key}", "xcodebuild", "test-without-building", *xcode,
              "-destination", "platform=iOS Simulator,id=#{id}", "-parallel-testing-enabled", "NO",
              "-only-testing:TinglanUITests/PadUITests/#{device.fetch(:test)}", "-resultBundlePath", results,
              timeout: key == "duo" ? 240 : 360)
    rescue Release::Error => e
      if key == "duo"
        raise Release::Error, "#{e.message}。Duo 需要展开内屏和 2007 × 2853 竖屏尺寸"
      end
      raise e
    end
    exported = File.join(work, "#{key}-attachments")
    logged!(log, "导出 #{key} 截图", "xcrun", "xcresulttool", "export", "attachments",
            "--path", results, "--output-path", exported)
    import_attachments!(exported, File.join(work, "raw", key))
    progress("#{key} 三语素材就绪（#{LANGUAGES.size * RAW_PAGES.size} 张）")
  ensure
    cleanup_simulator(log, "清除 #{key} 状态栏覆盖", "status_bar", id, "clear") if time_overridden
    cleanup_simulator(log, "关闭 #{key}", "shutdown", id) if booted_here
  end

  def cleanup_simulator(log, stage, *arguments)
    logged!(log, stage, "xcrun", "simctl", *arguments, timeout: 15)
  rescue Release::Error => e
    progress(e.message)
  end

  def import_attachments!(exported, raw)
    manifest = JSON.parse(File.read(File.join(exported, "manifest.json")))
    attachments = manifest.flat_map { |entry| entry.fetch("attachments") }.group_by do |item|
      item.fetch("suggestedHumanReadableName").split("_", 3).first(2)
    end
    LANGUAGES.product(RAW_PAGES).each do |language, page|
      entries = attachments.fetch([language, page], [])
      filename = entries.one? && entries.first.fetch("exportedFileName")
      unless filename && filename.match?(/\A[0-9a-f-]{36}\.png\z/i)
        raise Release::Error, "#{language}/#{page} 须有且仅有一张 PNG 截图"
      end

      directory = File.join(raw, language)
      FileUtils.mkdir_p(directory)
      FileUtils.cp(File.join(exported, filename), File.join(directory, "#{page}.png"))
    end
  end

  def validate_png!(file, size)
    header = File.binread(file, 33)
    unless header.start_with?("\x89PNG\r\n\x1a\n".b) && header.byteslice(12, 4) == "IHDR" &&
           header.byteslice(16, 10)&.unpack("NNC2") == [*size, 8, 2]
      raise Release::Error, "#{File.basename(file)} 须为 #{size.join(' × ')} 的 8 位 RGB PNG"
    end
  end

  def validate_output!(rendered, devices: DEVICES)
    devices.each do |device|
      LANGUAGES.each do |language|
        folder = File.join(rendered, device.fetch(:output), language)
        unless Dir.children(folder).sort == PAGES.map { |page| "#{page}.png" }.sort
          raise Release::Error, "#{device.fetch(:key)}/#{language} 须恰好包含五张商店图"
        end
        PAGES.each { |page| validate_png!(File.join(folder, "#{page}.png"), device.fetch(:size)) }
      end
    end
    expected_overviews = devices.flat_map { |device| LANGUAGES.map { |language| "#{device.fetch(:key)}-#{language}.png" } }
    unless Dir.children(File.join(rendered, "overviews")).sort == expected_overviews.sort
      raise Release::Error, "商店图总览缺少设备或语言"
    end
  end

  def run!
    previous_umask = File.umask(0o077)
    password = Release.archive_password!
    ENV.delete("MATCH_PASSWORD")
    destination = Release.private_artifact_dir("screenshots")
    Dir.mktmpdir(".capture-", destination) do |work|
      log = File.join(work, "capture.log")
      begin
        config = Release.screenshot_project
        progress("读取 iOS 27.2 模拟器清单")
        devices = JSON.parse(Release.capture!("xcrun", "simctl", "list", "devices", "available", "-j")).fetch("devices")
        iphone = simulator_for!(DEVICES.first, devices)
        xcode = ["-project", File.join(Release.source_dir, config.fetch("project")), "-scheme", config.fetch("scheme"),
                 "-configuration", "Debug", "-derivedDataPath", File.join(work, "derived-data"),
                 "-skipMacroValidation", "CODE_SIGNING_ALLOWED=NO"]
        id = iphone.fetch("udid")
        logged!(log, "构建模拟器测试", "xcodebuild", "build-for-testing", *xcode,
                "-destination", "platform=iOS Simulator,id=#{id}", timeout: 600)
        captured = []
        duo_error = nil
        DEVICES.each do |device|
          begin
            progress("准备 #{device.fetch(:key)} 模拟器")
            simulator = device.equal?(DEVICES.first) ? iphone : simulator_for!(device, devices)
            capture_device!(work, log, xcode, device, simulator)
            captured << device
          rescue Release::Error => e
            raise unless device.fetch(:key) == "duo"

            duo_error = e
            progress("#{e.message}，继续打包已完成的 iPhone 和 iPad")
          end
        end
        rendered = File.join(work, "app-store-screenshots")
        logged!(log, "渲染商店截图", "swift", File.join(Release.source_dir, "Scripts", "RenderStorePreview.swift"),
                duo_error ? "--store" : "--store-all", File.join(work, "raw"), rendered, timeout: 120)
        progress("校验成品尺寸、张数和 PNG 格式")
        validate_output!(rendered, devices: captured)
        zip = File.join(work, "app-store-screenshots.zip")
        Release.encrypt_zip!(zip, password, rendered) { |message| progress(message) }
        File.chmod(0o600, zip)
        output = File.join(destination, File.basename(zip))
        File.rename(zip, output)
        Release.outputs(zip_path: output, artifact_name: duo_error ? "app-store-screenshots-iphone-ipad" : "app-store-screenshots")
        progress("加密 ZIP 校验完成，交给 Actions 上传")
        raise Release::Error, "#{duo_error.message}。已生成加密的 iPhone/iPad 截图 ZIP" if duo_error
      rescue StandardError => e
        diagnostic = Dir.mktmpdir("diagnostics-", destination)
        File.open(log, "a", 0o600) { |stream| stream.puts("#{e.class}: #{e.message}") }
        [log, *Dir.glob(File.join(work, "*.xcresult"))].each do |file|
          File.rename(file, File.join(diagnostic, File.basename(file)))
        end
        reason = e.is_a?(Release::Error) ? e.message : "商店截图处理失败"
        raise Release::Error, reason, cause: nil
      end
    end
    puts "45 张商店截图已打包为加密 ZIP"
  ensure
    File.umask(previous_umask) if previous_umask
  end
end
