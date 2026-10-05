local here = (arg and arg[0] or '.'):match('^(.*)/[^/]+$') or '.'
package.path = here .. '/../../mod/agentic-companion/?.lua;' .. package.path
local failures, checks = 0, 0
local function check(ok, message)
 checks=checks+1;print((ok and 'ok   ' or 'FAIL ')..message);if not ok then failures=failures+1 end
end
local function copy(v) if type(v)~='table' then return v end;local out={};for k,x in pairs(v)do out[k]=copy(x)end;return out end
_G.defines={build_mode={normal=1},inventory={robot_cargo=1}};_G.storage={};_G.game={tick=0}
local clear, reach, chart, covered, robots, space=true,true,true,true,2,true
local row, ghosts, built, captured, destroyed, ordered, drops, inventories
local force={is_chunk_charted=function()return chart end}
local surface={}
local c={surface=surface,force=force}
package.loaded['scripts.actions.approach']={ensure_entity=function()return reach and 'ok' or nil end}
package.loaded['scripts.placement_geometry']={footprint=function(_,p)return {left_top={x=p.x-1.4,y=p.y-1.4},right_bottom={x=p.x+1.4,y=p.y+1.4}}end,can_place=function()return clear end}
local R=require('scripts.actions.robot_move')
local function inventory(rows)
 local inv={};for i=1,4 do inv[i]={} end
 inv.get_contents=function()return copy(rows or {})end
 inv.is_empty=function()return #(rows or {})==0 end
 return inv
end
local function entity(pos)
 local modules=inventory({{name='speed-module',quality='uncommon',count=1}})
 local inputs=inventory()
 local e={valid=true,type='assembling-machine',name='assembling-machine-2',quality={name='uncommon'},minable=true,
   position=pos,direction=0,force=force,surface=surface,crafting_progress=0,fluidbox={}}
 e.bounding_box={left_top={x=pos.x-1.4,y=pos.y-1.4},right_bottom={x=pos.x+1.4,y=pos.y+1.4}}
 e.get_recipe=function()return {name=e.recipe or "iron-gear-wheel"},{name="normal"}end
 e.get_module_inventory=function()return modules end
 e.get_max_inventory_index=function()return 2 end
 e.get_inventory=function(i)return i==1 and inputs or modules end
 e.to_be_deconstructed=function()return e.marked==true end
 e.order_deconstruction=function(f)assert(f==force);e.marked=true;ordered=ordered+1;return true end
 e.cancel_deconstruction=function(f)assert(f==force);e.marked=false end
 e.get_wire_connectors=function()return {}end
 e.modules,e.inputs=modules,inputs
 return e
