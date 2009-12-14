$LOAD_PATH.concat Dir.glob(File.expand_path('../../vendor/gems/*/lib', __FILE__))

require 'css_parser'
require 'hpricot'
require 'open-uri'

begin
  require 'colored'
rescue LoadError
  class String
    %w(red green blue yellow).each do |color|
      define_method(color) { self }
    end
  end
end

class Deadweight
  attr_accessor :root, :stylesheets, :rules, :pages, :ignore_selectors, :mechanize, :log_file
  attr_reader :unused_selectors, :parsed_rules

  def initialize
    @root = 'http://localhost:3000'
    @stylesheets = []
    @pages = []
    @rules = ""
    @ignore_selectors = []
    @mechanize = false
    @log_file = STDERR
    yield self and run if block_given?
  end

  def analyze(html)
    doc = Hpricot(html)

    @unused_selectors.collect do |selector, declarations|
      # We test against the selector stripped of any pseudo classes,
      # but we report on the selector with its pseudo classes.
      unless doc.search(strip(selector)).empty?
        log.puts("  #{selector.green}")
        selector
      end
    end
  end

  # Find all unused CSS selectors and return them as an array.
  def run
    css = CssParser::Parser.new

    @stylesheets.each do |path|
      css.add_block!(fetch(path))
    end

    css.add_block!(rules)

    @parsed_rules     = {}
    @unused_selectors = []

    css.each_selector do |selector, declarations, specificity|
      unless @unused_selectors.include?(selector)
        unless selector =~ ignore_selectors
          @unused_selectors << selector
          @parsed_rules[selector] = declarations
        end
      end
    end

    # Remove selectors with pseudo classes that already have an equivalent
    # without the pseudo class. Keep the ones that don't, we need to test
    # them.
    @unused_selectors.each do |selector|
      if has_pseudo_classes(selector) && @unused_selectors.include?(strip(selector))
        @unused_selectors.delete(selector)
      end
    end

    total_selectors = @unused_selectors.size

    pages.each do |page|
      log.puts

      if page.respond_to?(:read)
        html = page.read
      elsif page.respond_to?(:call)
        result = instance_eval(&page)

        html = case result
               when String
                 result
               else
                 @agent.page.body
               end
      else
        begin
          html = fetch(page)
        rescue FetchError => e
          log.puts(e.message.red)
          next
        end
      end

      process!(html)
    end

    log.puts
    log.puts "found #{@unused_selectors.size} unused selectors out of #{total_selectors} total".yellow
    log.puts

    @unused_selectors
  end

  def dump(output)
    output.puts(@unused_selectors)
  end

  def process!(html)
    analyze(html).each do |selector|
      @unused_selectors.delete(selector)
    end
  end

  # Returns the Mechanize instance, if +mechanize+ is set to +true+.
  def agent
    @agent ||= initialize_agent
  end

  # Fetch a path, using Mechanize if +mechanize+ is set to +true+.
  def fetch(path)
    log.puts(path)

    loc = root + path

    if @mechanize
      loc = "file://#{File.expand_path(loc)}" unless loc =~ %r{^\w+://}

      begin
        page = agent.get(loc)
      rescue WWW::Mechanize::ResponseCodeError => e
        raise FetchError.new("#{loc} returned a response code of #{e.response_code}")
      end

      log.puts("#{loc} redirected to #{page.uri}".red) unless page.uri.to_s == loc

      page.body
    else
      begin
        open(loc).read
      rescue Errno::ENOENT
        raise FetchError.new("#{loc} was not found")
      rescue OpenURI::HTTPError => e
        raise FetchError.new("retrieving #{loc} raised an HTTP error: #{e.message}")
      end
    end
  end

private

  def has_pseudo_classes(selector)
    selector =~ /::?[\w\-]+/
  end

  def strip(selector)
    selector.gsub(/::?[\w\-]+/, '')
  end

  def log
    @log ||= if @log_file.respond_to?(:puts)
               @log_file
             else
               open(@log_file, 'w+')
             end
  end

  def initialize_agent
    begin
      require 'mechanize'
      return WWW::Mechanize.new
    rescue LoadError
      log.puts %{
        =================================================================
        Couldn't load 'mechanize', which is required for remote scraping.
        Install it like so: gem install mechanize
        =================================================================
      }

      raise
    end
  end

  class FetchError < StandardError; end
end

require 'deadweight/rake_task'

