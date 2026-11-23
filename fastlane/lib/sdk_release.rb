# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "open3"
require "shellwords"
require "tmpdir"
require "digest"
require "rubygems/version"
require_relative "adapter_release"

module SDKRelease
  class Error < StandardError; end

  SPECS_URL = "https://gitee.com/hxsdk/hxsdk-specs.git"
  SPECS_PUSH_URL = "git@gitee.com:hxsdk/hxsdk-specs.git"
  SOURCE_URL = "git@codeup.aliyun.com:672f43b6d309e5bbdbcb0a49/app/HXSDK.git"
  PROJECTS = {
    "HXSDK" => ["hxsdk/hxsdk-ios", "HXSDK_VERSION"],
    "HXTakuAdapter" => ["octmon/hxtaku-adapter-ios", "TAKU_VERSION"],
    "HXToBidAdapter" => ["octmon/hxwind-adapter-ios", "TOBID_VERSION"],
    "HXToBidAdapterNew" => ["octmon/hxwind-adapter-new-ios", "TOBID_NEW_VERSION"],
    "HXGMAdapter" => ["octmon/hxgm-adapter-ios", "GM_VERSION"]
  }.freeze

  class Request
    attr_reader :versions, :skipped_projects, :target, :dry_run, :sdk_version

    def initialize(options = {}, env = ENV)
      project = options[:project] || env.fetch("SDK_PROJECT", "HXSDK")
      batch = %w[all adapters].include?(project)
      raise Error, "未知项目: #{project}" unless batch || PROJECTS.key?(project)

      @target = options[:target] || env.fetch("POD_TARGET", "both")
      raise Error, "target 必须为 both 或 specs" unless %w[both specs].include?(@target)

      dry = options.fetch(:dry_run) { env.fetch("SDK_DRY_RUN", "true") }
      raise Error, "dry_run 必须为 true 或 false" unless [true, false, "true", "false"].include?(dry)

      @dry_run = dry.to_s == "true"
      names = case project
              when "all" then PROJECTS.keys
              when "adapters" then PROJECTS.keys - ["HXSDK"]
              else [project]
              end
      @skipped_projects = []
      @versions = names.each_with_object({}) do |name, versions|
        key = PROJECTS.fetch(name).last
        version = options[key.downcase.to_sym] || env[key]
        version = options[:version] || env["SDK_VERSION"] || version unless batch
        if batch && name != "HXSDK" && version.to_s.strip.empty?
          @skipped_projects << name
          next
        end
        raise Error, "#{name} 缺少有效版本 (#{key})，格式必须为 X.Y.Z，无 v 前缀" unless /\A\d+\.\d+\.\d+\z/.match?(version.to_s)

        versions[name] = version
      end
      raise Error, "adapters 模式至少填写一个适配器版本" if @versions.empty?
      @sdk_version = @versions["HXSDK"] || options[:hx_sdk_version] || env["HXSDK_VERSION"]
      raise Error, "必须填写 HXSDK tag (hx_sdk_version / HXSDK_VERSION)，格式为 X.Y.Z" unless /\A\d+\.\d+\.\d+\z/.match?(@sdk_version.to_s)
    end
  end

  class Commands
    def run(*args, chdir: nil)
      puts "+ #{Shellwords.join(args)}"
      options = chdir ? { chdir: chdir } : {}
      raise Error, "命令执行失败: #{args.first}" unless system(*args, **options)
    end

    def capture(*args, chdir: nil)
      options = chdir ? { chdir: chdir } : {}
      output, status = Open3.capture2e(*args, **options)
      raise Error, "命令执行失败: #{args.first}\n#{output}" unless status.success?

      output.strip
    end

    def tag_exists?(repo, version)
      output, status = Open3.capture2e("git", "ls-remote", "--exit-code", repo, "refs/tags/#{version}")
      return true if status.success?
      return false if status.exitstatus == 2

      raise Error, "无法查询远程 tag: #{output}"
    end
  end

  def self.remote_spec(name, version)
    hash = Digest::MD5.hexdigest(name)
    fetch_remote_spec("https://cdn.cocoapods.org/Specs/#{hash[0]}/#{hash[1]}/#{hash[2]}/#{name}/#{version}/#{name}.podspec.json")
  end

  def self.trunk_spec(name, version)
    fetch_remote_spec("https://trunk.cocoapods.org/api/v1/pods/#{name}/specs/#{version}")
  end

  def self.cdn_ready?(name, version)
    shard = Digest::MD5.hexdigest(name)[0, 3].chars.join("_")
    index = fetch_https("https://cdn.cocoapods.org/all_pods_versions_#{shard}.txt")
    indexed = index.to_s.each_line.any? do |row|
      pod, *versions = row.strip.split("/")
      pod == name && versions.include?(version)
    end
    indexed && !remote_spec(name, version).nil?
  end

  def self.fetch_remote_spec(url)
    body = fetch_https(url)
    JSON.parse(body) if body
  end

  # Only a 404 means the requested resource is missing.
  def self.fetch_https(url, redirects = 5)
    uri = URI(url)
    raise Error, "无效的 Specs HTTPS 地址" unless uri.scheme == "https"

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 20, read_timeout: 30) do |http|
      http.get(uri.request_uri)
    end
    case response
    when Net::HTTPSuccess then response.body
    when Net::HTTPNotFound then nil
    when Net::HTTPRedirection
      raise Error, "Specs 重定向过多" if redirects.zero?

      fetch_https(URI.join(url, response.fetch("location")).to_s, redirects - 1)
    else
      raise Error, "查询 CocoaPods 发布索引失败: HTTP #{response.code}"
    end
  end

  private_class_method :fetch_remote_spec, :fetch_https

  def self.assert_same_spec!(expected, actual)
    raise Error, "已发布的同名版本内容不同，禁止覆盖" unless expected == actual
  end

  def self.update_version(path, version)
    content = File.read(path)
    pattern = /^(\s*s\.version\s*=\s*)(['"])[^'"]+\2/
    raise Error, "podspec 必须有且只有一个 s.version" unless content.scan(pattern).size == 1

    File.write(path, content.sub(pattern) { "#{Regexp.last_match(1)}'#{version}'" })
  end

  class Runner
    TRUNK_PUSH_ATTEMPTS = 3
    TRUNK_CONFIRMATION_DELAYS = [0, 5, 10].freeze

    def initialize(request, commands: Commands.new, env: ENV, registry: SDKRelease.method(:remote_spec),
                   trunk_confirmation: SDKRelease.method(:trunk_spec), sleeper: Kernel.method(:sleep),
                   cdn_ready: SDKRelease.method(:cdn_ready?))
      @request, @commands, @env, @registry = request, commands, env, registry
      @trunk_confirmation, @sleeper, @cdn_ready = trunk_confirmation, sleeper, cdn_ready
      @results = []
      @linted = {}
      @output = File.expand_path(env.fetch("SDK_OUTPUT_DIR", "sdk-release-output"))
      @tools = File.expand_path("../..", __dir__)
    end

    def run
      FileUtils.mkdir_p(@output)
      if !@request.dry_run && @request.target == "both" && @env["COCOAPODS_TRUNK_TOKEN"].to_s.empty?
        raise Error, "缺少 COCOAPODS_TRUNK_TOKEN"
      end
      Dir.mktmpdir("sdk-release-") do |work|
        @work = work
        setup_specs
        prepare_sdk_dependency unless @request.versions.key?("HXSDK")
        @request.versions.each do |name, version|
          @stage = "prepare"
          begin
            root = name == "HXSDK" ? prepare_core(version) : prepare_adapter(name, version)
            spec = read_spec(File.join(root, "#{name}.podspec"))
            validate_spec!(spec, name, version)
            @stage = "validate"
            lint(root, name) unless @linted[name]
            if name == "HXSDK"
              @core_spec = File.join(root, "HXSDK.podspec")
              @preview_core = @request.dry_run && @linted[name]
              @sdk_sha = git(root, "rev-parse", "HEAD", capture: true) unless @preview_core
            end
            publish(root, name, version, spec)
            break if name == "HXSDK" && @results.any? { |r| r[:project] == name && r[:status] == "failed" }
          rescue StandardError => e
            @results << { project: name, version: version, stage: @stage, status: "failed", message: e.message }
            # A failed core build must not let a batch appear to test the new SDK.
            break if name == "HXSDK"
          end
        end
      end
      raise Error, "存在失败或未完成的发布，查看 results.json；成功的目标可在重跑时跳过" if @results.any? { |r| r[:status] == "failed" }
    rescue StandardError => e
      @results << { project: "release", version: "-", stage: "setup", status: "failed", message: e.message } unless @results.any? { |r| r[:status] == "failed" }
      raise
    ensure
      (@request.versions.keys - @results.map { |r| r[:project] }).each do |name|
        @results << { project: name, version: @request.versions.fetch(name), stage: "prepare", status: "blocked", message: "前置步骤失败，未发布" }
      end
      @request.skipped_projects.each do |name|
        @results << { project: name, version: "-", stage: "prepare", status: "skipped", message: "未填写适配器版本" }
      end
      write_results
    end

    private

    def pod(*args, chdir: nil, capture: false)
      @commands.public_send(capture ? :capture : :run, "bundle", "exec", "pod", *args, chdir: chdir)
    end

    def git(root, *args, capture: false)
      @commands.public_send(capture ? :capture : :run, "git", "-C", root, *args)
    end

    def repo_url(name)
      "https://gitee.com/#{PROJECTS.fetch(name).first}.git"
    end

    def clone_tag(repo, version, destination)
      FileUtils.mkdir_p(File.dirname(destination))
      @commands.run("git", "clone", "--quiet", "--no-checkout", repo, destination)
      git(destination, "fetch", "--quiet", "origin", "refs/tags/#{version}")
      git(destination, "checkout", "--quiet", "--detach", "FETCH_HEAD")
      destination
    end

    def setup_specs
      # Use a per-run repo so concurrent local jobs never modify each other's Specs.
      @repo_name = "hxsdk-release-#{Process.pid}-#{File.basename(@work)}"
      pod("repo", "add", @repo_name, SPECS_URL, "main")
      repos = @env.fetch("CP_REPOS_DIR", File.join(@env.fetch("CP_HOME_DIR", File.expand_path("~/.cocoapods")), "repos"))
      @specs_root = File.join(repos, @repo_name)
      git(@specs_root, "remote", "set-url", "--push", "origin", SPECS_PUSH_URL)
      git(@specs_root, "config", "user.name", "github-actions")
      git(@specs_root, "config", "user.email", "github-actions@users.noreply.github.com")
    end

    def indexed_spec(name, version)
      path = File.join(@specs_root, name, version, "#{name}.podspec")
      path += ".json" if !File.file?(path) && File.file?("#{path}.json")
      File.file?(path) ? read_spec(path) : nil
    end

    def prepare_sdk_dependency
      root = clone_tag(repo_url("HXSDK"), @request.sdk_version, File.join(@work, "dependency", "HXSDK"))
      @core_spec = File.join(root, "HXSDK.podspec")
      expected = read_spec(@core_spec)
      validate_spec!(expected, "HXSDK", @request.sdk_version)
      @sdk_sha = git(root, "rev-parse", "HEAD", capture: true)
      actual = indexed_spec("HXSDK", @request.sdk_version)
      raise Error, "HXSDK #{@request.sdk_version} 尚未发布到 Specs" unless actual

      SDKRelease.assert_same_spec!(expected, actual)
      if @request.target == "both"
        actual = @registry.call("HXSDK", @request.sdk_version)
        raise Error, "HXSDK #{@request.sdk_version} 尚未发布到 Trunk" unless actual

        SDKRelease.assert_same_spec!(expected, actual)
      end
    end

    def validate_adapter_dependency!(spec)
      expected = ["~> #{@request.sdk_version}"]
      raise Error, "适配器的 HXSDK 依赖必须为 #{expected.first}，已有 tag 禁止覆盖" unless spec.dig("dependencies", "HXSDK") == expected
    end

    def prepare_adapter(name, version)
      root = File.join(@work, name)
      if @commands.tag_exists?(repo_url(name), version)
        clone_tag(repo_url(name), version, root)
        spec = read_spec(File.join(root, "#{name}.podspec"))
        validate_spec!(spec, name, version)
        validate_adapter_dependency!(spec)
        recorded_sha = git(root, "log", "-1", "--format=%B", capture: true)[/^HXSDK-Dependency-SHA: (.+)$/, 1]
        raise Error, "已有 tag 记录的 HXSDK 提交与所选 tag 不匹配" if recorded_sha && @sdk_sha && recorded_sha != @sdk_sha

        return root
      end

      @commands.run("git", "clone", "--quiet", "--branch", "main", "--single-branch", repo_url(name), root)
      current = read_spec(File.join(root, "#{name}.podspec"))
      validate_spec!(current, name, current.fetch("version"))
      raise Error, "#{name} 新版本必须高于 main 当前版本 #{current['version']}" unless Gem::Version.new(version) > Gem::Version.new(current.fetch("version"))

      base = git(root, "rev-parse", "HEAD", capture: true)
      paths = AdapterRelease.prepare(root: root, name: name, version: version, sdk_version: @request.sdk_version)
      spec = read_spec(File.join(root, "#{name}.podspec"))
      validate_spec!(spec, name, version)
      validate_adapter_dependency!(spec)
      example = File.join(root, AdapterRelease::EXAMPLES.fetch(name))
      @stage = "resolve"
      resolve = -> { pod("update", name, "HXSDK", "--no-repo-update", chdir: example) }
      if @preview_core
        puts "dry_run: 示例临时使用本次本地 HXSDK 产物，预览锁文件不会提交"
        AdapterRelease.with_preview_sdk(File.join(example, "Podfile"), File.dirname(@core_spec), &resolve)
      else
        resolve.call
      end
      raise Error, "示例依赖解析未生成 Podfile.lock" unless File.file?(File.join(example, "Podfile.lock"))

      @stage = "validate"
      lint(root, name)
      @linted[name] = true
      unless @request.dry_run
        @stage = "push"
        message = "release: v#{version}\n\nHXSDK-Dependency-Tag: #{@request.sdk_version}\nHXSDK-Dependency-SHA: #{@sdk_sha}\nAdapter-Base-SHA: #{base}"
        commit_release(root, name, version, paths, message)
      end
      root
    end

    def commit_release(root, name, version, paths, message)
      git(root, "config", "user.name", "github-actions")
      git(root, "config", "user.email", "github-actions@users.noreply.github.com")
      git(root, "add", "--", *paths)
      git(root, "commit", "-m", message)
      git(root, "tag", "-a", version, "-m", message)
      git(root, "push", "--atomic", "git@gitee.com:#{PROJECTS.fetch(name).first}.git", "HEAD:refs/heads/main", "refs/tags/#{version}")
    end

    def prepare_core(version)
      source = clone_tag(@env.fetch("HXSDK_SOURCE_REPO", SOURCE_URL), version, File.join(@work, "source"))
      sha = git(source, "rev-parse", "HEAD", capture: true)
      sdk_source = File.read(File.join(source, "HXSDK/Classes/Public/HXSDK.m"))
      runtime_version = sdk_source[/\+\s*\(NSString\s*\*\)\s*getSDKVersion\s*\{\s*return\s*@"([^"]+)"\s*;/m, 1]
      raise Error, "源码 tag 的 getSDKVersion 必须为 #{version}，请在打 tag 前修改" unless runtime_version == version

      destination = File.join(@work, "HXSDK")
      if @commands.tag_exists?(repo_url("HXSDK"), version)
        clone_tag(repo_url("HXSDK"), version, destination)
        provenance = git(destination, "log", "-1", "--format=%B", capture: true)
        raise Error, "已有产物 tag 缺少匹配的源码提交记录，禁止覆盖" unless provenance.lines.map(&:strip).include?("HXSDK-Source-SHA: #{sha}")

        return destination
      end

      git(source, "submodule", "update", "--init", "HXSDK-iOS")
      pinned = git(source, "rev-parse", "HEAD:HXSDK-iOS", capture: true)
      @commands.run("git", "clone", "--quiet", "--branch", "main", "--single-branch", repo_url("HXSDK"), destination)
      base = git(destination, "rev-parse", "HEAD", capture: true)
      raise Error, "源码 tag 引用的 HXSDK-iOS 不是发布 main 的最新提交，请同步子模块后重新准备源码版本" unless base == pinned

      pod("install", "--deployment", chdir: File.join(source, "Example"))
      @commands.run("bash", File.join(@tools, "scripts/build_hxsdk.sh"), source, @output, version)
      FileUtils.rm_rf(File.join(destination, "HXSDK.framework"))
      FileUtils.cp_r(File.join(@output, "HXSDK.framework"), destination)
      SDKRelease.update_version(File.join(destination, "HXSDK.podspec"), version)
      readme = File.join(destination, "README.md")
      File.write(readme, File.read(readme).gsub(/(pod\s+'HXSDK(?:\/[^']+)?',\s*')\d+\.\d+\.\d+(')/) { "#{Regexp.last_match(1)}#{version}#{Regexp.last_match(2)}" }) if File.file?(readme)
      example = File.join(destination, "HXSDK-iOS-Example")
      # Resolve the example against the local new podspec, keeping its lockfile in
      # the same release commit as the framework and version documentation.
      pod("install", chdir: example) if File.file?(File.join(example, "Podfile"))
      validate_spec!(read_spec(File.join(destination, "HXSDK.podspec")), "HXSDK", version)
      lint(destination, "HXSDK")
      @linted["HXSDK"] = true
      unless @request.dry_run
        paths = ["HXSDK.framework", "HXSDK.podspec", "README.md", "HXSDK-iOS-Example/Podfile.lock"].select { |path| File.exist?(File.join(destination, path)) }
        @stage = "push"
        commit_release(destination, "HXSDK", version, paths, "release: v#{version}\n\nHXSDK-Source-SHA: #{sha}")
      end
      destination
    end

    def read_spec(path)
      JSON.parse(pod("ipc", "spec", path, capture: true))
    end

    def validate_spec!(spec, name, version)
      raise Error, "podspec 名称或版本与请求不一致" unless spec["name"] == name && spec["version"] == version
      raise Error, "podspec source 必须指向该项目和同名 tag" unless spec.dig("source", "git") == repo_url(name) && spec.dig("source", "tag") == version
    end

    def lint(root, name)
      args = ["lib", "lint", "#{name}.podspec", "--allow-warnings", "--skip-import-validation", "--platforms=ios", "--sources=#{SPECS_URL},https://cdn.cocoapods.org/"]
      args << "--include-podspecs=#{@core_spec}" if @core_spec && name != "HXSDK"
      pod(*args, chdir: root)
    end

    def publish(root, name, version, spec)
      record = ->(target, status, message = nil) { @results << { project: name, version: version, stage: target, status: status, message: message } }
      targets = @request.target == "both" ? %w[specs trunk] : ["specs"]
      targets.each do |target|
        begin
          existing = target == "specs" ? indexed_spec(name, version) : @registry.call(name, version)
          if existing
            SDKRelease.assert_same_spec!(spec, existing)
            record.call(target, "already_published")
          elsif @request.dry_run
            record.call(target, "dry_run")
          elsif target == "specs"
            pod("repo", "push", @repo_name, "#{name}.podspec", "--allow-warnings", "--skip-import-validation", "--no-overwrite", "--sources=#{SPECS_URL},https://cdn.cocoapods.org/", chdir: root)
            record.call(target, "published")
          else
            raise Error, "缺少 COCOAPODS_TRUNK_TOKEN" if @env["COCOAPODS_TRUNK_TOKEN"].to_s.empty?

            record.call(target, "published", push_trunk(root, name, version, spec))
          end
        rescue StandardError => e
          record.call(target, "failed", e.message)
        end
      end
    end

    def sdk_requires_trunk_sync?
      # Fetching a podspec by URL can succeed before the CDN version index
      # includes it. The adapter validator needs both to resolve HXSDK.
      @sdk_visible_on_cdn ||= @cdn_ready.call("HXSDK", @request.sdk_version)
      return false if @sdk_visible_on_cdn

      puts "CocoaPods CDN 尚未收录 HXSDK #{@request.sdk_version}，本次适配器校验使用 Git Specs"
      true
    rescue StandardError => e
      puts "无法确认 CocoaPods CDN 已收录 HXSDK #{@request.sdk_version}，本次适配器校验使用 Git Specs：#{e.message}"
      true
    end

    def push_trunk(root, name, version, spec)
      args = ["trunk", "push", "#{name}.podspec", "--allow-warnings", "--skip-import-validation"]
      args << "--synchronous" if name != "HXSDK" && sdk_requires_trunk_sync?
      TRUNK_PUSH_ATTEMPTS.times do |index|
        puts "Trunk 发布 #{name} #{version}（#{index + 1}/#{TRUNK_PUSH_ATTEMPTS}）"
        begin
          pod(*args, chdir: root)
          return nil
        rescue Error => push_error
          puts "Trunk 发布命令失败：#{push_error.message}"
        end

        # A failed push may already have published. Only a confirmed absence
        # permits another push; lookup errors must not be treated as absence.
        actual = confirm_trunk(name, version, push_error)
        if actual
          raise Error, "#{push_error.message}；Trunk 已有同名版本，但 podspec 内容不同" unless spec == actual

          message = "Trunk 推送命令报错，但已复查确认 #{name} #{version} 的 podspec 已发布且内容一致"
          puts message
          return message
        end
        if index + 1 < TRUNK_PUSH_ATTEMPTS
          puts "Trunk 未查到 #{name} #{version}，立即重试发布"
        else
          raise Error, "#{push_error.message}；已尝试发布 #{TRUNK_PUSH_ATTEMPTS} 次，未查到 #{name} #{version}"
        end
      end
    end

    def confirm_trunk(name, version, push_error)
      lookup_error = nil
      TRUNK_CONFIRMATION_DELAYS.each_with_index do |delay, index|
        puts "Trunk 复查 #{name} #{version}（#{index + 1}/#{TRUNK_CONFIRMATION_DELAYS.size}）：等待 #{delay} 秒后查询"
        @sleeper.call(delay) if delay.positive?
        begin
          return @trunk_confirmation.call(name, version)
        rescue StandardError => e
          lookup_error = e
          puts "Trunk 复查查询失败：#{e.message}"
        end
      end
      raise Error, "#{push_error.message}；已复查 #{TRUNK_CONFIRMATION_DELAYS.size} 次，未能确认 Trunk 发布：#{lookup_error.message}"
    end

    def write_results
      FileUtils.mkdir_p(@output)
      File.write(File.join(@output, "results.json"), JSON.pretty_generate(@results))
      rows = @results.map { |r| "| #{r[:project]} | #{r[:version]} | #{r[:stage]} | #{r[:status]} |" }
      summary = ["### SDK 发布结果", "", "| Pod | 版本 | 目标/阶段 | 结果 |", "| --- | --- | --- | --- |", *rows, ""].join("\n")
      puts summary
      File.open(@env["GITHUB_STEP_SUMMARY"], "a") { |f| f.puts(summary) } if @env["GITHUB_STEP_SUMMARY"]
      # Only the unique Specs clone created by this run is removed.
      FileUtils.rm_rf(@specs_root) if @specs_root && File.directory?(@specs_root)
    end
  end
end
