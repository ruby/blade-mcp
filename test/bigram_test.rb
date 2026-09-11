# frozen_string_literal: true

require 'test_helper'

class BigramTest < Minitest::Test
  def test_expand_splits_kanji_and_kana_into_overlapping_pairs
    assert_equal 'irb でお おこ こら られ れま まし した 。', BladeMcp::Bigram.expand('irbでおこられました。').split.join(' ')
  end

  def test_expand_keeps_single_characters_and_ascii
    assert_equal ' 金 ', BladeMcp::Bigram.expand('金')
    assert_equal 'File.exists?', BladeMcp::Bigram.expand('File.exists?')
  end

  def test_phrases_expand_each_word_and_keep_quoted_phrases_together
    assert_equal ['金本', 'おこ こら られ', 'method missing'], BladeMcp::Bigram.phrases('金本 おこられ "method missing"')
  end

  def test_phrases_drop_words_without_letters_or_digits
    assert_equal ['irb'], BladeMcp::Bigram.phrases('irb ? 。')
  end
end
