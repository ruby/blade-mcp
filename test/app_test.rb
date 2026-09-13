# frozen_string_literal: true

require 'test_helper'
require 'rack/test'

class AppTest < BladeMcp::TestCase
  include Rack::Test::Methods

  TOKEN = 'correct horse battery staple'
  # Values of headers that must never be returned.
  PRIVATE = %w[to-secret.example cc-secret.example reply-secret.example return-secret.example received-secret.example
               msgid-secret.example from-secret.example].freeze

  def app
    BladeMcp::App
  end

  def setup
    super
    BladeMcp::App.set :token, TOKEN
    BladeMcp::App.set :embedder, nil
    BladeMcp::App.set :reranker, nil
    headers = {
      'To' => 'ruby-dev@to-secret.example', 'Cc' => 'someone@cc-secret.example',
      'Reply-To' => 'ruby-dev@reply-secret.example', 'Return-Path' => '<bounce@return-secret.example>',
      'Received' => 'from mx.received-secret.example by blade', 'X-Mail-Count' => '30000'
    }
    save 'ruby-dev', 30000, subject: '[ruby-dev:30000] lib/irb/locale.rb uses File.exists?',
                            from: '"Yutaka Kanemoto" <kinpoco@from-secret.example>',
                            headers: headers.merge('Message-ID' => '<root@msgid-secret.example>'),
                            content_type: 'multipart/mixed; boundary="b"', body: <<~MIME
                              --b
                              Content-Type: text/plain; charset=us-ascii

                              irb warns about File.exists?
                              --b
                              Content-Type: text/x-diff; name="locale.patch"

                              -File.exists?
                              +File.exist?
                              --b
                              Content-Type: application/octet-stream; name="core"

                              \x00\x01
                              --b--
                            MIME
    save 'ruby-dev', 30001, subject: '[ruby-dev:30001] Re: [Ruby master Bug#2345] File.exists?',
                            date: 'Sun, 10 Dec 2006 10:00:00 +0900',
                            headers: headers.merge('Message-ID' => '<reply@msgid-secret.example>',
                                                   'In-Reply-To' => '<root@msgid-secret.example>'),
                            body: "Fixed.\n"
    store.resolve_parents
  end

  def mcp(method, params = {}, token: TOKEN)
    header 'Authorization', "Bearer #{token}" if token
    header 'Accept', 'application/json, text/event-stream'
    header 'Content-Type', 'application/json'
    post '/mcp', JSON.generate(jsonrpc: '2.0', id: 1, method:, params:)
  end

  def call_tool(name, arguments)
    mcp('tools/call', {name:, arguments:})
    assert_equal 200, last_response.status
    result = JSON.parse(last_response.body).fetch('result')
    refute result['isError'], result.dig('content', 0, 'text')
    JSON.parse(result.dig('content', 0, 'text'))
  end

  def test_rejects_a_missing_or_wrong_token
    mcp('ping', token: nil)
    assert_equal 401, last_response.status
    assert_equal 'Bearer', last_response.headers['www-authenticate']
    mcp('ping', token: 'wrong')
    assert_equal 401, last_response.status
  end

  def test_rejects_everything_when_no_token_is_configured
    BladeMcp::App.set :token, nil
    mcp('ping', token: '')
    assert_equal 401, last_response.status
  end

  def test_initialize_and_tools_list
    mcp('initialize', {protocolVersion: '2025-06-18', capabilities: {}, clientInfo: {name: 'test', version: '0'}})
    result = JSON.parse(last_response.body)['result']
    assert_equal 'blade-mcp', result.dig('serverInfo', 'name')
    assert_match 'get_thread', result['instructions']
    mcp('tools/list')
    tools = JSON.parse(last_response.body).dig('result', 'tools')
    assert_equal %w[get_message get_thread search], tools.map { _1['name'] }.sort
    assert tools.all? { _1.dig('annotations', 'readOnlyHint') }
  end

  def test_get_is_not_allowed
    header 'Authorization', "Bearer #{TOKEN}"
    get '/mcp'
    assert_equal 405, last_response.status
  end

  def test_search
    results = call_tool('search', {query: 'File.exists', lists: ['ruby-dev']})['results']
    assert_equal ['[ruby-dev:30000]', '[ruby-dev:30001]'], results.map { _1['ref'] }.sort
    reply = results.find { _1['ref'] == '[ruby-dev:30001]' }
    assert_equal 2345, reply['issue']
    assert_equal 'Yukihiro Matsumoto <matz@...>', reply['from']
    assert_equal '2006-12-10T01:00:00Z', reply['date']
    assert_equal 'Fixed.', reply['snippet']
    assert_equal ['[ruby-dev:30000]'], call_tool('search', {query: 'File.exists', from: 'kanemoto'})['results'].map { _1['ref'] }
  end

  def test_search_date_range_includes_both_ends
    refs = ->(arguments) { call_tool('search', {query: 'File.exists', **arguments})['results'].map { _1['ref'] } }
    assert_equal ['[ruby-dev:30000]'], refs.(date_to: '2006-12-08')
    assert_equal ['[ruby-dev:30001]'], refs.(date_from: '2006-12-10', date_to: '2006-12-10')
  end

  def test_search_reports_bad_arguments_as_tool_errors
    mcp('tools/call', {name: 'search', arguments: {query: 'irb', date_from: '2006/12/01'}})
    result = JSON.parse(last_response.body)['result']
    assert result['isError']
    assert_equal 'date_from and date_to must be YYYY-MM-DD', result.dig('content', 0, 'text')
  end

  def test_get_message
    message = call_tool('get_message', {ref: '[ruby-dev:30000]'})
    assert_equal 'Yutaka Kanemoto <kinpoco@...>', message['from']
    assert_equal 'irb warns about File.exists?', message['body']
    assert_equal ['[ruby-dev:30001]'], message['replies']
    assert_nil message['parent']
    assert_equal [{'filename' => 'locale.patch', 'size' => 26, 'content' => "-File.exists?\n+File.exist?"},
                  {'filename' => 'core', 'size' => 2}], message['attachments']
    assert_equal '[ruby-dev:30000]', call_tool('get_message', {ref: 'ruby-dev:30001'})['parent']
  end

  def test_get_message_of_an_unknown_ref
    mcp('tools/call', {name: 'get_message', arguments: {ref: '[ruby-dev:1]'}})
    assert JSON.parse(last_response.body).dig('result', 'isError')
  end

  def test_get_thread
    thread = call_tool('get_thread', {ref: '[ruby-dev:30001]'})
    assert_equal '[ruby-dev:30000]', thread['root']
    assert_equal [['[ruby-dev:30000]', nil, 0], ['[ruby-dev:30001]', '[ruby-dev:30000]', 1]],
                 thread['messages'].map { _1.values_at('ref', 'parent', 'depth') }
    refute thread['truncated']
  end

  def test_responses_never_carry_private_headers
    bodies = [
      call_tool('search', {query: 'File.exists'}),
      call_tool('get_message', {ref: '[ruby-dev:30000]'}),
      call_tool('get_message', {ref: '[ruby-dev:30001]'}),
      call_tool('get_thread', {ref: '[ruby-dev:30000]'})
    ].map { JSON.generate(_1) }
    PRIVATE.each do |value|
      bodies.each { |body| refute_includes body, value }
    end
    expected = %w[ref from date subject issue snippet parent replies body attachments root messages truncated depth
                  results filename size content]
    keys = bodies.flat_map { |body| collect_keys(JSON.parse(body)) }.uniq
    assert_empty keys - expected
  end

  def collect_keys(value)
    case value
    when Hash then value.keys + value.values.flat_map { collect_keys(_1) }
    when Array then value.flat_map { collect_keys(_1) }
    else []
    end
  end
end
