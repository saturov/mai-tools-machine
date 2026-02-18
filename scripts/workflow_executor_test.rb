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
