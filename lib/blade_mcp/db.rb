# frozen_string_literal: true

require 'sequel'

module BladeMcp
  module DB
    MIGRATIONS = File.expand_path('../../db/migrate', __dir__).freeze
    # Puma serves with up to 5 threads by default, each holding a connection
    # for the request it serves.
    POOL = 5

    @current = nil
    @lock = Mutex.new

    module_function

    def connect(url = ENV.fetch('DATABASE_URL'), **options)
      Sequel.connect(url, max_connections: POOL, **options).extension(:pg_array)
    end

    # The pool shared by the threads of the web process. A connection the
    # server dropped while idle is replaced before it serves a request.
    def current
      @lock.synchronize do
        @current ||= connect.extension(:connection_validator).tap { |db| db.pool.connection_validation_timeout = -1 }
      end
    end

    # Applies the migrations not yet recorded in schema_migrations.
    def migrate(db = current)
      Sequel.extension :migration
      Sequel::Migrator.run(db, MIGRATIONS)
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
