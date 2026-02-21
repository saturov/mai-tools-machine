#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require_relative "../skills/request-router/request_router"

class RequestRouterTest < Minitest::Test
  class FakeLLM
    def plan_workflow(text:, request:, model: nil)
      {
        "steps" => [
          {
            "capability" => "drive.upload",
            "coverage_confidence" => 0.9,
            "coverage_rationale" => "user asks to upload a file to Drive",
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

  class FakeLegacyRefsLLM
    def plan_workflow(text:, request:, model: nil)
      {
        "steps" => [
          {
            "step_id" => "step-1",
            "capability" => "data.collection",
            "coverage_confidence" => 0.82,
            "coverage_rationale" => "collect source data",
            "capability_contract" => {
              "input_schema" => {
                "type" => "object",
                "required" => ["source"],
                "additionalProperties" => true,
                "properties" => {
                  "source" => { "type" => "string" },
                },
              },
              "output_schema" => {
                "type" => "object",
                "required" => ["data"],
                "additionalProperties" => true,
                "properties" => {
                  "data" => { "type" => "array", "items" => { "type" => "object" } },
                },
              },
            },
            "inputs" => {
              "source" => { "from" => "request.inputs.source" },
            },
          },
          {
            "step_id" => "step-2",
            "capability" => "report.generation",
            "coverage_rationale" => "generate report from collected data",
            "capability_contract" => {
              "input_schema" => {
                "type" => "object",
                "required" => ["data"],
                "additionalProperties" => true,
                "properties" => {
                  "data" => { "type" => "array", "items" => { "type" => "object" } },
                },
              },
              "output_schema" => {
                "type" => "object",
                "required" => ["report"],
                "additionalProperties" => true,
                "properties" => {
                  "report" => { "type" => "string" },
                },
              },
            },
            "inputs" => {
              "data" => { "from" => "step-1.output.data" },
            },
          },
        ],
      }
    end
  end

  def test_routes_youtube_then_drive_from_example_request
    request_path = File.expand_path("../templates/workflow/request.example.yaml", __dir__)
    request = YAML.safe_load(File.read(request_path))
    plan = RequestRouter.build_plan(request, now: Time.utc(2026, 2, 17, 0, 0, 0))

    assert_equal "planned", plan["status"]
    assert_equal 2, plan.fetch("steps").length

    step1 = plan["steps"][0]
    step2 = plan["steps"][1]

    assert_equal "youtube.download", step1["capability"]
    assert_nil step1["tool"]
    assert_equal "rule", step1["planner_source"]
    assert_equal 1.0, step1["coverage_confidence"]
    assert_equal "rule_matched", step1["coverage_rationale"]

    assert_equal "drive.upload", step2["capability"]
    assert_nil step2["tool"]
    assert_equal "rule", step2["planner_source"]
    assert_equal 1.0, step2["coverage_confidence"]
    assert_equal "rule_matched", step2["coverage_rationale"]

    assert_equal "steps.step-1.outputs.file_path", step2.dig("inputs", "file_path", "from")
  end

  def test_routes_from_raw_text_by_extracting_youtube_and_drive
    text = <<~TEXT
      Скачай видео по ссылке https://www.youtube.com/live/igYb8BwMTA4?si=vC85Ed8UaKchTfl2
      и положи его в папку Drive https://drive.google.com/drive/folders/1X_YM9F9s83Ij7qCFvtGMEBehZtxtfsGt.
    TEXT

    plan = RequestRouter.build_plan_from_text(text, now: Time.utc(2026, 2, 17, 0, 0, 0))
    assert_equal 2, plan.fetch("steps").length

    step1 = plan["steps"][0]
    step2 = plan["steps"][1]

    assert_equal "youtube.download", step1["capability"]
    assert_equal "request.inputs.youtube_url", step1.dig("inputs", "url", "from")

    assert_equal "drive.upload", step2["capability"]
    assert_equal "request.inputs.drive_folder_id", step2.dig("inputs", "folder_id", "from")
  end

  def test_routes_from_raw_text_by_extracting_youtube_and_yandex_disk
    text = <<~TEXT
      Скачай видео по ссылке https://www.youtube.com/live/igYb8BwMTA4?si=vC85Ed8UaKchTfl2
      и положи его в папку Яндекс Диска https://disk.yandex.ru/d/CCj7sZ-5f4GG6A.
    TEXT

    plan = RequestRouter.build_plan_from_text(text, now: Time.utc(2026, 2, 18, 0, 0, 0))
    assert_equal 2, plan.fetch("steps").length

    step1 = plan["steps"][0]
    step2 = plan["steps"][1]

    assert_equal "youtube.download", step1["capability"]
    assert_equal "request.inputs.youtube_url", step1.dig("inputs", "url", "from")

    assert_equal "yandex.disk.upload", step2["capability"]
    assert_equal "request.inputs.yandex_disk_url", step2.dig("inputs", "destination_url", "from")
  end

  def test_hybrid_falls_back_to_llm_when_rules_do_not_match
    request, plan = RequestRouter.build_hybrid_plan_from_text(
      "Загрузи локальный файл /tmp/a.mp4 в папку folder-123",
      llm_client: FakeLLM.new,
      model: "fake-model",
      now: Time.utc(2026, 2, 17, 0, 0, 0)
    )

    assert_equal "planned", plan["status"]
    assert_equal request["request_id"], plan["request_id"]
    assert_equal "llm", plan.dig("steps", 0, "planner_source")
    assert_equal "hybrid", plan.dig("planner", "mode")
    assert_equal 0.9, plan.dig("steps", 0, "coverage_confidence")
  end

  def test_hybrid_normalizes_legacy_llm_step_output_references
    _request, plan = RequestRouter.build_hybrid_plan_from_text(
      "Сделай краткий план автоматизации",
      llm_client: FakeLegacyRefsLLM.new,
      model: "fake-model",
      now: Time.utc(2026, 2, 17, 0, 0, 0)
    )

    assert_equal "steps.step-1.outputs.data", plan.dig("steps", 1, "inputs", "data", "from")
    assert_equal 0.82, plan.dig("steps", 0, "coverage_confidence")
    assert_equal 0.0, plan.dig("steps", 1, "coverage_confidence")
  end

  def test_hybrid_requires_llm_contract
    bad_llm = Class.new do
      def plan_workflow(text:, request:, model: nil)
        {
          "steps" => [
            {
              "capability" => "drive.upload",
              "coverage_confidence" => 0.8,
              "inputs" => { "folder_id" => { "from" => "request.inputs.folder_id" } },
            },
          ],
        }
      end
    end

    assert_raises(RequestRouter::ValidationError) do
      RequestRouter.build_hybrid_plan_from_text(
        "Загрузи файл в папку folder-123",
        llm_client: bad_llm.new,
        model: "fake-model",
        now: Time.utc(2026, 2, 17, 0, 0, 0)
      )
    end
  end

  def test_routes_video_convert_all_from_text
    text = "Сконвертируй все webm из input_data в mp4 и сохрани в output_data"
    plan = RequestRouter.build_plan_from_text(text, now: Time.utc(2026, 2, 21, 0, 0, 0))

    assert_equal "planned", plan["status"]
    assert_equal 1, plan.fetch("steps").length

    step = plan["steps"][0]
    assert_equal "video.convert", step["capability"]
    assert_equal "all", step.dig("inputs", "mode")
    assert_equal "input_data", step.dig("inputs", "input_dir")
    assert_equal "output_data", step.dig("inputs", "output_dir")
    assert_equal true, step.dig("inputs", "overwrite")
    assert_equal [], step.dig("inputs", "files")
  end

  def test_routes_video_convert_selected_files_from_text
    text = "Сконвертируй файлы hero.webm, trailer.webm в mp4"
    plan = RequestRouter.build_plan_from_text(text, now: Time.utc(2026, 2, 21, 0, 0, 0))

    assert_equal "planned", plan["status"]
    assert_equal 1, plan.fetch("steps").length

    step = plan["steps"][0]
    assert_equal "video.convert", step["capability"]
    assert_equal "selected", step.dig("inputs", "mode")
    assert_equal %w[hero.webm trailer.webm], step.dig("inputs", "files")
  end

  def test_mixed_video_convert_and_youtube_is_not_supported_in_rule_plan
    text = "Скачай https://www.youtube.com/watch?v=abc и сконвертируй все webm из input_data в mp4"
    assert_raises(RequestRouter::ValidationError) do
      RequestRouter.build_plan_from_text(text, now: Time.utc(2026, 2, 21, 0, 0, 0))
    end
  end
end
