-- airclkr//
-- Link to MIDI Bridge
-- v1.1.1 (by MonCalamari)
--
-- E1: Tempo (nur wenn allein!)
-- K1 + E1: Port (nur im Stop)
-- E2: Offset (ms)
-- E3: Sync Mode
-- K2: STOP | K3: START
-- K2+K3: MIDI PANIC (Forces Blink-Stop)
--
-- NOTE ON NEGATIVE OFFSETS:
-- This script intentionally only supports positive offsets (0 to 100ms).
-- True negative offsets (look-ahead) require hardware-level timers to 
-- accurately predict the next Ableton Link beat in advance. Implementing 
-- a software-based "sleep" workaround in Lua introduces jitter and 
-- ruins the timing stability when BPM changes. If your hardware lags 
-- behind, please use the track/sync delay compensation directly within 
-- Ableton Live instead.

local midi_out
local is_playing = false
local queued_start = false
local is_panic_stop = false
local k1_held, k2_held, k3_held = false, false, false
local panic_active = false 

local start_clock_id 

-- UI STATES
local show_splash = true
local screen_dirty = true
local panic_visual = 0 

function init()
  params:add_group("airclkr//", 3)
  params:add{type = "number", id = "midi_port", name = "MIDI Port", min = 1, max = 16, default = 1}
  params:set_action("midi_port", function(value) midi_out = midi.connect(value) end)
  
  -- Min value is now 0 (positive offsets only)
  params:add{type = "number", id = "offset", name = "Offset (ms)", min = 0, max = 100, default = 0}
  params:add{type = "option", id = "sync_mode", name = "Sync Mode", options = {"1 BAR", "1 BEAT"}, default = 1}

  params:set("clock_source", 3) 
  params:set("link_start_stop_sync", 2) 
  
  midi_out = midi.connect(params:get("midi_port"))
  
  -- Trigger UI update if Ableton Link changes tempo remotely
  clock.tempo_change_handler = function()
    screen_dirty = true
  end
  
  clock.run(function()
    clock.sleep(2.0)
    show_splash = false
    screen_dirty = true
  end)

  clock.run(midi_clock_loop)
  
  -- Optimized UI Loop (15 FPS, conditional redraw)
  clock.run(function()
    while true do
      clock.sleep(1/15)
      if panic_visual > 0 then 
        panic_visual = panic_visual - 1 
        screen_dirty = true
      end
      
      if is_playing or queued_start or screen_dirty or is_panic_stop then
        redraw()
        screen_dirty = false
      end
    end
  end)
end

function clock.transport.start()
  if not is_playing and not queued_start then
    is_panic_stop = false
    queued_start = true
    screen_dirty = true
    start_clock_id = clock.run(quantized_start_task)
  end
end

function clock.transport.stop()
  if start_clock_id then clock.cancel(start_clock_id) end
  if midi_out then midi_out:stop() end
  is_playing = false
  queued_start = false
  screen_dirty = true
end

function quantized_start_task()
  local s = (params:get("sync_mode") == 1) and 4 or 1
  clock.sync(s) 
  
  -- Simplified: Only handles positive delays now
  local off = params:get("offset")
  if off > 0 then clock.sleep(off / 1000) end 
  
  if midi_out then midi_out:start() end
  is_playing = true
  queued_start = false
  screen_dirty = true
end

function midi_panic()
  if midi_out then
    for c = 1, 16 do
      midi_out:cc(123, 0, c); midi_out:cc(120, 0, c)
    end
  end
  clock.link.stop()
  clock.transport.stop()
  is_panic_stop = true
  panic_visual = 15
  panic_active = true 
  screen_dirty = true
end

function enc(n, d)
  if show_splash then return end 
  local peers = (link and link.num_peers) and link.num_peers() or 0

  if n == 1 then
    if k1_held then
      if not is_playing and not queued_start then params:delta("midi_port", d) end
    elseif peers == 0 then
      params:delta("clock_tempo", d)
    end
  elseif n == 2 then params:delta("offset", d)
  elseif n == 3 then params:delta("sync_mode", d) end
  
  screen_dirty = true
end