end
local function setup()
 game.tick=0;clear,reach,chart,covered,robots,space=true,true,true,true,2,true
 ghosts,built,captured,destroyed,ordered,drops,inventories={},nil,0,0,0,0,0
 row={entity_number=7,name='assembling-machine-2',position={x=8.5,y=.5},quality='uncommon',recipe='iron-gear-wheel',
   items={{id={name='speed-module',quality='uncommon'},items={in_inventory={{inventory=4,stack=0}}}}}}
 local source=entity({x=8.5,y=.5})
 surface.count_entities_filtered=function(p)assert(p.limit==17 and p.area);return 1 end
 local net={network_id=1,all_construction_robots=robots,available_construction_robots=robots,
   select_drop_point=function(p)assert(p.members=='storage');drops=drops+1;return space and {} or nil end}
 surface.find_logistic_networks_by_construction_area=function()return covered and {net} or {}end
 surface.find_entity=function(id,p)assert(id.quality=='uncommon' and p.x==12.5);return built end
 game.create_inventory=function(n)
   assert(n==1);inventories=inventories+1
   local stack={set_stack=function()end,create_blueprint=function(p)assert(p.include_modules and not p.include_fuel);captured=captured+1;return {[7]=built or source}end,
     get_blueprint_entities=function()return {copy(row)}end,
     set_blueprint_entities=function(rows)assert(#rows==1);row=copy(rows[1]);row.entity_number=7 end}
   stack.build_blueprint=function(p)
     assert(p.build_mode==defines.build_mode.normal and not p.player and p.position.x==12)
     local ghost={valid=true,position={x=12.5,y=.5}}
     ghost.destroy=function()ghost.valid=false;destroyed=destroyed+1 end
     ghosts[1]=ghost;return ghosts
   end
   return {valid=true,[1]=stack,destroy=function()inventories=inventories-1 end}
 end
 local task={_proto={},_item='assembling-machine-2',_to={x=12.5,y=.5},_direction=0}
 return task,source
end
local function ordered_task()
 local task,source=setup();R.start(task,c,source);check(R.tick(task,c)==nil and ordered==1,'robot order enters a pending native phase')
 return task,source
end
local function recover(task,source,buffer)
 R.on_robot_pre_mined(task,{entity=source})
 R.on_robot_mined_entity(task,{entity=source,buffer=inventory(buffer or {{name='assembling-machine-2',quality='uncommon',count=1},{name='speed-module',quality='uncommon',count=1}})})
 source.valid=false;game.tick=30;return R.tick(task,c)
end
local task,source=ordered_task()
check(recover(task,source)==nil and #ghosts==1,'only proven paid recovery creates a native ghost')
check(R.diagnostics(task).native_recovery_verified and R.waiting(task),'pending relocation reports native recovery and deliberate wait')
built=entity({x=12.5,y=.5});ghosts[1].valid=false;R.on_robot_built_entity(task,{entity=built});game.tick=60
local out=R.tick(task,c)
check(out.status=='done' and out.outcome.moved and out.outcome.native_build_verified and out.outcome.destination_built and not out.outcome.native_requests_may_continue,'native quality/settings/module match is required for successful relocation')
check(inventories==0 and destroyed==0,'success releases scratch inventory and retains paid destination')

task,source=setup();reach=false;R.start(task,c,source);R.tick(task,c)
check(ordered==0 and not R.waiting(task),'source must be physically reached before ordering')
R.cancelled(task);check(inventories==0,'approach cancellation leaks no scratch resources')
for _,case in ipairs({'chart','coverage','storage','contents','wire','fluid','crafting','inventory_bound'})do
 task,source=setup()
 if case=='chart'then chart=false elseif case=='coverage'then covered=false elseif case=='storage'then space=false
 elseif case=='contents'then source.inputs.is_empty=function()return false end
 elseif case=='wire'then source.get_wire_connectors=function()return {{connection_count=1}}end
 elseif case=='fluid'then source.fluidbox={{amount=10}}
 elseif case=='crafting'then source.crafting_progress=.5
 else source.get_max_inventory_index=function()return 17 end end
 local ok=pcall(R.start,task,c,source)
 check(not ok and ordered==0 and #ghosts==0,'unsafe '..case..' is refused before native work')
end

task,source=ordered_task();source.valid=false;game.tick=30;out=R.tick(task,c)
check(out.status=='failed' and out.outcome.code=='MOVE_ROBOT_RECOVERY_UNPROVEN' and #ghosts==0,'unproven source removal never becomes paid success')
check(inventories==0,'unproven recovery releases scratch inventory')

task,source=ordered_task();out=recover(task,source,{{name='assembling-machine-2',quality='normal',count=1}})
check(out.status=='failed' and #ghosts==0,'wrong quality or missing module recovery refuses rebuild')

task,source=ordered_task();source.recipe='copper-cable';out=recover(task,source)
check(out.status=='failed' and #ghosts==0,'changed source configuration after order is reported honestly')

task,source=ordered_task();recover(task,source);built=entity({x=12.5,y=.5});ghosts[1].valid=false;game.tick=60;out=R.tick(task,c)
check(out.status=='failed' and out.outcome.code=='MOVE_ROBOT_BUILD_UNPROVEN' and built.valid,'matching entity without native build event remains a truthful failed partial')

task,source=ordered_task();recover(task,source);built=entity({x=12.5,y=.5});ghosts[1].valid=false;R.on_robot_built_entity(task,{entity=built});row.recipe='copper-cable';game.tick=60;out=R.tick(task,c)
check(out.status=='failed' and out.outcome.code=='MOVE_ROBOT_CONFIGURATION_MISMATCH' and built.valid and out.outcome.destination_built and out.outcome.native_requests_may_continue,'native configuration mismatch retains paid actual entity')

task,source=ordered_task();out=R.cancelled(task)
check(not source.marked and source.valid and not out.source_removed and inventories==0,'cancel before recovery removes owned order without mining or refund')

task,source=ordered_task();recover(task,source);out=R.cancelled(task)
check(out.source_removed and not out.ghost_pending and destroyed==1 and inventories==0,'cancel after recovery removes only owned ghost and preserves paid recovered items')

task,source=ordered_task();game.tick=7200;out=R.tick(task,c)
check(out.status=='failed' and out.outcome.code=='MOVE_ROBOT_TIMEOUT' and not source.marked and inventories==0,'bounded native wait fails and cancels pending owned work')

task,source=ordered_task();local before=captured;for t=1,29 do game.tick=t;R.tick(task,c)end
check(captured==before,'waiting ticks do not repeatedly capture or scan entities')
R.cancelled(task)
-- Native 2.0.77 extracts modules in a separate pass; the building buffer
-- must not fabricate them or double count the building already in bot cargo.
task,source=ordered_task()
local cargo=inventory()
local robot={valid=true,get_inventory=function()return cargo end}
R.on_robot_pre_mined(task,{entity=source,robot=robot})
cargo.get_contents=function()return {{name='speed-module',quality='uncommon',count=1}}end
source.modules.get_contents=function()return {}end
R.observe(task)
cargo.get_contents=function()return {}end -- native deposit happens before final building mining
local building_robot={valid=true,get_inventory=function()return inventory()end}
R.on_robot_pre_mined(task,{entity=source,robot=building_robot})
R.on_robot_mined_entity(task,{entity=source,buffer=inventory({{name='assembling-machine-2',quality='uncommon',count=1}})})
source.valid=false;game.tick=30
check(R.tick(task,c)==nil and #ghosts==1 and R.diagnostics(task).native_recovery_verified,
 'separate observed module cargo survives native deposit and proves paid recovery without double counting building cargo')
R.cancelled(task)
print('robot move checks '..checks);os.exit(failures==0 and 0 or 1)
