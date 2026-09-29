-- A bounded RFC 6455 client for Droplet's text stream. Socket is injected for tests.
local codec = require 'codec'
local M = {}
local MAX = 65536
local function send_all(sock, data)
  local at = 1
  while at <= #data do
    local sent, err, partial = sock:send(data, at)
    if not sent then error('WebSocket send failed: '..tostring(err)) end
    if sent < at then error('WebSocket send made no progress') end
    at = sent + 1
  end
end
function M.client(sock, host, token, random)
  assert(not host:find('[\r\n]') and not token:find('[\r\n]'), 'Invalid connection fields')
  local self = { sock=sock, buffer='', random=random or codec.random, fragments=nil }
  function self:read(n)
    while #self.buffer < n do
      local data, err, partial = self.sock:receive(n-#self.buffer)
      self.buffer = self.buffer .. (data or partial or '')
      if not data then error('WebSocket receive failed: '..tostring(err)) end
    end
    local out = self.buffer:sub(1,n)
    self.buffer = self.buffer:sub(n+1)
    return out
  end
  function self:send(opcode, payload)
    payload = payload or ''
    assert(#payload <= MAX and (opcode < 8 or #payload <= 125), 'Frame too large')
    local key = self.random(4)
    local len = #payload
    local header = string.char(128+opcode)
    if len < 126 then header = header..string.char(128+len)
    elseif len <= 65535 then header = header..string.char(254,math.floor(len/256),len%256)
    else header = header..string.char(255)..codec.u32(0)..codec.u32(len) end
    send_all(self.sock, header..key..codec.mask(payload,key))
  end
  function self:handshake()
    local key = codec.base64(self.random(16))
    send_all(self.sock, 'GET /ws HTTP/1.1\r\nHost: '..host..'\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: '..key..'\r\nAuthorization: '..token..'\r\n\r\n')
    local response = ''
    repeat
      response = response .. self:read(1)
      if #response > 8192 then error('HTTP response headers too large') end
    until response:sub(-4) == '\r\n\r\n'
    if not response:match('^HTTP/1%.[01] 101 ') then
      local status = response:match('^HTTP/1%.[01] (%d%d%d)') or 'invalid'
      error('Droplet rejected connection (HTTP '..status..')')
    end
    local headers = {}
    for name, value in response:gmatch('\r\n([%w%-]+):%s*([^\r\n]+)') do
      headers[name:lower()] = value:gsub('%s+$','')
    end
    local expected = codec.base64(codec.sha1(key..'258EAFA5-E914-47DA-95CA-C5AB0DC85B11'))
    assert(headers['sec-websocket-accept'] == expected, 'Invalid WebSocket acceptance')
    assert((headers.upgrade or ''):lower() == 'websocket', 'Invalid WebSocket upgrade')
    assert((','..(headers.connection or ''):lower():gsub('%s','')..','):find(',upgrade,',1,true), 'Invalid Connection header')
    assert(not headers['sec-websocket-extensions'], 'Unrequested WebSocket extension')
  end
  function self:receive()
    while true do
      local a,b = self:read(2):byte(1,2)
      local final, opcode, len = a >= 128, a%16, b%128
      assert(a%128 < 16 and b < 128, 'Invalid server frame flags')
      if len == 126 then local x,y = self:read(2):byte(1,2); len=x*256+y
      elseif len == 127 then
        local bytes = self:read(8)
        assert(bytes:sub(1,4) == string.rep('\0',4), 'Frame too large')
        len=0; for i=5,8 do len=len*256+bytes:byte(i) end
      end
      assert(len <= MAX, 'Frame too large')
      assert(opcode < 8 or (final and len <= 125), 'Invalid control frame')
      local payload = self:read(len)
      if self.on_activity then self.on_activity() end
      if opcode == 8 then
        assert(len ~= 1, 'Invalid close frame')
        self:send(8,payload); error('Droplet closed connection')
      elseif opcode == 9 then self:send(10,payload)
      elseif opcode == 10 then -- pong; keep receiving
      elseif opcode == 1 then
        assert(not self.fragments, 'Unexpected text frame')
        if final then return payload end
        self.fragments, self.fragment_size = {payload}, #payload
      elseif opcode == 0 then
        assert(self.fragments, 'Unexpected continuation')
        self.fragment_size = self.fragment_size + #payload
        assert(self.fragment_size <= MAX, 'Message too large')
        self.fragments[#self.fragments+1] = payload
        if final then local message=table.concat(self.fragments); self.fragments=nil; return message end
      else error('Unsupported WebSocket opcode') end
    end
  end
  return self
end
return M
