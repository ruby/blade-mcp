# frozen_string_literal: true

require 'json'
require 'net/http'

module BladeMcp
  # Clients for Heroku Managed Inference. The add-on attached with the
  # INFERENCE, EMBEDDING and RERANK aliases sets <ALIAS>_URL and <ALIAS>_KEY.
  module Inference
    class Error < StandardError; end

    # CloudFront in front of the API answers 403 to request bodies it takes
    # for attacks. A wrong key gets 401 instead.
    class Blocked < Error; end

    class RateLimited < Error
      attr_reader :retry_after

      def initialize(message, retry_after)
        super(message)
        @retry_after = retry_after
      end
    end

    class Client
      RETRIES = 3
      READ_TIMEOUT = 60
      NETWORK_ERRORS = [IOError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError].freeze
      # Code in the archive is full of URLs such as http://localhost:3000/ and
      # http://192.168.1.1/, which CloudFront blocks as SSRF. Without the
      # scheme they pass, and the text means the same to the models.
      URL_SCHEME = %r{\b[a-z][a-z0-9+.\-]*://}i

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

      def defuse(text)
        text.gsub(URL_SCHEME, '')
      end

      def post(path, payload)
        data = request(path, payload) { |response| JSON.parse(response.body) }
        raise Error, "#{path} failed: #{data['error']}" if data['error']
        data
      end

      # Yields the parsed data line of each server-sent event.
      def stream(path, payload)
        request(path, payload.merge(stream: true)) do |response|
          buffer = +''
          response.read_body do |chunk|
            buffer << chunk
            while (line = buffer.slice!(/\A.*\n/))
              data = line.chomp[/\Adata:\s*(.+)/, 1]
              next if data.nil? || data == '[DONE]'
              event = JSON.parse(data)
              raise Error, "#{path} failed: #{event['error']}" if event['error']
              yield event
            end
          end
        end
      end

      # Returns what the block makes of a successful response. A 429 is not
      # retried here. The limits are per minute, and a search request should
      # fall back to full-text rather than stall that long.
      def request(path, payload)
        uri = URI("#{@url}#{path}")
        body = JSON.generate(payload)
        RETRIES.times do |attempt|
          Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https', read_timeout: self.class::READ_TIMEOUT) do |http|
            post = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json', 'Authorization' => "Bearer #{@key}")
            post.body = body
            http.request(post) do |response|
              return yield(response) if response.is_a?(Net::HTTPSuccess)
              message = "#{path} returned #{response.code}: #{response.body.to_s[0, 200]}"
              if response.is_a?(Net::HTTPTooManyRequests)
                raise RateLimited.new(message, Integer(response['Retry-After'], exception: false))
              end
              raise Blocked, "#{path} returned 403" if response.is_a?(Net::HTTPForbidden)
              raise Error, message unless response.is_a?(Net::HTTPServerError) && attempt < RETRIES - 1
            end
          end
          sleep 2**attempt
        end
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
        input = texts.map { |text| defuse(text).byteslice(0, MAX_BYTES).scrub('') }
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
        data = post('/v1/rerank', {model: @model, query: defuse(query), documents: documents.map { |document| defuse(document) },
                                   top_n: documents.size})
        data.fetch('results').map { |item| [item['index'], item['relevance_score']] }
      end
    end

    class Chat < Client
      READ_TIMEOUT = 300

      def self.from_env(env = ENV)
        super('INFERENCE', 'claude-opus-4-8', env)
      end

      attr_reader :model

      # Makes the model call the given tool once and returns its arguments and
      # the token usage. The response is streamed, because Heroku answers a
      # request that takes long to generate with a timeout error.
      def call_tool(system, user, tool, max_tokens: 8000)
        payload = {
          model: @model, max_completion_tokens: max_tokens,
          messages: [{role: 'system', content: system}, {role: 'user', content: defuse(user)}],
          tools: [tool], tool_choice: {type: 'function', function: {name: tool.dig(:function, :name)}}
        }
        arguments = +''
        finish_reason = usage = nil
        stream('/v1/chat/completions', payload) do |event|
          choice = event.dig('choices', 0) || {}
          choice.dig('delta', 'tool_calls')&.each { |call| arguments << call.dig('function', 'arguments').to_s }
          finish_reason ||= choice['finish_reason']
          usage ||= event['usage']
        end
        raise Error, "no tool call, finish_reason #{finish_reason}" if arguments.empty?
        [JSON.parse(arguments), usage]
      rescue JSON::ParserError => e
        raise Error, "unreadable tool arguments: #{e.message}"
      end
    end
  end
end
