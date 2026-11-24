# frozen_string_literal: true

require "open3"
require "shellwords"
require "tmpdir"
require "yaml"

module NativeAndroidRelease
  class Error < StandardError; end

  CONFIG_PATH = ".github/native-android.yml"
  MAX_VERSION_CODE = 2_100_000_000

  module_function

  def checkout!
    branch = requested_branch
    branch_arguments = branch ? ["--branch", branch] : []
    target = File.expand_path(ENV.fetch("TARGET_APP_DIR"))
    repository = ENV.fetch("TARGET_REPO", "")
    with_source_ssh(repository) do |git_env|
      git!(git_env, "clone", "--single-branch", *branch_arguments, "--", repository, target)
    end

    actual_branch = source_branch(target)
    raise Error, "The checked-out branch does not match the requested branch" if branch && branch != actual_branch

    revision = git!({}, "-C", target, "rev-parse", "HEAD")
    puts "Source #{actual_branch} @ #{revision}"
    if ENV["GITHUB_OUTPUT"]
      File.open(ENV.fetch("GITHUB_OUTPUT"), "a") { |file| file.puts("branch=#{actual_branch}", "revision=#{revision}") }
    end
  end

  def source_branch(target)
    ref = git!({}, "-C", target, "symbolic-ref", "--quiet", "HEAD")
    raise Error, "The checked-out source is not a branch" unless ref.start_with?("refs/heads/")

    ref.delete_prefix("refs/heads/")
  end

  def requested_branch
    branch = ENV["NATIVE_BRANCH"].to_s.strip
    return nil if branch.empty?

    unless branch.match?(%r{\A[a-zA-Z0-9][a-zA-Z0-9._/-]*\z}) && system("git", "check-ref-format", "refs/heads/#{branch}", out: File::NULL)
      raise Error, "Invalid Android source branch"
    end

    branch
  end

  def with_source_ssh(repository)
    # Keep the Android checkout and its credentials scoped to its release job.
    match = repository.match(%r{\Agit@(codeup\.aliyun\.com|github\.com):[A-Za-z0-9][A-Za-z0-9._/-]*\.git\z})
    raise Error, "Configure the selected project's Android SSH repository" unless match
    key = ENV.fetch("SSH_PRIVATE_KEY", "")
    raise Error, "Configure the Android checkout SSH key" if key.strip.empty?

    Dir.mktmpdir("native-android-ssh-", ENV.fetch("RUNNER_TEMP")) do |directory|
      identity = File.join(directory, "identity")
      known_hosts = File.join(directory, "known_hosts")
      File.write(identity, "#{key}\n", perm: 0o600)
      host_keys, status = Open3.capture2("ssh-keyscan", "-T", "10", match[1])
      raise Error, "Unable to obtain Android source host keys" unless status.success? && !host_keys.strip.empty?
      File.write(known_hosts, host_keys, perm: 0o600)
      command = Shellwords.join(["ssh", "-F", "/dev/null", "-i", identity, "-o", "UserKnownHostsFile=#{known_hosts}",
                                 "-o", "StrictHostKeyChecking=yes", "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes"])
      yield({ "GIT_SSH_COMMAND" => command, "GIT_TERMINAL_PROMPT" => "0", "SSH_PRIVATE_KEY" => nil })
    end
  end

  def git!(environment, *arguments, error: "Git failed during the Android release")
    output, status = Open3.capture2(environment, "git", *arguments)
    raise Error, error unless status.success?

    output.strip
  end

  def project(root = ENV.fetch("TARGET_APP_DIR"))
    root = File.realpath(root)
    config = YAML.safe_load(File.read(File.join(root, CONFIG_PATH)))
    unless config.is_a?(Hash) && config["schema_version"] == 1
      raise Error, "Invalid Android release config"
    end

    gradle_root = config["project"] == "." ? root : path_under(root, config["project"])
    has_settings = %w[settings.gradle.kts settings.gradle].any? { |name| File.file?(File.join(gradle_root, name)) }
    unless File.file?(File.join(gradle_root, "gradlew")) && has_settings
      raise Error, "Gradle wrapper is missing from the configured project"
    end

    if config.key?("version_code_property")
      version_code_property = config_value(config, "version_code_property", /\A[A-Za-z][A-Za-z0-9_.-]*\z/)
    end
    {
      "project" => gradle_root,
      "package_name" => config_value(config, "package_name", /\A[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+\z/),
      "bundle" => path_under(gradle_root, config["bundle"]),
      "mapping" => config["mapping"].nil? ? "" : path_under(gradle_root, config["mapping"]),
      "module" => config_value(config, "module", /\A(?::[A-Za-z0-9_][A-Za-z0-9_.-]*)+\z/, ":app"),
      "java_version" => config_value(config, "java_version", /\A[1-9][0-9]*\z/, "21"),
      "sdk_platform" => config_value(config, "sdk_platform", /\Aandroid-[0-9]+(?:\.[0-9]+)?(?:-ext[0-9]+)?\z/, "android-37.0"),
      "build_tools" => config_value(config, "build_tools", /\A[0-9]+\.[0-9]+\.[0-9]+\z/, "36.0.0"),
      "version_code_property" => version_code_property,
      "catalog_check" => optional_check(root, "validate_catalog.py"),
      "bundle_check" => optional_check(root, "validate_bundle.py")
    }
  rescue Errno::ENOENT
    raise Error, "Android release configuration not found at #{CONFIG_PATH}"
  end

  def config_value(config, key, pattern, default = nil)
    value = config.fetch(key, default)
    raise Error, "Invalid #{key} in #{CONFIG_PATH}" unless value.is_a?(String) && pattern.match?(value)

    value
  end

  def optional_check(root, filename)
    path = File.join(root, "scripts", filename)
    File.file?(path) ? path : ""
  end

  def latest_play_version_code(package_name, client:)
    client.begin_edit(package_name: package_name)
    begin
      track_codes = client.tracks.flat_map do |track|
        Array(track.releases).flat_map { |release| Array(release.version_codes) }
      end
      (track_codes + client.aab_version_codes + client.apks_version_codes).map { |code| Integer(code) }.max || 0
    ensure
      client.abort_current_edit
    end
  end

  def next_version_code(run_number, uploaded, current: 1)
    baseline = Integer(run_number)
    version = [baseline, current, uploaded + 1].max
    unless baseline.positive? && version <= MAX_VERSION_CODE
      raise Error, "Android versionCode must be in 1..#{MAX_VERSION_CODE}"
    end

    version
  end

  def version_code_property(config)
    project_id = ENV.fetch("NATIVE_ANDROID_PROJECT", "")
    raise Error, "Invalid Android project name" unless /\A[a-z][a-z0-9_]*\z/.match?(project_id)

    config["version_code_property"] || "#{project_id}VersionCode"
  end

  def gradle_version_setting(config)
    path = File.join(config.fetch("project"), "gradle.properties")
    raise Error, "gradle.properties must be a regular file" if File.symlink?(path)

    contents = File.exist?(path) ? File.binread(path) : ""
    property = Regexp.escape(version_code_property(config))
    pattern = /^([ \t]*#{property}(?:[ \t]*[=:][ \t]*|[ \t]+))([^\r\n]*?)([ \t]*)(?=\r?$)/
    entries = contents.scan(pattern)
    value = entries.empty? ? "1" : entries.fetch(0).fetch(1)
    current = value.to_i
    unless entries.size <= 1 && /\A[1-9][0-9]*\z/.match?(value) && current <= MAX_VERSION_CODE
      raise Error, "gradle.properties must define at most one valid Android versionCode"
    end

    [path, contents, pattern, current]
  end

  def source_version_code(config)
    gradle_version_setting(config).last
  end

  def commit_version_code!
    target = File.realpath(ENV.fetch("TARGET_APP_DIR"))
    source = git!({}, "-C", target, "rev-parse", "HEAD")
    raise Error, "Android source checkout changed before the build" unless source == ENV.fetch("SOURCE_REVISION")

    config = project(target)
    path, contents, pattern, current = gradle_version_setting(config)
    version = Integer(ENV.fetch("VERSION_CODE"))
    unless (current..MAX_VERSION_CODE).cover?(version)
      raise Error, "Android versionCode cannot go below the source build number or exceed #{MAX_VERSION_CODE}"
    end

    updated = if contents.match?(pattern)
                contents.sub(pattern) { "#{Regexp.last_match(1)}#{version}#{Regexp.last_match(3)}" }
              else
                newline = contents.include?("\r\n") ? "\r\n" : "\n"
                separator = contents.empty? || contents.end_with?("\n") ? "" : newline
                "#{contents}#{separator}#{version_code_property(config)}=#{version}#{newline}"
              end
    if updated != contents
      File.binwrite(path, updated)
      git!({}, "-C", target, "add", "--", path)
      git!({}, "-C", target, "-c", "user.name=github-actions[bot]",
           "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
           "commit", "-m", "release: Android versionCode #{version}", "--", path)
    end

    revision = git!({}, "-C", target, "rev-parse", "HEAD")
    File.open(ENV.fetch("GITHUB_OUTPUT"), "a") { |file| file.puts("revision=#{revision}") }
  end

  def push_version_code!
    target = File.realpath(ENV.fetch("TARGET_APP_DIR"))
    branch = ENV.fetch("SOURCE_BRANCH")
    source = ENV.fetch("SOURCE_REVISION")
    release = ENV.fetch("RELEASE_REVISION")
    unless source_branch(target) == branch && git!({}, "-C", target, "rev-parse", "HEAD") == release
      raise Error, "The Android checkout does not match the packaged release"
    end

    repository = ENV.fetch("TARGET_REPO")
    ref = "refs/heads/#{branch}"
    with_source_ssh(repository) do |git_env|
      remote = git!(git_env, "ls-remote", "--exit-code", "--refs", repository, ref,
                    error: "Unable to read the Android source branch").split.first
      unless remote == release
        raise Error, "Android source branch advanced during the build. Dispatch a new release." unless remote == source

        git!(git_env, "-C", target, "push", repository, "#{release}:#{ref}",
             error: "Unable to write back versionCode. Check Android source branch write access or dispatch a new release.")
      end
    end
    puts "Android versionCode written back to #{branch} @ #{release}"
  end

  def path_under(root, relative)
    unless relative.is_a?(String) && relative.match?(%r{\A[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*\z}) &&
           relative.split("/").none? { |part| part == "." || part == ".." }
      raise Error, "Expected a relative Android release path"
    end
    File.join(root, relative)
  end

  def describe!
    config = project
    config["version_code_property"] = version_code_property(config)
    File.open(ENV.fetch("GITHUB_OUTPUT"), "a") do |file|
      config.each { |key, value| file.puts("#{key}=#{value}") }
    end
  end
end
