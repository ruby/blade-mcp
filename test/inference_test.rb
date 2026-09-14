# frozen_string_literal: true

require 'test_helper'
require 'socket'

class InferenceTest < Minitest::Test
  # Serves the given [status, body, headers] responses in order and records
  # the requests.
  def serve(*responses)
    server = TCPServer.new('127.0.0.1', 0)
    requests = []
    thread = Thread.new do
      responses.each do |status, body, headers = {}|
        socket = server.accept
        head = socket.gets("\r\n\r\n")
        length = head[/^content-length: (\d+)/i, 1].to_i
        requests << [head, JSON.parse(socket.read(length))]
        extra = headers.map { |name, value| "#{name}: #{value}\r\n" }.join
        socket.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n" \
                     "#{extra}Connection: close\r\n\r\n#{body}")
        socket.close
      end
    end
    yield "http://127.0.0.1:#{server.addr[1]}/"
    thread.join
    requests
  ensure
    server&.close
  end

  def test_embed_posts_the_texts_and_returns_vectors_in_input_order
    body = JSON.generate(data: [{index: 1, embedding: [0.2]}, {index: 0, embedding: [0.1]}])
    requests = serve([200, body]) do |url|
      client = BladeMcp::Inference::Embedding.new(url, 'secret', 'cohere-embed-v4')
      assert_equal [[0.1], [0.2]], client.embed(%w[a b], input_type: 'search_document')
    end
    head, payload = requests.first
    assert_match %r{\APOST /v1/embeddings }, head
    assert_match(/^authorization: Bearer secret\r$/i, head)
    assert_equal({'model' => 'cohere-embed-v4', 'input' => %w[a b], 'input_type' => 'search_document',
                  'embedding_type' => 'float'}, payload)
  end

  def test_embed_cuts_inputs_to_2048_bytes_on_a_character_boundary
    body = JSON.generate(data: [{index: 0, embedding: [0.1]}, {index: 1, embedding: [0.2]}])
    requests = serve([200, body]) do |url|
      client = BladeMcp::Inference::Embedding.new(url, 'secret', 'cohere-embed-v4')
      client.embed(["#{'a' * 2047}é", 'あ' * 683], input_type: 'search_document')
    end
    assert_equal ['a' * 2047, 'あ' * 682], requests.first.last['input']
  end

  def test_rerank_returns_indexes_best_first_after_retrying_a_server_error
    body = JSON.generate(results: [{index: 1, relevance_score: 0.9}, {index: 0, relevance_score: 0.1}])
    requests = serve([503, '{}'], [200, body]) do |url|
      client = BladeMcp::Inference::Rerank.new(url, 'secret', 'cohere-rerank-3-5')
      assert_equal [[1, 0.9], [0, 0.1]], client.rerank('q', %w[x y])
    end
    assert_equal 2, requests.size
    assert_equal({'model' => 'cohere-rerank-3-5', 'query' => 'q', 'documents' => %w[x y], 'top_n' => 2},
                 requests.last.last)
  end

  def test_rate_limits_are_raised_at_once_with_retry_after
    requests = serve([429, '{}', {'Retry-After' => '7'}], [429, '{}']) do |url|
      client = BladeMcp::Inference::Embedding.new(url, 'secret', 'cohere-embed-v4')
      error = assert_raises(BladeMcp::Inference::RateLimited) { client.embed(%w[a], input_type: 'search_query') }
      assert_equal 7, error.retry_after
      assert_nil assert_raises(BladeMcp::Inference::RateLimited) { client.embed(%w[a], input_type: 'search_query') }.retry_after
    end
    assert_equal 2, requests.size
  end

  def test_urls_lose_their_scheme_before_they_are_sent
    embedded = JSON.generate(data: [{index: 0, embedding: [0.1]}])
    reranked = JSON.generate(results: [{index: 0, relevance_score: 0.5}])
    requests = serve([200, embedded], [200, reranked]) do |url|
      BladeMcp::Inference::Embedding.new(url, 'secret', 'cohere-embed-v4')
                                    .embed(["server = 'http://localhost:7000/'"], input_type: 'search_document')
      BladeMcp::Inference::Rerank.new(url, 'secret', 'cohere-rerank-3-5').rerank('druby://localhost:12345', ['HTTPS://192.168.1.1/'])
    end
    assert_equal ["server = 'localhost:7000/'"], requests[0].last['input']
    assert_equal ['localhost:12345', ['192.168.1.1/']], requests[1].last.values_at('query', 'documents')
  end

  # A stream shaped like the one Heroku sends.
  def events(*chunks)
    "#{chunks.map { |chunk| "event:message\ndata:#{JSON.generate(chunk)}\n\n" }.join}event:done\ndata:[DONE]\n\n"
  end

  def test_chat_forces_the_tool_and_joins_the_streamed_arguments
    call = ->(arguments, head = {}) { {choices: [{delta: {tool_calls: [{index: 0, **head, function: {arguments:}}]}, index: 0}]} }
    body = events({choices: [{delta: {role: 'assistant'}, index: 0}]}, call.('', id: 'tooluse_1'), call.('{"items"'),
                  call.(':[1]}'), {choices: [{delta: {}, finish_reason: 'tool_calls', index: 0}]},
                  {choices: [{delta: {}, index: 0}], usage: {total_tokens: 42}})
    tool = {type: 'function', function: {name: 'record', parameters: {type: 'object'}}}
    requests = serve([200, body]) do |url|
      client = BladeMcp::Inference::Chat.new(url, 'secret', 'claude-opus-4-8')
      assert_equal [{'items' => [1]}, {'total_tokens' => 42}], client.call_tool('system', 'see http://localhost:3000/', tool)
    end
    head, payload = requests.first
    assert_match %r{\APOST /v1/chat/completions }, head
    assert payload['stream']
    assert_equal({'type' => 'function', 'function' => {'name' => 'record'}}, payload['tool_choice'])
    assert_equal [{'role' => 'system', 'content' => 'system'}, {'role' => 'user', 'content' => 'see localhost:3000/'}],
                 payload['messages']
  end

  def test_errors_in_a_successful_response_are_errors
    serve([200, JSON.generate(error: {message: 'Request timed out'})]) do |url|
      client = BladeMcp::Inference::Embedding.new(url, 'secret', 'cohere-embed-v4')
      error = assert_raises(BladeMcp::Inference::Error) { client.embed(%w[a], input_type: 'search_document') }
      assert_match 'Request timed out', error.message
    end
  end

  def test_chat_without_a_tool_call_is_an_error
    body = events({choices: [{delta: {content: 'I refuse.'}, index: 0}]}, {choices: [{delta: {}, finish_reason: 'stop', index: 0}]})
    serve([200, body]) do |url|
      client = BladeMcp::Inference::Chat.new(url, 'secret', 'claude-opus-4-8')
      error = assert_raises(BladeMcp::Inference::Error) { client.call_tool('system', 'user', {function: {name: 'record'}}) }
      assert_match 'finish_reason stop', error.message
    end
  end

  def test_errors_in_a_stream_are_errors
    body = events({error: {message: 'Request timed out'}}).gsub("\n", "\r\n")
    serve([200, body]) do |url|
      client = BladeMcp::Inference::Chat.new(url, 'secret', 'claude-opus-4-8')
      error = assert_raises(BladeMcp::Inference::Error) { client.call_tool('system', 'user', {function: {name: 'record'}}) }
      assert_match 'Request timed out', error.message
    end
  end

  def test_blocked_requests_raise_at_once
    requests = serve([403, '<html>Request blocked</html>']) do |url|
      client = BladeMcp::Inference::Embedding.new(url, 'secret', 'cohere-embed-v4')
      assert_raises(BladeMcp::Inference::Blocked) { client.embed(%w[a], input_type: 'search_document') }
    end
    assert_equal 1, requests.size
  end

  def test_client_errors_are_not_retried
    requests = serve([400, '{"error":"bad input"}']) do |url|
      client = BladeMcp::Inference::Embedding.new(url, 'secret', 'cohere-embed-v4')
      error = assert_raises(BladeMcp::Inference::Error) { client.embed(%w[a], input_type: 'search_query') }
      assert_match '/v1/embeddings returned 400: {"error":"bad input"}', error.message
    end
    assert_equal 1, requests.size
  end

  def test_from_env_needs_both_url_and_key
    assert_nil BladeMcp::Inference::Embedding.from_env('EMBEDDING_URL' => 'https://example.com')
    client = BladeMcp::Inference::Rerank.from_env('RERANK_URL' => 'https://example.com', 'RERANK_KEY' => 'k')
    assert_instance_of BladeMcp::Inference::Rerank, client
  end
end
