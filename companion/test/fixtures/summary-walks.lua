-- Disposable native fixture only; never installed in the production mod.
local M = {}
local summary = require("scripts.map_summary")
local baseline = require("scripts.walk_baseline")
local rpc = require("scripts.rpc")
local jobs=require("scripts.jobs")
local fixture=require("scripts.walk_fixture")
local companion = require("scripts.companion")
local surfaces = require("scripts.surfaces")
local output_target = require("scripts.output_target")
companion.body = function()
  local s = storage.eq_surface and game.surfaces[storage.eq_surface] or game.surfaces.nauvis
  return {state="on_surface",surface=s,surface_ref=s.name,force=game.forces.player,position={x=0,y=0}}
end
local charted = surfaces.charted
surfaces.charted = function(force,surface,cx,cy,platform)
  if surface.index == storage.eq_surface then return true end
  return charted(force,surface,cx,cy,platform)
end
function M.physical()
  local s = game.create_surface("walk-physical", {width=256,height=64,autoplace_settings={entity={treat_missing_as_default=false}}})
  storage.eq_surface = s.index
  s.request_to_generate_chunks({0,0},4) s.force_generate_chunk_requests()
  local tiles = {}
  for x=-128,127 do for y=-32,31 do tiles[#tiles+1]={name="refined-concrete",position={x,y}} end end
  s.set_tiles(tiles)
  local function make(name,x,y,dir)
    return assert(s.create_entity{name=name,position={x=x,y=y},direction=dir or 0,force="player"})
  end
  for x=-88,-86 do for y=-1,1 do s.create_entity{name="iron-ore",position={x=x,y=y},amount=100000} end end
  local drill=make("burner-mining-drill",-87,0,defines.direction.east)
  drill.insert{name="coal",count=20}
  local drop=output_target.output_position(drill.prototype,drill.position,drill.direction)
  for i=0,79 do make("transport-belt",drop.x+i,drop.y,defines.direction.east) end
  local take=make("inserter",drop.x+80,drop.y,defines.direction.west)
  local chest=make("iron-chest",drop.x+81,drop.y)
  chest.insert{name="coal",count=50}
  local furnace=make("stone-furnace",15,0)
  furnace.insert{name="iron-ore",count=10} furnace.insert{name="coal",count=10}
  for x=30,37 do make("transport-belt",x,0,defines.direction.east) end
  make("transport-belt",38,0,defines.direction.south)
  make("transport-belt",38,1,defines.direction.south)
  make("transport-belt",38,2,defines.direction.west)
  for x=30,37 do make("transport-belt",x,2,defines.direction.west) end
  make("transport-belt",29,2,defines.direction.north)
  make("transport-belt",29,1,defines.direction.north)
  make("transport-belt",29,0,defines.direction.east)
  local a,b=make("lab",0,12),make("lab",4,12)
  a.insert{name="automation-science-pack",count=10}
  make("inserter",2,12,defines.direction.west)
  make("wooden-chest",60,12).insert{name="copper-plate",count=5}
  for _,e in pairs(s.find_entities_filtered{force="player"}) do if e.type~="resource" then pcall(function() e.active=false end) end end
  storage.patch_caches=nil
  storage.registry.ready=true
  return {surface=s.index,entities=#s.find_entities_filtered{force="player"},drop=drop,tick=game.tick}
end
function M.new(version,detail)
  storage.patch_caches=nil
  return (version=="baseline" and baseline or summary).summary_job.start{detail=detail,surface="walk-physical"}
end
function M.run(version,S,work)
  local def=(version=="baseline" and baseline or summary).summary_job
  local result
  for i=1,1000 do
    result=def.step(S,{left=work})
    if result then return rpc.to_json(result),i end
  end
  return nil,1000
end
function M.boundary(version,detail,stage)
  local mod=version=="baseline" and baseline or summary
  local S=M.new(version,detail)
  while S.stage~="flow" do assert(not mod.summary_job.step(S,{left=1})) end
  assert(S.flow.stage<=stage)
  while S.flow.stage<stage do
    if mod.stage_probe[S.flow.stage](S.flow,{left=7}) then S.flow.stage=S.flow.stage+1 S.flow.cursor=nil end
  end
  return S
end

function fixture.caller(kind, n, shape)
  local F = fixture.build(kind, n, shape)
  local root, entities = F.node_by_id.root, storage.walk_entities
  root._entity = kind == "upstream_products" and entities.lab or entities.chest
  if kind == "upstream_proven" then
    local destination = { id = "destination", requires_fuel = true, fuel_categories = { chemical = true },
      status = "working", ingredients = {}, _fuel_destination_proven = true, _entity = entities.drill }
    local inserter = { id = "return-inserter", type = "inserter", _waiting_for_destination = true, _entity = entities.inserter }
    F.nodes = { inserter }
    F.node_by_id[destination.id], F.node_by_id[inserter.id] = destination, inserter
    F.edges_of[inserter.id] = { { from = "root", to = inserter.id, kind = "inserter_pickup" },
      { from = inserter.id, to = destination.id, kind = "inserter_drop" } }
  end
  return F
end

local eq=M
local function stage_for(kind)
  return kind=="upstream_proven" and 19 or (kind=="reaches_downstream" or kind=="material_upstream") and 24 or 20
end
local function project(F)
  local out={nodes={},edges=F.edges,components={},diagnostics=F.diagnostics}
  for _,field in ipairs({"nodes","components"}) do
    for _,node in ipairs(F[field]) do
      local row={}
      for key,value in pairs(node) do
        if key:sub(1,1)~="_" and key~="ingredients" and key~="products" and key~="fuel_categories" and key~="requires_fuel" then row[key]=value end
      end
      if field=="nodes" and (node.role=="buffer" or node.role=="sink") then
        row.evaluation={downstream_buffer=node._downstream_buffer,accepting=node._accepting,
          blocked_output=node._blocked_output,missing_science_pack=node._missing_science_pack}
      end
      out[field][#out[field]+1]=row
    end
  end
  return out
end
local function pending(F)
  local P=F.fuel or F.buffer or F.current
  local W=P and P.walk
  return {phase=P and P.phase,node_phase=P and P.node_phase,observed=P and P.observed or nil,
    product_key=P and P.product_key or nil,ingredient=P and P.ingredient or nil,kind=W and W.kind or nil,
    head=W and W.head or nil,walk_phase=W and W.phase or nil,index=W and W.index or nil}
end
local function checkpoint(F)
  local P=F.fuel or F.buffer or F.current
  if not P then return {} end
  local W=P.walk
  return {progress=pending(F),rows=P.rows,h1=P.h1,h2=P.h2,
    producing_nodes=P.producing_nodes,accepting_sinks=P.accepting_sinks,buffers=P.buffers,consumers=P.consumers,
    products=P.products,ok=P.ok,fuel=P.fuel,quality=P.quality,identity=P.identity,
    walk=W and {queue=W.queue,seen=W.seen,ingredient=W.ingredient,fuel_only=W.fuel_only} or nil}
end
M.stage_job={defer_encode=true,
  start=function() local S=assert(storage.eq_prepared) storage.eq_prepared=nil return S end,
  step=function(S,budget)
    if S.hold then S.hold=nil budget.left=0 return end
    local b={left=math.min(7,budget.left)} local before=b.left
    local done=summary.stage_probe[S.stage](S.F,b)
    budget.left=budget.left-math.max(0,before-b.left)
    if done then return {json=rpc.to_json(project(S.F))} end
  end}
jobs.register("eq_stage",M.stage_job)
function M.actors()
  local s=game.surfaces[storage.eq_surface]
  storage.walk_entities={}
  for key,name in pairs({chest="iron-chest",lab="lab",drill="burner-mining-drill",inserter="burner-inserter"}) do
    local x=key=="chest" and 80 or key=="lab" and 85 or key=="drill" and 90 or 95
    local e=assert(s.create_entity{name=name,position={x=x,y=12},force="player"})
    e.active=false storage.walk_entities[key]=e
  end
  local e=storage.walk_entities.drill
  e.get_fuel_inventory().insert{name="coal",count=5}
  e.burner.currently_burning={name="coal",quality="normal"} e.burner.remaining_burning_fuel=100000
  storage.walk_entities.inserter.held_stack.set_stack{name="coal",count=1}
end
function M.prepare_stage(kind,variant)
  local component=variant=="ingredient" or variant=="fuel" or variant=="cargo"
  local stage=component and 24 or stage_for(kind)
  local shape=variant=="products" and "fanout" or "branch"
  local function make()
    if not component then return fixture.caller(kind,128,shape) end
    local F=fixture.build("material_upstream",128,"branch")
    local node=F.node_by_id.root
    node.products={{name="iron-plate",type="item"}}
    if variant=="ingredient" then
      node.ingredients={{name="copper-ore",type="item"},{name="iron-ore",type="item"}}
    else
      node.requires_fuel,node.fuel_categories=true,{chemical=true}
      if variant=="cargo" then
        node.role,node.type,node.name="transport","inserter","burner-inserter"
        F.pickup_of.root="path-1"
        F.node_by_id["path-128"].products={{name="iron-ore",type="item"}}
      end
    end
    return F
  end
  local B=make()
  while not baseline.stage_probe[stage](B,{left=600}) do end
  local expected=rpc.to_json(project(B))
  storage.eq_prepared={F=make(),stage=stage,hold=true}
  local ticket=jobs.start("eq_stage",{})
  local S=assert(storage.jobs.by_id[ticket.job_id].state)
  local found=false
  for i=1,100000 do
    local done=summary.stage_probe[stage](S.F,{left=1})
    local p=pending(S.F)
    if component then
      local phase=variant=="ingredient" and 5 or variant=="fuel" and 6 or 7
      found=p.node_phase==phase and p.kind==kind and p.head and p.head>2
        and (variant~="ingredient" or p.ingredient==2)
    elseif variant=="products" then found=p.product_key~=nil
    elseif variant=="caller" then
      found=kind=="upstream_proven" and p.observed==true and p.kind==kind
        or kind=="first_reached" and p.phase==2 and p.kind==kind
        or kind=="material_upstream" and S.F.current and S.F.current.node_phase==2 and p.kind==kind
    else found=p.kind==kind and p.head and p.head>2 end
    if found then break end
    assert(not done,"case ended before requested cursor")
  end
  assert(found,"pending case not reached")
  storage.eq_cases=storage.eq_cases or {}
  storage.eq_cases[ticket.job_id]={expected=expected,kind="eq_stage",checkpoint=rpc.to_json(checkpoint(S.F))}
  return {id=ticket.job_id,kind=kind,variant=variant,progress=pending(S.F),expected=expected}
end
function M.prepare_full(kind,stage)
  local B=eq.new("baseline","full")
  local expected
  repeat expected=eq.run("baseline",B,600) until expected
  local S
  if stage then S=eq.boundary("baseline","full",stage)
  else
    S=eq.new("candidate","full")
    local found=false
    for i=1,1000000 do
      local result=summary.summary_job.step(S,{left=1})
      local p=pending(S.flow)
      if p.kind==kind and p.head and p.head>=2 then found=true break end
      assert(not result,"full summary ended before requested pending walk")
    end
    assert(found,"full pending case not reached")
  end
  local ticket=jobs.start("map_summary",{detail="full",surface="walk-physical"})
  local job=assert(storage.jobs.by_id[ticket.job_id])
  assert(job.status=="pending") job.state=S
  storage.eq_cases=storage.eq_cases or {}
  storage.eq_cases[ticket.job_id]={expected=expected,kind="map_summary",checkpoint=rpc.to_json(checkpoint(S.flow))}
  return {id=ticket.job_id,kind=kind,stage=stage,progress=pending(S.flow),expected=expected}
end
function M.collect(id)
  local record=assert(storage.eq_cases[id])
  if record.checkpoint then
    local S=assert(storage.jobs.by_id[id].state)
    assert(rpc.to_json(checkpoint(record.kind=="eq_stage" and S.F or S.flow))==record.checkpoint,
      "pending state changed across save/load")
    record.checkpoint=nil
  end
  for i=1,64 do
    local job=jobs.get{job_id=id}
    assert(job.job_status~="failed",job.error)
    if job.job_status=="done" then
      local json=record.kind=="eq_stage" and job.result.json or rpc.to_json(job.result)
      assert(json==record.expected,"resumed output differs")
      storage.eq_cases[id]=nil
      storage.eq_json=json
      return {done=true,bytes=#json,tick=game.tick}
    end
  end
  return {done=false}
end
M.stage_result=project

local persistence=M
function M.input(kind,n,shape)
  local F=fixture.caller(kind,n,shape)
  local bindings={}
  for id,node in pairs(F.node_by_id) do
    if node._entity then
      for key,entity in pairs(storage.walk_entities) do if node._entity==entity then bindings[id]=key break end end
      assert(bindings[id]) node._entity=nil
    end
  end
  storage.eq_input_json=rpc.to_json({flow=F,bindings=bindings})
  return #storage.eq_input_json
end
function M.prepare(version,kind,work)
  local input=helpers.json_to_table(storage.eq_input_json)
  local F=input.flow
  for id,key in pairs(input.bindings) do F.node_by_id[id]._entity=storage.walk_entities[key] end
  for i,node in ipairs(F.nodes) do F.nodes[i]=assert(F.node_by_id[node.id]) end
  storage.eq_prepared={F=F,kind=kind,version=version,work=work,steps=0,hold=true,
    stage=kind=="upstream_proven" and 19 or (kind=="reaches_downstream" or kind=="material_upstream") and 24 or 20}
end
jobs.register("eq_serialized",{defer_encode=true,
  start=function() local S=assert(storage.eq_prepared) storage.eq_prepared=nil return S end,
  step=function(S,budget)
    if S.hold then S.hold=nil budget.left=0 return end
    local b={left=math.min(budget.left,S.work)} local before=b.left
    local source=S.version=="baseline" and baseline or summary
    local done=source.stage_probe[S.stage](S.F,b)
    budget.left=budget.left-math.max(0,before-b.left) S.steps=S.steps+1
    if done then return {json=rpc.to_json(persistence.stage_result(S.F)),steps=S.steps} end
  end})
rpc.register("eq_serialized",jobs.rpc("eq_serialized"))

function M.profile()
  local advance,dispatch=jobs.on_tick,rpc.dispatch
  jobs.on_tick=function()
    local state,kinds=storage.jobs,{}
    for _,id in ipairs(state and state.order or {}) do
      local job=state.by_id[id]
      if job and job.status=="pending" then kinds[#kinds+1]=job.kind end
    end
    if #kinds==0 then return advance() end
    local heap,timer=collectgarbage("count"),helpers.create_profiler()
    advance() timer.stop()
    log({"","job_tick ",game.tick," ",table.concat(kinds,",")," ",timer})
    if collectgarbage("count")<heap then log("gc_freed "..game.tick.." jobs") end
  end
  rpc.dispatch=function(method,params)
    local heap=collectgarbage("count") dispatch(method,params)
    if collectgarbage("count")<heap then log("gc_freed "..game.tick.." rpc:"..method) end
  end
end
return M
