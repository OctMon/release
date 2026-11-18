# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "open3"
require "shellwords"
require "tmpdir"
require "digest"

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
    attr_reader :versions, :target, :dry_run

    def initialize(options = {}, env = ENV)
      project = options[:project] || env.fetch("SDK_PROJECT", "HXSDK")
      raise Error, "未知项目: #{project}" unless project == "all" || PROJECTS.key?(project)

      @target = options[:target] || env.fetch("POD_TARGET", "both")
      raise Error, "target 必须为 both 或 specs" unless %w[both specs].include?(@target)

      dry = options.fetch(:dry_run) { env.fetch("SDK_DRY_RUN", "true") }
      raise Error, "dry_run 必须为 true 或 false" unless [true, false, "true", "false"].include?(dry)

      @dry_run = dry.to_s == "true"
      names = project == "all" ? PROJECTS.keys : [project]
      @versions = names.to_h do |name|
        key = PROJECTS.fetch(name).last
        version = options[key.downcase.to_sym] || env[key]
        version = options[:version] || env["SDK_VERSION"] || version if project != "all"
        raise Error, "#{name} 缺少有效版本 (#{key})，格式必须为 X.Y.Z，无 v 前缀" unless /\A\d+\.\d+\.\d+\z/.match?(version.to_s)

        [name, version]
      end
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

  # A missing version is different from an unavailable registry: network errors must
  # never be treated as permission to publish or to skip an existing version.
  def self.remote_spec(name, version, url = nil, redirects = 5)
    hash = Digest::MD5.hexdigest(name)
    url ||= "https://cdn.cocoapods.org/Specs/#{hash[0]}/#{hash[1]}/#{hash[2]}/#{name}/#{version}/#{name}.podspec.json"
    uri = URI(url)
    raise Error, "无效的 Specs HTTPS 地址" unless uri.scheme == "https"

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 20, read_timeout: 30) do |http|
      http.get(uri.request_uri)
    end
    case response
    when Net::HTTPSuccess then JSON.parse(response.body)
    when Net::HTTPNotFound then nil
    when Net::HTTPRedirection
      raise Error, "Specs 重定向过多" if redirects.zero?

      remote_spec(name, version, URI.join(url, response.fetch("location")).to_s, redirects - 1)
    else
      raise Error, "查询 Trunk 已发布版本失败: HTTP #{response.code}"
    end
  end

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
    def initialize(request, commands: Commands.new, env: ENV, registry: SDKRelease.method(:remote_spec))
      @request, @commands, @env, @registry = request, commands, env, registry
      @results = []
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
        @request.versions.each do |name, version|
          begin
            root = name == "HXSDK" ? prepare_core(version) : clone_tag(repo_url(name), version, File.join(work, name))
            spec = read_spec(File.join(root, "#{name}.podspec"))
            validate_spec!(spec, name, version)
            lint(root, name) unless name == "HXSDK" && @core_linted
            @core_spec = File.join(root, "HXSDK.podspec") if name == "HXSDK"
            publish(root, name, version, spec)
          rescue StandardError => e
            @results << { project: name, version: version, stage: "prepare", status: "failed", message: e.message }
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
      @core_linted = true
      unless @request.dry_run
        git(destination, "config", "user.name", "github-actions")
        git(destination, "config", "user.email", "github-actions@users.noreply.github.com")
        paths = ["HXSDK.framework", "HXSDK.podspec", "README.md", "HXSDK-iOS-Example/Podfile.lock"].select { |path| File.exist?(File.join(destination, path)) }
        git(destination, "add", "--", *paths)
        git(destination, "commit", "-m", "release: v#{version}\n\nHXSDK-Source-SHA: #{sha}")
        git(destination, "tag", "-a", version, "-m", "HXSDK #{version}\nSource: #{sha}")
        # Atomic refs prevent a branch-only or tag-only release on a failed push.
        git(destination, "push", "--atomic", "git@gitee.com:#{PROJECTS.fetch('HXSDK').first}.git", "HEAD:refs/heads/main", "refs/tags/#{version}")
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
      specs_file = File.join(@specs_root, name, version, "#{name}.podspec")
      specs_file += ".json" if !File.file?(specs_file) && File.file?("#{specs_file}.json")
      targets = @request.target == "both" ? %w[specs trunk] : ["specs"]
      targets.each do |target|
        begin
          existing = target == "specs" ? (File.file?(specs_file) ? read_spec(specs_file) : nil) : @registry.call(name, version)
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

            pod("trunk", "push", "#{name}.podspec", "--allow-warnings", "--skip-import-validation", "--synchronous", chdir: root)
            record.call(target, "published")
          end
        rescue StandardError => e
          record.call(target, "failed", e.message)
        end
      end
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
