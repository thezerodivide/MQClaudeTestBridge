local function w(p, s) local f = assert(io.open(p, 'wb')); f:write(s); f:close() end
local function r(p) local f = io.open(p, 'rb'); if not f then return nil end local s = f:read('*a'); f:close(); return s end
os.remove('rt_a.tmp'); os.remove('rt_b.json')
w('rt_a.tmp', 'new'); w('rt_b.json', 'old')
print('rename onto existing file:', os.rename('rt_a.tmp', 'rt_b.json'))
print('rt_b.json now:', r('rt_b.json'), '| rt_a.tmp exists:', r('rt_a.tmp') ~= nil)
-- reader holding the destination open (default sharing) while writer renames onto it
os.remove('rt_a.tmp'); os.remove('rt_c.json'); os.remove('rt_d.tmp')
w('rt_c.json', 'old'); w('rt_d.tmp', 'new')
local held = io.open('rt_c.json', 'rb')
print('remove destination while a reader holds it open:', os.remove('rt_c.json'))
held:close()
os.remove('rt_c.json'); os.remove('rt_d.tmp')
