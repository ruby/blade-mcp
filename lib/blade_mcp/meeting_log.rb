# frozen_string_literal: true

require 'date'
require 'json'
require 'net/http'
require 'rubygems/package'
require 'stringio'
require 'zlib'
require_relative 'redmine'

module BladeMcp
  # Notes of the Ruby developers' meetings in ruby/dev-meeting-log, split into
  # agenda items at their level 1 to 3 headings. Level 4 headings such as
  # Discussion and Conclusion stay inside their item. The first import reads a
  # tarball of the repository, later syncs fetch only the files changed since
  # the commit imported last.
  class MeetingLog
    REPO = 'ruby/dev-meeting-log'
    BRANCH = 'master'
    API = 'https://api.github.com'
    ARCHIVE = 'https://codeload.github.com'
    RAW = 'https://raw.githubusercontent.com'
    # Japanese copies of notes kept in English as well are left out.
    NOTES = %r{\A\d{4}/[^/]+(?<!-JA)\.md\z}
    HEADING = /\A\#{1,3} /
    ISSUE = /(?:Feature|Bug|Misc) #(\d+)/
    MIN_BODY = 20

    # Names carry the date as DevMeeting-2026-07-09, DevelopersMeeting20200514Japan
    # or, under the year, DevCamp-08-11.
    def self.date(path)
      name = File.basename(path)
      if (match = name.match(/(\d{4})-?(\d{2})-?(\d{2})/))
        Date.new(*match.captures.map(&:to_i))
      elsif (match = name.match(/(\d{2})-(\d{2})/))
        Date.new(path[0, 4].to_i, *match.captures.map(&:to_i))
      end
    rescue Date::Error
      nil
    end

    # Returns [heading, body] pairs. Lines in code blocks are never headings,
    # and items with next to no body are dropped.
    def self.items(text)
      items = [[+'', +'']]
      fenced = false
      text.sub(/\A---\n.*?\n---\n/m, '').each_line do |line|
        fenced = !fenced if line.lstrip.start_with?('```')
        if !fenced && line.match?(HEADING)
          items << [line.sub(/\A#+ /, '').strip, +'']
        else
          items.last[1] << line
        end
      end
      items.reject { |_, body| body.strip.size < MIN_BODY }
    end

    def initialize(db, api: API, archive: ARCHIVE, raw: RAW, token: ENV.fetch('GITHUB_TOKEN', nil), log: $stdout)
      @db = db
      @api = api
      @archive = archive
      @raw = raw
      @token = token
      @log = log
    end

    def import
      commit = head
      files = {}
      tar = Zlib::GzipReader.new(StringIO.new(get("#{@archive}/#{REPO}/tar.gz/#{commit}")))
      Gem::Package::TarReader.new(tar).each do |entry|
        path = entry.full_name.split('/', 2)[1]
        files[path] = entry.read.force_encoding(Encoding::UTF_8) if entry.file? && path&.match?(NOTES)
      end
      @db.transaction do
        @db[:meeting_items].exclude(path: files.keys).delete
        files.each { |path, text| save(path, text) }
        checked!(commit)
      end
      @log.puts "imported #{files.size} meeting notes from #{REPO}"
      files.size
    end

    def sync
      base = @db[:sync_state].where(name: 'meeting_log_commit').get(:value)
      raise 'run import-meetings before syncing' unless base
      commit = head
      files = JSON.parse(get("#{@api}/repos/#{REPO}/compare/#{base}...#{commit}", api: true)).fetch('files')
      changed = files.select { |file| file['filename'].match?(NOTES) || file['previous_filename']&.match?(NOTES) }
      @db.transaction do
        changed.each do |file|
          delete(file['previous_filename']) if file['previous_filename']
          if file['status'] == 'removed'
            delete(file['filename'])
          elsif file['filename'].match?(NOTES)
            save(file['filename'], get("#{@raw}/#{REPO}/#{commit}/#{file['filename']}").force_encoding(Encoding::UTF_8))
          end
        end
        checked!(commit)
      end
      @log.puts "synced #{changed.size} meeting notes from #{REPO}"
      changed.size
    end

    private

    # An item whose heading or body changed is read again by the extractor.
    def save(path, text)
      date = self.class.date(path) or return @log.puts("#{path} has no date in its name, skipped")
      items = self.class.items(text)
      unchanged = Sequel.&(Sequel[:meeting_items][:heading] =~ Sequel[:excluded][:heading],
                           Sequel[:meeting_items][:body] =~ Sequel[:excluded][:body])
      update = %i[date heading body issue_id].to_h { |column| [column, Sequel[:excluded][column]] }
      update[:statements_extracted_at] = Sequel.case({unchanged => Sequel[:meeting_items][:statements_extracted_at]}, nil)
      items.each_with_index do |(heading, body), position|
        @db[:meeting_items].insert_conflict(target: %i[path position], update:)
                           .insert(path:, position:, date:, heading:, body:, issue_id: heading[ISSUE, 1]&.to_i)
      end
      @db[:meeting_items].where(path:).where(Sequel[:position] >= items.size).delete
    end

    def delete(path)
      @db[:meeting_items].where(path:).delete
    end

    def checked!(commit)
      @db[:sync_state].insert_conflict(target: :name, update: {value: Sequel[:excluded][:value]})
                      .insert(name: 'meeting_log_commit', value: commit)
    end

    def head
      JSON.parse(get("#{@api}/repos/#{REPO}/commits/#{BRANCH}", api: true)).fetch('sha')
    end

    # Anonymous API calls are limited to 60 an hour per address, which a
    # Heroku dyno shares with others, so GITHUB_TOKEN is sent when set.
    def get(url, api: false)
      headers = {'User-Agent' => Redmine::USER_AGENT}
      headers['Authorization'] = "Bearer #{@token}" if api && @token
      response = Net::HTTP.get_response(URI(url), headers)
      raise "#{url} returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      response.body
    end
  end
end
