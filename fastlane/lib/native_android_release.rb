# frozen_string_literal: true

require "open3"
require "shellwords"
require "tmpdir"
require "yaml"

module NativeAndroidRelease
  class Error < StandardError; end

  CONFIG_PATH = ".github/native-android.yml"

  module_function

  def checkout!
    branch = requested_branch
    branch_arguments = branch ? ["--branch", branch] : []
    target = File.expand_path(ENV.fetch("TARGET_APP_DIR"))
    repository = ENV.fetch("TARGET_REPO", "")
    with_source_ssh(repository) do |git_env|
      git!(git_env, "clone", "--single-branch", *branch_arguments, "--", repository, target)
    end

    actual_ref = git!({}, "-C", target, "symbolic-ref", "--quiet", "HEAD")
    raise Error, "The checked-out source is not a branch" unless actual_ref.start_with?("refs/heads/")

    actual_branch = actual_ref.delete_prefix("refs/heads/")
    raise Error, "The checked-out branch does not match the requested branch" if branch && branch != actual_branch

    revision = git!({}, "-C", target, "rev-parse", "HEAD")
    puts "Source #{actual_branch} @ #{revision}"
    if ENV["GITHUB_OUTPUT"]
      File.open(ENV.fetch("GITHUB_OUTPUT"), "a") { |file| file.puts("branch=#{actual_branch}", "revision=#{revision}") }
    end
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

  def git!(environment, *arguments)
    output, status = Open3.capture2(environment, "git", *arguments)
    raise Error, "Unable to check out the Android source branch" unless status.success?

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

  def path_under(root, relative)
    unless relative.is_a?(String) && relative.match?(%r{\A[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*\z}) &&
           relative.split("/").none? { |part| part == "." || part == ".." }
      raise Error, "Expected a relative Android release path"
    end
    File.join(root, relative)
  end

  def describe!
    config = project
    project_id = ENV.fetch("NATIVE_ANDROID_PROJECT", "")
    raise Error, "Invalid Android project name" unless /\A[a-z][a-z0-9_]*\z/.match?(project_id)

    config["version_code_property"] ||= "#{project_id}VersionCode"
    File.open(ENV.fetch("GITHUB_OUTPUT"), "a") do |file|
      config.each { |key, value| file.puts("#{key}=#{value}") }
    end
  end
end
