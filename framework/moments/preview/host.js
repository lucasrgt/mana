// One document, one ordered command stream. No browser tab automation or app
// injection: only this page's owned iframe elements may be created or removed.
const documentId=crypto.randomUUID(),frames=new Map(),status=document.querySelector('#status'),lamp=document.querySelector('#lamp');
let configuration,sequence=0,browserKey,provider;
const show=(text,connected=false)=>{status.textContent=text;lamp.classList.toggle('connected',connected);};
const update=()=>{document.querySelector('#empty').hidden=frames.size>0;};
const canonical=value=>{const url=new URL(value);if(!configuration.origins.includes(url.origin)||url.username||url.password||url.searchParams.getAll('momentsActor').length!==1)throw Error('Unscoped preview');url.hash='';return url.href;};
async function post(path,body,auth=true){const response=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json',...(auth?{Authorization:`Bearer ${configuration.token}`}:{})},body:JSON.stringify({document:documentId,...body})});const value=await response.json();if(!response.ok)throw Error(value.error??'Host unavailable');return value;}
function inspect(id){const frame=frames.get(id);return frame&&frame.element.isConnected?{id,status:'present',url:frame.url}:{id,status:'absent'};}
function execute(command){
  if(command.version!==1||command.deadline<Date.now())throw Error('Expired operation');
  const {id,url}=command.target??{};if(!/^[a-f0-9-]{36}$/.test(id??''))throw Error('Invalid surface');
  if(command.method==='open'){
    const target=canonical(url);if(new URL(target).searchParams.get('momentsActor')!==id||frames.has(id))throw Error('Opening cannot be replayed');
    const card=document.createElement('article');card.className='preview';const heading=document.createElement('header'),title=document.createElement('h2'),detail=document.createElement('small');
    title.textContent=`Situation ${++sequence}`;detail.textContent=new URL(target).pathname;heading.append(title,detail);
    const frame=document.createElement('iframe');frame.title=title.textContent;frame.setAttribute('sandbox','allow-scripts allow-same-origin allow-forms');frame.referrerPolicy='no-referrer';frame.src=target;
    card.append(heading,frame);frames.set(id,{element:frame,card,url:target});document.querySelector('#previews').append(card);update();
    // Browsers may suspend animation frames for offscreen iframes. Flutter's
    // restore observation needs a rendered frame, so reveal each new preview.
    card.scrollIntoView({block:'start',behavior:'instant'});return inspect(id);
  }
  if(command.method==='inspect')return inspect(id);
  if(command.method==='reveal'){
    const frame=frames.get(id);if(!frame?.element.isConnected)throw Error('Surface absent');
    frame.card.scrollIntoView({block:'start',behavior:'instant'});return inspect(id);
  }
  if(command.method==='close'){const frame=frames.get(id);if(frame){frame.card.remove();frames.delete(id);}update();return {id,status:'absent'};}
  if(command.method==='find'){
    const target=canonical(url),frame=inspect(id);
    // Execution is synchronous and ordered. Expired commands never create a
    // frame; no deferred create task can run after this inventory response.
    return {matches:frame.status==='present'&&frame.url===target?[frame]:[],settled:true};
  }
  throw Error('Unknown preview operation');
}
async function connect(){
  configuration=await post('/join',{protocol:2,ownership:{kind:'web-lock-v1',browserKey}},false);
  if(configuration.provider!==provider)throw Error('The host identity changed. Reopen the page.');
  const response=await fetch(`/events?document=${documentId}`,{headers:{Authorization:`Bearer ${configuration.token}`}});
  if(!response.ok)throw Error('Could not connect to the host');
  show('Connected to the engine',true);const reader=response.body.getReader(),decoder=new TextDecoder();let buffer='';
  try { while(true){const {done,value}=await reader.read();if(done)throw Error('Connection closed');buffer+=decoder.decode(value,{stream:true});if(buffer.length>65536)throw Error('Invalid host stream');let end;
    while((end=buffer.indexOf('\n'))>=0){const line=buffer.slice(0,end);buffer=buffer.slice(end+1);if(!line)continue;const command=JSON.parse(line);if(command.type)continue;
      let reply;try{reply={result:execute(command)};}catch{reply={error:'Preview operation refused'};}
      // Awaiting the reply keeps all DOM operations strictly serial. A lost
      // acknowledgment is reconciled by the same document after reconnect.
      await post('/reply',{id:command.id,...reply});
    }
  }} finally { await reader.cancel().catch(()=>{});reader.releaseLock(); }
}
async function ownPreviews(){
  if(!navigator.locks)throw Error('This browser must support Web Locks to recover previews.');
  const response=await fetch('/health');if(!response.ok)throw Error('Host unavailable');
  const identity=await response.json();if(identity.protocol!==2)throw Error('Restart the updated host.');provider=identity.provider;
  const key=`mana-preview:${provider}:browser`,lockName=`mana-preview:${provider}:document`;
  show('Waiting for the page that owns this host…');
  // Never steal or release while frames exist. Browser unload terminates the
  // lock. A surviving/frozen old document keeps it, blocking a second owner.
  await navigator.locks.request(lockName,{mode:'exclusive'},async()=>{
    browserKey=localStorage.getItem(key);
    if(browserKey===null){browserKey=Array.from(crypto.getRandomValues(new Uint8Array(32)),n=>n.toString(16).padStart(2,'0')).join('');localStorage.setItem(key,browserKey);}
    if(!/^[a-f0-9]{64}$/.test(browserKey)||localStorage.getItem(key)!==browserKey)throw Error('Local browser identity unavailable.');
    try{while(true){try{await connect();}catch(error){show(error.message);}await new Promise(resolve=>setTimeout(resolve,1000));}}
    finally{for(const frame of frames.values())frame.card.remove();frames.clear();update();}
  });
}
try{await ownPreviews();}catch(error){show(error.message);}
