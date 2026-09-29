-- Parse partial updates without fabricating missing or invalid measurements.
local M = {}
local function finite(v) return type(v)=='number' and v==v and math.abs(v)<math.huge end
local function alert(v)
  if v == true or v == 'ON' then return 'detected' end
  if v == false or v == 'OFF' then return 'clear' end
end
function M.parse(msg)
  local out = {}
  if type(msg) ~= 'table' then return out end
  if finite(msg.flow) then out.flow=msg.flow end
  if finite(msg.volume) then out.volumeDelta=msg.volume end
  if type(msg.signal)=='string' and #msg.signal<=64 then out.signal=msg.signal end
  if type(msg.server)=='string' and #msg.server<=64 then out.server=msg.server end
  out.highFlow, out.unusualFlow = alert(msg.high_leak), alert(msg.low_leak)
  return out
end
function M.local_ipv4(host)
  if type(host)~='string' then return false end
  local a,b,c,d=host:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
  a,b,c,d=tonumber(a),tonumber(b),tonumber(c),tonumber(d)
  if not a or a>255 or b>255 or c>255 or d>255 then return false end
  return a==10 or (a==172 and b>=16 and b<=31) or (a==192 and b==168) or (a==169 and b==254)
end
return M
