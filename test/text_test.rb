# frozen_string_literal: true

require 'test_helper'

class TextTest < Minitest::Test
  def test_passage_drops_quoted_lines_and_truncates
    body = "> quoted line\n＞全角の引用\nmy answer\n"
    assert_equal "Subject\n\nmy answer", BladeMcp::Text.passage('Subject', body, 100)
    assert_equal 'Subj', BladeMcp::Text.passage('Subject', body, 4)
  end

  def test_snippet_starts_near_the_first_hit
    body = "#{'filler ' * 100}the File.exists? call is deprecated #{'tail ' * 100}"
    snippet = BladeMcp::Text.snippet(body, ['file.exists'], 80)
    assert_includes snippet, 'File.exists? call'
    assert snippet.start_with?('...')
    assert snippet.end_with?('...')
  end
end
