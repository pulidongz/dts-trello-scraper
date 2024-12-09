#!/usr/bin/env ruby

ENV['BUNDLE_GEMFILE'] ||= File.expand_path('Gemfile', __dir__)
require 'bundler'
Bundler.setup(:default)

require 'fileutils'
require 'json'
require 'openai'
require 'progressbar'
require 'dotenv'
require 'trello'
require 'sqlite3'

# Load environment variables from .env file
Dotenv.load

# Load Trello API keys
Trello.configure do |config|
  config.developer_public_key = ENV['TRELLO_API_KEY']
  config.member_token = ENV['TRELLO_API_TOKEN']
end

class TrelloScraper
  LOG_PROCESSED_PATH = File.join(Dir.pwd, 'logs', 'processed.log')
  ERROR_LOG_FILE_PATH = File.join(Dir.pwd, 'logs', 'errors.log')
  DB_PATH = File.join(Dir.pwd, 'trello_scraper.db')
  LAST_BOARD_FILE = File.join(Dir.pwd, 'last_board.txt')

  def initialize
    %w[OPENAI_API_KEY TRELLO_API_KEY TRELLO_API_TOKEN].each do |key|
      unless ENV[key]
        puts "Error: #{key} not found in .env file"
        exit 1
      end
    end

    FileUtils.mkdir_p(File.dirname(ERROR_LOG_FILE_PATH))
    File.write(ERROR_LOG_FILE_PATH, '')

    setup_database

    @openai_client = OpenAI::Client.new(access_token: ENV['OPENAI_API_KEY'], log_errors: true)
  end

  def run
    loop do
      puts 'Enter the name of the board you want to scrape, or press L to list all boards. Press Enter to exit.'
      user_input = gets.chomp.strip

      case user_input.downcase
      when 'l'
        list_boards
        puts 'Enter the name or ID of the board you want to scrape, or press Enter to exit.'
        board_input = gets.chomp.strip
        process_board(board_input)
      when ''
        puts 'Exiting script.'
        exit
      else
        process_board(user_input)
      end
    end
  end

  private

  def setup_database
    @db = SQLite3::Database.new(DB_PATH)
    @db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS lists (
        id TEXT PRIMARY KEY,
        name TEXT,
        board_id TEXT
      );
    SQL

    @db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS cards (
        id TEXT PRIMARY KEY,
        name TEXT,
        description TEXT,
        list_id TEXT,
        board_id TEXT
      );
    SQL

    @db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS comments (
        id TEXT PRIMARY KEY,
        card_id TEXT,
        text TEXT,
        FOREIGN KEY(card_id) REFERENCES cards(id)
      );
    SQL

    @db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS contacts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        card_id TEXT NOT NULL,
        name TEXT NOT NULL,
        location TEXT NOT NULL,
        phone TEXT NOT NULL,
        UNIQUE (card_id, name, location, phone)
        FOREIGN KEY(card_id) REFERENCES cards(id)
      );
    SQL
  end

  def list_boards
    puts "\nFetching boards..."
    boards = Trello::Board.all
    boards.each do |board|
      puts "Board Name: #{board.name}, ID: #{board.id}"
    end
  rescue StandardError => e
    log_error("Error listing boards: #{e.message}")
    puts "\nFailed to fetch boards. Please check your API keys and try again."
  end

  def process_board(board_input)
    board = find_board_by_name_or_id(board_input)

    if board
      if last_board_stored == board.id
        puts "\nUsing last stored board: #{board.name}"
        scrape_board(board, update: true)
      else
        puts "\nNew board selected: #{board.name}. Truncating database."
        truncate_database
        save_last_board(board.id)
        scrape_board(board)
      end
    else
      puts "Board does not exist. Exiting script."
      exit
    end
  end

  def find_board_by_name_or_id(input)
    Trello::Board.all.find { |b| b.name.casecmp(input).zero? || b.id == input }
  rescue StandardError => e
    log_error("Error finding board: #{e.message}")
    nil
  end

  def scrape_board(board, update: false)
    board.lists.each do |list|
      list_progress = ProgressBar.create(
        title: "Processing List: #{list.name}",
        total: list.cards.size,
        format: '%t |%B| %p%%'
      )

      @db.execute("INSERT OR IGNORE INTO lists (id, name, board_id) VALUES (?, ?, ?)", [list.id, list.name, board.id])

      list.cards.each do |card|
        begin
          @db.execute("INSERT OR IGNORE INTO cards (id, name, description, list_id, board_id) VALUES (?, ?, ?, ?, ?)", [
            card.id, card.name, card.desc, list.id, board.id
          ])

          card.comments.each do |comment|
            @db.execute("INSERT OR IGNORE INTO comments (id, card_id, text) VALUES (?, ?, ?)", [
              comment.id, card.id, comment.data['text']
            ])
          end

          scan_for_contacts(card)
          list_progress.increment
        rescue StandardError => e
          log_error("Failed to process card: #{board.id} -> #{list.id} -> #{card.id}: #{e.message}")
        end
      end
    end

    puts "\nScraping complete for board: #{board.name}"
  rescue StandardError => e
    log_error("Error scraping board #{board.name}: #{e.message}")
    puts "Failed to scrape board. Please try again."
  end

  def scan_for_contacts(card)
    data_to_scan = [card.name, card.desc]

    @db.execute("SELECT text FROM comments WHERE card_id = ?", [card.id]).each do |row|
      data_to_scan << row.first
    end

    data_to_scan.compact!

    extracted_contacts = []

    data_to_scan.each do |text|
      begin
        response = @openai_client.chat(
          parameters: {
            model: 'gpt-4o-mini',
            response_format: { type: 'json_object' },
            messages: [
              {
                role: 'system',
                content: "You are an assistant that extracts structured information."
              },
              {
                role: 'user',
                content: "Extract name, location, and phone from the following text:\n#{text}. Respond in JSON format."
              }
            ],
            max_tokens: 100
          }
        )

        content = response.dig('choices', 0, 'message', 'content')
        return nil unless content

        data = JSON.parse(content, symbolize_names: true) rescue nil
        unless data
          log_error("Failed to parse JSON for card #{card.id}. Content: #{content}")
          next
        end

        # Validate extracted data and skip or log errors as necessary
        if data[:phone].to_s.strip.empty? ||
            data[:name].to_s.strip.empty? ||
            data[:location].to_s.strip.empty? ||
            [data[:name], data[:location], data[:phone]].any? { |field| %w[N/A not provided Not specified].include?(field.to_s.strip) }
          log_error("Skipping invalid or incomplete record for card #{card.id}. Extracted data: #{data.inspect}")
          next
        end

        # Check for duplicates
        existing_contact = @db.get_first_row("SELECT * FROM contacts WHERE card_id = ? AND name = ? AND location = ? AND phone = ?", [
          card.id, data[:name].strip, data[:location].strip, data[:phone].strip
        ])
        if existing_contact
          log_error("Skipping duplicate record for card #{card.id}. Extracted data: #{data.inspect}")
          next
        end

        # Add to extracted_contacts if all fields are valid
        extracted_contacts << [card.id, data[:name].strip, data[:location].strip, data[:phone].strip]
      rescue StandardError => e
        log_error("Error scanning card #{card.id}. Text: #{text}. Error: #{e.message}")
      end
    end

    # Insert contacts in bulk if valid records exist
    if extracted_contacts.any?
      @db.execute("BEGIN TRANSACTION;")
      begin
        extracted_contacts.each do |contact|
          @db.execute("INSERT INTO contacts (card_id, name, location, phone) VALUES (?, ?, ?, ?)", contact)
        end
        @db.execute("COMMIT;")
      rescue StandardError => e
        @db.execute("ROLLBACK;")
        log_error("Database insertion failed for card #{card.id}: #{e.message}")
      end
    end
  end

  def truncate_database
    @db.execute("DELETE FROM lists;")
    @db.execute("DELETE FROM cards;")
    @db.execute("DELETE FROM comments;")
    @db.execute("DELETE FROM contacts;")
  end

  def save_last_board(board_id)
    File.write(LAST_BOARD_FILE, board_id)
  end

  def last_board_stored
    return nil unless File.exist?(LAST_BOARD_FILE)

    File.read(LAST_BOARD_FILE).strip
  end

  def log_error(message)
    File.open(ERROR_LOG_FILE_PATH, 'a') { |file| file.puts(message) }
  end
end

# Run the Trello scraper
if __FILE__ == $0
  puts 'Starting Trello scraper...'
  TrelloScraper.new.run
end
