# frozen_string_literal: true

require 'test_helper'

class DBTest < Minitest::Test
  def test_current_reconnects_after_the_connection_is_closed
    conn = BladeMcp::DB.current
    conn.close
    refute_same conn, BladeMcp::DB.current
    assert_equal 1, BladeMcp::DB.current.exec('SELECT 1').getvalue(0, 0)
  end
end
