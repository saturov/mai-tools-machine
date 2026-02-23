#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "yaml"

require_relative "../skills/request-router/request_router"
require_relative "../skills/gap-detector/gap_detector"
require_relative "../skills/workflow-executor/workflow_executor"

class WorkflowExecutorTest < Minitest::Test
  def registry_path
    File.expand_path("../state/registry-cache.json", __dir__)
  end

  def example_request
    request_path = File.expand_path("../templates/workflow/request.example.yaml", __dir__)
    YAML.safe_load(File.read(request_path))
  end

  def test_dry_run_builds_expected_argv_for_steps
    request = example_request
    plan = RequestRouter.build_plan(request, now: Time.utc(2026, 2, 17, 0, 0, 0))
    GapDetector.apply!(plan, registry_path: registry_path)
    assert_equal "complete", plan["status"]

    registry = ToolRegistry.load_registry!(registry_path)
    by_id = registry.dig("index", "by_id")

    step1 = plan["steps"][0]
    tool1 = by_id.fetch(step1["tool"])
    res1 = WorkflowExecutor.execute_step!(
      step1,
      tool1,
      request_inputs: request.fetch("inputs").transform_keys(&:to_s),
      step_outputs: {},
      dry_run: true
    )
    assert_equal "dry-run", res1["status"]
    assert_includes res1["argv"][0], "run.sh"
    assert_equal request.dig("inputs", "youtube_url"), res1["argv"][1]

    step2 = plan["steps"][1]
    tool2 = by_id.fetch(step2["tool"])
    res2 = WorkflowExecutor.execute_step!(
      step2,
      tool2,
      request_inputs: request.fetch("inputs").transform_keys(&:to_s),
      step_outputs: {},
      dry_run: true
    )
    assert_equal "dry-run", res2["status"]

    argv2 = res2["argv"]
    assert_equal "--file-path", argv2[1]
    assert_equal "steps.step-1.outputs.file_path", argv2[2]
    assert_equal "--folder-id", argv2[3]
    assert_equal request.dig("inputs", "drive_folder_id"), argv2[4]
  end

  def test_dry_run_builds_expected_argv_for_video_convert
    text = "Сконвертируй файлы intro.webm и outro.webm в mp4"
    request = RequestRouter.build_request_from_text(text, now: Time.utc(2026, 2, 21, 0, 0, 0))
    plan = RequestRouter.build_plan(request, now: Time.utc(2026, 2, 21, 0, 0, 0))
    GapDetector.apply!(plan, registry_path: registry_path)
    assert_equal "complete", plan["status"]

    registry = ToolRegistry.load_registry!(registry_path)
    by_id = registry.dig("index", "by_id")
    step = plan["steps"][0]
    tool = by_id.fetch(step["tool"])

    res = WorkflowExecutor.execute_step!(
      step,
      tool,
      request_inputs: request.fetch("inputs").transform_keys(&:to_s),
      step_outputs: {},
      dry_run: true
    )

    assert_equal "dry-run", res["status"]
    argv = res["argv"]
    assert_equal "./run.sh", argv[0]
    assert_equal "--mode", argv[1]
    assert_equal "selected", argv[2]
    assert_includes argv, "--input-dir"
    assert_includes argv, "input_data"
    assert_includes argv, "--output-dir"
    assert_includes argv, "output_data"
    assert_equal 2, argv.count("--file")
    assert_includes argv, "intro.webm"
    assert_includes argv, "outro.webm"
  end

  def test_dry_run_builds_expected_argv_for_youtube_options
    registry = ToolRegistry.load_registry!(registry_path)
    by_id = registry.dig("index", "by_id")
    youtube_tool_id = registry.dig("index", "by_capability", "youtube.download").first
    tool = by_id.fetch(youtube_tool_id)

    step = {
      "step_id" => "step-1",
      "capability" => "youtube.download",
      "inputs" => {
        "url" => "https://youtu.be/abc123",
        "cookies_from_browser" => "chrome",
        "target_quality" => 1080,
        "min_height" => 720,
        "quality_policy" => "strict",
        "player_clients" => %w[web android],
      },
    }

    res = WorkflowExecutor.execute_step!(
      step,
      tool,
      request_inputs: {},
      step_outputs: {},
      dry_run: true
    )

    argv = res["argv"]
    assert_equal "dry-run", res["status"]
    assert_equal "./run.sh", argv[0]
    assert_equal "https://youtu.be/abc123", argv[1]
    assert_includes argv, "--cookies-from-browser"
    assert_includes argv, "chrome"
    assert_includes argv, "--target-quality"
    assert_includes argv, "1080"
    assert_includes argv, "--min-height"
    assert_includes argv, "720"
    assert_includes argv, "--quality-policy"
    assert_includes argv, "strict"
    assert_equal 2, argv.count("--player-client")
    assert_includes argv, "web"
    assert_includes argv, "android"
  end

  def test_run_plan_raises_execution_failed_with_progress
    request = example_request
    plan = RequestRouter.build_plan(request, now: Time.utc(2026, 2, 17, 0, 0, 0))
    GapDetector.apply!(plan, registry_path: registry_path)
    assert_equal "complete", plan["status"]

    singleton = WorkflowExecutor.singleton_class
    singleton.send(:alias_method, :__orig_execute_step_for_test, :execute_step!)
    call_idx = 0
    singleton.send(:define_method, :execute_step!) do |step, tool, **_opts|
      call_idx += 1
      if call_idx == 1
        {
          "step_id" => step["step_id"],
          "capability" => step["capability"],
          "tool" => tool["id"],
          "status" => "ok",
          "outputs" => { "file_path" => "/tmp/f.mp4" },
        }
      else
        raise WorkflowExecutor::ExecutionError.new("failed on second step", code: "tool_failed")
      end
    end

    error = assert_raises(WorkflowExecutor::ExecutionFailed) do
      WorkflowExecutor.run_plan!(plan, request, registry_path: registry_path, runs_dir: Dir.tmpdir, dry_run: false)
    end
    assert_equal "step-2", error.failed_step_id
    assert_equal "drive.upload", error.failed_capability
    assert_equal 1, error.executed_steps.length
    assert_equal "step-1", error.executed_steps.first["step_id"]
    assert_equal "step-2", error.remaining_steps.first["step_id"]
  ensure
    singleton.send(:alias_method, :execute_step!, :__orig_execute_step_for_test)
    singleton.send(:remove_method, :__orig_execute_step_for_test)
  end
end
