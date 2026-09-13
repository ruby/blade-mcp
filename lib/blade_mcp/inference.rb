# frozen_string_literal: true

require 'json'
require 'net/http'

module BladeMcp
  # Clients for Heroku Managed Inference. The add-on attached with the
  # EMBEDDING and RERANK aliases sets <ALIAS>_URL and <ALIAS>_KEY.
  module Inference
    class Error < StandardError; end

    class RateLimited < Error
      attr_reader :retry_after

      def initialize(message, retry_after)
        super(message)
        @retry_after = retry_after
      end
    end

    class Client
      RETRIES = 3
      NETWORK_ERRORS = [IOError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError].freeze

      def self.from_env(prefix, default_model, env = ENV)
        url = env["#{prefix}_URL"]
        key = env["#{prefix}_KEY"]
        new(url, key, env.fetch("#{prefix}_MODEL_ID", default_model)) if url && key
      end

      def initialize(url, key, model)
        @url = url.chomp('/')
        @key = key
        @model = model
      end

      private

      # A 429 is not retried here. The limits are per minute, and a search
      # request should fall back to full-text rather than stall that long.
      def post(path, payload)
        RETRIES.times do |attempt|
          response = http_post(path, payload)
          return JSON.parse(response.body) if response.is_a?(Net::HTTPSuccess)
          message = "#{path} returned #{response.code}: #{response.body.to_s[0, 200]}"
          if response.is_a?(Net::HTTPTooManyRequests)
            raise RateLimited.new(message, Integer(response['Retry-After'], exception: false))
          end
          raise Error, message unless response.is_a?(Net::HTTPServerError) && attempt < RETRIES - 1
          sleep 2**attempt
        end
      end

      def http_post(path, payload)
        Net::HTTP.post(URI("#{@url}#{path}"), JSON.generate(payload),
                       'Content-Type' => 'application/json', 'Authorization' => "Bearer #{@key}")
      rescue *NETWORK_ERRORS => e
        raise Error, "#{path}: #{e.class}: #{e.message}"
      end
    end

    class Embedding < Client
      # The API rejects more inputs per request, or longer ones. Its error
      # speaks of 2048 characters, but it counts UTF-8 bytes.
      MAX_INPUTS = 96
      MAX_BYTES = 2048

      def self.from_env(env = ENV)
        super('EMBEDDING', 'cohere-embed-v4', env)
      end

      def embed(texts, input_type:)
        input = texts.map { |text| text.byteslice(0, MAX_BYTES).scrub('') }
        data = post('/v1/embeddings', {model: @model, input:, input_type:, embedding_type: 'float'})
        data.fetch('data').sort_by { |item| item['index'] }.map { |item| item['embedding'] }
      end
    end

    class Rerank < Client
      def self.from_env(env = ENV)
        super('RERANK', 'cohere-rerank-3-5', env)
      end

      # Returns [index, relevance_score] pairs, best first.
      def rerank(query, documents)
        data = post('/v1/rerank', {model: @model, query:, documents:, top_n: documents.size})
        data.fetch('results').map { |item| [item['index'], item['relevance_score']] }
      end
    end
  end
end
