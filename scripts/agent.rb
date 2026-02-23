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
require_relative "logging/agent_status"
require_relative "llm_client"
require_relative "policy_engine"

module Agent
  class ValidationError < StandardError; end

  STAGE_PLAN = AgentLogging::Status::STAGE_PLAN
  STAGE_COVERAGE = AgentLogging::Status::STAGE_COVERAGE
  STAGE_POLICY = AgentLogging::Status::STAGE_POLICY
  STAGE_EXECUTION = AgentLogging::Status::STAGE_EXECUTION
  STAGE_FINAL = AgentLogging::Status::STAGE_FINAL
  STAGE_ORDER = AgentLogging::Status::STAGE_ORDER

  NullRenderer = AgentLogging::Status::NullRenderer
  PlainRenderer = AgentLogging::Status::PlainRenderer
  TTYRenderer = AgentLogging::Status::TTYRenderer

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
    elsif format == "json"
      print json
    end
  end

  def llm_client_from_settings(settings, llm_log: false)
    return nil if settings["model"].to_s.strip.empty? || settings["api_key"].to_s.strip.empty?
    LLMClient::Client.from_settings(settings, log_io: (llm_log ? $stderr : nil))
  end

  def pretty_renderer(output_format:, io: $stdout)
    AgentLogging::Status.build_renderer(output_format: output_format, io: io, no_color_env: ENV["NO_COLOR"])
  end

  def tty_redraw_enabled?(output_format:, io: $stdout)
    AgentLogging::Status.tty_redraw_enabled?(output_format: output_format, io: io, no_color_env: ENV["NO_COLOR"])
  end

  def human_coverage_message(missing_caps)
    caps = Array(missing_caps).map(&:to_s).reject(&:empty?)
    return "Не хватает реализации нужных capability." if caps.empty?
    "Недоступны capability: #{caps.join(", ")}."
  end

  def human_policy_message(policy_reason)
    reason = policy_reason.to_s.strip
    reason = "policy_violation" if reason.empty?
    "Выполнение заблокировано политикой: #{reason}."
  end

  def human_execution_message(failed_capability, failure)
    cap = failed_capability.to_s.strip
    cap = "шаг workflow" if cap.empty?
    hint = failure["action_hint"].to_s.strip
    hint = "Проверь входные параметры и доступы." if hint.empty?
    "Не удалось выполнить #{cap}. #{hint}"
  end

  def policy_status_fields(policy_result)
    violations = Array(policy_result["violations"])
    if policy_result["status"] == "blocked_by_policy"
      first_reason = violations.first.is_a?(Hash) ? violations.first["reason"].to_s : "policy_violation"
      {
        "state" => "FAIL",
        "payload" => {
          "verdict" => "deny",
          "risk" => "high",
          "reason" => (first_reason.empty? ? "policy_violation" : first_reason),
          "confirmation_required" => "no",
        },
        "summary" => "Выполнение заблокировано политикой",
      }
    else
      {
        "state" => "OK",
        "payload" => {
          "verdict" => "allow",
          "risk" => "low",
          "reason" => "policy_passed",
          "confirmation_required" => "no",
        },
        "summary" => "Выполнение разрешено",
      }
    end
  end

  def map_execution_failure(error, capability:, retry_info:)
    msg = error.message.to_s
    code = error.respond_to?(:code) ? error.code.to_s : "tool_failed"

    if capability == "drive.upload" && msg.match?(/403|insufficient[_\s-]?permissions/i)
      return {
        "root_cause" => "google_drive_api_403_insufficient_permissions",
        "error_code" => "GDRIVE_403",
        "action_hint" => "Проверь права на папку и OAuth scope",
        "retry_info" => retry_info,
      }
    end

    if capability == "drive.upload" && msg.match?(/429|quota/i)
      return {
        "root_cause" => "quota_exceeded",
        "error_code" => "GDRIVE_429",
        "action_hint" => "Освободи место или используй другую папку",
        "retry_info" => retry_info,
      }
    end

    if code == "tool_timeout"
      return {
        "root_cause" => "operation_timeout",
        "error_code" => "TOOL_TIMEOUT",
        "action_hint" => "Проверь сеть/сервис и увеличь timeout",
        "retry_info" => retry_info,
      }
    end

    root = msg.split("\n").first.to_s.strip
    root = "tool_execution_failed" if root.empty?

    {
      "root_cause" => root.gsub(/\s+/, "_").downcase,
      "error_code" => code.upcase,
      "action_hint" => "Проверь логи шага и исправь входные параметры/доступы",
      "retry_info" => retry_info,
    }
  end

  def run_from_text(text, execute:, dry_run:, output_format:, output_path:, config_path:, policy_path:, provider:, model:, registry_path:, runs_dir:, llm_log: false)
    raise ValidationError, "text must be non-empty" if text.to_s.strip.empty?

    request = nil
    plan = nil
    policy = nil
    policy_result = nil
    llm_client = nil
    reporter = pretty_renderer(output_format: output_format, io: $stdout)
    reporter.start(stages: STAGE_ORDER, chain: [])
    reporter.update_stage(name: STAGE_PLAN, state: "RUNNING")

    settings = load_settings(config_path)
    settings["provider"] = provider if provider
    settings["model"] = model if model

    llm_client = llm_client_from_settings(settings, llm_log: llm_log)
    request, plan = RequestRouter.build_hybrid_plan_from_text(text, llm_client: llm_client, model: settings["model"])

    errors = PlanValidator.validate(plan)
    unless errors.empty?
      reporter.update_stage(name: STAGE_PLAN, state: "FAIL")
      reporter.emit_final(success: false, message: "План не прошел валидацию. Проверь входные данные запроса.")
      payload = { "status" => "error", "error" => { "code" => "plan_invalid", "details" => errors }, "request" => request, "plan" => plan }
      write_json(payload, format: output_format, output_path: output_path)
      return 1
    end

    reporter.update_stage(name: STAGE_PLAN, state: "OK")

    steps = Array(plan["steps"])
    chain_states = Array.new(steps.length, :pending)
    reporter.update_chain(steps: steps, step_states: chain_states)

    reporter.update_stage(name: STAGE_COVERAGE, state: "RUNNING")
    GapDetector.apply!(plan, registry_path: registry_path)

    missing_caps = Array(plan.dig("gap_report")).map { |gap| gap["missing_capability"].to_s }.reject(&:empty?).uniq

    if plan["status"] != "complete"
      reporter.update_stage(name: STAGE_COVERAGE, state: "FAIL")
      reporter.emit_coverage_error(missing_caps: missing_caps)
      reporter.emit_final(success: false, message: human_coverage_message(missing_caps))

      payload = {
        "status" => "partial",
        "request" => request,
        "plan" => plan,
        "policy_report" => policy_result,
        "selected_tools" => steps.map do |step|
          next unless step.is_a?(Hash)
          tool = step["tool"].to_s
          next if tool.empty?
          { "tool" => tool, "capabilities" => [step["capability"].to_s].reject(&:empty?) }
        end.compact.uniq,
      }
      write_json(payload, format: output_format, output_path: output_path)
      return (dry_run || !execute) ? 0 : 2
    end
    reporter.update_stage(name: STAGE_COVERAGE, state: "OK")

    reporter.update_stage(name: STAGE_POLICY, state: "RUNNING")
    policy = PolicyEngine.load_policy(policy_path)
    policy_result = PolicyEngine.check!(plan, policy: policy, registry_path: registry_path, execute: execute && !dry_run)
    pol = policy_status_fields(policy_result)
    reporter.update_stage(name: STAGE_POLICY, state: pol["state"])

    if policy_result["status"] == "blocked_by_policy"
      reporter.emit_final(success: false, message: human_policy_message(pol.dig("payload", "reason")))
      payload = { "status" => "blocked_by_policy", "request" => request, "plan" => plan, "policy_report" => policy_result }
      write_json(payload, format: output_format, output_path: output_path)
      return (dry_run || !execute) ? 0 : 4
    end

    reporter.update_stage(name: STAGE_EXECUTION, state: "RUNNING")
    workflow_started_at = Time.now

    event_handler = proc do |event|
      idx = event["step_index"].to_i - 1
      next if idx.negative? || idx >= chain_states.length

      case event["type"].to_s
      when "step_attempt_started", "step_retry"
        chain_states[idx] = :active
      when "step_succeeded"
        chain_states[idx] = :done
      when "step_failed"
        chain_states[idx] = :failed
        reporter.update_stage(name: STAGE_EXECUTION, state: "FAIL")
      end
      reporter.update_chain(steps: steps, step_states: chain_states)
    end

    run = WorkflowExecutor.run_plan!(
      plan,
      request,
      registry_path: registry_path,
      runs_dir: runs_dir,
      dry_run: dry_run || !execute,
      max_tool_retries: policy["max_tool_retries"].to_i,
      timeout_seconds: policy["max_run_seconds"].to_i.positive? ? policy["max_run_seconds"].to_i : 300,
      event_handler: event_handler,
      stream_tool_stderr: !tty_redraw_enabled?(output_format: output_format, io: $stdout)
    )

    reporter.update_stage(name: STAGE_EXECUTION, state: "OK")
    reporter.emit_final(success: true)

    status = dry_run || !execute ? "preview" : "executed"
    payload = {
      "status" => status,
      "request" => request,
      "plan" => plan,
      "policy_report" => policy_result,
      "run" => run,
    }
    write_json(payload, format: output_format, output_path: output_path)
    0
  rescue WorkflowExecutor::ExecutionFailed => e
    failed_capability = e.respond_to?(:failed_capability) ? e.failed_capability.to_s : "unknown"
    retry_limit = policy.is_a?(Hash) ? policy["max_tool_retries"].to_i + 1 : 1
    failure = map_execution_failure(e, capability: failed_capability, retry_info: "#{retry_limit}/#{retry_limit}")
    reporter.update_stage(name: STAGE_EXECUTION, state: "FAIL")
    reporter.emit_final(success: false, message: human_execution_message(failed_capability, failure))

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
      "error" => { "code" => e.code, "message" => e.message },
    }
    write_json(payload, format: output_format, output_path: output_path)
    1
  rescue RequestRouter::ValidationError => e
    error_code = llm_client.nil? ? "routing_error_no_llm" : "routing_error"
    message = e.message.to_s
    if llm_client.nil?
      message = "#{message} Configure config/agent.yaml api_key or set AGENT_API_KEY/ZAI_API_KEY for free-form planning."
    end

    reporter.update_stage(name: STAGE_PLAN, state: "FAIL")
    reporter.emit_final(success: false, message: "Не удалось построить маршрут запроса. Уточни формулировку или настрой LLM.")
    payload = {
      "status" => "unroutable",
      "error" => { "code" => error_code, "message" => message },
      "request" => { "user_goal" => text.to_s.strip, "inputs" => {} },
    }
    write_json(payload, format: output_format, output_path: output_path)
    3
  rescue LLMClient::Error => e
    reporter.update_stage(name: STAGE_PLAN, state: "FAIL")
    reporter.emit_final(success: false, message: "Ошибка LLM: проверь конфигурацию и повтори запуск.")
    payload = { "status" => "error", "error" => { "code" => e.code, "message" => e.message } }
    write_json(payload, format: output_format, output_path: output_path)
    1
  rescue ValidationError, PolicyEngine::ValidationError, ToolRegistry::ValidationError, GapDetector::ValidationError, WorkflowExecutor::ValidationError, WorkflowExecutor::ExecutionError => e
    code = e.respond_to?(:code) ? e.code : "error"
    reporter.emit_final(success: false, message: "Системная ошибка: #{e.message}")
    payload = { "status" => "error", "error" => { "code" => code, "message" => e.message } }
    write_json(payload, format: output_format, output_path: output_path)
    1
  ensure
    reporter.flush
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
