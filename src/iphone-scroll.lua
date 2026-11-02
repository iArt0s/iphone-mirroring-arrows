-- iPhone Mirroring: Up/Down scroll; Left/Right horizontal scroll.
-- Double Left/Right within 400ms makes a full swipe across the content.
-- Option+click or a right click over the phone picks the swipe area; the click does not reach the iPhone.
-- The same action with the cursor outside the phone, or leaving the app, clears it.
local verticalStep, horizontalStep, doubleInterval = 60, 160, 0.4
local bundleID = "com.apple.ScreenContinuity"
if iphoneArrowControl then iphoneArrowControl.stop() end
if iphoneScrollTap then iphoneScrollTap:stop() end
local c, timers, pending = {}, {}, nil
iphoneArrowControl = c
local restoreTimer, original, target
local gestureTimers = {}
local gestureActive = false
local anchor, swallowClick

local function movePointer(point)
    local current = hs.mouse.absolutePosition()
    hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.mouseMoved,point)
        :setProperty(hs.eventtap.event.properties.mouseEventDeltaX,math.floor(point.x-current.x+0.5))
        :setProperty(hs.eventtap.event.properties.mouseEventDeltaY,math.floor(point.y-current.y+0.5)):post()
end

local function after(delay, fn)
    local t
    t = hs.timer.doAfter(delay, function() timers[t] = nil; fn() end)
    timers[t] = true
    return t
end
local function cancel(t)
    if t then t:stop(); timers[t] = nil end
end
local function restore()
    if original and target then
        local p = hs.mouse.absolutePosition()
        if math.abs(p.x-target.x)<2 and math.abs(p.y-target.y)<2 then
            movePointer(original)
        end
    end
    original, target = nil, nil
end
local function activeWindow()
    local a = hs.application.frontmostApplication()
    if a and a:bundleID()==bundleID then return a:mainWindow() end
end
local function scroll(dx, dy, phase)
    local e = hs.eventtap.event.newScrollEvent({dx,dy}, {}, "pixel")
    e:location(hs.mouse.absolutePosition())
    e:setProperty(hs.eventtap.event.properties.scrollWheelEventIsContinuous,1)
    if phase then e:setProperty(hs.eventtap.event.properties.scrollWheelEventScrollPhase,phase) end
    e:post()
end
local function perform(key, fullSwipe)
    local w = activeWindow()
    if not w then return end
    if c.task then return end -- Keep cursor gestures from overlapping.
    if key=="left" or key=="right" then
        local frame = w:frame()
        local distance = fullSwipe and frame.w*0.85 or horizontalStep
        local x = anchor and frame.x+anchor.x or frame.x+frame.w*0.5
        local y = anchor and frame.y+anchor.y or frame.y+frame.h*0.72
        c.task = hs.task.new(hs.configdir .. "/iphone-swipe",function(code,_,err)
            c.task=nil
            if code~=0 then print("iPhone swipe:",code,err) end
        end,{tostring(x),tostring(y),key,tostring(distance),anchor and "anchor" or "scroll"})
        if c.task then c.task:start() else print("iPhone swipe: helper missing") end
        return
    end
    if gestureActive then scroll(0,0,8); gestureActive=false end
    for _, t in ipairs(gestureTimers) do cancel(t) end
    gestureTimers = {}
    cancel(restoreTimer)
    restore()
    local f, left = w:frame(), key=="left"
    local horizontal = key=="left" or key=="right"
    original = hs.mouse.absolutePosition()
    target = {x=f.x+f.w*0.5, y=f.y+f.h*(horizontal and 0.72 or 0.28)}
    movePointer(target)
    movePointer({x=target.x+1,y=target.y})
    movePointer(target)
    if horizontal then
        local distance = fullSwipe and f.w*0.85 or horizontalStep
        local delta = (left and -1 or 1)*math.floor(distance/8)
        gestureActive=true
        scroll(0,0,128)
        gestureTimers[#gestureTimers+1] = after(0.1,function() scroll(delta,0,1) end)
        for i=1,7 do
            gestureTimers[#gestureTimers+1] = after(0.1+i*0.02,function()
                local current = activeWindow()
                if current and current:id()==w:id() then scroll(delta,0,2) end
            end)
        end
        gestureTimers[#gestureTimers+1] = after(0.26,function()
            scroll(0,0,4)
            gestureActive=false
        end)
    elseif key=="up" or key=="down" then
        scroll(0,key=="up" and verticalStep or -verticalStep)
    end
    restoreTimer = after(horizontal and 0.34 or 0.08,function() restore(); restoreTimer=nil end)
end
local function flush()
    if not pending then return end
    local key = pending.key
    cancel(pending.timer)
    pending = nil
    perform(key,false)
end
function c.press(key, repeated)
    if key=="up" or key=="down" or repeated then
        flush()
        perform(key,false)
    elseif pending and pending.key==key then
        cancel(pending.timer)
        pending = nil
        perform(key,true)
    else
        flush()
        pending = {key=key}
        pending.timer = after(doubleInterval,flush)
    end
end
c.tap = hs.eventtap.new({hs.eventtap.event.types.keyDown},function(e)
    local key
    for _, name in ipairs({"up","down","left","right"}) do
        if e:getKeyCode()==hs.keycodes.map[name] then key=name; break end
    end
    if not key then return false end
    local f = e:getFlags()
    if f.cmd or f.ctrl or f.alt or f.shift or not activeWindow() then
        if pending then cancel(pending.timer); pending=nil end
        return false
    end
    c.press(key,e:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat)~=0)
    return true
end)
local function pickArea(w)
    local f, p = w:frame(), hs.mouse.absolutePosition()
    if p.x>f.x+f.w*0.144 and p.x<f.x+f.w*0.856 and p.y>f.y+f.h*0.089 and p.y<f.y+f.h*0.911 then
        anchor = {x=p.x-f.x,y=p.y-f.y}
        hs.alert.show("Свайп: выбранная область",0.5)
        return true
    elseif anchor then
        anchor = nil
        hs.alert.show("Свайп: всё приложение",0.5)
        return true
    end
    return false
end
c.clickTap = hs.eventtap.new({
    hs.eventtap.event.types.leftMouseDown,hs.eventtap.event.types.leftMouseDragged,hs.eventtap.event.types.leftMouseUp,
    hs.eventtap.event.types.rightMouseDown,hs.eventtap.event.types.rightMouseDragged,hs.eventtap.event.types.rightMouseUp
},function(e)
    local types = hs.eventtap.event.types
    local kind = e:getType()
    if kind==types.leftMouseDown or kind==types.rightMouseDown then
        local w = activeWindow()
        local wanted = w and (kind==types.rightMouseDown or e:getFlags().alt)
        swallowClick = wanted and pickArea(w) or false
        return swallowClick
    end
    local swallowed = swallowClick
    if kind==types.leftMouseUp or kind==types.rightMouseUp then swallowClick=false end
    return swallowed or false
end)
c.watcher = hs.application.watcher.new(function(_,event,app)
    if event==hs.application.watcher.deactivated and app and app:bundleID()==bundleID then anchor=nil end
end)
function c.stop()
    c.tap:stop()
    c.clickTap:stop()
    c.watcher:stop()
    for t in pairs(timers) do t:stop() end
    if gestureActive then scroll(0,0,8); gestureActive=false end
    timers, pending = {}, nil
    restore()
end
iphoneScrollTap = c.tap
c.tap:start()
c.clickTap:start()
c.watcher:start()
