# frozen_string_literal: true

require "shellwords"
require "yaml"

module CentralRelease
  class ConfigurationError < StandardError; end

  module_function

  def load_config(path)
    raise ConfigurationError, "发布配置不存在: #{path}" unless File.file?(path)

    config = YAML.safe_load(File.read(path), aliases: true)
    raise ConfigurationError, "发布配置必须是 YAML 对象: #{path}" unless config.is_a?(Hash)

    config
  rescue Psych::SyntaxError => e
    raise ConfigurationError, "发布配置 YAML 格式错误: #{e.message}"
  end

  def load_pubspec(project_root)
    path = File.join(project_root, "pubspec.yaml")
    raise ConfigurationError, "pubspec.yaml 不存在: #{path}" unless File.file?(path)

    YAML.safe_load(File.read(path), aliases: true) || {}
  rescue Psych::SyntaxError => e
    raise ConfigurationError, "pubspec.yaml 格式错误: #{e.message}"
  end

  def validate!(config, project_root:)
    errors = []
    errors << "schema_version 必须为 1" unless config["schema_version"] == 1

    ios = config.fetch("ios", {})
    validate_ios(ios, errors) if enabled?(ios)

    android = config.fetch("android", {})
    validate_android(android, project_root, errors) if enabled?(android)

    notification = config.fetch("notification", {})
    unless [true, false].include?(notification["enabled"])
      errors << "notification.enabled 必须为 true 或 false"
    end

    raise ConfigurationError, errors.join("\n") unless errors.empty?

    true
  end

  def validate_pubspec!(config, pubspec)
    errors = []
    required_string(pubspec, "name", "pubspec.name", errors)
    required_string(pubspec, "version", "pubspec.version", errors)
    if enabled?(config["ios"])
      required_string(pubspec, "appstore_api_key", "pubspec.appstore_api_key", errors)
      required_string(pubspec, "appstore_api_issuer", "pubspec.appstore_api_issuer", errors)
      required_string(pubspec, "appstore_base64_content", "pubspec.appstore_base64_content", errors)
    end
    raise ConfigurationError, errors.join("\n") unless errors.empty?

    true
  end

  def validate_runtime!(config, external_testing:, changelog:)
    external = config.fetch("ios", {}).fetch("external_testing", {})
    return true unless truthy?(external_testing) && external["enabled"] == true

    raise ConfigurationError, "启用外部测试时 ios.external_testing.group 不能为空" if blank?(external["group"])
    raise ConfigurationError, "启用外部测试时 changelog 不能为空" if blank?(changelog)

    true
  end

  def validate_ios(ios, errors)
    required_string(ios, "team_id", "ios.team_id", errors)
    required_string(ios, "apple_id", "ios.apple_id", errors)

    bundles = ios["bundle_identifiers"]
    if !bundles.is_a?(Array) || bundles.empty?
      errors << "ios.bundle_identifiers 至少需要一个配置"
    else
      bundles.each_with_index do |bundle, index|
        unless bundle.is_a?(Hash)
          errors << "ios.bundle_identifiers[#{index}] 必须是对象"
          next
        end

        required_string(bundle, "identifier", "ios.bundle_identifiers[#{index}].identifier", errors)
        targets = bundle["targets"]
        if !targets.is_a?(Array) || targets.empty? || targets.any? { |target| blank?(target) }
          errors << "ios.bundle_identifiers[#{index}].targets 至少需要一个 target"
        end
      end
    end

    match = ios.fetch("match", {})
    required_string(match, "git_url", "ios.match.git_url", errors)
    required_string(match, "type", "ios.match.type", errors)

    unless %w[build_app flutter_archive].include?(ios["archive_strategy"])
      errors << "ios.archive_strategy 只能是 build_app 或 flutter_archive"
    end

    external = ios.fetch("external_testing", {})
    if external["enabled"] == true && blank?(external["group"])
      errors << "启用外部测试时 ios.external_testing.group 不能为空"
    end
  end

  def validate_android(android, project_root, errors)
    required_string(android, "app_channel", "android.app_channel", errors)

    google_play = android.fetch("google_play", {})
    return unless google_play["enabled"] == true

    required_string(google_play, "package_name", "android.google_play.package_name", errors)
    required_string(google_play, "json_key_path", "android.google_play.json_key_path", errors)
    json_key_path = resolve_path(project_root, google_play["json_key_path"])
    errors << "Google Play service account 文件不存在: #{json_key_path}" unless File.file?(json_key_path)
  end

  def required_string(hash, key, label, errors)
    errors << "#{label} 不能为空" if blank?(hash[key])
  end

  def enabled?(section)
    section.is_a?(Hash) && section["enabled"] == true
  end

  def truthy?(value)
    value == true || value.to_s == "true"
  end

  def blank?(value)
    value.nil? || value.to_s.strip.empty?
  end

  def resolve_path(project_root, path)
    return "" if blank?(path)
    return File.expand_path(path) if path.start_with?(File::SEPARATOR)

    File.expand_path(path, project_root)
  end

  def ios_flutter_command(config:, flavor:, branch:, commit:)
    ios = config.fetch("ios")
    command = common_flutter_command(
      artifact: "ipa",
      branch: branch,
      commit: commit,
      app_channel: "appstore"
    )
    command << "--no-codesign"
    append_beta_flag(command, ios, flavor)
  end

  def android_flutter_command(config:, artifact:, flavor:, branch:, commit:, is_overseas:)
    android = config.fetch("android")
    app_channel = if truthy?(is_overseas) && !blank?(android["overseas_app_channel"])
                    android["overseas_app_channel"]
                  else
                    android["app_channel"]
                  end
    command = common_flutter_command(
      artifact: artifact,
      branch: branch,
      commit: commit,
      app_channel: app_channel
    )
    command.concat(["--target-platform", "android-arm64"])
    command << "--split-per-abi" if artifact == "apk" && android["split_per_abi"] == true
    command << "--dart-define=is-overseas=#{truthy?(is_overseas)}" if android["include_overseas_define"] == true
    append_beta_flag(command, android, flavor)
  end

  def common_flutter_command(artifact:, branch:, commit:, app_channel:)
    [
      "flutter", "build", artifact,
      "--dart-define=git-branch=#{branch}",
      "--dart-define=git-commit=#{commit}",
      "--dart-define=app-channel=#{app_channel}",
      "--obfuscate",
      "--split-debug-info=symbols"
    ]
  end

  def append_beta_flag(command, platform_config, flavor)
    command << "--dart-define=app-debug-flag=true" if flavor == "beta" && platform_config["beta_debug_flag"] == true
    command
  end

  def apk_path(config:, project_root:)
    android = config.fetch("android")
    output_dir = File.join(project_root, "build", "app", "outputs", "flutter-apk")
    if android["split_per_abi"] == true
      Dir[File.join(output_dir, "*arm64*release.apk")].max_by { |path| File.mtime(path) }
    else
      path = File.join(output_dir, "app-release.apk")
      File.file?(path) ? path : nil
    end
  end

  def aab_path(project_root:)
    Dir[File.join(project_root, "build", "app", "outputs", "bundle", "**", "*.aab")]
      .max_by { |path| File.mtime(path) }
  end

  def testflight_upload_options(config:, requested:, changelog:, api_key:)
    external = config.fetch("ios").fetch("external_testing", {})
    external_enabled = truthy?(requested) && external["enabled"] == true
    changelog = changelog.to_s.strip

    if external_enabled
      group = external["group"].to_s.strip
      raise ConfigurationError, "启用外部测试时必须配置测试组" if group.empty?
      raise ConfigurationError, "启用外部测试时 changelog 不能为空" if changelog.empty?

      {
        api_key: api_key,
        distribute_external: true,
        groups: [group],
        notify_external_testers: true,
        changelog: changelog
      }
    else
      options = { api_key: api_key, skip_waiting_for_build_processing: true }
      options[:changelog] = changelog unless changelog.empty?
      options
    end
  end

  def notification_webhook(config:, pubspec:)
    return nil unless config.dig("notification", "enabled") == true

    webhook = pubspec["fei_shu_webhook"].to_s.strip
    webhook.empty? ? nil : webhook
  end

  def shell_join(command)
    command.map { |part| Shellwords.escape(part.to_s) }.join(" ")
  end
end
