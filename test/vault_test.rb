# frozen_string_literal: true

require 'test_helper'

class VaultTest < Minitest::Test
  def test_seqs_lists_every_page_and_skips_keys_that_are_not_numbers
    client = Aws::S3::Client.new(stub_responses: true)
    client.stub_responses(:list_objects_v2, [
      {contents: %w[ruby-list/10 ruby-list/581.jis ruby-list/64data].map { {key: _1} }, is_truncated: true,
       next_continuation_token: 'next'},
      {contents: %w[ruby-list/2 ruby-list/00001 ruby-list/].map { {key: _1} }, is_truncated: false}
    ])
    assert_equal [2, 10], BladeMcp::Vault.new(client).seqs('ruby-list')
    assert_equal({bucket: 'blade-data-vault', prefix: 'ruby-list/'}, client.api_requests.first[:params])
  end

  def test_fetch_returns_the_raw_bytes_or_nil
    client = Aws::S3::Client.new(stub_responses: true)
    client.stub_responses(:get_object, lambda do |context|
      context.params[:key] == 'ruby-dev/1' ? {body: "From: a\n\nbody"} : 'NoSuchKey'
    end)
    vault = BladeMcp::Vault.new(client)
    assert_equal "From: a\n\nbody", vault.fetch('ruby-dev', 1)
    assert_nil vault.fetch('ruby-dev', 2)
  end
end
