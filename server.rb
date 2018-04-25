require "sinatra"
require "net/http"
require "uri"
require "json"
require "yaml"

config = {
  freshdesk_key: ENV['FRESHDESK_API_KEY'],
  freshdesk_domain: ENV['FRESHDESK_DOMAIN'],
  freshdesk_custom_field: ENV['FRESHDESK_CUSTOM_FIELD']
}

if File.exists?(path = File.join(File.dirname(__FILE__), 'config.yml')) then
  config.merge!(YAML.load(File.read(path)) || {})
end

Config = config


def send_api_request(action, params = nil, data = nil, put = false)
  key = Config[:freshdesk_key]
  domain = Config[:freshdesk_domain]

  params ||= {}

  query_parts = []
  params.each_pair {|k,v| query_parts << "#{k.to_s}:#{v.to_s}"}
  query_string = query_parts.join(" AND ")

  uri = URI.parse(query_string.length > 0 ? 
    "https://#{domain}.freshdesk.com/api/v2/#{action}?query=\"#{query_string}\"" : 
    "https://#{domain}.freshdesk.com/api/v2/#{action}")

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  if data then
    request = put ? Net::HTTP::Put.new(uri.request_uri) : Net::HTTP::Post.new(uri.request_uri)
    request.body = data
  else
    request = Net::HTTP::Get.new(uri.request_uri)
  end

  request.basic_auth(key, "X")
  request["Content-Type"] = "application/json"

  response = http.request(request)

  unless response.kind_of? Net::HTTPSuccess then
    throw "Response wasn't susccessful #{response.code} #{uri.to_s} \n#{response.body}"
  end

  JSON.parse response.body
end

def field_for_repo(repo)
  return unless Config["repositories"]

  Config["repositories"][repo["full_name"]] || Config["repositories"][repo["name"]]
end

def tickets_for_issue(number, repo) 
  custom_field_name = field_for_repo(repo) || Config[:freshdesk_custom_field]
  tickets = send_api_request("search/tickets", { custom_field_name => number })["results"]

  tickets
end

def handle_labeled(number, repo, label)
  return unless label =~ /^fixed/i

  tickets = tickets_for_issue(number, repo)

  tickets.each do |ticket|
    send_api_request("tickets/#{ticket['id']}/notes", nil, JSON.generate({
      :body => "Github issue #{repo["full_name"]}##{number} has been marked as #{label}.",
      :private => false
    }))
    
    regexes = [/dev/i, /staging/i, /prod/i]
    match_index = nil
    regexes.find_index { |r| match_index = label.match(r) }
    if match_index then
      updated_status = match_index + 2
      send_api_request("tickets/#{ticket['id']}", nil, JSON.generate({
        :status => updated_status
      }), true)
    end
  end
end

def handle_closed(number, repo)

  tickets = tickets_for_issue(number, repo)

  tickets.each do |ticket|
    send_api_request("tickets/#{ticket['id']}", nil, JSON.generate({
      :status => 4
    }), true)

  end
end

post '/endpoint' do
  body = request.body.read
  event = JSON.parse(body)

  case event["action"]
  when "labeled"
    handle_labeled(event["issue"]["number"], event["repository"], event["label"]["name"])
  when "closed"
    handle_closed(event["issue"]["number"], event["repository"])
  end

  "OK"
end