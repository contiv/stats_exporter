require "httparty"
require "json"
require "sinatra"

set :bind, '0.0.0.0'

get '/metrics' do
  url = "http://localhost:9090/svcstats"

  records = []

  # do HTTParty.get
  resp = HTTParty.get(url)

  # parse result as json
  data = JSON.parse(resp.body)

  # convert JSON to prometheus format
  data.keys.each do |ip|
    x = "ip_#{ip}_"
    svcstats = data[ip]["SvcStats"]

    svcstats.keys.each do |svc_ip|
      y = x + "svcip_#{svc_ip}_"
      provstats = svcstats[svc_ip]["ProvStats"]

      provstats.keys.each do |prov_ip|
        z = y + "provip_#{prov_ip}"
        z = z.gsub(".", "_")
        records << "#{z}_bytes_in #{provstats[prov_ip]["BytesIn"]}"
        records << "#{z}_bytes_out #{provstats[prov_ip]["BytesOut"]}"
        records << "#{z}_packets_in #{provstats[prov_ip]["PacketsIn"]}"
        records << "#{z}_packets_out #{provstats[prov_ip]["PacketsOut"]}"
      end
    end
  end

  # return prometheus formatted string
  records.join("\n") + "\n"
end