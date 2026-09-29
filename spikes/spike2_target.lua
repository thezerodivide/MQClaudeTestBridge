local mq = require('mq')
local t0 = os.time()
while os.time() - t0 < 20 do mq.delay(200) end
return 'target-done'
