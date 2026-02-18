#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"

require_relative "../skills/request-router/request_router"
require_relative "../skills/gap-detector/gap_detector"
require_relative "../skills/workflow-executor/workflow_executor"

module Dispatch
  class ValidationError < StandardError; end

  module_function

  def write_json(obj, pretty:, output_path:)
    json = pretty ? JSON.pretty_generate(obj) : JSON.generate(obj)
    json << "\n"
    if output_path
      File.write(output_path, json)
    else
      print json
    end
  end

  def plan_from_text(text, registry_path:)
    request = RequestRouter.build_request_from_text(text)
    plan = RequestRouter.build_plan(request)
    GapDetector.apply!(plan, registry_path: registry_path)
    [request, plan]
  end

  def developer_request?(text)
    text.to_s.lstrip.start_with?("Dev:")
  end

  def developer_request_payload(text)
    {
      "status" => "bypass",
      "reason" => "developer_request",
      "message" => "Messages with 'Dev:' prefix are system-improvement requests and bypass dispatcher routing.",
      "request" => {
        "request_id" => "req-dev-bypass",
        "user_goal" => text.to_s.strip,
        "inputs" => {},
      },
    }
  end

  def unroutable_payload(text, error_message)
    {
      "status" => "unroutable",
      "error" => {
        "type" => "routing_error",
        "message" => error_message.to_s,
      },
      "request" => {
        "request_id" => "req-unroutable",
        "user_goal" => text.to_s.strip,
        "inputs" => {},
      },
      "plan" => {
        "status" => "unroutable",
        "steps" => [],
        "gap_report" => [
          {
            "missing_capability" => nil,
            "reason" => "RequestRouter could not match route rules",
            "proposed_tool_name" => "request-router",
            "proposed_input_schema" => { "type" => "object", "required" => [], "additionalProperties" => true },
            "proposed_output_schema" => { "type" => "object", "required" => [], "additionalProperties" => true },
            "priority" => "high",
          },
        ],
      },
    }
  end

  def run_from_text(text, registry_path:, runs_dir:, dry_run:, execute:, pretty:, output_path:)
    if developer_request?(text)
      write_json(developer_request_payload(text), pretty: pretty, output_path: output_path)
      return 0
    end

    request = nil
    plan = nil

    begin
      request, plan = plan_from_text(text, registry_path: registry_path)
    rescue RequestRouter::ValidationError => e
      payload = unroutable_payload(text, e.message)
      write_json(payload, pretty: pretty, output_path: output_path)
      return 3
    end

    unless plan.is_a?(Hash) && plan["status"].is_a?(String)
      write_json({ "status" => "error", "error" => { "message" => "Invalid plan produced" } }, pretty: pretty, output_path: output_path)
      return 1
    end

    if plan["status"] != "complete"
      payload = { "status" => "partial", "request" => request, "plan" => plan }
      write_json(payload, pretty: pretty, output_path: output_path)
      return 2
    end

    unless execute
      # Dispatcher-only default: preview only.
      run = WorkflowExecutor.run_plan!(plan, request, registry_path: registry_path, runs_dir: runs_dir, dry_run: true)
      payload = { "status" => "preview", "request" => request, "plan" => plan, "run" => run }
      write_json(payload, pretty: pretty, output_path: output_path)
      return 0
    end

    run = WorkflowExecutor.run_plan!(plan, request, registry_path: registry_path, runs_dir: runs_dir, dry_run: dry_run)
    payload = { "status" => "executed", "request" => request, "plan" => plan, "run" => run }
    write_json(payload, pretty: pretty, output_path: output_path)
    0
  end

  class CLI
    def self.run(argv)
      command = argv.shift
      case command
      when "run"
        text = nil
        text_file = nil
        registry_path = WorkflowExecutor.default_registry_path
        runs_dir = WorkflowExecutor.default_runs_dir
        output_path = nil
        pretty = false
        dry_run = false
        execute = false

        OptionParser.new do |o|
          o.on("--text TEXT", "Raw user request text") { |v| text = v }
          o.on("--text-file PATH", "Read raw user request text from file") { |v| text_file = v }
          o.on("--registry PATH", "Path to registry cache JSON") { |v| registry_path = v }
          o.on("--runs-dir PATH", "Directory to write run artifacts") { |v| runs_dir = v }
          o.on("--dry-run", "Do not execute tools; only show commands/placeholders") { dry_run = true }
          o.on("--execute", "Execute tools (side-effects). Default: preview only.") { execute = true }
          o.on("--output PATH", "Write JSON to PATH (default: stdout)") { |v| output_path = v }
          o.on("--pretty", "Pretty-print JSON") { pretty = true }
        end.parse!(argv)

        if text.nil? || text.strip.empty?
          if text_file && !text_file.strip.empty?
            text = File.read(text_file)
          end
        end
        raise ValidationError, "Missing --text TEXT (or --text-file PATH)" if text.nil? || text.strip.empty?

        return Dispatch.run_from_text(
          text,
          registry_path: registry_path,
          runs_dir: runs_dir,
          dry_run: dry_run,
          execute: execute,
          pretty: pretty,
          output_path: output_path
        )
      else
        warn(<<~USAGE)
          Usage:
            dispatch.rb run --text TEXT [--registry PATH] [--runs-dir PATH] [--dry-run] [--execute] [--output PATH] [--pretty]
        USAGE
        return 1
      end
    rescue ValidationError, ToolRegistry::ValidationError, GapDetector::ValidationError, RequestRouter::ValidationError, WorkflowExecutor::ValidationError, WorkflowExecutor::ExecutionError => e
      warn(e.message)
      return 1
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  exit(Dispatch::CLI.run(ARGV))
end
