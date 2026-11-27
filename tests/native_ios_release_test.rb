# frozen_string_literal: true

require "minitest/autorun"
require_relative "../fastlane/lib/native_ios_release"

class NativeIOSReleaseTest < Minitest::Test
  Release = NativeIOSRelease
  Group = Struct.new(:id, :name, :is_internal_group)
  App = Struct.new(:get_beta_groups)
  BetaDetail = Struct.new(:external_build_state, :auto_notify_enabled)

  def test_release_zip_encrypts_both_files_and_keeps_the_originals
    Dir.mktmpdir do |work|
      ipa = File.join(work, "source.ipa")
      symbols = File.join(work, "symbols")
      published = File.join(work, "published")
      unpacked = File.join(work, "unpacked")
      [symbols, published, unpacked].each { |directory| Dir.mkdir(directory) }
      dsym = File.join(symbols, "source.dSYM.zip")
      File.binwrite(ipa, "signed IPA fixture")
      File.binwrite(dsym, "dSYM ZIP fixture")
      password = Release.archive_password!(env: { "MATCH_PASSWORD" => " fixture-only password " })
      zip = Release.package_release!({ "ipa" => ipa, "dsym" => dsym }, published, password)

      assert_equal ["release.zip"], Dir.children(published)
      assert_equal 0o600, File.stat(zip).mode & 0o777
      assert_equal 2, Release.capture!("/usr/bin/zipinfo", "-v", zip).scan(/file security status:\s+encrypted/).size
      assert Release.archive_command(password, "-xf", zip, "-C", unpacked)
      [ipa, dsym].each do |source|
        assert_equal File.binread(source), File.binread(File.join(unpacked, File.basename(source)))
      end
      assert_raises(Release::Error) { Release.package_release!({ "ipa" => ipa }, published, password) }
    end
  end

  def test_checkout_defaults_are_available_before_reading_host_config
    assert_nil Release.requested_branch(env: { "NATIVE_PROJECT" => "tinglan" })
    assert_nil Release.requested_branch(env: { "NATIVE_PROJECT" => "another_app" })
    assert_equal "release/next", Release.requested_branch(env: { "NATIVE_PROJECT" => "tinglan", "NATIVE_BRANCH" => " release/next " })
    assert_raises(Release::Error) { Release.requested_branch(env: { "NATIVE_PROJECT" => "tinglan", "NATIVE_BRANCH" => "feature/../main" }) }
  end

  def test_host_config_reads_credentials_and_both_signing_targets
    with_host_config do |root|
      config = Release.project(root: root, env: { "NATIVE_PROJECT" => "tinglan" })
      assert_equal "tinglan", config.fetch("key")
      assert_equal({ "Tinglan" => "com.ting.lan", "TinglanWidgets" => "com.ting.lan.widgets" }, config.fetch("signing_targets"))
      assert_equal "ABCD123456", config.fetch("ASC_KEY_ID")
      assert_equal "ABCDEFGHIJ", config.dig("match", "certificate_id")
    end
  end

  def test_missing_host_config_and_invalid_key_fail_without_disclosing_credential
    Dir.mktmpdir do |root|
      error = assert_raises(Release::Error) { Release.project(root: root, env: { "NATIVE_PROJECT" => "tinglan" }) }
      assert_match(/宿主项目缺少/, error.message)
    end

    with_host_config(key: "DO_NOT_PRINT_BAD_PRIVATE_KEY") do |root|
      error = assert_raises(Release::Error) { Release.project(root: root, env: { "NATIVE_PROJECT" => "tinglan" }) }
      assert_match(/ASC_KEY_P8_BASE64/, error.message)
      refute_includes error.message, "DO_NOT_PRINT_BAD_PRIVATE_KEY"
      assert_nil error.cause
    end
  end

  def test_number_comes_from_latest_upload_or_source
    assert_equal 4, Release.next_build_number("3", 3)
    assert_equal 6, Release.next_build_number("3", "5")
    assert_equal 7, Release.next_build_number("7", 0)
    assert_raises(Release::Error) { Release.next_build_number("3", "bad response") }
  end

  def test_writeback_aborts_on_concurrent_source_changes
    assert Release.writeback_needed?("source", "source", "built")
    refute Release.writeback_needed?("built", "source", "built")
    refute Release.writeback_needed?("source", "source", "source")
    assert_raises(Release::Error) { Release.writeback_needed?("new source", "source", "built") }
  end

  def test_testing_notes_are_required
    assert_equal "曲尾优化", Release.changelog(env: { "NATIVE_CHANGELOG" => " 曲尾优化 \n" })
    assert_raises(Release::Error) { Release.changelog(env: { "NATIVE_CHANGELOG" => " \n " }) }
  end

  def test_group_matches_the_app_and_is_external
    external = Group.new("qa", "外部", false)
    custom = Group.new("pilot", "试用组", false)
    app = App.new([external, custom, Group.new("internal", "内部", true)])
    assert_equal external, Release.external_group!(app, "外部")
    assert_equal custom, Release.external_group!(app, "试用组")
    assert_equal external, Release.external_group!(app, "qa")
    assert_raises(Release::Error) { Release.external_group!(app, "内部") }
    assert_raises(Release::Error) { Release.external_group!(app, "other-app-group") }
    ambiguous = App.new(app.get_beta_groups + [Group.new("qa-2", "外部", false)])
    assert_raises(Release::Error) { Release.external_group!(ambiguous, "外部") }
    assert_equal external, Release.external_group!(ambiguous, "qa")
  end

  def test_beta_status_distinguishes_review_and_test_availability
    assert_match(/已提交 Beta 审核/, Release.beta_status(BetaDetail.new("WAITING_FOR_BETA_REVIEW", true)))
    assert_nil Release.beta_status(BetaDetail.new("IN_BETA_REVIEW", false))
    assert_equal "已可外测", Release.beta_status(BetaDetail.new("IN_BETA_TESTING", true))
    assert_nil Release.beta_status(BetaDetail.new("BETA_REJECTED", true))
  end

  def test_match_must_return_a_profile_for_each_target
    with_host_config do |root|
      config = Release.project(root: root, env: { "NATIVE_PROJECT" => "tinglan" })
      assert_raises(Release::Error) { Release.match_profile_names!(config, nil) }
      mapping = { "com.ting.lan" => "AppStore main" }
      error = assert_raises(Release::Error) { Release.match_profile_names!(config, mapping) }
      assert_includes error.message, "com.ting.lan.widgets"
      mapping["com.ting.lan.widgets"] = "AppStore widget"
      assert_equal mapping, Release.match_profile_names!(config, mapping)
    end
  end

  def test_profile_must_match_bundle_team_certificate_and_app_group
    time = Time.utc(2026, 10, 1)
    certificate = "test certificate"
    signing = {
      identifier: "com.ting.lan.widgets", team: "TEAM", app_groups: ["group.com.ting.lan"],
      fingerprint_candidates: [Digest::SHA1.hexdigest(certificate).upcase], now: time
    }
    profile = {
      "UUID" => "test-profile",
      "ExpirationDate" => time + 3600,
      "TeamIdentifier" => ["TEAM"],
      "ApplicationIdentifierPrefix" => ["PREFIX"],
      "DeveloperCertificates" => [certificate],
      "Entitlements" => {
        "application-identifier" => "PREFIX.com.ting.lan.widgets",
        "get-task-allow" => false,
        "beta-reports-active" => true,
        "com.apple.security.application-groups" => ["group.com.ting.lan"]
      }
    }
    assert_equal "test-profile", Release.validate_profile!(profile, **signing)
    managed_error = assert_raises(Release::Error) { Release.validate_profile!(profile.merge("IsXcodeManaged" => true), **signing) }
    assert_match(/由 Xcode 自动管理/, managed_error.message)
    assert_raises(Release::Error) { Release.validate_profile!(profile, **signing.merge(identifier: "com.ting.lan")) }
    assert_raises(Release::Error) { Release.validate_profile!(profile, **signing.merge(team: "OTHER_TEAM")) }
    assert_raises(Release::Error) { Release.validate_profile!(profile, **signing.merge(fingerprint_candidates: [])) }
    assert_raises(Release::Error) { Release.validate_profile!(profile, **signing.merge(app_groups: ["group.other"])) }
    assert_raises(Release::Error) { Release.validate_profile!(profile.merge("ExpirationDate" => time), **signing) }
    assert_raises(Release::Error) { Release.validate_profile!(profile.merge("ProvisionedDevices" => ["device"]), **signing) }
  end

  private

  def with_host_config(key: Base64.strict_encode64(OpenSSL::PKey::EC.generate("prime256v1").private_to_pem))
    Dir.mktmpdir("native-ios-test-") do |root|
      FileUtils.mkdir_p(File.join(root, ".github"))
      FileUtils.mkdir_p(File.join(root, "Tinglan.xcodeproj"))
      File.write(File.join(root, "Tinglan.xcodeproj/project.pbxproj"), "")
      config = {
        "project" => "Tinglan.xcodeproj", "scheme" => "Tinglan", "team_id" => "2HHTRN5N5L", "app_target" => "Tinglan",
        "signing_targets" => { "Tinglan" => "com.ting.lan", "TinglanWidgets" => "com.ting.lan.widgets" },
        "match" => {
          "git_url" => "git@github.com:OctMon/AppleProfileFastlaneMatch.git",
          "git_branch" => "master", "certificate_id" => "ABCDEFGHIJ"
        },
        "ASC_KEY_ID" => "ABCD123456", "ASC_ISSUER_ID" => "12345678-1234-1234-1234-123456789abc", "ASC_KEY_P8_BASE64" => key
      }
      File.write(File.join(root, Release::CONFIG_PATH), YAML.dump(config))
      yield root
    end
  end

end
