# frozen_string_literal: true

require "base64"
require "digest/sha1"
require "fileutils"
require "json"
require "open3"
require "openssl"
require "shellwords"
require "tmpdir"
require "yaml"

module NativeIOSRelease
  class Error < StandardError; end

  CONFIG_PATH = ".github/native-ios.yml"
  SSH_HOSTS = %w[codeup.aliyun.com github.com].freeze

  module_function

  def required(name, env: ENV)
    value = env[name].to_s.strip
    raise Error, "缺少 #{name}" if value.empty?

    value
  end

  def project_key(env: ENV)
    key = required("NATIVE_PROJECT", env: env)
    raise Error, "无效的原生 iOS 项目名" unless key.match?(/\A[a-zA-Z][a-zA-Z0-9_]*\z/)

    key
  end

  def project(root: source_dir, env: ENV)
    key = project_key(env: env)
    path = File.join(root, CONFIG_PATH)
    raise Error, "宿主项目缺少 #{CONFIG_PATH}" unless File.file?(path)

    config = YAML.safe_load_file(path)
    raise Error, "#{CONFIG_PATH} 必须为 YAML 对象" unless config.is_a?(Hash)

    %w[project scheme team_id app_target ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8_BASE64].each do |field|
      unless config[field].is_a?(String) && !config[field].strip.empty?
        raise Error, "#{CONFIG_PATH} 缺少 #{field}"
      end
    end
    validate_project_path!(root, config.fetch("project"))
    targets = config["signing_targets"]
    unless targets.is_a?(Hash) && targets.key?(config["app_target"]) && targets.values.uniq.size == targets.size &&
           targets.all? { |target, bundle| target.is_a?(String) && !target.strip.empty? && bundle.is_a?(String) && bundle.match?(/\A[A-Za-z0-9.-]+\z/) }
      raise Error, "#{CONFIG_PATH} 的 signing_targets 须为主 App 和扩展分别配置 Bundle ID"
    end

    match = config["match"]
    unless match.is_a?(Hash) && match["certificate_id"].is_a?(String) && match["certificate_id"].match?(/\A[A-Z0-9]{10}\z/)
      raise Error, "#{CONFIG_PATH} 须设置有效的 match.certificate_id"
    end
    ssh_host!(match["git_url"], "match.git_url")
    validate_branch!(required("git_branch", env: match))

    validate_asc_key!(config)
    puts "::add-mask::#{config.fetch('ASC_KEY_P8_BASE64')}" if env["GITHUB_ACTIONS"] == "true"
    config.merge("key" => key)
  rescue Psych::Exception
    raise Error, "#{CONFIG_PATH} 的 YAML 格式无效", cause: nil
  end

  def validate_project_path!(root, path)
    raise Error, "project 须为宿主仓库内的 .xcodeproj 路径" unless File.extname(path) == ".xcodeproj"

    resolved = File.realpath(File.expand_path(path, root))
    unless resolved.start_with?(File.realpath(root) + File::SEPARATOR) &&
           File.file?(File.join(resolved, "project.pbxproj"))
      raise Error, "project 须指向宿主仓库内存在的 .xcodeproj"
    end
  rescue Errno::ENOENT
    raise Error, "找不到宿主配置指定的 .xcodeproj", cause: nil
  end

  def validate_asc_key!(config)
    unless config["ASC_KEY_ID"].match?(/\A[A-Z0-9]{10}\z/) &&
           config["ASC_ISSUER_ID"].match?(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i)
      raise Error, "#{CONFIG_PATH} 的 ASC_KEY_ID 或 ASC_ISSUER_ID 格式无效"
    end

    encoded = config.fetch("ASC_KEY_P8_BASE64")
    key = OpenSSL::PKey.read(Base64.strict_decode64(encoded))
    unless key.is_a?(OpenSSL::PKey::EC) && key.private? && key.group.curve_name == "prime256v1"
      raise Error, "#{CONFIG_PATH} 的 ASC_KEY_P8_BASE64 须为有效的 P-256 私钥"
    end
  rescue ArgumentError, OpenSSL::PKey::PKeyError
    raise Error, "#{CONFIG_PATH} 的 ASC_KEY_P8_BASE64 须为有效的 Base64 私钥", cause: nil
  end

  def validate_branch!(name)
    unless name.match?(%r{\A[a-zA-Z0-9][a-zA-Z0-9._/-]*\z}) && system("git", "check-ref-format", "refs/heads/#{name}", out: File::NULL)
      raise Error, "无效的 Git 分支"
    end

    name
  end

  def requested_branch(env: ENV)
    name = env["NATIVE_BRANCH"].to_s.strip
    name.empty? ? nil : validate_branch!(name)
  end

  def source_branch
    validate_branch!(git!("symbolic-ref", "--short", "HEAD", error: "所选 ref 不是源码分支"))
  end

  def changelog(env: ENV)
    required("NATIVE_CHANGELOG", env: env)
  end

  def source_dir
    File.join(required("RUNNER_TEMP"), "native-ios-source")
  end

  def output_dir
    File.join(required("RUNNER_TEMP"), "native-ios-output")
  end

  def capture!(*command, env: {}, error: nil)
    output, stderr, status = Open3.capture3(env, *command)
    raise Error, error || "#{command.first} 执行失败：#{stderr.strip}" unless status.success?

    output
  end

  def git!(*arguments, env: {}, error: nil)
    capture!("git", "-C", source_dir, *arguments, env: env, error: error).strip
  end

  def ssh_host!(repo, label)
    match = repo.to_s.match(%r{\Agit@([a-zA-Z0-9.-]+):[a-zA-Z0-9][a-zA-Z0-9._/-]*\.git\z})
    unless match && SSH_HOSTS.include?(match[1])
      raise Error, "#{label} 须使用受支持的 git@ SSH 地址"
    end

    match[1]
  end

  def with_git_ssh(repo, label:)
    host = ssh_host!(repo, label)
    key = required("SSH_PRIVATE_KEY")
    Dir.mktmpdir("native-ios-ssh-", required("RUNNER_TEMP")) do |directory|
      identity = File.join(directory, "identity")
      known_hosts = File.join(directory, "known_hosts")
      File.write(identity, "#{key}\n", perm: 0o600)
      keys = capture!("ssh-keyscan", "-T", "10", host, error: "无法获取 #{host} 的 SSH 主机公钥")
      raise Error, "#{host} 未返回 SSH 主机公钥" if keys.strip.empty?

      File.write(known_hosts, keys, perm: 0o600)
      ssh = Shellwords.join(["ssh", "-F", "/dev/null", "-i", identity,
                             "-o", "UserKnownHostsFile=#{known_hosts}", "-o", "StrictHostKeyChecking=yes",
                             "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes"])
      yield({ "GIT_SSH_COMMAND" => ssh, "GIT_TERMINAL_PROMPT" => "0", "SSH_PRIVATE_KEY" => nil })
    end
  end

  def with_source_ssh
    label = "源码仓库 Secret #{project_key.upcase}"
    repo = ENV["TARGET_REPO"].to_s.strip
    raise Error, "缺少#{label}" if repo.empty?

    with_git_ssh(repo, label: label) { |git_env| yield repo, git_env }
  end

  def checkout!
    changelog
    name = requested_branch
    branch_arguments = name ? ["--branch", name] : []
    with_source_ssh do |repo, git_env|
      capture!("git", "clone", "--single-branch", *branch_arguments, "--", repo, source_dir, env: git_env,
               error: "无法检出源码，请检查分支设置及 SSH 权限")
    end
    actual = source_branch
    raise Error, "检出的源码分支与输入不一致" if name && actual != name

    puts "源码 #{actual} @ #{git!('rev-parse', 'HEAD')}"
    project
  end

  def build_settings(config)
    project_path = File.join(source_dir, config.fetch("project"))
    raise Error, "找不到 Xcode 项目：#{config.fetch('project')}" unless File.file?(File.join(project_path, "project.pbxproj"))

    command = ["xcodebuild", "-project", project_path, "-configuration", "Release"]
    output = capture!(*command, "-scheme", config.fetch("scheme"), "-destination", "generic/platform=iOS",
                      "-showBuildSettings", "-json")
    scheme_targets = JSON.parse(output).to_h { |row| [row.fetch("target"), row.fetch("buildSettings")] }
    config.fetch("signing_targets").to_h do |target, identifier|
      settings = scheme_targets[target]
      if !settings && target != config.fetch("app_target")
        # showBuildSettings for a scheme may omit implicitly built extensions.
        extension = capture!(*command, "-target", target, "-sdk", "iphoneos", "-showBuildSettings", "-json")
        settings = JSON.parse(extension).find { |row| row.fetch("target") == target }&.fetch("buildSettings")
      end
      unless settings && settings["PRODUCT_BUNDLE_IDENTIFIER"] == identifier && settings["DEVELOPMENT_TEAM"] == config.fetch("team_id")
        raise Error, "Release 配置中 #{target} 的 Bundle ID 或 Team ID 与发布配置不匹配"
      end
      [target, settings]
    end
  end

  def next_build_number(current, uploaded)
    unless current.to_s.match?(/\A[1-9]\d*\z/) && uploaded.to_s.match?(/\A\d+\z/)
      raise Error, "源码及 TestFlight 的构建号须为整数"
    end

    [current.to_i, uploaded.to_i + 1].max
  end

  def external_group!(app, selector)
    groups = app.get_beta_groups
    group = groups.find { |candidate| candidate.id == selector }
    unless group
      by_name = groups.select { |candidate| candidate.name == selector }
      raise Error, "当前 App 有多个同名测试组，请填写测试组 ID" if by_name.size > 1

      group = by_name.first
    end
    raise Error, "当前 App 找不到指定的 TestFlight 测试组" unless group
    raise Error, "指定的 TestFlight 测试组必须是外部组" unless group.is_internal_group == false

    group
  end

  def match_profile_names!(config, mapping)
    mapping ||= {}
    ids = config.fetch("signing_targets").values
    missing = ids.select { |id| mapping[id].to_s.strip.empty? }
    raise Error, "Match 缺少 App Store 描述文件：#{missing.join(', ')}" unless missing.empty?

    mapping.slice(*ids)
  end

  def validate_profile!(profile, identifier:, team:, fingerprint_candidates:, app_groups: [], now: Time.now)
    if profile["IsXcodeManaged"] == true
      raise Error, "#{identifier} 的描述文件由 Xcode 自动管理，请在 Match 中替换成手动创建的 App Store Connect 描述文件"
    end

    entitlements = profile.fetch("Entitlements", {})
    prefix, bundle = entitlements["application-identifier"].to_s.split(".", 2)
    unless bundle == identifier && Array(profile["TeamIdentifier"]).include?(team) &&
           Array(profile["ApplicationIdentifierPrefix"]).include?(prefix)
      raise Error, "#{identifier} 的描述文件 Bundle ID 或 Team ID 不匹配"
    end
    unless entitlements["get-task-allow"] == false && entitlements["beta-reports-active"] == true &&
           !profile.key?("ProvisionedDevices") && !profile["ProvisionsAllDevices"]
      raise Error, "#{identifier} 需要 App Store 发行描述文件"
    end
    raise Error, "#{identifier} 的描述文件已过期或缺少有效期" unless profile["ExpirationDate"]&.to_time&.>(now)
    if (app_groups - Array(entitlements["com.apple.security.application-groups"])).any?
      raise Error, "#{identifier} 的描述文件缺少项目需要的 App Groups"
    end
    fingerprints = Array(profile["DeveloperCertificates"]).map do |certificate|
      Digest::SHA1.hexdigest(certificate.respond_to?(:string) ? certificate.string : certificate).upcase
    end
    if (fingerprints & fingerprint_candidates).empty?
      raise Error, "#{identifier} 的描述文件与导入的 Apple Distribution 证书不匹配"
    end
    profile.fetch("UUID")
  end

  def project_model(config)
    require "xcodeproj"
    Xcodeproj::Project.open(File.join(source_dir, config.fetch("project")))
  end

  def write_build_number(config, build_number)
    model = project_model(config)
    path = File.join(model.path, "project.pbxproj")
    original = File.binread(path)
    contents = original
    config.fetch("signing_targets").each_key do |name|
      target = model.targets.find { |candidate| candidate.name == name }
      raise Error, "找不到签名目标 #{name}" unless target

      target.build_configurations.each do |item|
        # Use the parser's configuration IDs, while preserving the existing pbxproj formatting.
        definition = /^([ \t]*)#{item.uuid}(?:[ \t]+\/\*[^\r\n]*\*\/)?[ \t]*=[ \t]*\{\r?\n.*?^\1\};/m
        setting = /^([ \t]*CURRENT_PROJECT_VERSION[ \t]*=[ \t]*"?)(\d+)("?[ \t]*;[ \t]*\r?)$/
        body = contents[definition]
        unless body && body.scan(setting).size == 1
          raise Error, "#{name} 的 #{item.name} 配置须显式设置整数 CURRENT_PROJECT_VERSION"
        end
        updated = body.sub(setting) { "#{$1}#{build_number}#{$3}" }
        contents = contents.sub(definition) { updated }
      end
    end
    File.binwrite(path, contents) unless contents == original
  end

  def commit_version!(config, version, build_number)
    path = File.join(config.fetch("project"), "project.pbxproj")
    original = git!("rev-parse", "HEAD")
    write_build_number(config, build_number)
    if git!("diff", "--name-only", "--", path) != ""
      git!("add", "--", path)
      git!("-c", "user.name=github-actions[bot]", "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
           "commit", "-m", "release: #{version} build: #{build_number}", "--", path)
    end
    [original, git!("rev-parse", "HEAD")]
  end

  def writeback_needed?(remote, source, release)
    return false if remote == release
    raise Error, "源码分支已前进，请重新触发发布" unless remote == source

    true
  end

  def push_version!
    result = metadata
    name = source_branch
    unless result.fetch("branch") == name && result.fetch("release_sha") == git!("rev-parse", "HEAD")
      raise Error, "打包所用源码与待回写的提交不一致"
    end

    ref = "refs/heads/#{name}"
    with_source_ssh do |repo, git_env|
      remote = git!("ls-remote", "--exit-code", "--refs", repo, ref, env: git_env, error: "无法读取源码分支 #{name}")
      sha = remote.split.first
      if writeback_needed?(sha, result.fetch("source_sha"), result.fetch("release_sha"))
        # A normal fast-forward push also rejects a concurrent update after ls-remote.
        git!("push", repo, "#{result.fetch('release_sha')}:#{ref}", env: git_env,
             error: "构建号回写失败，请检查分支写权限或重新触发发布")
      end
    end
    puts "源码构建号已确认：#{name} @ #{result.fetch('release_sha')}"
  end

  def plist(path)
    JSON.parse(capture!("plutil", "-convert", "json", "-o", "-", path))
  end

  def verify_ipa!(ipa, config, version, build_number)
    raise Error, "没有生成 IPA" unless File.file?(ipa)

    Dir.mktmpdir("verify-native-ipa-") do |directory|
      capture!("ditto", "-x", "-k", ipa, directory)
      apps = Dir.glob(File.join(directory, "Payload", "*.app"))
      raise Error, "IPA 必须包含一个主 App" unless apps.size == 1

      app = apps.first
      capture!("codesign", "--verify", "--deep", "--strict", app)
      expected = config.fetch("signing_targets")
      app_info = plist(File.join(app, "Info.plist"))
      unless app_info["DTSDKName"] == "iphoneos27.2" && app_info["CFBundleIdentifier"] == expected.fetch(config.fetch("app_target"))
        raise Error, "IPA 的 SDK 或主 App Bundle ID 不匹配"
      end
      bundles = [app, *Dir.glob(File.join(app, "PlugIns", "*.appex"))]
      identifiers = bundles.map do |bundle|
        info = plist(File.join(bundle, "Info.plist"))
        unless info["CFBundleVersion"] == build_number.to_s && info["CFBundleShortVersionString"] == version
          raise Error, "#{info['CFBundleIdentifier']} 的版本或构建号与主 App 不一致"
        end
        info.fetch("CFBundleIdentifier")
      end
      raise Error, "IPA 的签名目标与配置不一致" unless identifiers.sort == expected.values.sort
    end
  end

  def metadata_path
    File.join(required("RUNNER_TEMP"), "native-ios-build.json")
  end

  def metadata
    JSON.parse(File.read(metadata_path))
  end

  def outputs(values)
    File.open(required("GITHUB_OUTPUT"), "a") do |file|
      values.each { |key, value| file.puts("#{key}=#{value}") }
    end
  end

  def beta_status(detail)
    case detail&.external_build_state
    when "WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW"
      "已提交 Beta 审核（通过后自动通知）" if detail.auto_notify_enabled
    when "BETA_APPROVED", "READY_FOR_BETA_TESTING"
      "已加入外测组，等待 TestFlight 开放" if detail.auto_notify_enabled
    when "IN_BETA_TESTING"
      "已可外测"
    end
  end
end
