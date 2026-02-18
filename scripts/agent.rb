#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "pathname"
require "time"
require "yaml"

require_relative "../skills/request-router/request_router"
require_relative "../skills/gap-detector/gap_detector"
require_relative "../skills/workflow-executor/workflow_executor"
require_relative "llm_client"
require_relative "policy_engine"

module Agent
  class ValidationError < StandardError; end

  class ProgressReporter
    FRAMES = %w[| / - \\].freeze

    def initialize(enabled:, io: $stderr, interval_seconds: 0.1)
      @enabled = enabled
      @io = io
      @interval_seconds = interval_seconds
      @label = nil
      @active = false
      @thread = nil
      @frame_idx = 0
    end

    def start_phase(label)
      return unless @enabled
      finish_phase(success: true) if @active

      @label = label.to_s
      @active = true
      @frame_idx = 0
      @thread = Thread.new do
        while @active
          frame = FRAMES[@frame_idx % FRAMES.length]
          @frame_idx += 1
          @io.print("\r#{frame} #{@label}")
          @io.flush if @io.respond_to?(:flush)
          sleep(@interval_seconds)
        end
      end
    end

    def finish_phase(success:)
      return unless @enabled
      return unless @active

      @active = false
      @thread&.join
      @thread = nil
      suffix = success ? "готово" : "ошибка"
      @io.print("\r- #{@label}: #{suffix}\n")
      @io.flush if @io.respond_to?(:flush)
    end

    def stop
      finish_phase(success: false) if @active
    end
  end

  module PlanValidator
    module_function

    def validate(plan)
      errors = []
      steps = plan["steps"]
      unless steps.is_a?(Array)
        return ["plan.steps must be an array"]
      end

      known_step_ids = {}
      steps.each_with_index do |step, idx|
        unless step.is_a?(Hash)
          errors << "steps[#{idx}] must be an object"
          next
        end
        step_id = step["step_id"].to_s
        capability = step["capability"].to_s
        errors << "steps[#{idx}].step_id is required" if step_id.empty?
        errors << "steps[#{idx}].capability is required" if capability.empty?

        inputs = step["inputs"]
        if inputs.is_a?(Hash)
          inputs.each do |k, v|
            next unless v.is_a?(Hash) && v.key?("from")
            from = v["from"].to_s
            unless from.start_with?("request.inputs.") || from.match?(/\Asteps\.[a-zA-Z0-9_-]+\.outputs\.[a-zA-Z0-9_-]+\z/)
              errors << "steps[#{idx}].inputs.#{k}.from has unsupported reference #{from.inspect}"
            end
            if from.start_with?("steps.")
              ref_step = from.split(".")[1]
              errors << "steps[#{idx}] references unknown step #{ref_step.inspect}" unless known_step_ids.key?(ref_step)
            end
          end
        else
          errors << "steps[#{idx}].inputs must be an object"
        end

        known_step_ids[step_id] = true unless step_id.empty?
      end

      errors
    end
  end

  module_function

  GREEN = "\e[32m"
  RED = "\e[31m"
  RESET = "\e[0m"

  def repo_root
    @repo_root ||= Pathname.new(__dir__).join("..").expand_path
  end

  def default_agent_config_path
    File.join(repo_root.to_s, "config", "agent.yaml")
  end

  def default_policy_path
    File.join(repo_root.to_s, "config", "policy.yaml")
  end

  def default_settings
    {
      "provider" => "openai_compatible",
      "model" => "",
      "base_url" => "https://api.openai.com/v1",
      "api_key" => "",
      "timeout_seconds" => 30,
      "max_retries" => 2,
    }
  end

  def read_yaml(path)
    raw = YAML.safe_load(File.read(path))
    raw.is_a?(Hash) ? raw.transform_keys(&:to_s) : {}
  rescue Errno::ENOENT
    {}
  end

  def load_settings(config_path)
    cfg = default_settings.merge(read_yaml(config_path))
    env_map = {
      "provider" => ENV["AGENT_PROVIDER"],
      "model" => ENV["AGENT_MODEL"],
      "base_url" => ENV["AGENT_BASE_URL"],
      "api_key" => (ENV["AGENT_API_KEY"] || ENV["ZAI_API_KEY"]),
      "timeout_seconds" => ENV["AGENT_TIMEOUT_SECONDS"],
    }
    env_map.each do |k, v|
      next if v.nil? || v.strip.empty?
      cfg[k] = (k == "timeout_seconds" ? v.to_i : v)
    end
    cfg
  end

  def write_json(obj, format:, output_path:)
    json = format == "pretty" ? JSON.pretty_generate(obj) : JSON.generate(obj)
    json << "\n"
    if output_path
      File.write(output_path, json)
    elsif format == "pretty"
      print human_report(obj)
    else
      print json
    end
  end

  def operation_label(step)
    return nil unless step.is_a?(Hash)
    step_id = step["step_id"].to_s.strip
    capability = step["capability"].to_s.strip
    return nil if step_id.empty? && capability.empty?
    return capability if step_id.empty?
    return step_id if capability.empty?

    "#{step_id} #{capability}"
  end

  def executed_operation_labels(payload)
    Array(payload.dig("run", "steps")).map { |step| operation_label(step) }.compact
  end

  def missing_operation_labels_from_partial(payload)
    steps = Array(payload.dig("plan", "steps"))
    missing = steps.select { |step| step.is_a?(Hash) && (step["tool"].nil? || step["tool"].to_s.strip.empty?) }
    missing.map { |step| operation_label(step) }.compact.uniq
  end

  def missing_operation_labels_from_execution_failure(payload)
    Array(payload["missing_operations"]).map { |step| operation_label(step) }.compact
  end

  def selected_tools_for_report(plan)
    steps = Array(plan && plan["steps"])
    seen = {}
    selected = []
    steps.each do |step|
      next unless step.is_a?(Hash)
      tool = step["tool"].to_s.strip
      next if tool.empty? || seen[tool]
      seen[tool] = true
      selected << {
        "tool" => tool,
        "capabilities" => [step["capability"].to_s].reject(&:empty?),
      }
    end
    selected
  end

  def render_step_lines(success_ops, failed_ops)
    lines = []
    success_ops.each { |op| lines << "#{GREEN}✓#{RESET} #{op}" }
    failed_ops.each { |op| lines << "#{RED}✗#{RESET} #{op}" }
    lines
  end

  def render_selected_tools(payload)
    tools = Array(payload["selected_tools"])
    return "Отобранные утилиты: нет.\n" if tools.empty?

    rendered = tools.flat_map { |tool| Array(tool["capabilities"]) }.map(&:to_s).reject(&:empty?).uniq
    return "Отобранные утилиты: нет.\n" if rendered.empty?

    "Отобранные утилиты: #{rendered.join('; ')}.\n"
  end

  def human_report(payload)
    status = payload["status"].to_s
    case status
    when "executed"
      executed = executed_operation_labels(payload)
      lines = render_step_lines(executed, [])
      body = lines.empty? ? "Выполненные операции: нет.\n" : "Операции:\n#{lines.join("\n")}\n"
      "Задача успешно выполнена.\n#{body}"
    when "preview"
      executed = executed_operation_labels(payload)
      lines = render_step_lines(executed, [])
      body = lines.empty? ? "Выполненные операции: нет.\n" : "Операции:\n#{lines.join("\n")}\n"
      "Задача успешно выполнена.\n#{body}"
    when "blocked_by_policy"
      violations = Array(payload.dig("policy_report", "violations"))
      first_reason = violations.first && violations.first["reason"]
      reason = first_reason && !first_reason.empty? ? first_reason : "policy_violation"
      "Ошибка: выполнение заблокировано политикой (#{reason}).\n"
    when "partial"
      missing = missing_operation_labels_from_partial(payload)
      lines = render_step_lines([], missing)
      body = lines.empty? ? "Операции: нет.\n" : "Операции:\n#{lines.join("\n")}\n"
      "Задача не выполнена.\n#{body}#{render_selected_tools(payload)}"
    when "execution_failed"
      executed = executed_operation_labels(payload)
      missing = missing_operation_labels_from_execution_failure(payload)
      lines = render_step_lines(executed, missing)
      body = lines.empty? ? "Операции: нет.\n" : "Операции:\n#{lines.join("\n")}\n"
      "Задача не выполнена.\n#{body}#{render_selected_tools(payload)}"
    when "unroutable"
      message = payload.dig("error", "message").to_s
      message = "не удалось построить маршрут" if message.empty?
      "Ошибка: #{message}\n"
    when "error"
      code = payload.dig("error", "code").to_s
      message = payload.dig("error", "message").to_s
      details = payload.dig("error", "details")
      if message.empty? && details.is_a?(Array) && !details.empty?
        message = details.join("; ")
      elsif message.empty?
        message = "неизвестная ошибка"
      end
      prefix = code.empty? ? "Ошибка" : "Ошибка (#{code})"
      "#{prefix}: #{message}\n"
    else
      "Статус: #{status.empty? ? 'unknown' : status}.\n"
    end
  end

  def llm_client_from_settings(settings, llm_log: false)
    return nil if settings["model"].to_s.strip.empty? || settings["api_key"].to_s.strip.empty?
    LLMClient::Client.from_settings(settings, log_io: (llm_log ? $stderr : nil))
  end

  def run_from_text(text, execute:, dry_run:, output_format:, output_path:, config_path:, policy_path:, provider:, model:, registry_path:, runs_dir:, llm_log: false)
    raise ValidationError, "text must be non-empty" if text.to_s.strip.empty?

    progress = ProgressReporter.new(enabled: output_format == "pretty")

    settings = load_settings(config_path)
    settings["provider"] = provider if provider
    settings["model"] = model if model

    progress.start_phase("Планирование запроса...")
    llm_client = llm_client_from_settings(settings, llm_log: llm_log)
    request, plan = RequestRouter.build_hybrid_plan_from_text(text, llm_client: llm_client, model: settings["model"])
    progress.finish_phase(success: true)

    errors = PlanValidator.validate(plan)
    unless errors.empty?
      progress.stop
      payload = { "status" => "error", "error" => { "code" => "plan_invalid", "details" => errors }, "request" => request, "plan" => plan }
      write_json(payload, format: output_format, output_path: output_path)
      return 1
    end

    progress.start_phase("Проверка покрытия capability...")
    GapDetector.apply!(plan, registry_path: registry_path)
    progress.finish_phase(success: true)

    progress.start_phase("Проверка политик...")
    policy = PolicyEngine.load_policy(policy_path)
    policy_result = PolicyEngine.check!(plan, policy: policy, registry_path: registry_path, execute: execute && !dry_run)
    progress.finish_phase(success: true)
    if policy_result["status"] == "blocked_by_policy"
      progress.stop
      payload = { "status" => "blocked_by_policy", "request" => request, "plan" => plan, "policy_report" => policy_result }
      write_json(payload, format: output_format, output_path: output_path)
      return (dry_run || !execute) ? 0 : 4
    end

    if plan["status"] != "complete"
      progress.stop
      payload = {
        "status" => "partial",
        "request" => request,
        "plan" => plan,
        "policy_report" => policy_result,
        "selected_tools" => selected_tools_for_report(plan),
      }
      write_json(payload, format: output_format, output_path: output_path)
      return (dry_run || !execute) ? 0 : 2
    end

    progress.start_phase(dry_run || !execute ? "Подготовка предпросмотра..." : "Выполнение workflow...")
    run = WorkflowExecutor.run_plan!(
      plan,
      request,
      registry_path: registry_path,
      runs_dir: runs_dir,
      dry_run: dry_run || !execute,
      max_tool_retries: policy["max_tool_retries"].to_i,
      timeout_seconds: policy["max_run_seconds"].to_i.positive? ? policy["max_run_seconds"].to_i : 300
    )
    progress.finish_phase(success: true)

    status = dry_run || !execute ? "preview" : "executed"
    payload = { "status" => status, "request" => request, "plan" => plan, "policy_report" => policy_result, "run" => run }
    write_json(payload, format: output_format, output_path: output_path)
    0
  rescue WorkflowExecutor::ExecutionFailed => e
    progress.finish_phase(success: false)
    missing_operations = Array(e.remaining_steps).map do |step|
      next unless step.is_a?(Hash)
      { "step_id" => step["step_id"], "capability" => step["capability"] }
    end.compact
    payload = {
      "status" => "execution_failed",
      "request" => request,
      "plan" => plan,
      "run" => {
        "steps" => e.executed_steps,
        "failed_step_id" => e.failed_step_id,
        "failed_tool_id" => e.failed_tool_id,
      },
      "missing_operations" => missing_operations,
      "selected_tools" => selected_tools_for_report(plan),
      "error" => { "code" => e.code, "message" => e.message },
    }
    write_json(payload, format: output_format, output_path: output_path)
    1
  rescue RequestRouter::ValidationError => e
    progress&.stop
    error_code = llm_client.nil? ? "routing_error_no_llm" : "routing_error"
    message = e.message.to_s
    if llm_client.nil?
      message = "#{message} Configure config/agent.yaml api_key or set AGENT_API_KEY/ZAI_API_KEY for free-form planning."
    end
    payload = {
      "status" => "unroutable",
      "error" => { "code" => error_code, "message" => message },
      "request" => { "user_goal" => text.to_s.strip, "inputs" => {} },
    }
    write_json(payload, format: output_format, output_path: output_path)
    3
  rescue LLMClient::Error => e
    progress&.stop
    payload = { "status" => "error", "error" => { "code" => e.code, "message" => e.message } }
    write_json(payload, format: output_format, output_path: output_path)
    1
  rescue ValidationError, PolicyEngine::ValidationError, ToolRegistry::ValidationError, GapDetector::ValidationError, WorkflowExecutor::ValidationError, WorkflowExecutor::ExecutionError => e
    progress&.stop
    payload = { "status" => "error", "error" => { "code" => (e.respond_to?(:code) ? e.code : "error"), "message" => e.message } }
    write_json(payload, format: output_format, output_path: output_path)
    1
  ensure
    progress.stop if defined?(progress) && progress
  end

  class CLI
    def self.run(argv)
      text = nil
      execute = true
      dry_run = false
      output_format = "pretty"
      output_path = nil
      config_path = Agent.default_agent_config_path
      policy_path = Agent.default_policy_path
      provider = nil
      model = nil
      registry_path = WorkflowExecutor.default_registry_path
      runs_dir = WorkflowExecutor.default_runs_dir
      llm_log = false

      OptionParser.new do |o|
        o.on("--text TEXT", "Raw user request text") { |v| text = v }
        o.on("--execute", "Execute steps (default: true)") { execute = true }
        o.on("--no-execute", "Do not execute steps") { execute = false }
        o.on("--dry-run", "Resolve and preview command execution") { dry_run = true }
        o.on("--policy PATH", "Path to policy YAML") { |v| policy_path = v }
        o.on("--config PATH", "Path to agent YAML config") { |v| config_path = v }
        o.on("--provider ID", "LLM provider id") { |v| provider = v }
        o.on("--model NAME", "LLM model name") { |v| model = v }
        o.on("--output FORMAT", "Output format: json|pretty") { |v| output_format = v }
        o.on("--output-path PATH", "Write output JSON to file") { |v| output_path = v }
        o.on("--registry PATH", "Path to registry cache JSON") { |v| registry_path = v }
        o.on("--runs-dir PATH", "Directory for run logs") { |v| runs_dir = v }
        o.on("--llm-log", "Print raw LLM response content to stderr") { llm_log = true }
      end.parse!(argv)

      text ||= argv.join(" ").strip
      raise ValidationError, "Missing request text (use --text or positional string)" if text.nil? || text.empty?
      raise ValidationError, "--output must be json or pretty" unless %w[json pretty].include?(output_format)

      Agent.run_from_text(
        text,
        execute: execute,
        dry_run: dry_run,
        output_format: output_format,
        output_path: output_path,
        config_path: config_path,
        policy_path: policy_path,
        provider: provider,
        model: model,
        registry_path: registry_path,
        runs_dir: runs_dir,
        llm_log: llm_log
      )
    rescue ValidationError => e
      warn(e.message)
      1
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  exit(Agent::CLI.run(ARGV))
end
