-- Portable WebSocket encoding helpers (no native dependencies).
local M = {}
local floor = math.floor
local function bitop(a, b, and_mode)
  local result, place = 0, 1
  for _ = 1, 32 do
    local x, y = a % 2, b % 2
    if (and_mode and x == 1 and y == 1) or (not and_mode and x ~= y) then
      result = result + place
    end
    a, b, place = floor(a / 2), floor(b / 2), place * 2
  end
  return result
end
local function xor(a, b) return bitop(a, b, false) end
local function band(a, b) return bitop(a, b, true) end
local function rol(a, n)
  return (a * 2^n) % 2^32 + floor(a / 2^(32-n))
end
function M.u32(n)
  return string.char(floor(n / 2^24) % 256, floor(n / 2^16) % 256,
    floor(n / 256) % 256, n % 256)
end
function M.sha1(s)
  local bits = #s * 8
  s = s .. '\128' .. string.rep('\0', (55 - #s) % 64) .. M.u32(0) .. M.u32(bits)
  local a0,b0,c0,d0,e0 = 0x67452301,0xefcdab89,0x98badcfe,0x10325476,0xc3d2e1f0
  for offset = 1, #s, 64 do
    local w = {}
    for i = 0, 15 do
      local a,b,c,d = s:byte(offset+i*4, offset+i*4+3)
      w[i] = a*2^24+b*2^16+c*256+d
    end
    for i = 16,79 do w[i] = rol(xor(xor(w[i-3],w[i-8]),xor(w[i-14],w[i-16])),1) end
    local a,b,c,d,e = a0,b0,c0,d0,e0
    for i = 0,79 do
      local f,k
      if i < 20 then f,k = band(b,c)+band(2^32-1-b,d),0x5a827999
      elseif i < 40 then f,k = xor(xor(b,c),d),0x6ed9eba1
      elseif i < 60 then f,k = xor(xor(band(b,c),band(b,d)),band(c,d)),0x8f1bbcdc
      else f,k = xor(xor(b,c),d),0xca62c1d6 end
      local temp = (rol(a,5)+f+e+k+w[i]) % 2^32
      e,d,c,b,a = d,c,rol(b,30),a,temp
    end
    a0,b0,c0,d0,e0 = (a0+a)%2^32,(b0+b)%2^32,(c0+c)%2^32,(d0+d)%2^32,(e0+e)%2^32
  end
  return M.u32(a0)..M.u32(b0)..M.u32(c0)..M.u32(d0)..M.u32(e0)
end
function M.base64(s)
  local alphabet, out = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/', {}
  for i = 1,#s,3 do
    local a,b,c = s:byte(i,i+2)
    local n = a*65536+(b or 0)*256+(c or 0)
    out[#out+1] = alphabet:sub(floor(n/262144)%64+1,floor(n/262144)%64+1)
      ..alphabet:sub(floor(n/4096)%64+1,floor(n/4096)%64+1)
      ..(b and alphabet:sub(floor(n/64)%64+1,floor(n/64)%64+1) or '=')
      ..(c and alphabet:sub(n%64+1,n%64+1) or '=')
  end
  return table.concat(out)
end
function M.random(n)
  local out = {}
  for i=1,n do out[i] = string.char(math.random(0,255)) end
  return table.concat(out)
end
function M.mask(s, key)
  local out = {}
  for i=1,#s do out[i] = string.char(xor(s:byte(i),key:byte((i-1)%4+1))) end
  return table.concat(out)
end
return M
