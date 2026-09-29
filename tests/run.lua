package.path='driver/src/?.lua;'..package.path
local codec=require 'codec'
local ws=require 'websocket'
local readings=require 'readings'
local count=0
local function test(name,fn)
  fn(); count=count+1; print('ok '..count..' - '..name)
end
local function hex(s) return (s:gsub('.',function(c) return string.format('%02x',c:byte()) end)) end
local function fails(fn) local ok=pcall(fn); assert(not ok,'expected rejection') end
local function fake(data)
  return {data=data or '',sent='',receive=function(self,n)
    if #self.data<n then local p=self.data; self.data=''; return nil,'timeout',p end
    local s=self.data:sub(1,n); self.data=self.data:sub(n+1); return s
  end,send=function(self,s,at)
    at=at or 1; local last=math.min(at+6,#s); self.sent=self.sent..s:sub(at,last); return last
  end}
end
local function client(data) local s=fake(data); return ws.client(s,'192.168.1.20:443','EXAMPLE',function(n) return string.rep('a',n) end),s end
local function frame(op,s,fin)
  local a=(fin==false and 0 or 128)+op
  if #s<126 then return string.char(a,#s)..s end
  return string.char(a,126,math.floor(#s/256),#s%256)..s
end
test('SHA-1 standard vectors',function()
  assert(hex(codec.sha1(''))=='da39a3ee5e6b4b0d3255bfef95601890afd80709')
  assert(hex(codec.sha1('abc'))=='a9993e364706816aba3e25717850c26c9cd0d89d')
  assert(hex(codec.sha1(string.rep('a',1000)))=='291e9a6c66994949b57ba5e650361e98fc36b1ba')
end)
test('RFC WebSocket acceptance vector',function()
  assert(codec.base64(codec.sha1('dGhlIHNhbXBsZSBub25jZQ==258EAFA5-E914-47DA-95CA-C5AB0DC85B11'))=='s3pPLMBiTxaQ9kYGzzhZRbK+xOo=')
end)
test('base64 padding and binary mask round trip',function()
  assert(codec.base64('f')=='Zg=='); assert(codec.base64('fo')=='Zm8='); assert(codec.base64('foo')=='Zm9v')
  local s='\0\255\128test'; assert(codec.mask(codec.mask(s,'abcd'),'abcd')==s)
end)
test('upgrade validates acceptance and supports partial writes',function()
  local accept=codec.base64(codec.sha1(codec.base64(string.rep('a',16))..'258EAFA5-E914-47DA-95CA-C5AB0DC85B11'))
  local c,s=client('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Accept: '..accept..'\r\n\r\n')
  c:handshake(); assert(s.sent:find('Authorization: EXAMPLE\r\n',1,true)); assert(s.sent:find('GET /ws HTTP/1.1',1,true))
end)
test('rejects unauthorized upgrade and header injection',function()
  fails(function() client('HTTP/1.1 401 Unauthorized\r\n\r\n'):handshake() end)
  fails(function() client('HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: invalid\r\n\r\n'):handshake() end)
  fails(function() ws.client(fake(),'host','x\r\nInjected: y') end)
end)
test('answers ping before delivering text',function()
  local c,s=client(frame(9,'ping')..frame(1,'{"flow":0}'))
  assert(c:receive()=='{"flow":0}'); assert(s.sent:byte()==138); assert(s.sent:byte(2)==132)
  assert(codec.mask(s.sent:sub(7),s.sent:sub(3,6))=='ping')
end)
test('fragmentation with interleaved ping and extended length',function()
  local expected=string.rep('x',200)..'tail'
  local c=client(frame(1,string.rep('x',200),false)..frame(9,'')..frame(0,'tail'))
  assert(c:receive()==expected)
end)
test('retains partial input on timeout',function()
  local c,s=client('\129'); fails(function() c:receive() end)
  assert(c.buffer=='\129')
end)
test('rejects invalid and oversized frames',function()
  for _,data in ipairs({string.char(129,128),string.char(193,0),frame(0,'x'),frame(2,'x'),frame(9,'x',false),string.char(129,127)..codec.u32(1)..codec.u32(0),frame(8,'x')}) do
    fails(function() client(data):receive() end)
  end
end)
test('close is acknowledged and ends stream',function()
  local c,s=client(frame(8,string.char(3,232))); fails(function() c:receive() end)
  assert(s.sent:byte()==136)
end)
test('partial updates preserve zero and negative volume',function()
  local r=readings.parse({flow=0,volume=-0.3,low_leak='OFF'})
  assert(r.flow==0 and r.volumeDelta==-0.3 and r.unusualFlow=='clear' and r.highFlow==nil)
end)
test('invalid fields never fabricate a clear alarm or zero reading',function()
  local r=readings.parse({flow='bad',volume=0/0,high_leak='invalid',low_leak=1})
  assert(next(r)==nil); assert(next(readings.parse(false))==nil)
  assert(readings.parse({high_leak=true}).highFlow=='detected')
end)
test('only local IPv4 addresses are accepted',function()
  for _,v in ipairs({'10.0.0.1','172.16.0.1','192.168.86.5','169.254.1.5'}) do assert(readings.local_ipv4(v)) end
  for _,v in ipairs({'8.8.8.8','127.0.0.1','192.168.1.300','172.32.0.1','host\r\n','example.com','::1'}) do assert(not readings.local_ipv4(v)) end
end)
print(count..' tests passed')
