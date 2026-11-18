# frozen_string_literal: true

require "minitest/autorun"
require_relative "../fastlane/lib/sdk_release"

class SDKReleaseTest < Minitest::Test
  VERSION = "1.2.3"

  # Simulates Git, CocoaPods and Xcode without executing any external command.
  class Commands
    attr_reader :calls
    attr_accessor :existing_tag, :provenance, :fail_target, :wrong_version, :existing_spec, :wrong_runtime

    def initialize(env)
      @env, @calls = env, []
      @provenance = "HXSDK-Source-SHA: #{'a' * 40}"
    end

    def run(*args, chdir: nil)
      @calls << args
      if args[0..3] == %w[bundle exec pod repo] && args[4] == "add"
        @specs = File.join(@env.fetch("CP_HOME_DIR"), "repos", args[5])
        FileUtils.mkdir_p(@specs)
        if existing_spec
          path = File.join(@specs, existing_spec.fetch("name"), VERSION)
          FileUtils.mkdir_p(path)
          File.write(File.join(path, "#{existing_spec.fetch('name')}.podspec.json"), JSON.generate(existing_spec))
        end
      elsif args[0..1] == %w[git clone]
        destination = args.last
        FileUtils.mkdir_p(destination)
        if destination.end_with?("/source")
          path = File.join(destination, "HXSDK/Classes/Public")
          FileUtils.mkdir_p(path)
          File.write(File.join(path, "HXSDK.m"), "+ (NSString *)getSDKVersion { return @\"#{wrong_runtime || VERSION}\"; }")
          FileUtils.mkdir_p(File.join(destination, "Example"))
        else
          name = File.basename(destination)
          repo = SDKRelease::PROJECTS.fetch(name).first
          File.write(File.join(destination, "#{name}.podspec"), "s.name = '#{name}'\ns.version = '#{wrong_version || VERSION}'\ns.source = 'https://gitee.com/#{repo}.git'\n")
          File.write(File.join(destination, "README.md"), "pod 'HXSDK', '0.0.1'\n")
          if name == "HXSDK"
            FileUtils.mkdir_p(File.join(destination, "HXSDK-iOS-Example"))
            File.write(File.join(destination, "HXSDK-iOS-Example/Podfile"), "# example")
          end
        end
      elsif args.first == "bash"
        FileUtils.mkdir_p(File.join(args[3], "HXSDK.framework"))
        File.write(File.join(args[3], "HXSDK.framework/HXSDK"), "fake binary")
      elsif args[0..4] == %w[bundle exec pod repo push]
        raise SDKRelease::Error, "Specs rejected" if fail_target == "specs"
      elsif args[0..4] == %w[bundle exec pod trunk push]
        raise SDKRelease::Error, "Trunk read-only" if fail_target == "trunk"
      elsif args[0..3] == %w[bundle exec pod install] && chdir.end_with?("/HXSDK-iOS-Example")
        File.write(File.join(chdir, "Podfile.lock"), "# resolved example")
      end
      true
    end

    def capture(*args, chdir: nil)
      @calls << args
      if args[0..4] == %w[bundle exec pod ipc spec]
        content = File.read(args.last)
        return content if args.last.end_with?(".json")

        name = content[/s.name = '([^']+)'/, 1]
        version = content[/s.version = '([^']+)'/, 1]
        return JSON.generate("name" => name, "version" => version, "source" => { "git" => content[/s.source = '([^']+)'/, 1], "tag" => version })
      end
      return provenance if args.include?("log")
      return "a" * 40 if args.include?("rev-parse") && args[2].end_with?("/source") && args.last == "HEAD"

      "b" * 40
    end

    def tag_exists?(*_args)
      existing_tag
    end
  end

  def setup
    @dir = Dir.mktmpdir("sdk-release-test-")
    @env = { "CP_HOME_DIR" => File.join(@dir, "cp"), "SDK_OUTPUT_DIR" => File.join(@dir, "output"), "COCOAPODS_TRUNK_TOKEN" => "test-token" }
    @commands = Commands.new(@env)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def request(**options)
    SDKRelease::Request.new({ project: "HXGMAdapter", version: VERSION }.merge(options), {})
  end

  def runner(req = request, registry: ->(*) { nil })
    SDKRelease::Runner.new(req, commands: @commands, env: @env, registry: registry)
  end

  def results
    JSON.parse(File.read(File.join(@env.fetch("SDK_OUTPUT_DIR"), "results.json")))
  end

  def spec(name = "HXGMAdapter")
    { "name" => name, "version" => VERSION, "source" => { "git" => "https://gitee.com/#{SDKRelease::PROJECTS.fetch(name).first}.git", "tag" => VERSION } }
  end

  def test_defaults_and_independent_versions
    assert request.dry_run
    assert_equal "both", request.target
    env = SDKRelease::PROJECTS.values.to_h { |_, key| [key, VERSION] }.merge("SDK_PROJECT" => "all")
    assert_equal SDKRelease::PROJECTS.keys, SDKRelease::Request.new({}, env).versions.keys
    env.delete("GM_VERSION")
    assert_raises(SDKRelease::Error) { SDKRelease::Request.new({}, env) }
  end

  def test_rejects_unknown_project_invalid_version_target_and_boolean
    [{ project: "other" }, { version: "v1.2.3" }, { version: "1.2.3; touch x" }, { target: "trunk" }, { dry_run: "yes" }].each do |options|
      assert_raises(SDKRelease::Error) { request(**options) }
    end
  end

  def test_update_only_release_version
    path = File.join(@dir, "SDK.podspec")
    File.write(path, "s.version = '1.0.0'\ns.dependency 'HXSDK', '~> 5.2.9'\n")
    SDKRelease.update_version(path, VERSION)
    assert_includes File.read(path), "s.version = '#{VERSION}'"
    assert_includes File.read(path), "'~> 5.2.9'"
    File.write(path, "# no version\n")
    assert_raises(SDKRelease::Error) { SDKRelease.update_version(path, VERSION) }
  end

  def test_adapter_dry_run_does_not_commit_tag_push_or_publish
    capture_io { runner.run }
    assert_equal %w[dry_run dry_run], results.map { |r| r.fetch("status") }
    refute @commands.calls.any? { |c| c.include?("push") || c.include?("commit") || c.include?("tag") || c.include?("add") && c.first == "git" }
    assert @commands.calls.any? { |c| c.include?("refs/tags/#{VERSION}") }
  end

  def test_specs_only_never_contacts_trunk
    registry = ->(*) { flunk "Specs-only must not query Trunk" }
    capture_io { runner(request(target: "specs", dry_run: false), registry: registry).run }
    assert_equal ["specs"], results.map { |r| r.fetch("stage") }
    assert_equal ["published"], results.map { |r| r.fetch("status") }
  end

  def test_partial_success_is_failed_and_preserves_each_target_status
    @commands.fail_target = "trunk"
    capture_io { assert_raises(SDKRelease::Error) { runner(request(dry_run: false)).run } }
    assert_equal %w[published failed], results.map { |r| r.fetch("status") }
    assert_equal "Trunk read-only", results.last.fetch("message")
  end

  def test_specs_failure_still_attempts_trunk
    @commands.fail_target = "specs"
    capture_io { assert_raises(SDKRelease::Error) { runner(request(dry_run: false)).run } }
    assert_equal %w[failed published], results.map { |r| r.fetch("status") }
  end

  def test_identical_published_versions_are_skipped_on_both_targets
    @commands.existing_spec = spec
    capture_io { runner(request(dry_run: false), registry: ->(*) { spec }).run }
    assert_equal %w[already_published already_published], results.map { |r| r.fetch("status") }
    refute @commands.calls.any? { |c| c.include?("push") }
  end

  def test_different_published_spec_is_never_overwritten
    @commands.existing_spec = spec.merge("summary" => "different")
    capture_io { assert_raises(SDKRelease::Error) { runner(request(target: "specs", dry_run: false)).run } }
    assert_equal "failed", results.first.fetch("status")
    refute @commands.calls.any? { |c| c.include?("push") }
  end

  def test_registry_network_error_is_not_treated_as_a_missing_version
    registry = ->(*) { raise SDKRelease::Error, "timeout" }
    capture_io { assert_raises(SDKRelease::Error) { runner(request(dry_run: false), registry: registry).run } }
    assert_equal "timeout", results.last.fetch("message")
    refute @commands.calls.any? { |c| c.include?("trunk") && c.include?("push") }
  end

  def test_wrong_tag_version_fails_before_any_publication
    @commands.wrong_version = "0.0.1"
    capture_io { assert_raises(SDKRelease::Error) { runner.run } }
    assert_equal "prepare", results.first.fetch("stage")
    refute @commands.calls.any? { |c| c.include?("lint") || c.include?("push") }
  end

  def test_core_build_dry_run_updates_artifact_without_pushing
    capture_io { runner(request(project: "HXSDK")).run }
    assert File.file?(File.join(@env.fetch("SDK_OUTPUT_DIR"), "HXSDK.framework/HXSDK"))
    assert_equal %w[dry_run dry_run], results.map { |r| r.fetch("status") }
    refute @commands.calls.any? { |c| c.include?("commit") || c.include?("push") || c.include?("tag") }
  end

  def test_core_publication_pushes_atomic_refs_and_records_source_commit
    capture_io { runner(request(project: "HXSDK", dry_run: false, target: "specs")).run }
    commit = @commands.calls.find { |c| c.include?("commit") }
    assert_includes commit.last, "HXSDK-Source-SHA: #{'a' * 40}"
    push = @commands.calls.find { |c| c.first == "git" && c.include?("push") }
    assert_includes push, "--atomic"
    assert_includes push, "refs/tags/#{VERSION}"
    staged = @commands.calls.find { |c| c.first == "git" && c.include?("add") }
    assert_includes staged, "HXSDK-iOS-Example/Podfile.lock"
  end

  def test_existing_core_tag_must_match_source_and_is_not_rebuilt
    @commands.existing_tag = true
    capture_io { runner(request(project: "HXSDK")).run }
    refute @commands.calls.any? { |c| c.first == "bash" || c.include?("commit") }
    @commands.provenance = "HXSDK-Source-SHA: unknown"
    capture_io { assert_raises(SDKRelease::Error) { runner(request(project: "HXSDK")).run } }
    assert_equal "failed", results.first.fetch("status")
  end

  def test_wrong_runtime_version_blocks_core_before_build
    @commands.wrong_runtime = "0.0.0"
    capture_io { assert_raises(SDKRelease::Error) { runner(request(project: "HXSDK")).run } }
    refute @commands.calls.any? { |c| c.first == "bash" || c.include?("push") }
  end

  def test_missing_trunk_token_fails_before_preparing_release
    @env.delete("COCOAPODS_TRUNK_TOKEN")
    capture_io { assert_raises(SDKRelease::Error) { runner(request(dry_run: false)).run } }
    assert_empty @commands.calls
  end

  def batch_request
    env = SDKRelease::PROJECTS.values.to_h { |_, key| [key, VERSION] }.merge("SDK_PROJECT" => "all")
    SDKRelease::Request.new({}, env)
  end

  def test_batch_builds_core_first_and_lints_adapters_with_the_new_core
    capture_io { runner(batch_request).run }
    assert_equal SDKRelease::PROJECTS.keys, results.map { |r| r.fetch("project") }.uniq
    assert_equal 10, results.size
    included = @commands.calls.select { |c| c.any? { |arg| arg.start_with?("--include-podspecs=") } }
    assert_equal 4, included.size
    refute @commands.calls.any? { |c| c.include?("commit") || c.include?("push") }
  end

  def test_failed_core_blocks_batch_adapters
    @commands.wrong_runtime = "0.0.0"
    capture_io { assert_raises(SDKRelease::Error) { runner(batch_request).run } }
    assert_equal ["failed", *Array.new(4, "blocked")], results.map { |r| r.fetch("status") }
  end
end
