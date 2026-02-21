#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"

require_relative "agent"

class AgentTest < Minitest::Test
  class FakeUnknownPlanner
    def plan_workflow(text:, request:, model: nil)
      {
        "steps" => [
          {
            "capability" => "tg.scrape",
            "coverage_confidence" => 0.9,
            "coverage_rationale" => "extract telegram data",
            "capability_contract" => {
              "input_schema" => {
                "type" => "object",
                "required" => ["url"],
                "additionalProperties" => true,
                "properties" => {
                  "url" => { "type" => "string" },
                },
              },
              "output_schema" => {
                "type" => "object",
                "required" => ["messages"],
                "additionalProperties" => true,
                "properties" => {
                  "messages" => { "type" => "array", "items" => { "type" => "string" } },
                },
              },
            },
            "inputs" => {
              "url" => { "from" => "request.inputs.url" },
            },
          },
        ],
      }
    end
  end

  class FakeLowConfidenceKnownPlanner
    def plan_workflow(text:, request:, model: nil)
      {
        "steps" => [
          {
            "capability" => "drive.upload",
            "coverage_confidence" => 0.3,
            "coverage_rationale" => "unsure if user means Google Drive upload",
            "capability_contract" => {
              "input_schema" => {
                "type" => "object",
                "required" => %w[file_path folder_id],
                "additionalProperties" => true,
                "properties" => {
                  "file_path" => { "type" => "string" },
                  "folder_id" => { "type" => "string" },
                },
              },
              "output_schema" => {
                "type" => "object",
                "required" => %w[file_id file_name],
                "additionalProperties" => true,
                "properties" => {
                  "file_id" => { "type" => "string" },
                  "file_name" => { "type" => "string" },
                },
              },
            },
            "inputs" => {
              "file_path" => { "from" => "request.inputs.file_path" },
              "folder_id" => { "from" => "request.inputs.folder_id" },
            },
          },
        ],
      }
    end
  end

  def registry_path
    File.expand_path("../state/registry-cache.json", __dir__)
  end

  def with_fake_llm(client)
    singleton = Agent.singleton_class
    singleton.send(:alias_method, :__orig_llm_client_for_test, :llm_client_from_settings)
    singleton.send(:define_method, :llm_client_from_settings) { |_settings, llm_log: false| client }
    yield
  ensure
    singleton.send(:alias_method, :llm_client_from_settings, :__orig_llm_client_for_test)
    singleton.send(:remove_method, :__orig_llm_client_for_test)
  end

  def with_workflow_executor_stub(stub_proc)
    singleton = WorkflowExecutor.singleton_class
    singleton.send(:alias_method, :__orig_run_plan_for_test, :run_plan!)
    singleton.send(:define_method, :run_plan!, &stub_proc)
    yield
  ensure
    singleton.send(:alias_method, :run_plan!, :__orig_run_plan_for_test)
    singleton.send(:remove_method, :__orig_run_plan_for_test)
  end

  def test_dry_run_preview_for_supported_rule_path
    Dir.mktmpdir do |dir|
      output = File.join(dir, "out.json")
      code = Agent.run_from_text(
        "Скачай https://www.youtube.com/watch?v=abc и загрузи в https://drive.google.com/drive/folders/folder123",
        execute: false,
        dry_run: true,
        output_format: "json",
        output_path: output,
        config_path: File.join(dir, "missing-agent.yaml"),
        policy_path: File.join(dir, "missing-policy.yaml"),
        provider: nil,
        model: nil,
        registry_path: registry_path,
        runs_dir: dir
      )
      assert_equal 0, code
      payload = JSON.parse(File.read(output))
      assert_equal "preview", payload["status"]
      assert_equal "dry-run", payload.dig("run", "status")
    end
  end

  def test_dry_run_preview_for_video_convert_rule_path
    Dir.mktmpdir do |dir|
      output = File.join(dir, "out.json")
      code = Agent.run_from_text(
        "Сконвертируй все webm из input_data в mp4",
        execute: false,
        dry_run: true,
        output_format: "json",
        output_path: output,
        config_path: File.join(dir, "missing-agent.yaml"),
        policy_path: File.join(dir, "missing-policy.yaml"),
        provider: nil,
        model: nil,
        registry_path: registry_path,
        runs_dir: dir
      )
      assert_equal 0, code
      payload = JSON.parse(File.read(output))
      assert_equal "preview", payload["status"]
      assert_equal "video.convert", payload.dig("plan", "steps", 0, "capability")
      assert_equal "all", payload.dig("plan", "steps", 0, "inputs", "mode")
      assert_equal "dry-run", payload.dig("run", "status")
    end
  end

  def test_blocks_when_policy_denies_capability
    Dir.mktmpdir do |dir|
      output = File.join(dir, "out.json")
      policy_path = File.join(dir, "policy.yaml")
      File.write(policy_path, <<~YAML)
        allowed_capabilities:
          - youtube.download
        denied_capabilities:
          - youtube.download
      YAML

      code = Agent.run_from_text(
        "Скачай https://www.youtube.com/watch?v=abc",
        execute: true,
        dry_run: false,
        output_format: "json",
        output_path: output,
        config_path: File.join(dir, "missing-agent.yaml"),
        policy_path: policy_path,
        provider: nil,
        model: nil,
        registry_path: registry_path,
        runs_dir: dir
      )
      assert_equal 4, code
      payload = JSON.parse(File.read(output))
      assert_equal "blocked_by_policy", payload["status"]
    end
  end

  def test_partial_complete_for_unknown_capability_from_llm_fallback
    Dir.mktmpdir do |dir|
      output = File.join(dir, "out.json")
      policy_path = File.join(dir, "policy.yaml")
      File.write(policy_path, <<~YAML)
        allowed_capabilities: []
        denied_capabilities: []
      YAML
      with_fake_llm(FakeUnknownPlanner.new) do
        code = Agent.run_from_text(
          "Сделай анализ Telegram канала",
          execute: false,
          dry_run: true,
          output_format: "json",
          output_path: output,
          config_path: File.join(dir, "missing-agent.yaml"),
          policy_path: policy_path,
          provider: nil,
          model: nil,
          registry_path: registry_path,
          runs_dir: dir
        )
        assert_equal 0, code
      end
      payload = JSON.parse(File.read(output))
      assert_equal "partial", payload["status"]
      assert_equal "tg.scrape", payload.dig("plan", "gap_report", 0, "missing_capability")
    end
  end

  def test_unroutable_error_explains_missing_llm_for_free_form_text
    Dir.mktmpdir do |dir|
      output = File.join(dir, "out.json")
      code = Agent.run_from_text(
        "Сделай краткий план автоматизации для отправки отчетов клиентам",
        execute: false,
        dry_run: true,
        output_format: "json",
        output_path: output,
        config_path: File.join(dir, "missing-agent.yaml"),
        policy_path: File.join(dir, "missing-policy.yaml"),
        provider: nil,
        model: nil,
        registry_path: registry_path,
        runs_dir: dir
      )
      assert_equal 3, code
      payload = JSON.parse(File.read(output))
      assert_equal "unroutable", payload["status"]
      assert_equal "routing_error_no_llm", payload.dig("error", "code")
      assert_includes payload.dig("error", "message"), "AGENT_API_KEY"
    end
  end

  def test_partial_complete_for_low_confidence_llm_capability
    Dir.mktmpdir do |dir|
      output = File.join(dir, "out.json")
      policy_path = File.join(dir, "policy.yaml")
      File.write(policy_path, <<~YAML)
        allowed_capabilities: []
        denied_capabilities: []
      YAML
      with_fake_llm(FakeLowConfidenceKnownPlanner.new) do
        code = Agent.run_from_text(
          "Загрузи локальный файл /tmp/a.mp4 в папку folder-123",
          execute: true,
          dry_run: false,
          output_format: "json",
          output_path: output,
          config_path: File.join(dir, "missing-agent.yaml"),
          policy_path: policy_path,
          provider: nil,
          model: nil,
          registry_path: registry_path,
          runs_dir: dir
        )
        assert_equal 2, code
      end
      payload = JSON.parse(File.read(output))
      assert_equal "partial", payload["status"]
      assert_equal "low_confidence", payload.dig("plan", "gap_report", 0, "reason")
      assert_nil payload["run"]
    end
  end

  def test_execute_returns_partial_for_yandex_disk_destination_without_tool
    Dir.mktmpdir do |dir|
      output = File.join(dir, "out.json")
      policy_path = File.join(dir, "policy.yaml")
      File.write(policy_path, <<~YAML)
        allowed_capabilities: []
        denied_capabilities: []
      YAML
      code = Agent.run_from_text(
        "Скачай https://www.youtube.com/watch?v=abc и загрузи в https://disk.yandex.ru/d/CCj7sZ-5f4GG6A",
        execute: true,
        dry_run: false,
        output_format: "json",
        output_path: output,
        config_path: File.join(dir, "missing-agent.yaml"),
        policy_path: policy_path,
        provider: nil,
        model: nil,
        registry_path: registry_path,
        runs_dir: dir
      )

      assert_equal 2, code
      payload = JSON.parse(File.read(output))
      assert_equal "partial", payload["status"]
      assert_equal "yandex.disk.upload", payload.dig("plan", "gap_report", 0, "missing_capability")
      assert_nil payload["run"]
    end
  end

  def test_prints_human_readable_success_report_to_stdout
    Dir.mktmpdir do |dir|
      stdout, _stderr = capture_io do
        code = Agent.run_from_text(
          "Скачай https://www.youtube.com/watch?v=abc и загрузи в https://drive.google.com/drive/folders/folder123",
          execute: false,
          dry_run: true,
          output_format: "pretty",
          output_path: nil,
          config_path: File.join(dir, "missing-agent.yaml"),
          policy_path: File.join(dir, "missing-policy.yaml"),
          provider: nil,
          model: nil,
          registry_path: registry_path,
          runs_dir: dir
        )
        assert_equal 0, code
      end

      assert_includes stdout, "Задача успешно выполнена."
      assert_includes stdout, "✓"
      assert_includes stdout, "step-1 youtube.download"
      assert_includes stdout, "step-2 drive.upload"
      refute_includes stdout, "\"steps\":"
    end
  end

  def test_prints_human_readable_partial_report_to_stdout
    Dir.mktmpdir do |dir|
      policy_path = File.join(dir, "policy.yaml")
      File.write(policy_path, <<~YAML)
        allowed_capabilities: []
        denied_capabilities: []
      YAML
      stdout, _stderr = capture_io do
        code = Agent.run_from_text(
          "Скачай https://www.youtube.com/watch?v=abc и загрузи в https://disk.yandex.ru/d/CCj7sZ-5f4GG6A",
          execute: true,
          dry_run: false,
          output_format: "pretty",
          output_path: nil,
          config_path: File.join(dir, "missing-agent.yaml"),
          policy_path: policy_path,
          provider: nil,
          model: nil,
          registry_path: registry_path,
          runs_dir: dir
        )
        assert_equal 2, code
      end

      assert_includes stdout, "Задача не выполнена."
      assert_includes stdout, "✗"
      assert_includes stdout, "step-2 yandex.disk.upload"
      assert_includes stdout, "Отобранные утилиты:"
      assert_includes stdout, "youtube.download"
      refute_includes stdout, "youtube-downloader@0.1.0"
    end
  end

  def test_returns_execution_failed_payload_and_human_report
    Dir.mktmpdir do |dir|
      policy_path = File.join(dir, "policy.yaml")
      File.write(policy_path, <<~YAML)
        allowed_capabilities: []
        denied_capabilities: []
      YAML
      with_workflow_executor_stub(
        proc do |_plan, _request, **_opts|
          raise WorkflowExecutor::ExecutionFailed.new(
            "Step step-2 failed",
            code: "tool_failed",
            executed_steps: [{ "step_id" => "step-1", "capability" => "youtube.download", "tool" => "youtube-downloader@0.1.0" }],
            failed_step_id: "step-2",
            failed_tool_id: "drive-uploader@0.1.0",
            failed_capability: "drive.upload",
            remaining_steps: [{ "step_id" => "step-2", "capability" => "drive.upload" }]
          )
        end
      ) do
        stdout, _stderr = capture_io do
          code = Agent.run_from_text(
            "Скачай https://www.youtube.com/watch?v=abc и загрузи в https://drive.google.com/drive/folders/folder123",
            execute: true,
            dry_run: false,
            output_format: "pretty",
            output_path: nil,
            config_path: File.join(dir, "missing-agent.yaml"),
            policy_path: policy_path,
            provider: nil,
            model: nil,
            registry_path: registry_path,
            runs_dir: dir
          )
          assert_equal 1, code
        end

        assert_includes stdout, "Задача не выполнена."
        assert_includes stdout, "✓"
        assert_includes stdout, "✗"
        assert_includes stdout, "step-1 youtube.download"
        assert_includes stdout, "step-2 drive.upload"
        assert_includes stdout, "Отобранные утилиты:"
        assert_includes stdout, "youtube.download"
        assert_includes stdout, "drive.upload"
      end
    end
  end
end
