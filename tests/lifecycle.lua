-- Run the actual driver lifecycle against mocked Edge APIs.
package.path='driver/src/?.lua;'..package.path
local count=0
local function scenario(messages,pinned,code,manual,unit,reject_flow)
  local options,task,time,connects=nil,nil,0,0
  local device={id='test-device',device_network_id='droplet:droplet-test.local',preferences={pairingCode=code or 'TESTCODE',ipAddress=manual or '',flowUnit=unit},events={},fields={droplet_id=pinned}}
  function device:emit_event(e) self.events[#self.events+1]=e end
  function device:set_field(k,v) self.fields[k]=v end
  function device:get_field(k) return self.fields[k] end
  function device:try_update_metadata(meta) self.updated_profile=meta.profile end
  function device:online() self.went_online=true end
  function device:offline() self.went_offline=true end
  local function cap(id)
    return setmetatable({ID=id},{__index=function(_,attribute) return function(value,metadata) if reject_flow and attribute=='flow' then error('Unsupported flow unit') end; return {id=id,attribute=attribute,value=value,metadata=metadata} end end})
  end
  local capabilities={refresh={ID='refresh',commands={refresh={NAME='refresh'}}}}
  for _,id in ipairs({'dropletflowrate','dropletvolumedelta','dropletstatus'}) do capabilities['dictionaryguide60352.'..id]=cap(id) end
  package.loaded['st.capabilities']=capabilities
  package.loaded['st.driver']=function(_,opts) options=opts; return {run=function() end} end
  local sock={settimeout=function() end,connect=function() connects=connects+1; return true end,close=function() end,dohandshake=function() return true end}
  package.loaded.cosock={socket={tcp=function() return sock end,gettime=function() return time end,sleep=function() error('END TEST') end},spawn=function(fn) task=fn; device.spawns=(device.spawns or 0)+1 end}
  package.loaded['cosock.ssl']={wrap=function() return sock end}
  package.loaded['st.mdns']={discover=function() return {found={{host_info={name='droplet-test.local',address='192.168.1.20',port=443}}}} end}
  package.loaded['st.json']={decode=function(value) return value end}
  package.loaded.log={warn=function(msg) assert(not msg:find('TESTCODE',1,true)) end,info=function(msg) assert(not msg:find('TESTCODE',1,true)) end}
  package.loaded.websocket={client=function()
    return {handshake=function() end,receive=function(self)
      local entry=table.remove(messages,1)
      if not entry then error('stream ended') end
      time=time+(entry.advance or 0)
      if self.on_activity then self.on_activity() end
      return entry
    end}
  end}
  dofile('driver/src/init.lua')
  options.lifecycle_handlers.init({},device)
  if task then pcall(task) end
  local function values(attribute)
    local out={}; for _,e in ipairs(device.events) do if e.attribute==attribute then out[#out+1]=e.value end end; return out
  end
  return device,values,connects,options
end
local function test(name,fn) fn();count=count+1;print('ok '..count..' - '..name) end
test('pins authenticated metadata before emitting readings',function()
  local d,v=scenario({{flow=999},{ids='Droplet-ABCD'},{server='Connected',flow=0,volume=-2,high_leak='OFF'}})
  assert(d.fields.droplet_id=='Droplet-ABCD' and d.went_online)
  assert(d.updated_profile=='droplet' and d.fields.profile_revision==4)
  assert(#v('flow')==1 and v('flow')[1].value==0)
  assert(v('volumeDelta')[1].value==-2)
end)
test('refuses a different device identity',function()
  local d,v=scenario({{ids='Droplet-WRONG'},{flow=5}},'Droplet-ABCD')
  assert(not d.went_online and #v('flow')==0 and d.fields.droplet_id=='Droplet-ABCD')
end)
test('missing pairing code makes no network connection',function()
  local d,v,n=scenario({},nil,'')
  assert(n==0 and v('connection')[1]=='Enter pairing code in Settings')
end)
test('public address never receives pairing code',function()
  local d,v,n=scenario({},nil,'TESTCODE','8.8.8.8')
  assert(n==0 and d.went_offline)
end)
test('cloud disconnect does not report a clear alarm',function()
  local _,v=scenario({{ids='Droplet-ABCD'},{server='Disconnected',high_leak='OFF',low_leak='OFF'}})
  for _,s in ipairs(v('highFlow')) do assert(s=='unknown') end
  for _,s in ipairs(v('unusualFlow')) do assert(s=='unknown') end
end)
test('stale alerts become unknown during activity',function()
  local _,v=scenario({{ids='Droplet-ABCD'},{server='Connected',high_leak='ON'},{advance=91,flow=1}})
  local a=v('highFlow'); local detected
  for i,x in ipairs(a) do if x=='detected' then detected=i end end
  assert(detected and a[detected+1]=='unknown')
end)
test('metadata deadline prevents unauthenticated sensor updates',function()
  local d,v=scenario({{advance=16,flow=5}})
  assert(not d.went_online and #v('flow')==0)
end)
test('US gallons conversion and switching back preserve original measurement',function()
  local d,v,_,opts=scenario({{ids='Droplet-ABCD'},{flow=3.785411784},{flow=0},{flow=7.570823568}},nil,nil,nil,'gpm')
  assert(v('flow')[1].value==1 and v('flow')[1].unit=='gal/min')
  assert(v('flow')[2].value==0 and v('flow')[3].value==2)
  local spawns=d.spawns
  d.preferences.flowUnit='lpm'; opts.lifecycle_handlers.infoChanged({},d)
  local events=v('flow'); assert(events[#events].value==7.570823568 and events[#events].unit=='L/min')
  d.preferences.flowUnit='gpm'; opts.lifecycle_handlers.infoChanged({},d)
  events=v('flow'); assert(events[#events].value==2 and d.spawns==spawns)
end)
test('rejected flow event does not interrupt other sensor reports',function()
  local _,v=scenario({{ids='Droplet-ABCD'},{flow=3.785411784,volume=10,server='Connected'},{volume=20}},nil,nil,nil,'gpm',true)
  assert(#v('flow')==0 and #v('volumeDelta')==2 and v('volumeDelta')[2].value==20)
  assert(v('server')[1]=='Connected')
end)
test('zero-flow unit changes explicitly propagate to the app',function()
  local d,_,_,opts=scenario({{ids='Droplet-ABCD'},{flow=0}},nil,nil,nil,'lpm')
  d.preferences.flowUnit='gpm'; opts.lifecycle_handlers.infoChanged({},d)
  local e=d.events[#d.events]
  assert(e.attribute=='flow' and e.value.value==0 and e.value.unit=='gal/min' and e.metadata.state_change)
end)
print(count..' lifecycle tests passed')
