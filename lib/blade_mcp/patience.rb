# frozen_string_literal: true

require_relative 'inference'

module BladeMcp
  # Heroku Managed Inference limits requests and tokens per minute, which a
  # batch job easily spends, so it waits for the window to pass instead of
  # giving up.
  module Patience
    RATE_LIMIT_WAIT = 60
    RATE_LIMIT_RETRIES = 10

    private

    def patiently
      waits = 0
      begin
        yield
      rescue Inference::RateLimited => e
        raise if (waits += 1) > RATE_LIMIT_RETRIES
        seconds = e.retry_after || RATE_LIMIT_WAIT
        @log.puts "rate limited, retrying in #{seconds}s"
        sleep seconds
        retry
      end
    end
  end
end
