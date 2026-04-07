-- ticketing_workload.lua
-- Sysbench script: ticketing workload with hot-row contention via Pareto distribution.
-- 80% of traffic hits the top 5% of rows (hot events).
--
-- Usage:
--   sysbench ticketing_workload.lua --mysql-host=X --mysql-port=3306 \
--     --mysql-user=U --mysql-password=P --mysql-db=D \
--     --threads=N [--num_tickets=10000] [--hot_rows=5] prepare|run|cleanup

sysbench.cmdline.options = {
   num_tickets = {"Number of tickets to create", 10000},
   hot_rows    = {"Percentage of rows that are hot (top N%)", 5},
}

local con
local drv

function prepare()
   local drv = sysbench.sql.driver()
   local con = drv:connect()

   con:query("DROP TABLE IF EXISTS orders")
   con:query("DROP TABLE IF EXISTS tickets")

   con:query([[
      CREATE TABLE tickets (
         ticket_id   INT NOT NULL PRIMARY KEY,
         event_id    INT NOT NULL,
         status      ENUM('available','reserved','sold') NOT NULL DEFAULT 'available',
         reserved_at TIMESTAMP NULL DEFAULT NULL,
         version     INT NOT NULL DEFAULT 0,
         INDEX idx_event_status (event_id, status)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
   ]])

   con:query([[
      CREATE TABLE orders (
         order_id   BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
         ticket_id  INT NOT NULL,
         user_id    INT NOT NULL,
         created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
         FOREIGN KEY (ticket_id) REFERENCES tickets(ticket_id)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
   ]])

   local num_tickets = sysbench.opt.num_tickets
   print(string.format("Inserting %d tickets across 100 events...", num_tickets))

   con:query("BEGIN")
   for i = 1, num_tickets do
      local event_id = ((i - 1) % 100) + 1
      con:query("INSERT INTO tickets (ticket_id, event_id) VALUES (" .. i .. ", " .. event_id .. ")")
      if i % 1000 == 0 then
         con:query("COMMIT")
         con:query("BEGIN")
      end
   end
   con:query("COMMIT")

   print("Data seeded.")
   con:disconnect()
end

function thread_init(thread_id)
   drv = sysbench.sql.driver()
   con = drv:connect()
end

function event()
   local num_tickets = sysbench.opt.num_tickets
   local hot_pct     = sysbench.opt.hot_rows

   -- Pareto: 80% of requests hit top hot_pct% rows, 20% hit the rest
   local hot_boundary = math.floor(num_tickets * hot_pct / 100)
   if hot_boundary < 1 then hot_boundary = 1 end

   local ticket_id
   if math.random(1, 100) <= 80 then
      ticket_id = math.random(1, hot_boundary)
   else
      if hot_boundary < num_tickets then
         ticket_id = math.random(hot_boundary + 1, num_tickets)
      else
         ticket_id = math.random(1, num_tickets)
      end
   end

   local ok, err

   ok, err = pcall(function() con:query("BEGIN") end)
   if not ok then
      pcall(function() con:query("ROLLBACK") end)
      return
   end

   local rs
   ok, err = pcall(function()
      rs = con:query("SELECT ticket_id, status FROM tickets WHERE ticket_id = " .. ticket_id .. " FOR UPDATE")
   end)
   if not ok then
      pcall(function() con:query("ROLLBACK") end)
      return
   end

   local status = nil
   if rs then
      local row = rs:fetch_row()
      if row then
         status = row[2]
      end
      rs:free()
   end

   if status == "available" then
      ok, err = pcall(function()
         con:query("UPDATE tickets SET status = 'reserved', reserved_at = NOW(), version = version + 1 WHERE ticket_id = " .. ticket_id)
      end)
      if not ok then
         pcall(function() con:query("ROLLBACK") end)
         return
      end

      local user_id = math.random(1, 100000)
      ok, err = pcall(function()
         con:query("INSERT INTO orders (ticket_id, user_id) VALUES (" .. ticket_id .. ", " .. user_id .. ")")
      end)
      if not ok then
         pcall(function() con:query("ROLLBACK") end)
         return
      end
   end

   ok, err = pcall(function() con:query("COMMIT") end)
   if not ok then
      pcall(function() con:query("ROLLBACK") end)
   end
end

function thread_done(thread_id)
   if con then
      con:disconnect()
   end
end

function cleanup()
   local drv = sysbench.sql.driver()
   local con = drv:connect()

   con:query("DROP TABLE IF EXISTS orders")
   con:query("DROP TABLE IF EXISTS tickets")
   print("Cleanup complete.")

   con:disconnect()
end
