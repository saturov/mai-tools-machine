#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

require_relative "logging/llm_trace_logger"

module LLMClient
  class Error < StandardError
    attr_reader :code

    def initialize(message, code: "llm_error")
      super(message)
      @code = code
    end
  end

  class Client
    DEFAULT_BASE_URL = "https://api.openai.com/v1"
    DEFAULT_TIMEOUT_SECONDS = 30
    DEFAULT_MAX_RETRIES = 2

    attr_reader :provider, :model, :base_url, :api_key, :timeout_seconds, :max_retries, :log_io, :logger

    def initialize(provider:, model:, base_url:, api_key:, timeout_seconds: DEFAULT_TIMEOUT_SECONDS, max_retries: DEFAULT_MAX_RETRIES, log_io: nil, logger: nil)
      @provider = provider.to_s
      @model = model.to_s
      @base_url = base_url.to_s
      @api_key = api_key.to_s
      @timeout_seconds = timeout_seconds.to_i
      @max_retries = max_retries.to_i
      @log_io = log_io
      @logger = logger || build_logger_from_io(log_io)
      @call_seq = 0

      validate!
    end

    def self.from_settings(settings, log_io: nil, logger: nil)
      provider = settings.fetch("provider", "openai_compatible")
      model = settings.fetch("model", "")
      base_url = settings.fetch("base_url", DEFAULT_BASE_URL)
      api_key = settings.fetch("api_key", "")
      timeout = settings.fetch("timeout_seconds", DEFAULT_TIMEOUT_SECONDS)
      retries = settings.fetch("max_retries", DEFAULT_MAX_RETRIES)

      new(
        provider: provider,
        model: model,
        base_url: base_url,
        api_key: api_key,
        timeout_seconds: timeout,
        max_retries: retries,
        log_io: log_io,
        logger: logger
      )
    end

    def chat_completions_uri
      base = URI(base_url)
      joined = base.path.to_s.end_with?("/") ? "#{base.path}chat/completions" : "#{base.path}/chat/completions"
      port_part = if (base.scheme == "https" && base.port == 443) || (base.scheme == "http" && base.port == 80)
                    ""
                  else
                    ":#{base.port}"
                  end
      URI.parse("#{base.scheme}://#{base.host}#{port_part}#{joined}")
    end

    def plan_workflow(text:, request:, model: nil)
      m = model.to_s.strip.empty? ? @model : model.to_s
      raise Error, "LLM model is required" if m.strip.empty?

      prompt = <<~PROMPT
        You are a workflow planner. Return JSON only.
        Build a plan for this user goal:
        #{text}

        Request context JSON:
        #{JSON.generate(request)}

        Output JSON shape:
        {
          "steps": [
            {
              "step_id": "step-1",
              "capability": "domain.action",
              "coverage_confidence": 0.0,
              "coverage_rationale": "why this capability matches the request",
              "capability_contract": {
                "input_schema": {"type":"object","required":[],"additionalProperties":true,"properties":{}},
                "output_schema": {"type":"object","required":[],"additionalProperties":true,"properties":{}}
              },
              "inputs": {
                "k": {"from":"request.inputs.x"},
                "next_k": {"from":"steps.step-1.outputs.some_value"}
              }
            }
          ]
        }
        Reference rules:
        - Allowed refs only: request.inputs.<key> or steps.<step_id>.outputs.<key>
        - Do NOT use forms like step-1.output.x
        - Every step MUST include capability_contract.input_schema and capability_contract.output_schema
        - Every step MUST include coverage_confidence in [0,1] and coverage_rationale
      PROMPT

      body = {
        model: m,
        temperature: 0,
        response_format: { type: "json_object" },
        messages: [
          { role: "system", content: "Return strict JSON object only." },
          { role: "user", content: prompt },
        ],
      }

      uri = chat_completions_uri
      call_id = next_call_id
      log_llm_request(call_id, uri, m, body)
      response_json = post_with_retries(uri, body, call_id: call_id)
      content = response_json.dig("choices", 0, "message", "content")
      raise Error.new("LLM response missing choices[0].message.content", code: "llm_invalid_response") unless content.is_a?(String)
      log_llm_content(call_id, content)

      JSON.parse(content)
    rescue JSON::ParserError => e
      raise Error.new("LLM returned invalid JSON: #{e.message}", code: "llm_invalid_json")
    end

    private

    def validate!
      raise Error, "Only provider=openai_compatible is supported in v1" unless provider == "openai_compatible"
      raise Error, "LLM base_url is required" if base_url.strip.empty?
      raise Error, "LLM API key is required" if api_key.strip.empty?
      raise Error, "timeout_seconds must be > 0" unless timeout_seconds.positive?
      raise Error, "max_retries must be >= 0" if max_retries.negative?
    end

    def post_with_retries(uri, payload, call_id:)
      attempt = 0
      last_error = nil

      while attempt <= max_retries
        attempt += 1
        begin
          response = post_json(uri, payload, call_id: call_id)
          return response
        rescue Error => e
          last_error = e
          retryable = %w[llm_rate_limited llm_upstream].include?(e.code)
          break unless retryable && attempt <= max_retries
          log_llm_retry(call_id, attempt + 1, e.code)
          sleep(0.2 * attempt)
        end
      end

      raise last_error || Error.new("Unknown LLM request failure")
    end

    def post_json(uri, payload, call_id:)
      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{api_key}"
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(payload)

      response =
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", read_timeout: timeout_seconds, open_timeout: timeout_seconds) do |http|
          http.request(req)
        end

      code = response.code.to_i
      body = response.body.to_s
      log_llm_response(call_id, code, body)

      case code
      when 200..299
        JSON.parse(body)
      when 401
        raise Error.new("LLM authentication failed (401): #{extract_error_message(body)}", code: "llm_auth")
      when 429
        details = extract_error_message(body)
        if details.downcase.include?("insufficient balance") || details.downcase.include?("no resource package")
          raise Error.new("LLM quota exceeded (429): #{details}", code: "llm_quota_exceeded")
        end
        raise Error.new("LLM rate limited (429): #{details}", code: "llm_rate_limited")
      when 500..599
        raise Error.new("LLM upstream error (#{code}): #{extract_error_message(body)}", code: "llm_upstream")
      else
        raise Error.new("LLM request failed (#{code}): #{body}", code: "llm_http")
      end
    rescue Timeout::Error => e
      raise Error.new("LLM timeout: #{e.message}", code: "llm_upstream")
    rescue Errno::ECONNREFUSED, SocketError, EOFError => e
      raise Error.new("LLM connection error: #{e.message}", code: "llm_upstream")
    rescue JSON::ParserError => e
      raise Error.new("LLM HTTP success but invalid JSON body: #{e.message}", code: "llm_invalid_response")
    end

    def extract_error_message(body)
      return "" if body.to_s.strip.empty?
      parsed = JSON.parse(body)
      return body.to_s unless parsed.is_a?(Hash)
      err = parsed["error"]
      if err.is_a?(Hash)
        msg = err["message"]
        return msg.to_s unless msg.nil?
      elsif !err.nil?
        return err.to_s
      end
      body.to_s
    rescue JSON::ParserError
      body.to_s
    end

    def next_call_id
      @call_seq += 1
      "call-#{@call_seq}"
    end

    def build_logger_from_io(io)
      return nil if io.nil?
      AgentLogging::LLMTraceLogger.new(io)
    end

    def log_llm_request(call_id, uri, model_name, payload)
      return if logger.nil?
      logger.request(call_id: call_id, endpoint: uri, model: model_name, payload: payload)
    end

    def log_llm_response(call_id, status_code, raw_body)
      return if logger.nil?
      logger.response(call_id: call_id, http_status: status_code, raw_body: raw_body)
    end

    def log_llm_content(call_id, content)
      return if logger.nil?
      logger.content(call_id: call_id, extracted_content: content)
    end

    def log_llm_retry(call_id, next_attempt, reason)
      return if logger.nil?
      logger.retry(call_id: call_id, next_attempt: next_attempt, reason: reason)
    end
  end
end
