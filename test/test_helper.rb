# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/blade_mcp/parser'

module BladeMcp
  class TestCase < Minitest::Test
    def raw_mail(subject: 'hello', from: 'Yukihiro Matsumoto <matz@ruby-lang.org>',
                 date: 'Sat, 09 Dec 2006 04:47:41 +0900', content_type: 'text/plain; charset=us-ascii',
                 headers: {}, body: "Hello.\n")
      fields = {'From' => from, 'Date' => date, 'Subject' => subject, 'Content-Type' => content_type}
      fields = fields.merge(headers).compact
      "#{fields.map { |name, value| "#{name}: #{value}" }.join("\n")}\n\n".b + body.b
    end

    def encoded_word(text)
      "=?ISO-2022-JP?B?#{[text.encode('ISO-2022-JP')].pack('m0')}?="
    end
  end
end
