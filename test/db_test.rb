# frozen_string_literal: true

require 'test_helper'

class DBTest < Minitest::Test
  def test_current_reconnects_after_the_connection_is_closed
    conn = BladeMcp::DB.current
    conn.close
    refute_same conn, BladeMcp::DB.current
    assert_equal 1, BladeMcp::DB.current.exec('SELECT 1').getvalue(0, 0)
  end

  def test_migrate_takes_a_database_made_before_migrations_were_tracked
    BladeMcp::DB.current.exec('DROP TABLE schema_migrations')
    2.times { BladeMcp::DB.migrate }
    assert_equal Dir.glob('*.rb', base: BladeMcp::DB::MIGRATIONS).sort,
                 BladeMcp::DB.current.exec('SELECT filename FROM schema_migrations ORDER BY filename').column_values(0)
  end
end
