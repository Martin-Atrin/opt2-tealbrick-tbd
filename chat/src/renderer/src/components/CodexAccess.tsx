import {useEffect,useState} from 'react';
import {useStore} from '../lib/store';
import type {CodexAccessState} from '../../../shared/ipc';

export function CodexAccess(){
 const {activeAgentId,agents,sessions,portalWorkspaceId}=useStore();
 const agent=agents.find(a=>a.id===activeAgentId),sessionId=sessions[activeAgentId];
 if(!agent?.url||!sessionId)return <p className="muted">New conversations start Restricted. Send a message to choose access for this session.</p>;
 return <AccessControl key={`${portalWorkspaceId}:${activeAgentId}:${sessionId}`} agentId={agent.id} sessionId={sessionId}/>;
}
function AccessControl({agentId,sessionId}:{agentId:string;sessionId:string}){
 const [state,setState]=useState<CodexAccessState|null>(null),[choice,setChoice]=useState<CodexAccessState['mode']>('restricted');
 const [error,setError]=useState(''),[saving,setSaving]=useState(false),[confirm,setConfirm]=useState(false);
 useEffect(()=>{let live=true;window.studio.codexAccess({agentId,sessionId}).then(s=>{if(live){setState(s);setChoice(s.mode);}}).catch(e=>{if(live)setError(String(e.message));});return()=>{live=false;};},[agentId,sessionId]);
 async function apply(){
  if(!state)return;setSaving(true);setError('');
  try{const next=await window.studio.codexAccess({agentId,sessionId,mode:choice,revision:state.revision,confirmed:choice!=='restricted'});setState(next);setConfirm(false);}
  catch(e){setError(e instanceof Error?e.message:String(e));}
  finally{setSaving(false);}
 }
 return <div className="card" aria-label="Codex session access">
  <h3>Session access</h3>
  <p className="muted">Applies to this conversation only. Knowledge permissions remain controlled by Portal.</p>
  {state&&<p role="status">Current: {state.mode} · {state.sandbox} · shell {state.shell?'on':'off'}</p>}
  <label>Access mode <select aria-label="Access mode" value={choice} disabled={!state||saving} onChange={e=>{setChoice(e.target.value as CodexAccessState['mode']);setConfirm(false);}}>
   <option value="restricted">Restricted — read-only, no shell</option>
   <option value="native">Native defaults — configured Codex permissions</option>
   <option value="full">Full access — shell and filesystem</option>
  </select></label>
  <p className="muted">Changes briefly reload the Teal Brick Codex worker and may stop its background terminals. All its conversations must be idle. ChatGPT Desktop is not restarted.</p>
  {confirm?<div role="alert">
   <p>{choice==='full'?'Full access allows commands, network access and changes to files accessible to your OS account, without per-command approval.':'Native defaults may grant full machine access, depending on your Codex configuration. The chosen permissions are saved for this session.'} Only enable this for work you trust.</p>
   <button className="btn" disabled={saving} onClick={()=>void apply()}>{saving?'Applying…':'Confirm access change'}</button>
   <button className="btn" disabled={saving} onClick={()=>setConfirm(false)}>Cancel</button>
  </div>:<button className="btn" disabled={!state||saving||choice===state.mode} onClick={()=>choice==='restricted'?void apply():setConfirm(true)}>{saving?'Applying…':'Apply to this session'}</button>}
  {error&&<p role="alert">{error}</p>}
 </div>;
}
