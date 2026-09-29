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
local flow = caps['dictionaryguide60352.dropletflowrate']
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
local function emit_flow(device, liters)
  local gallons=device.preferences.flowUnit=='gpm'
  local unit=gallons and 'gal/min' or 'L/min'
  -- A unit-only change (especially zero flow) must propagate to cloud/app state.
  local metadata=device:get_field('last_flow_unit')~=unit and {state_change=true} or nil
  local ok,result=pcall(flow.flow,{value=gallons and liters/3.785411784 or liters,unit=unit},metadata)
  if ok then device:emit_event(result); device:set_field('last_flow_unit',unit)
  else log.warn('Flow event validation failed: '..tostring(result)) end
end
local function emit_readings(device, session, msg)
  local values=readings.parse(msg)
  if values.flow or values.volumeDelta then session.state_count=session.state_count+1 end
  if msg.high_leak~=nil then session.high_count=session.high_count+1 end
  if msg.low_leak~=nil then session.low_count=session.low_count+1 end
  if values.highFlow then session.high_valid=session.high_valid+1 end
  if values.unusualFlow then session.low_valid=session.low_valid+1 end
  if values.flow then device:set_field('last_flow_lpm',values.flow); emit_flow(device,values.flow) end
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
  session.state_count,session.high_count,session.low_count=0,0,0
  session.high_valid,session.low_valid=0,0
  unknown_alerts(device)
  ws.on_activity=function()
    if session.stopped then error('Session stopped') end
    if not verified and socket.gettime()>metadata_deadline then error('Droplet metadata missing') end
    if session.connected_at and not session.diagnosed and socket.gettime()-session.connected_at>90 then
      session.diagnosed=true
      log.info(string.format('Droplet first 90s: %d state reports; high-flow fields %d (recognized %d); unusual-flow fields %d (recognized %d)',session.state_count,session.high_count,session.high_valid,session.low_count,session.low_valid))
    end
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
        session.connected_at=session.connected_at or socket.gettime()
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
  local session={stopped=false,pairing_code=code,ip_address=device.preferences.ipAddress or ''}
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
local function info_changed(driver,device)
  local liters=device:get_field('last_flow_lpm')
  if liters~=nil then emit_flow(device,liters) end
  local session=sessions[device.id]
  local code=(device.preferences.pairingCode or ''):gsub('%s',''):upper()
  if not session or session.pairing_code~=code or session.ip_address~=(device.preferences.ipAddress or '') then
    start(driver,device)
  end
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
local function init(driver,device)
  -- Migrate the flow capability to avoid stale hub-side unit schemas.
  if device:get_field('profile_revision') ~= 4 then
    device:try_update_metadata({profile='droplet'})
    device:set_field('profile_revision',4,{persist=true})
  end
  start(driver,device)
end
local driver=Driver('hydrific-droplet',{
  discovery=discovery,
  supported_capabilities={flow,volume,status,caps.refresh},
  lifecycle_handlers={init=init,infoChanged=info_changed,removed=function(_,device) stop(device) end},
  capability_handlers={[caps.refresh.ID]={[caps.refresh.commands.refresh.NAME]=start}}
})
driver:run()
