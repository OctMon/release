# frozen_string_literal: true

require "minitest/autorun"
require_relative "../fastlane/lib/native_ios_screenshots"

class NativeIOSScreenshotsTest < Minitest::Test
  Screenshots = NativeIOSScreenshots

  def test_hosted_simulator_selection_uses_only_the_requested_runtime_and_device
    iphone, ipad, duo = Screenshots::DEVICES
    phone_17 = simulator("iPhone-17-Pro-Max")
    phone_18 = simulator("iPhone-18-Pro-Max")
    pad = simulator("iPad-Pro-13-inch-M5-12GB")
    foldable = simulator("iPhone-Duo")
    inventory = { Screenshots::RUNTIME => [phone_18, pad, foldable],
                  "com.apple.CoreSimulator.SimRuntime.iOS-27-0" => [phone_17] }

    assert_equal phone_18, Screenshots.select_simulator(iphone, inventory)
    assert_equal pad, Screenshots.select_simulator(ipad, inventory)
    assert_equal foldable, Screenshots.select_simulator(duo, inventory)
    inventory.fetch(Screenshots::RUNTIME) << phone_17
    assert_equal phone_17, Screenshots.select_simulator(iphone, inventory)
    foldable["isAvailable"] = false
    assert_nil Screenshots.select_simulator(duo, inventory)
  end

  private

  def simulator(type)
    { "deviceTypeIdentifier" => "#{Screenshots::DEVICE_PREFIX}#{type}",
      "isAvailable" => true, "state" => "Shutdown" }
  end
end
