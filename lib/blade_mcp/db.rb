# frozen_string_literal: true

require 'pg'

module BladeMcp
  module DB
    MIGRATIONS = File.expand_path('../../db/migrate', __dir__).freeze

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

    # Applies the migrations not yet recorded in schema_migrations. Sequel is
    # loaded here only, so the web process does not carry it.
    def migrate(url = ENV.fetch('DATABASE_URL'))
      require 'sequel'
      Sequel.extension :migration
      Sequel.connect(url) { |db| Sequel::Migrator.run(db, MIGRATIONS) }
    end

    def vector(values)
      "[#{values.join(',')}]"
    end

    # A LIKE pattern for values that contain text as written.
    def contains(text)
      "%#{text.gsub(/[\\%_]/) { |c| "\\#{c}" }}%"
    end
  end
end
