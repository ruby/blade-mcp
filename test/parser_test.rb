# frozen_string_literal: true

require 'test_helper'

class ParserTest < BladeMcp::TestCase
  def parse(list = 'ruby-dev', seq = 100, **mail)
    BladeMcp::Parser.parse(raw_mail(**mail), list, seq)
  end

  def test_to_utf8_decodes_iso_2022_jp
    assert_equal 'まつもと ゆきひろです', BladeMcp::Parser.to_utf8('まつもと ゆきひろです'.encode('ISO-2022-JP'), 'ISO-2022-JP')
  end

  def test_to_utf8_ignores_a_japanese_label_that_does_not_match
    assert_equal '金本ともうします。', BladeMcp::Parser.to_utf8('金本ともうします。'.encode('EUC-JP'), 'ISO-2022-JP')
  end

  def test_to_utf8_honors_other_declared_charsets
    assert_equal 'Müller', BladeMcp::Parser.to_utf8('Müller'.encode('ISO-8859-1'), 'iso-8859-1')
  end

  def test_to_utf8_removes_nul
    assert_equal 'ab', BladeMcp::Parser.to_utf8("a\0b")
  end

  def test_decodes_iso_2022_jp_body_and_encoded_from_comment
    message = parse(
      from: "keiju@bc.mbn.or.jp (#{encoded_word('石塚圭樹')} )",
      subject: "[ruby-dev:100] #{encoded_word('シングルトンクラス')}",
      content_type: 'text/plain; charset=ISO-2022-JP',
      body: "けいじゅ＠日本ラショナルです.\n".encode('ISO-2022-JP')
    )
    assert_equal '石塚圭樹', message.from_name
    assert_equal 'keiju@...', message.from_address
    assert_equal '[ruby-dev:100] シングルトンクラス', message.subject
    assert_equal "けいじゅ＠日本ラショナルです.\n", message.body
    assert_equal Time.utc(2006, 12, 8, 19, 47, 41), message.date
  end

  def test_decodes_undeclared_euc_jp
    message = parse(content_type: nil, body: "大塚＠三井造船です. ruby ついに公開ですね.\n".encode('EUC-JP'))
    assert_equal "大塚＠三井造船です. ruby ついに公開ですね.\n", message.body
  end

  def test_masks_the_whole_domain_of_from
    message = parse(from: 'yamataka@u08.itscom.net')
    assert_nil message.from_name
    assert_equal 'yamataka@...', message.from_address
    message = parse(from: '"foo@example.com" <foo@example.com>')
    assert_equal 'foo@...', message.from_name
  end

  def test_joins_a_raw_subject_folded_inside_a_word
    subject = "[ruby-list:1455] Re: サブクラ\n\tスの作成".encode('EUC-JP')
    message = BladeMcp::Parser.parse("From: a@example.com\nSubject: #{subject.b}\n\nbody\n".b, 'ruby-list', 1455)
    assert_equal '[ruby-list:1455] Re: サブクラスの作成', message.subject
  end

  def test_reply_candidates_put_in_reply_to_first_then_the_nearest_reference
    message = parse(headers: {
      'Message-ID' => '<self@example>',
      'In-Reply-To' => '"Mon, 28 Jul 97" <parent@example>',
      'References' => "<root@example> <middle@example>\n <parent@example> <self@example>"
    })
    assert_equal 'self@example', message.msgid
    assert_equal %w[parent@example middle@example root@example], message.reply_msgids
  end

  def test_cites_a_list_ref_in_the_body_of_a_reply
    body = "In message \"[ruby-list:3516] Re: local class\"\n> quoted [ruby-list:3000]\n"
    message = parse('ruby-dev', 2, subject: '[ruby-dev:2] Re: local class', body:)
    assert_equal ['ruby-list', 3516], [message.cited_list, message.cited_seq]
  end

  def test_does_not_cite_from_a_new_thread_or_a_later_message
    assert_nil parse('ruby-list', 10, subject: 'new topic', body: "see [ruby-list:5]\n").cited_list
    message = parse('ruby-list', 10, subject: 'Re: topic', body: "[ruby-list :00010 ] and [ruby-list:12]\n[ruby-list:7]\n")
    assert_equal ['ruby-list', 7], [message.cited_list, message.cited_seq]
  end

  def test_redmine_notification_keeps_subject_and_issue_only
    message = parse(
      'ruby-core', 120000,
      subject: '[ruby-core:120000] [Ruby master Feature#20861] Add an environment variable',
      headers: {'X-Redmine-Host' => 'bugs.ruby-lang.org', 'X-Redmine-Issue-Id' => '20861'},
      body: "Issue #20861 has been updated by someone.\n"
    )
    assert message.notification
    assert_equal 20861, message.issue
    assert_nil message.body
  end

  def test_issue_number_of_a_human_reply_comes_from_the_subject
    message = parse('ruby-core', 45000, subject: '[ruby-core:45000] Re: [ruby-trunk - Feature #5632] Attempt to open')
    refute message.notification
    assert_equal 5632, message.issue
    assert_equal 4346, parse(subject: '[ruby-core:35000] [Ruby 1.9-Bug#4346][Closed] Sort_by!').issue
  end

  def test_attachments_keep_text_and_describe_binary
    gif = "GIF89a\x01\x00\x01\x00\x00\x00\x00;".b
    euc = "/* 例外を投げる */\n".encode('EUC-JP')
    body = <<~MIME.b
      --b
      Content-Type: text/plain; charset=us-ascii

      Here is a patch.
      --b
      Content-Type: application/octet-stream; name="fix.patch"
      Content-Disposition: attachment; filename="fix.patch"

      --- a/io.c
      +++ b/io.c
      --b
      Content-Type: application/octet-stream; name="ja.patch"
      Content-Transfer-Encoding: base64

      #{[euc].pack('m')}
      --b
      Content-Type: image/gif; name="logo.gif"
      Content-Transfer-Encoding: base64
      Content-Disposition: attachment; filename="logo.gif"

      #{[gif].pack('m')}
      --b--
    MIME
    message = parse(content_type: 'multipart/mixed; boundary="b"', body:)
    assert_equal "Here is a patch.", message.body.strip
    patch, japanese, image = message.attachments
    assert_equal ['fix.patch', "--- a/io.c\n+++ b/io.c"], [patch.filename, patch.content.strip]
    assert_equal ['ja.patch', "/* 例外を投げる */\n"], [japanese.filename, japanese.content]
    assert_equal ['logo.gif', gif.bytesize, nil], [image.filename, image.size, image.content]
  end

  def test_html_only_mail_becomes_text
    message = parse(content_type: 'text/html; charset=utf-8', body: '<p>Hello &amp; welcome</p><br>bye')
    assert_equal "Hello & welcome\n\nbye", message.body
  end
end
