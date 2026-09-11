# frozen_string_literal: true

require 'test_helper'
require 'socket'

class InferenceTest < Minitest::Test
  # Serves the given [status, body] pairs in order and records the requests.
  def serve(*responses)
    server = TCPServer.new('127.0.0.1', 0)
    requests = []
    thread = Thread.new do
      responses.each do |status, body|
        socket = server.accept
        head = socket.gets("\r\n\r\n")
        length = head[/^content-length: (\d+)/i, 1].to_i
        requests << [head, JSON.parse(socket.read(length))]
        socket.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n" \
                     "Connection: close\r\n\r\n#{body}")
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
