# frozen_string_literal: true

require_relative "native_ios_release"

module NativeIOSScreenshots
  Release = NativeIOSRelease
  LANGUAGES = %w[zh-Hans zh-Hant en-US].freeze
  PAGES = %w[01-five-tones 02-listening 03-bedtime 04-themes 05-schedule].freeze
  RAW_PAGES = (%w[theme-moonlit theme-bamboo theme-mountain] + (PAGES - ["04-themes"])).freeze
  RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-27-2"
  DUO_RUNTIME = "#{RUNTIME}-iPhone19-4"
  DEVICE_PREFIX = "com.apple.CoreSimulator.SimDeviceType."
  DUOCTL_REVISION = "c6ff3e961a9858fb061907448e702d7d1617dc4a"
  BUILD_PROGRESS = {
    /Resolving Package Graph|Resolve Package Graph/ => "解析 Swift Package 依赖",
    /Fetch(?:ing|ed) |Updating from / => "获取 Swift Package 依赖",
    /CreateBuildDescription|ComputeTargetDependencyGraph/ => "准备编译目标",
    /SwiftCompile |SwiftDriver |CompileSwift/ => "正在编译 Swift",
    /LinkStoryboards |CopySwiftLibs |WriteAuxiliaryFile / => "正在处理构建产物"
  }.freeze
  TEST_PROGRESS = {
    /Unable to boot|Failed to boot|failed to start the simulator/i => "模拟器启动失败",
    /Failed to (?:install|launch) (?:the )?(?:app|application|test runner)|Early unexpected exit/i => "应用或测试运行器启动失败",
    /Failed to establish communication|Failed to connect to the test|Lost connection to the test|test runner.*timed out/i => "与 XCTest 运行器的连接失败",
    /exceeded (?:its |the )?(?:test )?execution time allowance|test execution time allowance.*exceeded/i => "XCTest 用例超过执行时限",
    /Test Case .* failed|error: .*XCTAssert|error: .*XCTUnwrap/i => "XCTest 用例失败",
    /\*\* TEST FAILED \*\*/ => "xcodebuild 报告测试失败",
    /\bt =\s*[\d.]+s\s+Set device orientation/ => "XCTest 正在设置设备方向",
    /\bt =\s*[\d.]+s\s+Launch / => "XCTest 正在启动 App",
    /\bt =\s*[\d.]+s\s+Wait for .* to idle/ => "XCTest 正在等待 App 就绪",
    /Test Case .* started/ => "XCTest 已进入截图用例"
  }.freeze
  DEVICES = [
    { key: "iphone", types: [/\AiPhone-17-Pro-Max\z/, /\AiPhone-18-Pro-Max\z/],
      test: "testCaptureLocalizedStoreScreenshots", size: [1320, 2868], output: "screenshots" },
    { key: "ipad", types: [/\AiPad-Pro-13-inch-M5(?:-\d+GB)?\z/],
      test: "testCaptureLocalizedStoreScreenshots", size: [2064, 2752], output: "screenshots-ipad" },
    { key: "duo", types: [/\AiPhone-Duo\z/],
      runtime: DUO_RUNTIME, test: "testCaptureDuoStoreScreenshots", size: [2007, 2853], output: "screenshots-duo" }
  ].freeze

  module_function

  def select_simulator(device, devices)
    available = devices.fetch(device.fetch(:runtime, RUNTIME), [])
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

    runtime = device.fetch(:runtime, RUNTIME)
    unless devices.key?(runtime)
      raise Release::Error, "未安装 #{device.fetch(:key)} 所需的模拟器运行时 #{runtime}"
    end

    types = JSON.parse(Release.capture!("xcrun", "simctl", "list", "devicetypes", "-j")).fetch("devicetypes")
    device.fetch(:types).each do |pattern|
      types.each do |type|
        identifier = type.fetch("identifier")
        next unless pattern.match?(identifier.delete_prefix(DEVICE_PREFIX))

        name = "Tinglan Store #{device.fetch(:key)}"
        udid, _, status = Open3.capture3("xcrun", "simctl", "create", name, identifier, runtime)
        return { "udid" => udid.strip, "state" => "Shutdown", "name" => name } if status.success?
      end
    end
    raise Release::Error, "未找到可用的 iOS 27.2 #{device.fetch(:key)} 模拟器"
  end

  def progress(message)
    $stdout.puts("[截图] #{message}")
    $stdout.flush
  end

  def public_progress(line)
    shot = line.match(/snapshot: (#{LANGUAGES.join('|')})_(#{RAW_PAGES.join('|')})\s*\z/)
    return "开始拍摄 #{shot[1]} / #{shot[2]}" if shot

    return "启动截图 UI 测试" if line.include?("Running snapshot on:")
    exit_code = line[/Caught error\.\.\. (\d{1,3})\b/i, 1]
    return "xcodebuild 返回退出码 #{exit_code}" if exit_code

    TEST_PROGRESS.find { |pattern, _| pattern.match?(line) }&.last ||
      BUILD_PROGRESS.find { |pattern, _| pattern.match?(line) }&.last
  end

  def logged!(log, stage, *command, timeout: 60, heartbeat: 30, chdir: nil, &on_tick)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    progress("开始 #{stage}（上限 #{timeout}s）")
    File.open(log, "a", 0o600) do |stream|
      stream.puts("\n--- #{stage} ---")
      stream.flush
      options = { pgroup: true }
      options[:chdir] = chdir if chdir
      stdin, output, child = Open3.popen2e(*command, **options)
      begin
        stdin.close
        reader = Thread.new do
          reported = {}
          output.each_line do |line|
            stream.puts(line)
            message = public_progress(line.scrub)
            next unless message
            next if reported[message] && (BUILD_PROGRESS.value?(message) || TEST_PROGRESS.value?(message))

            reported[message] = true
            progress("#{stage} · #{message}")
          end
        end
        next_heartbeat = heartbeat
        loop do
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          remaining = timeout - elapsed
          break if remaining.positive? && child.join([on_tick ? 0.1 : next_heartbeat - elapsed, remaining].min)

          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          raise Release::Error, "#{stage}超时（#{timeout}s）" if elapsed >= timeout

          if elapsed >= next_heartbeat
            progress("#{stage}仍在运行（#{elapsed.round}s）")
            next_heartbeat = elapsed + heartbeat
          end
          on_tick&.call
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
            child.join(1)
          end
        end
        if reader&.alive?
          reader.kill
          reader.join(1)
        end
        output.close
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

  def capture_device!(work, log, project, scheme, device, simulator)
    key = device.fetch(:key)
    raw = File.join(work, "raw", key)
    if key != "duo"
      capture_snapshot!(work, log, project, scheme, device, simulator, raw)
      progress("#{key} 三语素材就绪（#{LANGUAGES.size * RAW_PAGES.size} 张）")
      return
    end

    id = simulator.fetch("udid")
    results = File.join(work, "#{key}.xcresult")
    booted_here = false
    xcode = xcode_options(work, project, scheme)
    logged!(log, "构建 Duo 模拟器测试", "xcodebuild", "build-for-testing", *xcode,
            "-destination", "platform=iOS Simulator,id=#{id}", timeout: 600)
    if simulator.fetch("state") == "Shutdown"
      logged!(log, "启动 #{key}", "xcrun", "simctl", "boot", id)
      booted_here = true
    end
    logged!(log, "等待 #{key} 启动", "xcrun", "simctl", "bootstatus", id, timeout: 180)
    test_command = ["xcodebuild", "test-without-building", *xcode,
                    "-destination", "platform=iOS Simulator,id=#{id}", "-parallel-testing-enabled", "NO",
                    "-only-testing:TinglanUITests/PadUITests/#{device.fetch(:test)}", "-resultBundlePath", results]
    capture_duo!(work, log, id, raw, device.fetch(:size), test_command)
    progress("duo 三语素材就绪（#{LANGUAGES.size * RAW_PAGES.size} 张）")
  ensure
    cleanup_simulator(log, "关闭 #{key}", "shutdown", id) if booted_here
  end

  def capture_snapshot!(work, log, project, scheme, device, simulator, raw, probe: false)
    key = device.fetch(:key)
    name = simulator.fetch("name")
    output = File.join(work, "snapshot-#{key}")
    languages = probe ? ["zh-Hans"] : LANGUAGES
    pages = probe ? ["01-five-tones"] : RAW_PAGES
    test = probe ? "testCaptureSnapshotHomeProbe" : device.fetch(:test)
    env = {
      "BUNDLE_GEMFILE" => File.expand_path("../../Gemfile", __dir__),
      "FASTLANE_OPT_OUT_USAGE" => "true",
      "FASTLANE_SKIP_UPDATE_CHECK" => "true",
      "FASTLANE_DISABLE_COLORS" => "true",
      "SNAPSHOT_EXECUTE_CONCURRENT_SIMULATORS" => "false",
      "TEST_RUNNER_TINGLAN_FASTLANE_SNAPSHOT" => "1"
    }
    logged!(log, "snapshot 采集 #{key}", env, "bundle", "exec", "fastlane", "snapshot",
            "--project", project, "--scheme", scheme, "--derived_data_path", File.join(work, "derived-data"),
            "--configuration", "Debug", "--devices", name, "--ios_version", "27.2",
            "--languages", languages.join(","), "--only_testing", "TinglanUITests/PadUITests/#{test}",
            "--xcargs=-parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 180 -skipMacroValidation CODE_SIGNING_ALLOWED=NO",
            "--output_directory", output, "--buildlog_path", File.join(output, "logs"),
            "--headless", "--skip_open_summary", "--result_bundle",
            "--override_status_bar", "false",
            "--number_of_retries", "0", "--stop_after_first_error", "--disable_xcpretty",
            chdir: Release.source_dir, timeout: probe ? 600 : 900)
    import_snapshot!(output, raw, name, device.fetch(:size), languages: languages, pages: pages)
  end

  def capture_duo!(work, log, id, raw, size, test_command)
    source = File.join(work, "duoctl")
    logged!(log, "准备 duoctl 源码目录", "git", "init", "--quiet", source)
    logged!(log, "下载固定版本 duoctl", "git", "-C", source, "fetch", "--quiet", "--depth", "1",
            "https://github.com/skarol/duoctl.git", DUOCTL_REVISION)
    logged!(log, "检出固定版本 duoctl", "git", "-C", source, "checkout", "--quiet", "--detach", DUOCTL_REVISION)
    duoctl = [File.join(source, "bin", "duoctl"), "-d", id]
    logged!(log, "展开 Duo 内屏", *duoctl, "open")
    logged!(log, "旋转 Duo 内屏至竖屏", *duoctl, "rotate", "portrait")
    progress("Duo 内屏已展开并切换至竖屏")

    bridge = File.join(work, "duo-requests")
    FileUtils.mkdir(bridge)
    logged!(log, "采集 duo", { "TEST_RUNNER_TINGLAN_DUO_REQUEST_DIR" => bridge }, *test_command, timeout: 480) do
      handle_duo_request!(bridge, log, duoctl, raw, size)
    end
    missing = LANGUAGES.product(RAW_PAGES).reject do |language, page|
      File.file?(File.join(raw, language, "#{page}.png"))
    end
    raise Release::Error, "Duo 缺少内屏截图 #{missing.map { |pair| pair.join('/') }.join(', ')}" unless missing.empty?
  end

  def handle_duo_request!(bridge, log, duoctl, raw, size)
    request = File.join(bridge, "request")
    return unless File.file?(request)

    operation, *arguments = File.read(request, 256).split
    File.unlink(request)
    case operation
    when "tap"
      unless arguments.size == 2 && arguments.all? { |coordinate| coordinate.match?(/\A\d{1,4}(?:\.\d+)?\z/) }
        raise Release::Error, "Duo 点击坐标无效"
      end
      logged!(log, "点击 Duo 内屏", *duoctl, "tap", *arguments, timeout: 30)
    when "screenshot"
      language, page = arguments
      unless arguments.size == 2 && LANGUAGES.include?(language) && RAW_PAGES.include?(page)
        raise Release::Error, "Duo 截图请求不在商店素材清单中"
      end
      directory = File.join(raw, language)
      FileUtils.mkdir_p(directory)
      png = File.join(directory, "#{page}.png")
      raise Release::Error, "Duo 收到重复截图请求 #{language}/#{page}" if File.exist?(png)

      logged!(log, "拍摄 Duo #{language}/#{page}", *duoctl, "screenshot", png, timeout: 30)
      validate_raw_png!(png, size, "Duo #{language}/#{page}")
    else
      raise Release::Error, "Duo 收到未知采集请求"
    end
    File.write(File.join(bridge, "response"), "")
  end

  def cleanup_simulator(log, stage, *arguments)
    logged!(log, stage, "xcrun", "simctl", *arguments, timeout: 15)
  rescue Release::Error => e
    progress(e.message)
  end

  def import_snapshot!(output, raw, name, size, languages: LANGUAGES, pages: RAW_PAGES)
    languages.product(pages).each do |language, page|
      png = File.join(output, language, "#{name}-#{language}_#{page}.png")
      raise Release::Error, "snapshot 缺少 #{language}/#{page}" unless File.file?(png)
      validate_raw_png!(png, size, "snapshot #{language}/#{page}")
      directory = File.join(raw, language)
      FileUtils.mkdir_p(directory)
      FileUtils.mv(png, File.join(directory, "#{page}.png"))
    end
  end

  def validate_png!(file, size)
    header = File.binread(file, 33)
    unless header.start_with?("\x89PNG\r\n\x1a\n".b) && header.byteslice(12, 4) == "IHDR" &&
           header.byteslice(16, 10)&.unpack("NNC2") == [*size, 8, 2]
      raise Release::Error, "#{File.basename(file)} 须为 #{size.join(' × ')} 的 8 位 RGB PNG"
    end
  end

  def validate_raw_png!(png, size, label)
    header = File.binread(png, 24) if File.file?(png)
    unless header&.start_with?("\x89PNG\r\n\x1a\n".b) && header.byteslice(12, 12) == ["IHDR", *size].pack("a4NN")
      raise Release::Error, "#{label} 原图须为 #{size.join(' × ')} 的竖屏 PNG"
    end
  end

  def xcode_options(work, project, scheme)
    ["-project", project, "-scheme", scheme, "-configuration", "Debug",
     "-derivedDataPath", File.join(work, "derived-data"), "-skipMacroValidation", "CODE_SIGNING_ALLOWED=NO"]
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

  def save_diagnostics!(work, log, destination, password, error)
    diagnostic = Dir.mktmpdir("diagnostics-", destination)
    File.open(log, "a", 0o600) { |stream| stream.puts("#{error.class}: #{error.message}") }
    diagnostics = [log, *Dir.glob(File.join(work, "simulator-home.png")), *Dir.glob(File.join(work, "*.xcresult")),
                   *Dir.glob(File.join(work, "snapshot-*", "{logs,test_output}"))]
    diagnostics.each do |file|
      name = file.delete_prefix("#{work}/").tr("/", "-")
      File.rename(file, File.join(diagnostic, name))
    end
    zip = File.join(work, "screenshot-diagnostics.zip")
    Release.encrypt_zip!(zip, password, diagnostic)
    File.chmod(0o600, zip)
    output = File.join(destination, File.basename(zip))
    File.rename(zip, output)
    Release.outputs(diagnostics_zip_path: output)
    progress("已打包加密诊断日志")
  rescue StandardError
    progress("加密诊断日志打包失败")
  end

  def capture_probe!(work, log, project, scheme, simulator, destination, password)
    device = DEVICES.first
    id = simulator.fetch("udid")
    progress("Runner 镜像 #{ENV.fetch('ImageOS', '未报告')} / #{ENV.fetch('ImageVersion', '未报告')}")
    logged!(log, "读取模拟器运行时", "xcrun", "simctl", "list", "runtimes")
    logged!(log, "单图验证 1/2 · 启动 iPhone 模拟器", "xcrun", "simctl", "bootstatus", id, "-b", timeout: 240)
    system_png = File.join(work, "simulator-home.png")
    logged!(log, "单图验证 1/2 · 截取模拟器屏幕", "xcrun", "simctl", "io", id, "screenshot", system_png, timeout: 30)
    validate_raw_png!(system_png, device.fetch(:size), "模拟器屏幕")

    progress("单图验证 2/2 · 使用 Fastlane snapshot 拍听澜首页")
    raw = File.join(work, "probe")
    capture_snapshot!(work, log, project, scheme, device, simulator, raw, probe: true)
    app_png = File.join(raw, "zh-Hans", "01-five-tones.png")
    zip = File.join(work, "screenshot-probe.zip")
    Release.encrypt_zip!(zip, password, system_png, app_png)
    File.chmod(0o600, zip)
    output = File.join(destination, File.basename(zip))
    File.rename(zip, output)
    Release.outputs(zip_path: output, artifact_name: "screenshot-probe")
    progress("单图验证通过，已打包两张加密验证图")
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
        project = File.join(Release.source_dir, config.fetch("project"))
        scheme = config.fetch("scheme")
        progress("读取 iOS 27.2 模拟器清单")
        devices = JSON.parse(Release.capture!("xcrun", "simctl", "list", "devices", "available", "-j")).fetch("devices")
        if ENV["NATIVE_SCREENSHOT_PROBE"] == "true"
          simulator = simulator_for!(DEVICES.first, devices)
          return capture_probe!(work, log, project, scheme, simulator, destination, password)
        end
        duo_only = ENV["NATIVE_SCREENSHOT_TARGET"] == "duo"
        selected = DEVICES.select { |device| (device.fetch(:key) == "duo") == duo_only }
        selected.each do |device|
          progress("准备 #{device.fetch(:key)} 模拟器")
          simulator = simulator_for!(device, devices)
          capture_device!(work, log, project, scheme, device, simulator)
        end
        rendered = File.join(work, "app-store-screenshots")
        logged!(log, "渲染商店截图", "swift", File.join(Release.source_dir, "Scripts", "RenderStorePreview.swift"),
                duo_only ? "--store-duo" : "--store", File.join(work, "raw"), rendered, timeout: 120)
        progress("校验成品尺寸、张数和 PNG 格式")
        validate_output!(rendered, devices: selected)
        artifact_name = duo_only ? "app-store-screenshots-duo" : "app-store-screenshots-iphone-ipad"
        zip = File.join(work, "#{artifact_name}.zip")
        Release.encrypt_zip!(zip, password, rendered) { |message| progress(message) }
        File.chmod(0o600, zip)
        output = File.join(destination, File.basename(zip))
        File.rename(zip, output)
        Release.outputs(zip_path: output, artifact_name: artifact_name)
        progress("#{selected.size * LANGUAGES.size * PAGES.size} 张商店截图已打包为加密 ZIP，交给 Actions 上传")
      rescue StandardError => e
        save_diagnostics!(work, log, destination, password, e)
        reason = e.is_a?(Release::Error) ? e.message : "商店截图处理失败"
        raise Release::Error, reason, cause: nil
      end
    end
  ensure
    File.umask(previous_umask) if previous_umask
  end
end
