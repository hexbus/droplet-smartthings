local Driver = require 'st.driver'
local caps = require 'st.capabilities'
local cosock = require 'cosock'
local socket = cosock.socket
local ssl = require 'cosock.ssl'
local mdns = require 'st.mdns'
local json = require 'st.json'
local log = require 'log'
local websocket = require 'websocket'
local readings = require 'readings'
local flow = caps['dictionaryguide60352.dropletflow']
local volume = caps['dictionaryguide60352.dropletvolumedelta']
local status = caps['dictionaryguide60352.dropletstatus']
local sessions, discovered = {}, {}
local function event(device, attribute, value)
  device:emit_event(status[attribute](value))
end
local function unknown_alerts(device)
  event(device,'highFlow','unknown'); event(device,'unusualFlow','unknown')
end
local function find_droplets()
  local result = mdns.discover('_droplet._tcp','local') or {}
  local found = {}
  for _, entry in ipairs(result.found or {}) do
    local host = entry.host_info or {}
    if readings.local_ipv4(host.address) and type(host.name)=='string' then
      found['droplet:'..host.name] = {address=host.address,port=host.port or 443}
    end
  end
  return found
end
local function close(session)
  if session.sock then pcall(function() session.sock:close() end); session.sock=nil end
end
local function stop(device)
  local session = sessions[device.id]
  if session then session.stopped=true; close(session); sessions[device.id]=nil end
end
local function emit_readings(device, session, msg)
  local values=readings.parse(msg)
  if values.flow then device:emit_event(flow.flow({value=values.flow,unit='L/min'})) end
  if values.volumeDelta then device:emit_event(volume.volumeDelta({value=values.volumeDelta,unit='mL'})) end
  for _, key in ipairs({'server','signal'}) do if values[key] then event(device,key,values[key]) end end
  if values.server then session.server=values.server end
  if session.server~='Connected' then
    unknown_alerts(device)
  else
    for _, key in ipairs({'highFlow','unusualFlow'}) do
      if values[key] then event(device,key,values[key]); session.alert_times[key]=socket.gettime() end
    end
  end
end
local function connect(device, session, address, port, code)
  assert(readings.local_ipv4(address),'Droplet address must be local IPv4')
  assert(type(port)=='number' and port>=1 and port<=65535,'Invalid Droplet port')
  local tcp=assert(socket.tcp()); session.sock=tcp
  tcp:settimeout(10)
  assert(tcp:connect(address,port),'Droplet TCP connection failed')
  -- Droplet uses a device certificate without public CA verification, as required
  -- by Hydrific's documented API. Restrict the endpoint to private/local IPv4.
  local tls=assert(ssl.wrap(tcp,{mode='client',protocol='any',verify='none',options={'no_sslv2','no_sslv3','no_tlsv1','no_tlsv1_1'}}))
  session.sock=tls; tls:settimeout(15)
  assert(tls:dohandshake(),'Droplet TLS handshake failed')
  local ws=websocket.client(tls,address..':'..port,code)
  ws:handshake()
  local verified=false
  local metadata_deadline=socket.gettime()+15
  session.server=nil; session.alert_times={}
  unknown_alerts(device)
  ws.on_activity=function()
    if session.stopped then error('Session stopped') end
    if not verified and socket.gettime()>metadata_deadline then error('Droplet metadata missing') end
    for key,time in pairs(session.alert_times) do
      if socket.gettime()-time>90 then event(device,key,'unknown'); session.alert_times[key]=nil end
    end
  end
  while not session.stopped do
    local message=ws:receive()
    local ok,msg=pcall(json.decode,message)
    if ok and type(msg)=='table' then
      if type(msg.ids)=='string' and msg.ids:lower():match('^droplet%-') then
        local pinned=device:get_field('droplet_id')
        if pinned and pinned~=msg.ids then error('Droplet identity changed; connection refused') end
        if not pinned then device:set_field('droplet_id',msg.ids,{persist=true}) end
        verified=true
        session.healthy=true
        device:online(); event(device,'connection','Connected')
      end
      if verified then emit_readings(device,session,msg) end
    end
    if not verified and socket.gettime()>metadata_deadline then error('Droplet metadata missing') end
    for key,time in pairs(session.alert_times) do
      if socket.gettime()-time>90 then event(device,key,'unknown'); session.alert_times[key]=nil end
    end
  end
end
local function start(driver,device)
  stop(device)
  local code=(device.preferences.pairingCode or ''):gsub('%s',''):upper()
  if code=='' then device:offline(); event(device,'connection','Enter pairing code in Settings'); unknown_alerts(device); return end
  local session={stopped=false}
  sessions[device.id]=session
  cosock.spawn(function()
    local backoff=5
    while not session.stopped do
      local ok=pcall(function()
        event(device,'connection','Connecting')
        local manual=device.preferences.ipAddress or ''
        local destination
        if manual~='' then destination={address=manual,port=443}
        else
          local found=find_droplets()
          destination=found[device.device_network_id] or discovered[device.device_network_id]
        end
        assert(destination,'Droplet not found on local network')
        connect(device,session,destination.address,destination.port,code)
      end)
      close(session)
      if session.stopped then break end
      device:offline(); event(device,'connection','Disconnected; retrying'); unknown_alerts(device)
      -- Never log tokens, headers, payloads, or raw exception strings.
      if not ok then log.warn('Droplet connection interrupted; check pairing code and local API') end
      if session.healthy then backoff=5; session.healthy=false end
      socket.sleep(backoff)
      backoff=math.min(backoff*2,60)
    end
  end,'droplet-connection')
end
local function discovery(driver)
  local found=find_droplets()
  local existing={}
  for _,device in ipairs(driver:get_devices()) do existing[device.device_network_id]=true end
  for dni,host in pairs(found) do
    discovered[dni]=host
    if not existing[dni] then
      driver:try_create_device({type='LAN',device_network_id=dni,label='Hydrific '..dni:gsub('^droplet:',''),profile='droplet',manufacturer='Hydrific',model='Droplet',vendor_provided_label='Hydrific Droplet'})
    end
  end
end
local driver=Driver('hydrific-droplet',{
  discovery=discovery,
  supported_capabilities={flow,volume,status,caps.refresh},
  lifecycle_handlers={init=start,infoChanged=start,removed=function(_,device) stop(device) end},
  capability_handlers={[caps.refresh.ID]={[caps.refresh.commands.refresh.NAME]=start}}
})
driver:run()
