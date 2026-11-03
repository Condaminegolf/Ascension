from pathlib import Path
p=Path("index.html")
s=p.read_text(encoding="utf-8")
if 'id="nfSocialSearchQuery"' in s:
    print("Already patched"); raise SystemExit(0)
def replace(a,b):
    global s
    if a not in s: raise SystemExit("Missing anchor: "+a[:100])
    s=s.replace(a,b,1)
replace('<h3>Invite by exact handle</h3><div class="nf-social-actions"><input id="nfSocialInviteHandle"', '<h3>Find athletes</h3><p class="muted">Search names or handles of athletes who have opted in.</p><div class="nf-social-actions"><input id="nfSocialSearchQuery" type="search" aria-label="Search athletes" placeholder="Search athletes or @handle"><button class="secondary" id="nfSocialSearchButton" type="button">Search</button></div><div id="nfSocialSearchResults" aria-live="polite"></div><details><summary>Invite by exact handle</summary><div class="nf-social-actions"><input id="nfSocialInviteHandle"')
replace('<button class="secondary" id="nfSocialSendRequest" type="button">Send request</button></div><h3>Friend requests','<button class="secondary" id="nfSocialSendRequest" type="button">Send request</button></div></details><h3>Friend requests')
replace('<div class="field"><label for="nfSocialMetric">Compare friends by</label><select id="nfSocialMetric"><option value="active_days">Active training days</option><option value="sessions">Logged training sessions</option><option value="strength_sets">Strength sets completed</option><option value="run_km">Running distance (km)</option><option value="cycle_km">Cycling distance (km)</option></select></div>','<p class="muted">Single weekly score: consistency 35, strength 25, cardio 25, variety 15.</p>')
a=s.index('function renderScores(){const box=')
b=s.index('async function load(){',a)
render="""function renderScores(){const box=$('nfSocialScores');if(!box)return;const rows=(state.scores||[]).slice().sort((a,b)=>Number(b.score||0)-Number(a.score||0)||Number(b.active_days||0)-Number(a.active_days||0)||String(a.handle).localeCompare(String(b.handle)));
box.innerHTML=rows.length?rows.map((p,i)=>'<div class="nf-social-score"><span class="nf-social-place">'+(i+1)+'</span><div><strong>'+esc(p.display_name)+'</strong>'+(p.self?' <small>YOU</small>':'')+'<small>@'+esc(p.handle)+' · '+Number(p.active_days||0)+' active days · '+Number(p.sessions||0)+' sessions</small><small>Consistency '+Number(p.consistency_score||0)+'/35 · Strength '+Number(p.strength_score||0)+'/25 · Cardio '+Number(p.cardio_score||0)+'/25 · Variety '+Number(p.variety_score||0)+'/15</small></div><strong>'+Number(p.score||0)+'<small>/100</small></strong></div>').join(''):'<p class="muted">Enable sharing to see your score. Accepted friends appear here.</p>';
const week=rows[0]?.week_start;const title=$('nfSocialWeekLabel');if(title)title.textContent=week?'Week starting '+String(week)+' · Monday–Sunday (Brisbane time)':'Current week · Monday–Sunday (Brisbane time)';}
function renderSearch(items){const box=$('nfSocialSearchResults');if(!box)return;
box.innerHTML=items.length?items.map(r=>{const handle=encodeURIComponent(r.handle);let actions='';
if(r.status==='accepted')actions='<small>Friends</small>';
else if(r.status==='pending'&&r.direction==='incoming')actions='<button class="primary" data-nf-social-action="accept" data-handle="'+handle+'">Accept</button><button class="secondary" data-nf-social-action="decline" data-handle="'+handle+'">Decline</button>';
else if(r.status==='pending')actions='<small>Request sent</small>';
else actions='<button class="secondary" data-nf-social-send="'+handle+'">Add friend</button>';
return '<div class="nf-social-row"><div><strong>'+esc(r.display_name)+'</strong><small>@'+esc(r.handle)+'</small></div><div class="nf-social-buttons">'+actions+'</div></div>'}).join(''):'<p class="muted">No matching athletes.</p>';}
async function searchAthletes(){const q=$('nfSocialSearchQuery')?.value.trim()||'';
if(q.length<2){message('Enter at least 2 characters.',true);return}
try{message('Searching…');const list=await rpc('nf_social_search',{p_query:q,p_limit:20});renderSearch(Array.isArray(list)?list:[]);message('Search updated.')}catch(e){message(errorText(e),true)}}
"""
s=s[:a]+render+s[b:]
replace("$('nfSocialMetric')?.addEventListener('change',e=>{state.metric=e.target.value;renderScores();});","""$('nfSocialSearchButton')?.addEventListener('click',searchAthletes);
$('nfSocialSearchQuery')?.addEventListener('keydown',e=>{if(e.key==='Enter'){e.preventDefault();searchAthletes()}});
document.addEventListener('click',async e=>{const b=e.target.closest('[data-nf-social-send]');if(!b)return;try{b.disabled=true;await rpc('nf_social_send_request',{p_handle:decodeURIComponent(b.dataset.nfSocialSend)});await load();await searchAthletes()}catch(err){message(errorText(err),true)}finally{b.disabled=false}});""")
replace("const state={profile:null,relationships:[],scores:[],loading:false,metric:'active_days'};","const state={profile:null,relationships:[],scores:[],loading:false,metric:'score'};")
replace('Optional, invite-only training comparisons.','Find athletes, send requests, and compare balanced weekly training scores.')
p.write_text(s,encoding="utf-8")
print("Updated the existing Friends tab")
