# frozen_string_literal: true

require 'cgi/escape'
require 'mail'
require 'nkf'

module BladeMcp
  # Turns one raw RFC822 message from the vault into the fields blade-mcp
  # keeps. To, Cc, Reply-To, Return-Path and Received are never read, and the
  # Message-ID only serves to link replies.
  module Parser
    Message = Data.define(:list, :seq, :msgid, :reply_msgids, :cited_list, :cited_seq, :from_name, :from_address,
                          :date, :subject, :body, :issue, :notification, :attachments)
    Attachment = Data.define(:filename, :size, :content)

    JAPANESE = /2022-JP|EUC-?JP|SHIFT_JIS|SJIS|WINDOWS-31J|CP932|CP5022|CP51932/i
    LIST_REF = /\[(ruby-[a-z]+)\s*:\s*0*(\d+)\s*\]/
    ISSUE = /\[[^\]]*\b(?:Bug|Feature|Misc|Backport)\s*#(\d+)\]/
    # blade.ruby-lang.org masks with /@[a-zA-Z.\-]+/, which leaves most of a
    # domain such as u08.example.net visible.
    DOMAIN = /@[a-zA-Z0-9.\-]+/
    MSGID = /<([^<>\s]+)>/
    REPLY = /\A(?:\s*\[[^\]]*\])*\s*re\b/i
    # Old list servers folded raw Japanese subjects in the middle of a word,
    # and unfolding leaves the continuation tab between the two halves.
    FOLD = /(?<=[\p{Han}\p{Hiragana}\p{Katakana}ー])[ \t]*\t[ \t]*(?=[\p{Han}\p{Hiragana}\p{Katakana}ー])/

    module_function

    def parse(raw, list, seq)
      mail = Mail.read_from_string(raw.b)
      msgid = message_ids(header(mail, 'Message-ID')).first
      replies = (message_ids(header(mail, 'In-Reply-To')) + message_ids(header(mail, 'References')).reverse).uniq - [msgid]
      subject = decode(header(mail, 'Subject'))
      notification = !field(mail, 'X-Redmine-Host').nil? || msgid.to_s.start_with?('redmine.')
      body, attachments = notification ? [nil, []] : content(mail)
      name, address = from(mail)
      cited_list, cited_seq = citation(body, subject, replies, list, seq)
      Message.new(list:, seq:, msgid:, reply_msgids: replies, cited_list:, cited_seq:, from_name: name,
                  from_address: address, date: date(mail), subject:, body:, issue: issue(mail, subject),
                  notification:, attachments:)
    end

    # Labels in the archive cannot be trusted for Japanese mail: declared
    # ISO-2022-JP bodies are often EUC-JP or Shift_JIS, and many old messages
    # declare nothing, so those go through NKF's guess. Other declared
    # charsets (Latin-1 on ruby-talk and the like) are honored.
    def to_utf8(str, charset = nil)
      bytes = str.b
      utf8 = bytes.dup.force_encoding(Encoding::UTF_8)
      text =
        if !bytes.include?("\e") && utf8.valid_encoding?
          utf8
        elsif (encoding = trusted_encoding(charset)) && !bytes.include?("\e")
          bytes.force_encoding(encoding).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
        else
          NKF.nkf('-w -m0 -x', bytes).force_encoding(Encoding::UTF_8)
        end
      text.scrub.delete("\0")
    end

    def trusted_encoding(charset)
      return unless charset
      encoding = Mail::Utilities.pick_encoding(charset)
      return if [Encoding::BINARY, Encoding::US_ASCII, Encoding::UTF_8].include?(encoding)
      encoding unless japanese?(encoding)
    end

    def japanese?(encoding)
      encoding.name.match?(JAPANESE)
    end

    # Mail decodes encoded words in Subject, display names and filenames
    # through this encoder, whose default String#encode has no converter for
    # labels such as ISO-2022-JP-2 and raises.
    class CharsetEncoder < Mail::Utilities::BestEffortCharsetEncoder
      def encode(string, charset)
        Parser.japanese?(Mail::Utilities.pick_encoding(charset)) ? Parser.to_utf8(string, charset) : super
      end
    end
    Mail::Utilities.charset_encoder = CharsetEncoder.new

    def field(mail, name)
      mail.header.fields.find { |f| f.name.casecmp?(name) }
    end

    def header(mail, name)
      field(mail, name)&.value
    end

    def message_ids(value)
      value = to_utf8(value.to_s)
      ids = value.scan(MSGID).flatten
      ids = [value.strip] if ids.empty? && value.strip.match?(/\A[^\s<>]+@[^\s<>]+\z/)
      ids
    end

    def decode(value)
      return if value.nil?
      text = to_utf8(value)
      text = to_utf8(Mail::Encodings.value_decode(text)) if text.include?('=?')
      text.gsub(FOLD, '').gsub(/\s+/, ' ').strip
    end

    def mask(value)
      value&.gsub(DOMAIN, '@...')
    end

    def from(mail)
      field = field(mail, 'From')
      return [nil, nil] unless field
      address = field.addrs.first if field.respond_to?(:addrs)
      if address
        [mask(decode(address.name)), mask(address.address)]
      else
        [mask(decode(field.value)), nil]
      end
    end

    def date(mail)
      mail.date&.to_time
    rescue Date::Error, ArgumentError
      nil
    end

    def issue(mail, subject)
      id = header(mail, 'X-Redmine-Issue-Id').to_i
      id = subject.to_s[ISSUE, 1].to_i if id.zero?
      id unless id.zero?
    end

    # Old ruby-list replies often carry no reply headers but quote the
    # parent as "In message [ruby-list:NNNN] ...". Only replies are looked at,
    # so a new thread that merely mentions another post is not attached to it.
    def citation(body, subject, replies, list, seq)
      return unless replies.any? || subject.to_s.match?(REPLY)
      body.to_s.scan(LIST_REF) do |cited_list, cited_seq|
        cited_seq = cited_seq.to_i
        return [cited_list, cited_seq] unless cited_list == list && cited_seq >= seq
      end
      nil
    end

    def content(mail)
      plain = +''
      html = +''
      attachments = []
      walk(mail, plain, html, attachments)
      body = plain.empty? && !html.empty? ? html_to_text(html) : plain
      [body, attachments]
    end

    def walk(part, plain, html, attachments)
      if part.multipart?
        part.parts.each { |child| walk(child, plain, html, attachments) }
      elsif part.attachment?
        attachments << attachment(part)
      else
        case part.mime_type&.downcase
        when nil, 'text/plain', 'text/enriched', 'message/rfc822', 'message/partial'
          plain << to_utf8(bytes(part), charset(part))
        when 'text/html'
          html << to_utf8(bytes(part), charset(part))
        when 'application/pgp-signature'
          nil
        else
          attachments << attachment(part)
        end
      end
    end

    def attachment(part)
      data = bytes(part)
      content = to_utf8(data, charset(part)) if textual?(part, data)
      Attachment.new(filename: decode(part.filename) || 'noname', size: data.bytesize, content:)
    end

    def textual?(part, data)
      return false if data.include?("\0")
      part.mime_type.to_s.downcase.start_with?('text/') ||
        data.dup.force_encoding(Encoding::UTF_8).valid_encoding? ||
        japanese?(NKF.guess(data))
    end

    def bytes(part)
      part.body.decoded.b
    rescue StandardError
      part.body.raw_source.b
    end

    def charset(part)
      part.content_type_parameters&.[]('charset')
    end

    def html_to_text(html)
      text = html.gsub(%r{<(script|style)\b.*?</\1>}im, '').gsub(%r{<br\s*/?>|</p>|</div>}i, "\n").gsub(/<[^>]*>/, '')
      CGI.unescapeHTML(text)
    end
  end
end
