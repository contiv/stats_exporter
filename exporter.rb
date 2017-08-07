require "httparty"
require "json"
require "sinatra"

STDOUT.sync = true

OVS_DB_PORT = 6640
REQUIRED_KEYS = %w[external_ids name statistics]

def netplugin?
  ENV.fetch("EXPORTER_MODE") == "netplugin"
end

def netmaster?
  !netplugin?
end

set :bind, '0.0.0.0'
set :port, netplugin? ? 9004 : 9005

get '/metrics' do
  # get etcd IP
  etcd = ENV.fetch("CONTIV_ETCD").split("//").last

  #get netmaster IP
  puts "fetching leading address"
  netmaster_addr = JSON.parse(HTTParty.get("http://#{etcd}/v2/keys/contiv.io/lock/netmaster/leader").body)["node"]["value"]

  # Get a list of networks
  puts "fetching networks"
  raw_networks = JSON.parse(HTTParty.get("http://#{netmaster_addr}/api/v1/networks/").body)

  to_display = []

  if netplugin?
    to_display = netplugin_stats(netmaster_addr, raw_networks)
  end

  if netmaster?
    to_display = netmaster_stats(netmaster_addr, raw_networks)
  end

  to_display.join("\n") + "\n"
end

def netplugin_stats(netmaster_addr, raw_networks)

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
    raw_epstats = JSON.parse(HTTParty.get("http://#{netmaster_addr}/api/v1/inspect/networks/#{net}/").body)

    tenant = raw_epstats["Config"]["tenantName"]
    network = raw_epstats["Config"]["networkName"]
    endpoints = raw_epstats["Oper"]["endpoints"]

    endpoints.each do |ep|
      endptID = ep["endpointID"]
      host = ep["homingHost"]
      container = ep["containerName"]
      epg = ep["serviceName"]

      # create hash of endpointID to hash of endpoint info
      epInfo[endptID] = {
        "tenant": tenant,
        "network": network,
        "host": host,
        "containerName": container,
      }

      # add epg if endpoint is part of one
      if epg
        epInfo[endptID]["endpointGroup"] = epg
      end
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


        # OVS outputs data from it's point of view, not the container point of view
        # so rx and tx must be reversed
        new_hash = {}

        epstats.keys.each do |key|
          if key.start_with?("rx_")
            new_hash[key.gsub("rx_", "tx_")] = epstats[key]
          elsif key.start_with?("tx_")
            new_hash[key.gsub("tx_", "rx_")] = epstats[key]
          else
            new_hash[key] = epstats[key]
          end
        end

        epstats = new_hash
        #create key-value pairs and store into array
        info = "{" + epInfo[key].map{|k,v| "#{k}=\"#{v}\""}.join(", ") + "}"
        epstats.each do |metric, value|
          records << "#{metric}#{info} #{value}"
        end 
      end
    end
  end

  records
end

def netmaster_stats(netmaster_addr, raw_networks)

  records = []
  # Get a list of networks
  puts "fetching data"
  raw_tenants = JSON.parse(HTTParty.get("http://#{netmaster_addr}/api/v1/tenants/").body)
  raw_epg = JSON.parse(HTTParty.get("http://#{netmaster_addr}/api/v1/endpointGroups/").body)

  records << "count_of_tenants #{raw_tenants.length}"

  # count of networks per tenant
  raw_tenants.each do |tenant_block|
    tenant = tenant_block["tenantName"]
    data = tenant_block["link-sets"]
    if data["Networks"]
      records << "count_of_networks{tenant=\"#{tenant}\"} #{data["Networks"].length}"
    end
  end

  # count of epg per (tenant, network)
  raw_networks.each do |network_block|
    data = network_block["link-sets"]
    if data["EndpointGroups"]
      records << "count_of_endpointGroups{tenant=\"#{network_block["tenantName"]}\", network=\"#{network_block["networkName"]}\"} #{data["EndpointGroups"].length}"
    end
  end

  # count of policies per (tenant, network, epg)
  raw_epg.each do |epg_block|
    data = epg_block["link-sets"]
    if data["Policies"]
      records << "count_of_policies{tenant=\"#{epg_block["tenantName"]}\", network=\"#{epg_block["networkName"]}\", endpointGroup=\"#{epg_block["groupName"]}\"} #{data["Policies"].length}"
    end
    if data["NetProfiles"]
      records << "count_of_netprofiles{tenant=\"#{epg_block["tenantName"]}\", network=\"#{epg_block["networkName"]}\", endpointGroup=\"#{epg_block["groupName"]}\"} #{data["NetProfiles"].length}"
    end
  end

  records
end