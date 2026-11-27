# frozen_string_literal: true

require "minitest/autorun"
require_relative "../fastlane/lib/native_ios_screenshots"

class NativeIOSScreenshotsTest < Minitest::Test
  Screenshots = NativeIOSScreenshots

  def test_capture_reports_safe_progress_and_keeps_raw_output_off_console
    Dir.mktmpdir do |directory|
      log = File.join(directory, "capture.log")
      stdout, = capture_io do
        Screenshots.logged!(log, "测试阶段", RbConfig.ruby, "-e",
                            %q(puts "private fixture"; puts "snapshot: en-US_02-listening"))
      end
      assert_includes stdout, "开始 测试阶段"
      assert_includes stdout, "开始拍摄 en-US / 02-listening"
      assert_includes stdout, "完成 测试阶段"
      refute_includes stdout, "private fixture"
      assert_includes File.read(log), "private fixture"
    end
  end

  def test_timeout_reports_the_stage_after_printing_a_heartbeat
    Dir.mktmpdir do |directory|
      log = File.join(directory, "capture.log")
      stdout, = capture_io do
        error = assert_raises(NativeIOSRelease::Error) do
          Screenshots.logged!(log, "Duo 采集", RbConfig.ruby, "-e", "sleep 10", timeout: 0.3, heartbeat: 0.1)
        end
        assert_includes error.message, "Duo 采集超时"
      end
      assert_includes stdout, "Duo 采集仍在运行"
    end
  end

  def test_import_reads_native_snapshot_output_for_every_language
    Dir.mktmpdir do |directory|
      output = File.join(directory, "snapshot")
      raw = File.join(directory, "raw")
      simulator = "iPhone 17 Pro Max"
      size = [1320, 2868]
      screenshots = Screenshots::LANGUAGES.product(Screenshots::RAW_PAGES)
      screenshots.each do |language, page|
        folder = File.join(output, language)
        FileUtils.mkdir_p(folder)
        File.binwrite(File.join(folder, "#{simulator}-#{language}_#{page}.png"),
                      "\x89PNG\r\n\x1a\n".b + [13, "IHDR", *size].pack("Na4NN"))
      end

      Screenshots.import_snapshot!(output, raw, simulator, size)
      assert_equal screenshots.map { |language, page| "#{language}/#{page}.png" }.sort,
                   Dir.glob("*/*.png", base: raw).sort
    end
  end

  def test_hosted_simulator_selection_uses_only_the_requested_runtime_and_device
    iphone, ipad, duo = Screenshots::DEVICES
    phone_17 = simulator("iPhone-17-Pro-Max")
    phone_18 = simulator("iPhone-18-Pro-Max")
    pad = simulator("iPad-Pro-13-inch-M5-12GB")
    foldable = simulator("iPhone-Duo")
    inventory = { Screenshots::RUNTIME => [phone_18, pad],
                  Screenshots::DUO_RUNTIME => [foldable],
                  "com.apple.CoreSimulator.SimRuntime.iOS-27-0" => [phone_17] }

    assert_equal phone_18, Screenshots.select_simulator(iphone, inventory)
    assert_equal pad, Screenshots.select_simulator(ipad, inventory)
    assert_equal foldable, Screenshots.select_simulator(duo, inventory)
    inventory.fetch(Screenshots::RUNTIME) << phone_17
    assert_equal phone_17, Screenshots.select_simulator(iphone, inventory)
    foldable["isAvailable"] = false
    assert_nil Screenshots.select_simulator(duo, inventory)
  end

  def test_duo_shot_acknowledges_supervised_capture_at_native_dimensions
    Dir.mktmpdir do |directory|
      log = File.join(directory, "capture.log")
      raw = File.join(directory, "raw")
      request = File.join(directory, "request")
      response = File.join(directory, "response")
      size = [2007, 2853]
      command = [RbConfig.ruby, "-e", <<~'RUBY', "--"]
        raise unless ARGV.shift == "screenshot"
        File.binwrite(ARGV.fetch(0), "\x89PNG\r\n\x1a\n".b + [13, "IHDR", 2007, 2853].pack("Na4NN"))
      RUBY

      File.write(request, "screenshot en-US 02-listening")
      capture_io { Screenshots.handle_duo_request!(directory, log, command, raw, size) }
      assert File.file?(File.join(raw, "en-US", "02-listening.png"))
      assert File.file?(response)
      refute File.exist?(request)

      File.unlink(response)
      File.write(request, "screenshot en-US 03-bedtime")
      capture_io do
        error = assert_raises(NativeIOSRelease::Error) do
          Screenshots.handle_duo_request!(directory, log, command, raw, [1398, 2034])
        end
        assert_includes error.message, "原图须为 1398 × 2034"
      end
      refute File.exist?(response)
    end
  end

  private

  def simulator(type)
    { "deviceTypeIdentifier" => "#{Screenshots::DEVICE_PREFIX}#{type}",
      "isAvailable" => true, "state" => "Shutdown" }
  end
end
