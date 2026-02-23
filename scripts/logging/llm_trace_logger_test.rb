#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/test"
require "stringio"

require_relative "llm_trace_logger"

class LLMTraceLoggerTest < Minitest::Test
  class FlushStringIO < StringIO
    attr_reader :flush_calls

    def initialize(*)
      super
      @flush_calls = 0
    end

    def flush
      @flush_calls += 1
      super
    end
  end

  class NoFlushIO
    attr_reader :lines

    def initialize
      @lines = []
    end

    def puts(value)
      @lines << value
    end
  end

  def test_logs_request_response_content_and_retry_sections
    io = FlushStringIO.new
    logger = AgentLogging::LLMTraceLogger.new(io)

    logger.request(
      call_id: "call-1",
      endpoint: "https://example.com/v1/chat/completions",
      model: "gpt-test",
      payload: { model: "gpt-test", messages: [{ role: "user", content: "x" }] }
    )
    logger.response(call_id: "call-1", http_status: 200, raw_body: "{\"ok\":true}")
    logger.content(call_id: "call-1", extracted_content: "{\"steps\":[]}")
    logger.retry(call_id: "call-1", next_attempt: 2, reason: "llm_rate_limited")

    output = io.string
    assert_includes output, "[llm][call-1] request"
    assert_includes output, "endpoint: https://example.com/v1/chat/completions"
    assert_includes output, "model: gpt-test"
    assert_includes output, "payload:"
    assert_includes output, "[llm][call-1] response"
    assert_includes output, "http_status: 200"
    assert_includes output, "raw_body:"
    assert_includes output, "[llm][call-1] extracted_content:"
    assert_includes output, "[llm][call-1] retry attempt=2 reason=llm_rate_limited"
    assert_equal 4, io.flush_calls
  end

  def test_handles_nil_io
    logger = AgentLogging::LLMTraceLogger.new(nil)
    logger.request(call_id: "call-1", endpoint: "x", model: "m", payload: {})
    logger.response(call_id: "call-1", http_status: 500, raw_body: "err")
    logger.content(call_id: "call-1", extracted_content: "x")
    logger.retry(call_id: "call-1", next_attempt: 2, reason: "r")
  end

  def test_skips_flush_when_io_does_not_support_it
    io = NoFlushIO.new
    logger = AgentLogging::LLMTraceLogger.new(io)
    logger.retry(call_id: "call-1", next_attempt: 2, reason: "llm_rate_limited")
    assert_equal ["[llm][call-1] retry attempt=2 reason=llm_rate_limited"], io.lines
  end
end
