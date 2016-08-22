require 'slack-ruby-client'
require 'logging'

logger = Logging.logger(STDOUT)
logger.level = :debug

Slack.configure do |config|
  config.token = ENV['SLACK_TOKEN']
  if not config.token
    logger.fatal('Missing ENV[SLACK_TOKEN]! Exiting program')
    exit
  end
end

client = Slack::RealTime::Client.new

# listen for hello (connection) event - https://api.slack.com/events/hello
client.on :hello do
  logger.debug("Connected '#{client.self['name']}' to '#{client.team['name']}' team at https://#{client.team['domain']}.slack.com.")
end

# listen for channel_joined event - https://api.slack.com/events/channel_joined
client.on :channel_joined do |data|
  if joiner_is_bot?(client, data)
    client.message channel: data['channel']['id'], text: "Thanks for the invite! I don\'t do much yet, but #{help}"
    logger.debug("#{client.self['name']} joined channel #{data['channel']['id']}")
  else
    logger.debug("Someone far less important than #{client.self['name']} joined #{data['channel']['id']}")
  end
end

# listen for message event - https://api.slack.com/events/message
client.on :message do |data|
  next unless data['type'] === 'message'
  next unless data['text']
  next if data['subtype']
  next if data['reply_to']
  next unless time_string = extract_time data['text']
  
  Time.zone = users[data['user']][:tz]
  begin
    time = Time.zone.parse(time_string)
  rescue
    next
  end
  
  logger.debug "[#{Time.now}] Got time #{time}"
  
  text = []
  
  i = 0
  timezones.each do |label, offset|
    i += 1
    localtime = time + offset.to_i.hours
    emoji = slack_clock_emoji_from_time(localtime)
    message = "#{emoji} #{localtime.strftime('%H:%M')} #{label}"
    message += (i % PER_LINE.to_i == 0) ? "\n" : " "
    text << (offset == users[data['user']][:offset] ? "#{message}" : message)
  end

  text << (MESSAGE % time.to_i.to_s)

  logger.debug "[#{Time.now}] Sending message..."
  client.message channel: data['channel'], text: text.join
end

def time_zones
  @time_zones ||= begin
    # Get users list and all available timezones and set default timezone

    uri = URI.parse("https://slack.com/api/users.list?token=#{TOKEN}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    response = http.get(uri.request_uri)
    timezones = {}
    users = {}

    JSON.parse(response.body)['members'].each do |user|
      offset, label = user['tz_offset'], user['tz']
      next if offset.nil? or offset == 0 or label.nil? or user['deleted']
      label = ActiveSupport::TimeZone.find_tzinfo(label).current_period.abbreviation.to_s
      offset /= 3600
      if key = timezones.key(offset) and !key.split(' / ').include?(label)
        timezones.delete(key)
        label = key + ' / ' + label
      end
      timezones[label] = offset unless timezones.has_value?(offset)
      users[user['id']] = { offset: offset, tz: ActiveSupport::TimeZone[offset].tzinfo.name }
    end

    timezones.sort_by{ |key, value| value }
  end
end

def extract_time(text)
  text.match(/([0-9]{1,2}):?([0-9]{2}) ?(([aA]|[pP])[mM])/) do |match|
    "#{match[1]}:#{match[2]} #{match[3]}"
  end
end

client.start!
