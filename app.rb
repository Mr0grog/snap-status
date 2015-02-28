require 'sinatra'
require 'net/https'
require 'uri'
require 'json'
require 'fileutils'
require './lib/pingometer.rb'
require 'aws-sdk'
require 'httparty'

PINGOMETER_USER = ENV['PINGOMETER_USER']
PINGOMETER_PASS = ENV['PINGOMETER_PASS']
AWS_KEY = ENV['AWS_KEY']
AWS_SECRET = ENV['AWS_SECRET']
AWS_BUCKET = ENV['AWS_BUCKET']
AWS_REGION = ENV['AWS_REGION']
PRODUCTION = ENV['RACK_ENV'] == 'production'

Aws.config.merge!({
  credentials: Aws::Credentials.new(AWS_KEY, AWS_SECRET),
  region: AWS_REGION || 'us-east-1'
})

MonitorList = JSON.parse(File.read('public/data/pingometer_monitors.json'))

get '/' do
  # Get basic info on all monitors.
  begin
    monitors = Pingometer.new(PINGOMETER_USER, PINGOMETER_PASS).monitors
  rescue
    @error_message = "Our status monitoring system, Pingometer, appears to be having problems."
    return erb :error
  end
  
  @down = monitors
    .select {|monitor| monitor['last_event']['type'] == 0}
    .map {|monitor| monitor['name'].partition(' |')[0].downcase}
  
  @state_status = {}
  @state_week_uptime = {}
  encounters = Hash.new(0)
  
  monitors.each do |monitor|
    # An event type of `-1` means a monitor is paused/non-operating.
    # For now, treat that like there's no monitor at all.
    if monitor['last_event']['type'] == -1
      next
    end
    
    state = monitor_state(monitor)['state'].downcase
    # We can have multiple monitors per state (e.g. California).
    # If any are down, we want to count all as down.
    if @state_status[state] != false
      @state_status[state] = monitor['last_event']['type'] != 0
    end
    
    days_checked = 0
    # NOTE: no straightforward way to get the UTC date, so we convert a Time object :\
    today = Time.now.utc.to_date
    total_uptime = ((today - 6)..today).reduce(0) do |sum, date|
      date_data = monitor['reports']['raw'][date.strftime('%Y-%m-%d')]
      if date_data
        days_checked += 1
        sum += date_data['uT']
      end
      sum
    end
    week_uptime = days_checked > 0 ? (total_uptime / days_checked) : 0
    if encounters[state] > 0
      week_uptime = (@state_week_uptime[state] * encounters[state] + week_uptime) / (encounters[state] + 1)
    end
    @state_week_uptime[state] = week_uptime

    encounters[state] += 1
  end
  
  erb :index
end

get '/states/:state_abbreviation' do
  state_abbreviation = params[:state_abbreviation].downcase
  monitors = MonitorList.find_all {|monitor_info| monitor_info["state_abbreviation"].downcase == state_abbreviation}
  if monitors.empty?
    monitor = MonitorList.find {|monitor_info| monitor_info["state"].downcase == state_abbreviation}
    if monitor
      redirect "/states/#{monitor['state_abbreviation']}"
    else
      raise Sinatra::NotFound
    end
    return
  end
  
  state = monitors[0]["state"]
  
  s3 = Aws::S3::Resource.new
  snapshots = s3.bucket(AWS_BUCKET).objects.find_all {|object| object.key.start_with? "#{state_abbreviation.upcase}-"}
  
  begin
    all_monitors = Pingometer.new(PINGOMETER_USER, PINGOMETER_PASS).monitors
  rescue
    @error_message = "Our status monitoring system, Pingometer, appears to be having problems."
    return erb :error
  end
  
  monitors_data = []
  all_monitors.each do |monitor_data|
    meta = monitors.find {|monitor| monitor["hostname"] == monitor_hostname(monitor_data)}
    if meta
      monitors_data << {
        :name => monitor_data["name"],
        :url => monitor_url(monitor_data),
        :status => monitor_data['last_event']['type'] == -1 ? :unknown : (monitor_data['last_event']['type'] == 0 ? :down : :up),
        :meta => meta,
        :details => monitor_data,
        :snapshots => snapshots.find_all {|snapshot| snapshot.key.start_with? "#{state_abbreviation.upcase}-#{monitor_data['id']}"}
      }
    end
  end
  
  erb :state, {:locals => {
    state: state,
    monitors: monitors_data
  }}
end

post '/hooks/event' do
  content_type :json
  
  logger.info "Received event hook for monitor #{params[:monitor_id]}"
  
  if !params[:monitor_id]
    status 400
    return { error: "No `monitor_id` included in POST." }.to_json
  end
  
  begin
    monitor = Pingometer.new(PINGOMETER_USER, PINGOMETER_PASS).monitor(params[:monitor_id])
  rescue
    logger.error "Failed getting info on monitor #{params[:monitor_id]} from Pingometer"
    status 500
    return { error: "Our status monitoring system, Pingometer, appears to be having problems." }.to_json
  end
  
  page_url = monitor_url(monitor)
  
  logger.info "Snapshotting #{page_url}"
  snapshot = nil
  begin
    snapshot = HTTParty.get("http://pagesnap.herokuapp.com/#{CGI.escape(page_url)}.png", :timeout => 20).parsed_response
  rescue
    snapshot = File.read("public/images/unreachable.png")
  end
  
  state_abbreviation = monitor_state(monitor)['state_abbreviation']
  state_status = monitor['last_event']['type'] != 0 ? "UP" : "DOWN"
  event_id = monitor['last_event']['id']
  file_name = "#{state_abbreviation}-#{params[:monitor_id]}-#{state_status}-#{event_id}.png"
  save_snapshot(file_name, snapshot)
  
  logger.info "Snapshot saved: #{file_name}"
  
  return { url: "http://pagesnap.herokuapp.com/#{CGI.escape(page_url)}.png" }.to_json
end

# Kind of hacky thing to get an ensured hostname
# (transactional tests don't have hostnames, so get the hostname of the URL it first loads).
# Not in Pingometer API class because there's not a real generic solution to this. (Or should it be?)
def monitor_hostname(monitor)
  monitor['hostname'].empty? ? monitor['commands']['1']['get'].match(/^[^\/]+\/\/([^\/]*)/)[1] : monitor['hostname']
end

def monitor_state(monitor)
  MonitorList.find {|monitor_info| monitor_info['hostname'] == monitor_hostname(monitor)}
end

def monitor_url(monitor)
  if monitor["hostname"] && !monitor["hostname"].empty?
    protocol = monitor['type'] && !monitor['type'].empty? ? monitor["type"] : "http"
    host = monitor["hostname"]
    path = monitor["path"] || ""
    query = monitor["querystring"] && !monitor["querystring"].empty? ? "?#{monitor["querystring"]}" : ""
    
    "#{protocol}://#{host}#{path}#{query}"
  else
    monitor["commands"]["1"]["get"]
  end
end

def save_snapshot(name, data)
  if PRODUCTION
    s3 = Aws::S3::Resource.new
    s3.bucket(AWS_BUCKET).object(name).put(
      body: data,
      acl: "public-read",
      content_type: "image/png")
  else
    Dir.mkdir("./tmp") unless File.exist?("./tmp")
    if !File.exist?(File.dirname("./tmp/#{name}"))
      FileUtils.mkdir_p(File.dirname("./tmp/#{name}"))
    end
    File.open("./tmp/#{name}", "w") do |file|
      file << data
    end
  end
end 