function key(n, z)
  if show_splash then return end
  if n == 1 then k1_held = (z == 1) end
  if n == 2 then k2_held = (z == 1) end
  if n == 3 then k3_held = (z == 1) end

  if z == 1 then
    if k2_held and k3_held then midi_panic() end
  end

  if z == 0 then
    if not panic_active then
      if n == 2 then 
        is_panic_stop = false
        clock.link.stop()
        clock.transport.stop()
      elseif n == 3 then 
        if not is_playing and not queued_start then clock.link.start() end
      end
    end
    if not k2_held and not k3_held then panic_active = false end
  end
  
  screen_dirty = true
end

function midi_clock_loop()
  while true do
    clock.sync(1/24) 
    
    -- Simplified: Only sleep if there is a positive delay
    local off = params:get("offset")
    if off > 0 then clock.sleep(off / 1000) end
    
    if midi_out then midi_out:clock() end
  end
end

function redraw()
  screen.clear()
  local suffix = is_playing and ">>" or "//"
  local name = "airclkr" .. suffix

  if show_splash then
    screen.level(15); screen.move(64, 28); screen.text_center(name)
    screen.level(10); screen.move(64, 40); screen.text_center("Dirk Becker")
    screen.level(4); screen.move(64, 52); screen.text_center("v1.1.1") 
  else
    draw_main(name) -- name wird jetzt korrekt übergeben!
  end
  screen.update()
end

function draw_main(name) -- name wird hier entgegengenommen
  local peers = (link and link.num_peers) and link.num_peers() or 0
  local beats = clock.get_beats() + 0.05
  local current_beat = 1
  if peers > 0 or is_playing or queued_start then
    current_beat = (math.floor(beats) % 4) + 1
  end
  
  screen.aa(0) 
  screen.level(1)
  screen.move(0, 11); screen.line(128, 11); screen.stroke() 
  screen.move(0, 56); screen.line(128, 56); screen.stroke() 

  -- HEADER
  screen.level(15); screen.move(0, 7); screen.text(name)
  
  -- BPM ANZEIGE
  if peers == 0 then screen.level(15) else screen.level(5) end
  screen.move(128, 7); screen.text_right(util.round(clock.get_tempo(), 0.1) .. (peers == 0 and "*" or "") .. " BPM")
  
  -- TIMELINE
  for i=1,4 do
    local x = 42 + (i*6) 
    local y = 3 
    screen.level((current_beat == i) and 15 or 2)
    if is_playing then
      screen.move(x, y-2); screen.line(x, y+2); screen.line(x+3, y); screen.fill()
    else
      screen.rect(x, y-1, 3, 3); screen.fill()
    end
  end
  
  -- MITTEL-BLOCK
  screen.move(0, 21); screen.level(is_playing and 2 or 5); screen.text("PORT:")
  screen.move(40, 21); screen.level(is_playing and 2 or 15)
  local port = params:get("midi_port")
  local dev_name = midi.vports[port] and midi.vports[port].name or "NONE"
  screen.text(is_playing and (string.sub(port .. ":" .. dev_name, 1, 10) .. " [LOK]") or string.sub(port .. ":" .. dev_name, 1, 16))
  
  screen.move(0, 31); screen.level(4); screen.text("STATE:")
  screen.move(40, 31); screen.level(15)
  if panic_visual > 0 then screen.text("! PANIC !")
  elseif queued_start then screen.text("WAITING...")
  elseif is_playing then screen.text("PLAYING")
  else 
    -- Blink-Effekt für Panic-Stop
    if is_panic_stop and (math.floor(clock.get_beats() * 4) % 2 == 0) then
      screen.text("")
    else
      screen.text("STOPPED")
    end
  end
  
  screen.move(0, 41); screen.level(4); screen.text("OFFS:")
  screen.move(40, 41); screen.level(10)
  screen.text("+" .. params:get("offset") .. " ms")
  
  screen.move(0, 51); screen.level(4); screen.text("SYNC:")
  screen.move(40, 51); screen.level(10)
  screen.text(params:string("sync_mode"))
  
  -- FOOTER
  screen.level(2) 
  screen.move(0, 64); screen.text("K2:STP")
  screen.move(64, 64); screen.text_center("K2+3:PANIC")
  screen.move(128, 64); screen.text_right("K3:STA")
end

function cleanup()
  clock.link.stop()
  clock.transport.stop()
end

```
