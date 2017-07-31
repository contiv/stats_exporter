require "httparty"
require "json"
require "sinatra"

STDOUT.sync = true

OVS_DB_PORT = 6640
REQUIRED_KEYS = %w[external_ids name statistics]

set :bind, '0.0.0.0'

get '/metrics' do

  records = []

  if ENV.fetch("EXPORTER_MODE") == "netplugin":
    records = netplugin_stats
  
  if ENV.fetch("EXPORTER_MODE") == "netmaster":
    record = netmaster_stats
end


def netplugin_stats
  # get etcd IP
  etcd = ENV.fetch("CONTIV_ETCD").split("//").last

  #get netmaster IP
  puts "fetching leading address"
  netmaster = JSON.parse(HTTParty.get("http://#{etcd}/v2/keys/contiv.io/lock/netmaster/leader").body)["node"]["value"]

  # Get a list of networks
  puts "fetching networks"
  raw_networks = JSON.parse(HTTParty.get("http://#{netmaster}/api/v1/networks/").body)

  networks = []
  epInfo = {}
  records = []

  raw_networks.each do |block|
    if block["nwType"] != "infra"
      networks << block["key"]
    end
  end

  # Get endpoints and endpoint info for each network
  networks.each do |net|
    puts "fetching #{net} network data"
    raw_epstats = JSON.parse(HTTParty.get("http://#{netmaster}/api/v1/inspect/networks/#{net}/").body)

    tenant = raw_epstats["Config"]["tenantName"]
    network = raw_epstats["Config"]["networkName"]
    endpoints = raw_epstats["Oper"]["endpoints"]

    endpoints.each do |ep|
      endptID = ep["endpointID"]
      host = ep["homingHost"]
      container = ep["containerName"]

      # create hash of endpointID to hash of endpoint info
      epInfo[endptID] = {
        "tenant": tenant,
        "network": network,
        "endpointID": endptID,
        "host": host,
        "containerName": container,
      }
    end
  end

  puts "epInfo:"
  puts epInfo.inspect

  # get ovs stats
  cmd = "ovs-vsctl --db=tcp:127.0.0.1:#{OVS_DB_PORT} list interface | egrep '^name|external_ids|statistics'"
  puts "Running: #{cmd}"

  ovs_output = `#{cmd}`

  raise "failed to run ovs-vsctl (expected: 0, received: #{$?.exitstatus})" unless $?.exitstatus == 0

  puts "Output:"
  puts ovs_output

  # group ovs output by interface
  interfaces = ovs_output.strip.split("\n").each_slice(3).inject([]) do |memo, obj|
    h = {}

    obj.each do |item|
      parts = item.split(":").map(&:strip)
      h[parts.first] = parts.last
    end

    missing_keys = REQUIRED_KEYS - h.keys

    raise "following keys are missing from the hash: #{missing_keys.join(", ")}" unless missing_keys.empty?
    memo << h
    memo
  end
  
  puts "Interfaces:"
  puts interfaces.inspect

  # parses data from OVS output and matches endpointIDs with epInfo map created above
  interfaces.each do |interface|
    epInfo.keys.each do |key|
      if interface["external_ids"].include?(key)
        # get container interface
        epInfo[key]["interface"] = interface["name"].split(":").last.gsub("\"", "").strip

        # get stats into hash
        epstats = interface["statistics"].split(":").last.scan(/(\w+)=(\d+)/).to_h

        #create key-value pairs and store into array
        info = "{" + epInfo[key].map{|k,v| "#{k}=\"#{v}\""}.join(", ") + "}"
        epstats.each do |metric, value|
          records << "#{metric}#{info} #{value}"
        end 
      end
    end
  end

  # return key-value pairs
  records.join("\n") + "\n"
end

def netmaster_stats
    # get etcd IP
  etcd = ENV.fetch("CONTIV_ETCD").split("//").last

  #get netmaster IP
  puts "fetching leading address"
  netmaster = JSON.parse(HTTParty.get("http://#{etcd}/v2/keys/contiv.io/lock/netmaster/leader").body)["node"]["value"]

  # Get a list of networks
  puts "fetching data"
  raw_tenants = JSON.parse(HTTParty.get("http://#{netmaster}/api/v1/tenants/").body)

  records << "count_of_tenants #{raw_tenants.length}"

  raw_tenants.each do |block|
    data = block["link-sets"]
    records << 'count_of_networks{"tenant" = #{block["tenantName"]}

    end
  end
end