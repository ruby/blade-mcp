# frozen_string_literal: true

require 'test_helper'
require 'open3'

class CLITest < Minitest::Test
  BIN = File.expand_path('../bin/blade-mcp', __dir__)

  def run_cli(*args)
    Open3.capture2e(RbConfig.ruby, BIN, *args)
  end

  def test_rejects_an_unknown_list_before_touching_anything
    output, status = run_cli('import', '--lists', 'ruby-dev,ruby-foo')
    refute status.success?
    assert_match 'invalid argument: --lists ruby-foo (known: ruby-core,ruby-dev,ruby-list,ruby-talk,ruby-ext,ruby-math)',
                 output
  end

  def test_prints_usage_without_a_command
    output, status = run_cli
    refute status.success?
    assert_match 'Usage: blade-mcp COMMAND [options]', output
  end
end
