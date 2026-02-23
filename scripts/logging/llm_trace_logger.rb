#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

module AgentLogging
  class LLMTraceLogger
    def initialize(io)
      @io = io
    end

    def request(call_id:, endpoint:, model:, payload:)
      return if @io.nil?

      @io.puts("[llm][#{call_id}] request")
      @io.puts("endpoint: #{endpoint}")
      @io.puts("model: #{model}")
      @io.puts("payload:")
      @io.puts(JSON.pretty_generate(payload))
      flush
    end

    def response(call_id:, http_status:, raw_body:)
      return if @io.nil?

      @io.puts("[llm][#{call_id}] response")
      @io.puts("http_status: #{http_status}")
      @io.puts("raw_body:")
      @io.puts(raw_body)
      flush
    end

    def content(call_id:, extracted_content:)
      return if @io.nil?

      @io.puts("[llm][#{call_id}] extracted_content:")
      @io.puts(extracted_content)
      flush
    end

    def retry(call_id:, next_attempt:, reason:)
      return if @io.nil?

      @io.puts("[llm][#{call_id}] retry attempt=#{next_attempt} reason=#{reason}")
      flush
    end

    private

    def flush
      @io.flush if @io.respond_to?(:flush)
    end
  end
end
