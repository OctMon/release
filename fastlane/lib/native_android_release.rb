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
    commit = ENV.fetch("SOURCE_SHA", "")
    raise Error, "SOURCE_SHA must be a full commit SHA" unless commit.match?(/\A[0-9a-f]{40}\z/)

    target = File.expand_path(ENV.fetch("TARGET_APP_DIR"))
    repository = ENV.fetch("TARGET_REPO")
    with_source_ssh(repository) do |git_env|
      git!(git_env, "clone", "--single-branch", "--branch", "main", "--", repository, target)
      git!(git_env, "-C", target, "merge-base", "--is-ancestor", commit, "origin/main")
      git!(git_env, "-C", target, "checkout", "--detach", commit)
    end
    puts "Source main @ #{commit}"
  end

  def with_source_ssh(repository)
    # Keep the Android checkout and its credentials scoped to its release job.
    match = repository.match(%r{\Agit@(codeup\.aliyun\.com|github\.com):[A-Za-z0-9][A-Za-z0-9._/-]*\.git\z})
    raise Error, "Configure an independent Tinglan Android SSH repository" unless match
    key = ENV.fetch("SSH_PRIVATE_KEY")
    raise Error, "Configure the Android checkout SSH key" if key.strip.empty?

    Dir.mktmpdir("tinglan-android-ssh-", ENV.fetch("RUNNER_TEMP")) do |directory|
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
    return if system(environment, "git", *arguments)

    raise Error, "Unable to check out the requested commit from main"
  end

  def project(root = ENV.fetch("TARGET_APP_DIR"))
    root = File.realpath(root)
    config = YAML.safe_load(File.read(File.join(root, CONFIG_PATH)))
    unless config.is_a?(Hash) && config["schema_version"] == 1 && config["package_name"] == "com.ting.lan"
      raise Error, "Invalid Android release config"
    end

    unless config["project"] == "." && File.file?(File.join(root, "gradlew")) && File.file?(File.join(root, "settings.gradle.kts"))
      raise Error, "Gradle wrapper is missing from the configured project"
    end

    {
      "project" => root,
      "package_name" => config.fetch("package_name"),
      "bundle" => path_under(root, config["bundle"]),
      "mapping" => path_under(root, config["mapping"])
    }
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
    File.open(ENV.fetch("GITHUB_OUTPUT"), "a") do |file|
      config.each { |key, value| file.puts("#{key}=#{value}") }
    end
  end
end
