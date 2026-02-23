#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/test"
require "stringio"

require_relative "agent_status"

class AgentStatusTest < Minitest::Test
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

  class TTYStringIO < FlushStringIO
    def tty?
      true
    end
  end

  class PlainNoFlushIO
    attr_reader :lines

    def initialize
      @lines = []
    end

    def puts(value)
      @lines << value
    end
  end

  def test_build_renderer_selects_null_for_non_pretty
    io = StringIO.new
    renderer = AgentLogging::Status.build_renderer(output_format: "json", io: io, no_color_env: "")
    assert_instance_of AgentLogging::Status::NullRenderer, renderer
  end

  def test_build_renderer_selects_plain_for_non_tty_or_no_color
    plain = AgentLogging::Status.build_renderer(output_format: "pretty", io: StringIO.new, no_color_env: "")
    assert_instance_of AgentLogging::Status::PlainRenderer, plain

    tty_io = TTYStringIO.new
    forced_plain = AgentLogging::Status.build_renderer(output_format: "pretty", io: tty_io, no_color_env: "1")
    assert_instance_of AgentLogging::Status::PlainRenderer, forced_plain
  end

  def test_build_renderer_selects_tty_when_allowed
    tty_io = TTYStringIO.new
    renderer = AgentLogging::Status.build_renderer(output_format: "pretty", io: tty_io, no_color_env: "")
    assert_instance_of AgentLogging::Status::TTYRenderer, renderer
  end

  def test_tty_redraw_enabled_requires_pretty_tty_and_no_color
    tty_io = TTYStringIO.new
    assert_equal true, AgentLogging::Status.tty_redraw_enabled?(output_format: "pretty", io: tty_io, no_color_env: "")
    assert_equal false, AgentLogging::Status.tty_redraw_enabled?(output_format: "json", io: tty_io, no_color_env: "")
    assert_equal false, AgentLogging::Status.tty_redraw_enabled?(output_format: "pretty", io: StringIO.new, no_color_env: "")
    assert_equal false, AgentLogging::Status.tty_redraw_enabled?(output_format: "pretty", io: tty_io, no_color_env: "1")
  end

  def test_normalize_state_and_emoji
    assert_equal "RUNNING", AgentLogging::Status.normalize_state("oops")
    assert_equal "OK", AgentLogging::Status.normalize_state("ok")
    assert_equal "FAIL", AgentLogging::Status.normalize_state("FAIL")
    assert_equal "⏳", AgentLogging::Status.emoji_for("unknown")
    assert_equal "✅", AgentLogging::Status.emoji_for("ok")
    assert_equal "❌", AgentLogging::Status.emoji_for("fail")
  end

  def test_normalize_step_names_and_chain_variants
    names = AgentLogging::Status.normalize_step_names([{ "capability" => "youtube.download" }, {}, "", nil])
    assert_equal ["youtube.download", "unknown", "unknown", "unknown"], names

    assert_equal "—", AgentLogging::Status.build_chain([], step_states: [], colorize: false)

    plain_chain = AgentLogging::Status.build_chain(
      %w[a b c d],
      step_states: [:done, :active, :failed, :pending],
      colorize: false
    )
    assert_equal "✅a  ->  ⏳b  ->  ❌c  ->  d", plain_chain

    color_chain = AgentLogging::Status.build_chain(
      %w[a b c d],
      step_states: [:done, :active, :failed, :pending],
      colorize: true
    )
    assert_includes color_chain, "\e[32ma\e[0m"
    assert_includes color_chain, "\e[33mb\e[0m"
    assert_includes color_chain, "\e[31mc\e[0m"
    assert_includes color_chain, "d"
  end

  def test_null_renderer_methods_are_noops
    renderer = AgentLogging::Status::NullRenderer.new
    renderer.start(stages: AgentLogging::Status::STAGE_ORDER, chain: [])
    renderer.update_stage(name: AgentLogging::Status::STAGE_PLAN, state: "RUNNING")
    renderer.update_chain(steps: [], step_states: [])
    renderer.emit_coverage_error(missing_caps: [])
    renderer.emit_final(success: true)
    renderer.flush
  end

  def test_plain_renderer_outputs_status_chain_and_final_messages
    io = FlushStringIO.new
    renderer = AgentLogging::Status::PlainRenderer.new(io: io)
    renderer.start(stages: AgentLogging::Status::STAGE_ORDER, chain: [])
    renderer.update_stage(name: AgentLogging::Status::STAGE_PLAN, state: "RUNNING")
    renderer.update_stage(name: AgentLogging::Status::STAGE_COVERAGE, state: "OK")
    renderer.update_stage(name: AgentLogging::Status::STAGE_POLICY, state: "FAIL")
    renderer.update_chain(
      steps: [{ "capability" => "youtube.download" }, { "capability" => "drive.upload" }],
      step_states: [:active, :pending]
    )
    renderer.emit_coverage_error(missing_caps: %w[yandex.disk.upload])
    renderer.emit_coverage_error(missing_caps: [])
    renderer.emit_final(success: false, message: "Причина")
    renderer.emit_final(success: false, message: " ")
    renderer.emit_final(success: true)

    output = io.string
    assert_includes output, "Планирование запроса ⏳"
    assert_includes output, "Проверка покрытия ✅"
    assert_includes output, "Проверка политик ❌"
    assert_includes output, "⏳youtube.download  ->  drive.upload"
    assert_includes output, "Реализуйте утилиты: yandex.disk.upload"
    assert_includes output, "Задача не выполнена ❌"
    assert_includes output, "Причина"
    assert_includes output, "Задача выполнена ✅"
    assert_operator io.flush_calls, :>=, 8
  end

  def test_plain_renderer_handles_io_without_flush
    io = PlainNoFlushIO.new
    renderer = AgentLogging::Status::PlainRenderer.new(io: io)
    renderer.update_stage(name: "X", state: "RUNNING")
    assert_equal ["X ⏳"], io.lines
  end

  def test_tty_renderer_renders_colors_and_compacts_lines
    io = TTYStringIO.new
    renderer = AgentLogging::Status::TTYRenderer.new(io: io, colorize: true)
    steps = [{ "capability" => "youtube.download" }, { "capability" => "drive.upload" }]

    renderer.start(stages: AgentLogging::Status::STAGE_ORDER, chain: steps)
    renderer.update_stage(name: AgentLogging::Status::STAGE_PLAN, state: "OK")
    renderer.update_chain(steps: steps, step_states: [:active, :pending])
    renderer.update_chain(steps: steps, step_states: [:done, :failed])
    renderer.emit_coverage_error(missing_caps: [])
    renderer.emit_coverage_error(missing_caps: ["yandex.disk.upload"])
    renderer.emit_final(success: false, message: "Ошибка")
    renderer.emit_final(success: true)
    renderer.flush

    output = io.string
    assert_includes output, "\e[2K\r"
    assert_includes output, "\e[33myoutube.download\e[0m"
    assert_includes output, "\e[32myoutube.download\e[0m"
    assert_includes output, "\e[31mdrive.upload\e[0m"
    assert_includes output, "Реализуйте утилиты: yandex.disk.upload"
    assert_includes output, "Задача не выполнена ❌"
    assert_includes output, "Задача выполнена ✅"
    assert_includes output, "\e[1A"
  end

  def test_tty_renderer_supports_custom_stages_without_execution_row
    io = TTYStringIO.new
    renderer = AgentLogging::Status::TTYRenderer.new(io: io, colorize: false)
    renderer.start(stages: ["A", AgentLogging::Status::STAGE_FINAL], chain: [])
    renderer.update_stage(name: "A", state: "OK")
    renderer.emit_final(success: true)

    output = io.string
    assert_includes output, "A ✅"
    refute_includes output, "  ->  "
  end
end
