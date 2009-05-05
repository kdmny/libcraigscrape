# = About libcraigscrape.rb
#
# All of libcraigscrape's objects and methods are loaded when you use <tt>require 'libcraigscrape'</tt> in your code.
#

require 'rubygems'
require 'hpricot'
require 'net/http'
require 'htmlentities'
require 'activesupport'

# A base class encapsulating the libcraigscrape objests, and providing some utility methods.
class CraigScrape
  cattr_accessor :logger
  cattr_accessor :time_now
  
  def self.most_recently_expired_time(month, day)  #:nodoc:
    now = (time_now) ? time_now : Time.now
    
    # This ensures we always generate a time in the past, by guessing the year and subtracting one if we guessed wrong
    ret = Time.local now.year, month, day
    ret = Time.local now.year-1, month, day if ret > now 
    
    ret
  end
  
  module ParseObjectHelper  #:nodoc:
    def he_decode(text)
      HTMLEntities.new.decode text
    end
  end
  
  # PostFull represents a fully downloaded, and parsed, Craigslist post.
  # This class is generally returned by the listing scrape methods, and 
  # contains the post summaries for a specific search url, or a general listing category 
  class PostFull
    include ParseObjectHelper
    
    # String, represents the post's reply-to address, if listed
    attr_reader :reply_to
    
    # Time, reflects the full timestamp of the posting 
    attr_reader :post_time
    
    # String, The contents of the item's html body heading
    attr_reader :header
    
    # String, the item's title
    attr_reader :title
    
    # Integer, Craigslist's unique posting id
    attr_reader :posting_id
    
    # String, The full-html contents of the post
    attr_reader :contents
    
    # String, the location of the item, as best could be parsed
    attr_reader :location
    
    # Array, hierarchial representation of the posts section
    attr_reader :full_section
    
    # Array, urls of the post's craigslist-hosted images 
    attr_reader :images
    
    POST_DATE  = /Date:[^\d]*((?:[\d]{2}|[\d]{4})\-[\d]{1,2}\-[\d]{1,2}[^\d]+[\d]{1,2}\:[\d]{1,2}[ ]*[AP]M[^a-z]+[a-z]+)/i
    LOCATION   = /Location\:[ ]+(.+)/
    POSTING_ID = /PostingID\:[ ]+([\d]+)/
    REPLY_TO   = /(.+)/
    PRICE      = /\$([\d]+(?:\.[\d]{2})?)/
    
    def initialize(page) #:nodoc:
      # We proceed from easy to difficult:
      
      @images = []
      
      @header = he_decode page.at('h2').inner_html if page.at('h2')
      @title = he_decode page.at('title').inner_html if page.at('title')
      @title = nil if @title.length ==0
      
      @full_section = []
      (page/"div[@class='bchead']//a").each do |a|
        @full_section << he_decode(a.inner_html) unless a['id'] and a['id'] == 'ef'
      end
      
      # Reply To:
      cursor = page.at 'hr'    
      cursor = cursor.next_sibling until cursor.nil? or cursor.name == 'a'
      @reply_to = $1 if cursor and REPLY_TO.match he_decode(cursor.inner_html) 
      
      # Post Date:
      cursor = page.at 'hr'
      cursor = cursor.next_node until cursor.nil? or POST_DATE.match cursor.to_s
      @post_time = Time.parse $1 if $1
      
      # Posting ID:
      cursor = (page/"#userbody").first
      cursor = cursor.next_node until cursor.nil? or POSTING_ID.match cursor.to_s
      @posting_id = $1.to_i if $1
      
      # OK - so the biggest problem parsing the contents of a craigslist post is that users post invalid html all over the place
      # THis bad html trips up hpricot, and I've resoorted to splitting the page up using string parsing.
      userbody_as_s,craigbody_as_s = $1, $2 if /\<div id\=\"userbody\">(.+)\<br[ ]*[\/]?\>\<br[ ]*[\/]?\>(.+)\<\/div\>/m.match page.to_s

      # Contents:
      @contents = he_decode(userbody_as_s.strip) if userbody_as_s
      
      # I made this a separate method since we're not actually parsing everything in here as-is.
      # This will make it easier for the next guy to work with if wants to parse out the information we're disgarding...
      parse_craig_body Hpricot.parse(craigbody_as_s) if craigbody_as_s
    end
    
    def parse_craig_body(craigbody_els)  #:nodoc:
      # Location (when explicitly defined):
      cursor = craigbody_els.at('ul')
      cursor = cursor.at('li') if cursor
      @location = he_decode($1) if cursor and LOCATION.match(cursor.inner_html)

      # Real estate listings can work a little different for location:
      unless @location
        cursor = craigbody_els.at('small')
        cursor = cursor.previous_node until cursor.nil? or cursor.text?
        
        @location = he_decode(cursor.to_s.strip) if cursor
      end

      # Now let's find the craigslist hosted images:
      img_table = (craigbody_els / 'table').find{|e| e.name == 'table' and e[:summary] == 'craigslist hosted images'}
      
      @images = (img_table / 'img').collect{|i| i[:src]} if img_table
    end
    
    # Returns the price (as float) of the item, as best ascertained by the post header
    def price
      $1.to_f if @title and @header and PRICE.match(@header.gsub(/#{@title}/, ''))
    end
    
    # Returns the post contents with all html tags removed
    def contents_as_plain
      @contents.gsub(/<\/?[^>]*>/, "") if @contents
    end
  end

  # Listings represents a parsed Craigslist listing page and is generally returned by CraigScrape.scrape_listing
  class Listings
    include ParseObjectHelper
    
    # Array, PostSummary objects found in the listing
    attr_reader :posts
    
    # String, URL Path of the next page link
    attr_reader :next_page_href

    def initialize(page, base_url = nil)  #:nodoc:
      current_date = nil
      @posts = []

      tags_worth_parsing = page.get_elements_by_tag_name('p','h4')
      
      # This will find the link on 'general listing' pages, if there is one:
      last_twp_a = tags_worth_parsing.last.at('a') if  tags_worth_parsing.last
      next_link = tags_worth_parsing.pop.at('a') if last_twp_a and /^[ ]*next [\d]+ postings[ ]*$/.match last_twp_a.inner_html    
      
      # Now we iterate though the listings:
      tags_worth_parsing.each do |el|
        case el.name
          when 'p'
           @posts << CraigScrape::PostSummary.new(el, current_date, base_url)
          when 'h4'            
            current_date = CraigScrape.most_recently_expired_time $1, $2 if /^[ ]*[^ ]+[ ]+([^ ]+)[ ]+([^ ]+)[ ]*$/.match he_decode(el.inner_html)
        end        
      end
    
      next_link = (page / 'a').find{ |a| he_decode(a.inner_html) == '<b>Next>></b>' } unless next_link
      
      # This will find the link on 'search listing' pages (if there is one):
      @next_page_href = next_link[:href] if next_link
    end
    
  end
  
  # PostSummary represents a parsed summary posting, typically found on a Listing page.
  # This object is returned by the CraigScrape.scrape_listing methods
  class PostSummary
    include ParseObjectHelper
    
    # Time, date of post, as a Time object. Does not include hours/minutes
    attr_reader :date
    
    # String, The label of the post
    attr_reader :label
    
    # String, The path fragment of the post's URI
    attr_reader :href
    
    # String, The location of the post
    attr_reader :location
    
    # String, The abbreviated section of the post
    attr_reader :section
    
    # Array, which image types are listed for the post
    attr_reader :img_types
    
    PRICE    = /((?:^\$[\d]+(?:\.[\d]{2})?)|(?:\$[\d]+(?:\.[\d]{2})?$))/
    DATE     = /^[ ]([^ ]+)[ ]+([^ ]+)[ ]*[\-][ ]*$/
    LABEL    = /^(.+?)[ ]*\-$/
    LOCATION = /^[ ]*\((.*?)\)$/
    IMG_TYPE = /^[ ]*(.+)[ ]*$/
  
    def initialize(p_element, date = nil, base_url = nil)  #:nodoc:
      title_anchor, section_anchor  = p_element.search 'a'
      location_tag = p_element.at 'font'
      has_pic_tag = p_element.at 'span'
      
      @location = he_decode p_element.at('font').inner_html if location_tag
      @location = $1 if LOCATION.match @location
  
      @img_types = []
      if has_pic_tag
        img_type = he_decode has_pic_tag.inner_html
        img_type = $1.tr('^a-zA-Z0-9',' ') if IMG_TYPE.match img_type
  
        @img_types = img_type.split(' ').collect{|t| t.to_sym}
      end
  
      @section = he_decode section_anchor.inner_html if section_anchor
      
      @date = date
      if DATE.match he_decode(p_element.children[0])
        @date = CraigScrape.most_recently_expired_time $1, $2.to_i
      end
  
      @label = he_decode title_anchor.inner_html
      @label = $1 if LABEL.match @label
  
      @href = title_anchor[:href]
      @base_url = base_url
    end
    
    # Returns the full uri including host and scheme, not just the href
    def full_url
      '%s%s' % [@base_url, @href]
    end
  
    # true if post summary has the img label
    def has_img?
      img_types.include? :img
    end

    # true if post summary has the pic label
    def has_pic?
      img_types.include? :pic
    end

    # true if post summary has either the img or pic label
    def has_pic_or_img?
      img_types.length > 0
    end
    
    # Returns the best-guess of a price, judging by the label's contents.
    def price
      $1.tr('$','').to_f if @label and PRICE.match(@label)
    end
    
    # Requests and returns the PostFull object that corresponds with this summary's full_url
    def full_post
      @full_post = CraigScrape.scrape_full_post(full_url) if @full_post.nil? and full_url
      
      @full_post
    end
  end

  # Scrapes a single listing url and returns a Listings object representing the contents
  def self.scrape_listing(listing_url)
    current_uri = ( listing_url.class == String ) ? URI.parse(listing_url) : listing_url 
    
    CraigScrape::Listings.new Hpricot.parse(self.fetch_url(current_uri)), '%s://%s' % [current_uri.scheme, current_uri.host]
  end

  # Continually scrapes listings, using the supplied url as a starting point, until the supplied block returns true or
  # until there's no more 'next page' links available to click on
  def self.scrape_until(listing_url, &post_condition)
    ret = []
    
    current_uri = URI.parse listing_url
    catch "ScrapeBreak" do
      while current_uri do 
        listings = scrape_listing current_uri
        
        listings.posts.each do |post|
          throw "ScrapeBreak" if post_condition.call(post)
          ret << post
        end

        current_uri = (listings.next_page_href) ? self.uri_from_href( current_uri, listings.next_page_href ) : nil
      end
    end

    ret
  end

  # Scrapes a single Post Url, and returns a PostFull object representing its contents.
  def self.scrape_full_post(post_url)
    CraigScrape::PostFull.new Hpricot.parse(self.fetch_url(post_url))
  end

  # Continually scrapes listings, using the supplied url as a starting point, until 'count' summaries have been retrieved
  # or no more 'next page' links are avialable to be clicked on. Returns an array of PostSummary objects.
  def self.scrape_posts(listing_url, count)
    count_so_far = 0
    self.scrape_until(listing_url) {|post| count_so_far+=1; count < count_so_far }
  end
  
  # Continually scrapes listings, until the date newer_then has been reached, or no more 'next page' links are avialable to be clicked on.
  # Returns an array of PostSummary objects. Dates are based on the Month/Day 'datestamps' reported in the listing summaries. 
  # As such, time-based cutoffs are not supported here. The scrape_until method, utilizing the SummaryPost.full_post method could achieve
  # time-based cutoffs, at the expense of retrieving every post in full during enumerations.
  #
  # <b>Note:<b> The results will not include post summaries having the newer_then date themselves.
  def self.scrape_posts_since(listing_url, newer_then)
    self.scrape_until(listing_url) {|post| post.date <= newer_then}
  end
  
  def self.fetch_url(uri) #:nodoc:
    # This handles the redirects for us
    uri_dest = ( uri.class == String ) ? URI.parse(uri) : uri 

    logger.info "Requesting: %s" % uri_dest.to_s unless logger.nil?
    
    resp, data = Net::HTTP.new( uri_dest.host, uri_dest.port).get uri_dest.request_uri, nil

    redirect_to = resp.response['Location'] if resp.response['Location']
    redirect_to = $1 if /<META HTTP-EQUIV=\"REFRESH\" CONTENT=\"0;[ ]*URL=(.*)\">/i.match data

    (redirect_to) ? self.fetch_url(redirect_to) : data
  end
  
  def self.uri_from_href(base_uri, href) #:nodoc:
    URI.parse(
      case href
        when /^http[s]?\:\/\// : href
        when /^\// : "%s://%s%s" % [ base_uri.scheme, base_uri.host, href ]
        else "%s://%s%s" % [
            base_uri.scheme, base_uri.host,
            /^(.*?\/)[^\/]+$/.match(base_uri.path) ? $1+href : base_uri.path+href
          ]
      end 
    )
  end

end