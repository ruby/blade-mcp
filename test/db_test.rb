# frozen_string_literal: true

require 'test_helper'

class DBTest < Minitest::Test
  def test_a_connection_the_server_dropped_is_replaced
    db = BladeMcp::DB.current
    db.synchronize(&:close)
    assert_equal 1, db.get(1)
  end

  def test_the_baseline_takes_a_database_made_before_migrations_were_tracked
    BladeMcp::DB.current[:schema_migrations].where(Sequel.like(:filename, '%\_baseline.rb')).delete
    2.times { BladeMcp::DB.migrate }
    assert_equal Dir.glob('*.rb', base: BladeMcp::DB::MIGRATIONS).sort,
                 BladeMcp::DB.current[:schema_migrations].order(:filename).select_map(:filename)
  end
end
