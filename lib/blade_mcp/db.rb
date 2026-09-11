# frozen_string_literal: true

require 'pg'

module BladeMcp
  module DB
    SCHEMA = File.expand_path('../../db/schema.sql', __dir__).freeze

    module_function

    def connect(url = ENV.fetch('DATABASE_URL'))
      conn = PG.connect(url)
      conn.type_map_for_results = PG::BasicTypeMapForResults.new(conn)
      conn.type_map_for_queries = PG::BasicTypeMapForQueries.new(conn)
      conn
    end

    # One connection per Puma thread, reopened after the server drops it.
    def current
      conn = Thread.current[:blade_mcp_db]
      conn = nil if conn && (conn.finished? || conn.status != PG::CONNECTION_OK)
      Thread.current[:blade_mcp_db] = conn || connect
    end

    def migrate(conn)
      conn.exec(File.read(SCHEMA))
    end

    def vector(values)
      "[#{values.join(',')}]"
    end
  end
end
