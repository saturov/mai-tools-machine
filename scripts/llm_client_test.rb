#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "stringio"

require_relative "llm_client"

class LLMClientTest < Minitest::Test
  FakeResponse = Struct.new(:code, :body)
  SpyLogger = Struct.new(:events) do
    def request(call_id:, endpoint:, model:, payload:)
      events << [:request, call_id, endpoint.to_s, model, payload]
    end

    def response(call_id:, http_status:, raw_body:)
      events << [:response, call_id, http_status, raw_body]
    end

    def content(call_id:, extracted_content:)
      events << [:content, call_id, extracted_content]
    end

    def retry(call_id:, next_attempt:, reason:)
      events << [:retry, call_id, next_attempt, reason]
    end
  end

  def with_http_start_stub(responses)
    calls = []
    singleton = Net::HTTP.singleton_class

    singleton.send(:alias_method, :__orig_start_for_test, :start)
    singleton.send(:define_method, :start) do |host, port, **kwargs, &block|
      http = Object.new
      http.define_singleton_method(:request) do |req|
        calls << req
        responses.shift || responses.last
      end
      block.call(http)
    end

    yield(calls)
  ensure
    singleton.send(:alias_method, :start, :__orig_start_for_test)
    singleton.send(:remove_method, :__orig_start_for_test)
  end

  def test_posts_json_and_parses_plan
    body = {
      "choices" => [
        { "message" => { "content" => "{\"steps\":[{\"capability\":\"youtube.download\",\"inputs\":{}}]}" } },
      ],
    }
    responses = [FakeResponse.new("200", JSON.generate(body))]

    with_http_start_stub(responses) do |calls|
      client = LLMClient::Client.new(
        provider: "openai_compatible",
        model: "gpt-test",
        base_url: "https://example.com/v1",
        api_key: "secret"
      )

      result = client.plan_workflow(text: "x", request: { "request_id" => "r1" })
      assert_equal "youtube.download", result.dig("steps", 0, "capability")
      assert_equal 1, calls.length
      assert_equal "Bearer secret", calls[0]["Authorization"]
    end
  end

  def test_retries_429_then_succeeds
    fail_response = FakeResponse.new("429", "{\"error\":\"rate\"}")
    ok_body = { "choices" => [{ "message" => { "content" => "{\"steps\":[{\"capability\":\"drive.upload\",\"inputs\":{}}]}" } }] }
    responses = [fail_response, FakeResponse.new("200", JSON.generate(ok_body))]

    with_http_start_stub(responses) do |_calls|
      client = LLMClient::Client.new(
        provider: "openai_compatible",
        model: "gpt-test",
        base_url: "https://example.com/v1",
        api_key: "secret",
        max_retries: 1
      )
      result = client.plan_workflow(text: "x", request: { "request_id" => "r1" })
      assert_equal "drive.upload", result.dig("steps", 0, "capability")
    end
  end

  def test_logs_request_and_response_sections_when_log_io_is_set
    body = {
      "choices" => [
        { "message" => { "content" => "{\"steps\":[{\"capability\":\"youtube.download\",\"inputs\":{}}]}" } },
      ],
    }
    responses = [FakeResponse.new("200", JSON.generate(body))]
    out = StringIO.new

    with_http_start_stub(responses) do |_calls|
      client = LLMClient::Client.new(
        provider: "openai_compatible",
        model: "gpt-test",
        base_url: "https://example.com/v1",
        api_key: "secret",
        log_io: out
      )

      client.plan_workflow(text: "x", request: { "request_id" => "r1" })
    end

    log = out.string
    assert_includes log, "[llm][call-1] request"
    assert_includes log, "[llm][call-1] response"
    assert_includes log, "payload:"
    assert_includes log, "raw_body:"
    assert_includes log, "extracted_content:"
    assert_includes log, "http_status: 200"
    assert_includes log, "\"steps\""
  end

  def test_logs_retry_events
    fail_response = FakeResponse.new("429", "{\"error\":\"rate\"}")
    ok_body = { "choices" => [{ "message" => { "content" => "{\"steps\":[{\"capability\":\"drive.upload\",\"inputs\":{}}]}" } }] }
    responses = [fail_response, FakeResponse.new("200", JSON.generate(ok_body))]
    out = StringIO.new

    with_http_start_stub(responses) do |_calls|
      client = LLMClient::Client.new(
        provider: "openai_compatible",
        model: "gpt-test",
        base_url: "https://example.com/v1",
        api_key: "secret",
        max_retries: 1,
        log_io: out
      )
      client.plan_workflow(text: "x", request: { "request_id" => "r1" })
    end

    log = out.string
    assert_includes log, "[llm][call-1] retry attempt=2 reason=llm_rate_limited"
  end

  def test_prompt_requires_contract_and_confidence_fields
    body = {
      "choices" => [
        { "message" => { "content" => "{\"steps\":[{\"capability\":\"youtube.download\",\"inputs\":{},\"capability_contract\":{\"input_schema\":{\"type\":\"object\",\"required\":[],\"additionalProperties\":true,\"properties\":{}},\"output_schema\":{\"type\":\"object\",\"required\":[],\"additionalProperties\":true,\"properties\":{}}},\"coverage_confidence\":1,\"coverage_rationale\":\"ok\"}]}" } },
      ],
    }
    responses = [FakeResponse.new("200", JSON.generate(body))]

    with_http_start_stub(responses) do |calls|
      client = LLMClient::Client.new(
        provider: "openai_compatible",
        model: "gpt-test",
        base_url: "https://example.com/v1",
        api_key: "secret"
      )
      client.plan_workflow(text: "x", request: { "request_id" => "r1" })

      payload = JSON.parse(calls[0].body)
      prompt = payload.dig("messages", 1, "content")
      assert_includes prompt, "capability_contract"
      assert_includes prompt, "coverage_confidence"
      assert_includes prompt, "coverage_rationale"
    end
  end

  def test_accepts_explicit_logger_and_prefers_it_over_log_io
    body = {
      "choices" => [
        { "message" => { "content" => "{\"steps\":[{\"capability\":\"youtube.download\",\"inputs\":{}}]}" } },
      ],
    }
    responses = [FakeResponse.new("200", JSON.generate(body))]
    log_io = StringIO.new
    logger = SpyLogger.new([])

    with_http_start_stub(responses) do |_calls|
      client = LLMClient::Client.new(
        provider: "openai_compatible",
        model: "gpt-test",
        base_url: "https://example.com/v1",
        api_key: "secret",
        log_io: log_io,
        logger: logger
      )
      client.plan_workflow(text: "x", request: { "request_id" => "r1" })
    end

    assert_equal true, logger.events.any? { |e| e[0] == :request }
    assert_equal true, logger.events.any? { |e| e[0] == :response }
    assert_equal true, logger.events.any? { |e| e[0] == :content }
    assert_equal "", log_io.string
  end

  def test_works_without_logger_or_log_io
    body = {
      "choices" => [
        { "message" => { "content" => "{\"steps\":[{\"capability\":\"youtube.download\",\"inputs\":{}}]}" } },
      ],
    }
    responses = [FakeResponse.new("200", JSON.generate(body))]

    with_http_start_stub(responses) do |_calls|
      client = LLMClient::Client.new(
        provider: "openai_compatible",
        model: "gpt-test",
        base_url: "https://example.com/v1",
        api_key: "secret",
        log_io: nil,
        logger: nil
      )
      result = client.plan_workflow(text: "x", request: { "request_id" => "r1" })
      assert_equal "youtube.download", result.dig("steps", 0, "capability")
    end
  end
end
