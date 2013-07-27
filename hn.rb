#!/usr/bin/env ruby
################################################################################
# ruby >=1.9
#
# This bot requires:
# -- apt-get install ruby ruby-dev sqlite3 libsqlite3-dev
# -- gem install oauth json datamapper dm-sqlite-adapter
#
# Pull latest messages from twitter feeds for IRC
################################################################################
require 'oauth'
require 'json'
require 'socket'
require 'openssl'
require 'thread'
require 'data_mapper'

# my config file to keep variables hidden
require_relative 'config'

# DEBUGGING PURPOSES, IF ANY THREAD DIES I WANT WOHLE PROGRAM TO CRASH
Thread.abort_on_exception = true

#########
# MODEL #
#########
DataMapper::setup(:default, "sqlite3://#{Dir.pwd}/tweets.db")
class Tweets
  include DataMapper::Resource
  property :id, Serial
  property :username, Text
  property :tweet_id, Text
  property :displayed, Boolean, :default => false
end
DataMapper.auto_migrate!  # drop and create table autostyle when changes
DataMapper.finalize.auto_upgrade!



############################################################
# This thread logs in to twitter API and polls for new
# posts every x minutes to forward to IRC
############################################################
class TwitterThread
  def initialize(c_key, c_sec, a_tok, a_sec, bot = nil)
    if bot == nil
      puts "We have no bots, who are we going to display twats to?"
      exit!
    end
    
    @bot = bot
    
    @c_key = c_key
    @c_sec = c_sec
    @a_tok = a_tok
    @a_sec = a_sec

    @tweets = Tweets.all
  end

  # LOGIN TO TWITTER API
  def connect
    consumer = OAuth::Consumer.new(@c_key, @c_sec,
                                   { :site => "https://api.twitter.com",
                                     :scheme => :header
    })

    token_hash = { :oauth_token => @a_tok,
      :oauth_token_secret => @a_sec
    }

    @access_token = OAuth::AccessToken.from_hash(consumer, token_hash)
  end

  def every( time )
    Thread.new {
      loop do
        sleep(time)
        yield
      end
    }
  end

  def pull_tweets
    # Pull last tweet from users timeline
    response = @access_token.request(:get, "https://api.twitter.com/1.1/statuses/user_timeline.json?screen_name=newsyc150&count=1")
    return response
  end

  def run
    # counted in seconds
    every( 60 ) {
      response = pull_tweets
      msg = JSON.parse(response.body)[0]
      record = @tweets.first(:tweet_id => msg["id"])

      if !record
        @tweets.create(:username => msg["user"]["screen_name"],
                       :tweet_id => msg["id"])
        record = @tweets.first(:tweet_id => msg["id"])
      end

      if record.displayed == true
        puts "Tweet #{msg["id"]} has already been seen."
      else
        prep = "#{msg["user"]["name"]} (@#{msg["user"]["screen_name"]}): #{msg["text"]}"
        @bot.say_to_chan prep
        record.displayed = true
        @tweets.save
      end
    }
  end
end


############################################################
# socket connection and irc side commands                  
############################################################
class IRC
  def initialize(server, port, channel, nick)
    @bot = { :server => server, :port => port, :channel => channel, :nick => nick }
  end

  def connect
    conn = TCPSocket.new(@bot[:server], @bot[:port])
    @socket = OpenSSL::SSL::SSLSocket.new(conn)
    @socket.connect

    say "NICK #{@bot[:nick]}"
    say "USER #{@bot[:nick]} 0 * ."
    # cheap and shitty way to wait for the time to /j channel
    Thread.new {
      sleep(2)
      say "JOIN #{@bot[:channel]}"
    }
  end

  def say(msg)
    puts msg
    @socket.puts(msg)
  end

  def say_to_chan(msg)
    say "PRIVMSG #{@bot[:channel]} :#{msg}"
  end

  def run
    until @socket.eof? do
      msg = @socket.gets
      puts msg
      @history = []
      @history.push( ['timestamp' => Time.now, 'username' => msg.match(/<.(\w+)>/)] )

      if msg.match(/^PING :(.*)$/)
        say "PONG #{$~[1]}"
        next
      end
    end
  end

  def get_history
    return @history
  end

  def quit(msg = nil)
    #say "PART ##{@channel} :SHIPOOPIE"
    say( msg ? "QUIT #{msg}" : "QUIT" )
    abort("Thank you for playing.")
  end
end

############################################################
# This thread interacts with console user intput           
# and sends commands/chat to connected irc                 
############################################################
class ConsoleThread
  def initialize(bot = nil)
    if bot == nil
      puts "We have no bots connected, console input is meaningless"
      exit!
    end

    while(true)
      # capture cli input
      input = gets
      ###########################
      # commands start with /   #
      # everything else is chat #
      ###########################
      case
      # check for irc graceful quit (and maybe a quit message)
      # a little shitty cause /quitte123 will yield strange results
      when input.match(/^\/(quit|q)(.*)/)
        bot.quit( $~[2] ? $~[2] : nil )
      # private message to user (or other channel)
      when input.match(/^\/msg ([^ ]*) (.*)/)
        bot.say "PRIVMSG #{$~[1]} #{$~[2]}"
      # join new channel command
      when input.match(/^\/(join|j) (#.*)/)
        bot.say "JOIN #{$~[2]}"
      # raw irc command (e.g. "JOIN #newchannel")
      when input.match(/^\/(raw|r) (.*)/)
        bot.say $~[2]
      # / followed by anything else gets filtered (prevent disclosing commands)
      when input.match(/^\/(.*)/)
        puts "Sorry #{$~[1]} is not a recognized command."
      # pressing enter by itself gets ignored
      when input.match(/^\n/)
        nil
      # does not being with /, send chat to channel
      else
        bot.say_to_chan(input)
      end
    end
  end
end


########
# Main #
########
# initialize our irc bot
irc = IRC.new(Conf::IRC[:server], Conf::IRC[:port], Conf::IRC[:channel], Conf::IRC[:nick])

# trap ^C signal from keyboard and gracefully shutdown the bot
# quit messages are only heard by IRCD's if you have been connected long enough(!)
trap("INT"){ irc.quit("fucking off..") }

# spawn console input handling thread
console = Thread.new{ ConsoleThread.new(irc) }

# spawn twitter scraper
twit =  TwitterThread.new(
  Conf::TWIT[:consumer_key],
  Conf::TWIT[:consumer_secret],
  Conf::TWIT[:access_token],
  Conf::TWIT[:access_secret],
  irc
)
twit.connect
irc.connect

twit.run

# all worker threads should be initialized before here
# irc connection is not threaded so it will prevent stepping further
irc.run

puts "end."
