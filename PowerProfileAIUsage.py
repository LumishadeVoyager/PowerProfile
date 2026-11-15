"""Local, incremental AI usage accounting. Never persists prompt/response content."""
import argparse, ctypes, hashlib, json, math, os, sqlite3, time
from collections.abc import MutableMapping
from contextlib import closing
from datetime import datetime, timezone, timedelta
from pathlib import Path

UTC=timezone.utc
CHINA=timezone(timedelta(hours=8))
def stamp(value):
    if isinstance(value,(float,int)):return datetime.fromtimestamp(value/1000 if value>1e12 else value,UTC)
    return datetime.fromisoformat(str(value).replace('Z','+00:00')).astimezone(UTC)
def number(value):
    try:
        x=float(value)
        return x if math.isfinite(x) and x>=0 else None
    except (ValueError,TypeError,OverflowError):return None
def count(value):return int(min(number(value) or 0,10**15))
def digest(value):return hashlib.sha256(str(value).encode()).hexdigest()
def read_json(path,default):
    try:return json.loads(path.read_text(encoding='utf-8-sig'))
    except (OSError,ValueError):return default
def atomic(path,data):
    tmp=path.with_suffix(path.suffix+'.tmp')
    with tmp.open('w',encoding='utf-8') as f:
        json.dump(data,f,ensure_ascii=False,separators=(',',':'));f.flush();os.fsync(f.fileno())
    os.replace(tmp,path)
class DiskMap(MutableMapping):
    def __init__(self,connection,namespace):self.db,self.ns=connection,namespace
    def __getitem__(self,key):
        row=self.db.execute('select value from entries where ns=? and key=?',(self.ns,key)).fetchone()
        if row is None:raise KeyError(key)
        return json.loads(row[0])
    def __setitem__(self,key,value):self.db.execute('insert or replace into entries values(?,?,?)',(self.ns,key,json.dumps(value,separators=(',',':'))))
    def __delitem__(self,key):self.db.execute('delete from entries where ns=? and key=?',(self.ns,key))
    def __iter__(self):return (r[0] for r in self.db.execute('select key from entries where ns=?',(self.ns,)))
    def __len__(self):return self.db.execute('select count(*) from entries where ns=?',(self.ns,)).fetchone()[0]
def counters(usage,codex=False):
    cached=count(usage.get('cached_input_tokens',usage.get('cache_read_input_tokens',0)))
    write=count(usage.get('cache_write_input_tokens',usage.get('cache_creation_input_tokens',0)))
    inp=count(usage.get('input_tokens'));out=count(usage.get('output_tokens'))
    # Codex input already contains cache reads; reasoning is a subset of output.
    return [max(0,inp-cached-write) if codex else inp,cached,write,out]

class Monitor:
    def __init__(self,root,home=None,now=None,historical=False,cutoff=None):
        self.root=Path(root);self.root.mkdir(parents=True,exist_ok=True);self.home=Path(home or Path.home())
        self.historical=historical;self.cutoff=cutoff;self.prefix='backfill-' if historical else ''
        self.path=self.root/('ai.backfill.history.json' if historical else 'ai.usage.history.json');now=now or datetime.now(UTC)
        self.state=read_json(self.path,None)
        self.db=sqlite3.connect(self.root/'ai.usage.db',timeout=3)
        self.db.execute('create table if not exists entries(ns text,key text,value text,primary key(ns,key))')
        stored=self.db.execute("select value from entries where ns=? and key='state'",(self.prefix+'metadata',)).fetchone()
        if stored:self.state=json.loads(stored[0])
        if self.state is None:
            self.state={'version':1,'startedAt':now.isoformat(),'files':{},'counters':{},'days':{},'seen':{},'errors':{}}
            # Durable start boundary before any log enumeration. No historical backfill.
            atomic(self.path,self.state)
        if self.state.get('version')!=1:raise ValueError('Unsupported AI history version')
        for ns in ('seen','counters','counterTimes','ccRequests'):
            old=self.state.get(ns,{})
            mapping=DiskMap(self.db,self.prefix+ns)
            for key,value in old.items():mapping[key]=value
            self.state[ns]=mapping
        self.persist()
        self.start=stamp(self.state['startedAt']);self.errors={}
    def persist(self):
        metadata={k:v for k,v in self.state.items() if not isinstance(v,DiskMap)}
        self.db.execute('insert or replace into entries values(?,?,?)',(self.prefix+'metadata','state',json.dumps(metadata,separators=(',',':'))));self.db.commit()
        atomic(self.path,metadata)
    def add(self,when,client,model,source,delta,cost=None):
        if when<self.start or when>datetime.now(UTC)+timedelta(minutes=5):return
        if self.cutoff and when>=self.cutoff:return
        if not any(delta) and cost is None:return
        key=json.dumps([when.astimezone(CHINA).strftime('%Y-%m-%d'),client,str(model or 'unknown')[:180],source],ensure_ascii=False)
        row=self.state['days'].setdefault(key,{'input':0,'cached':0,'write':0,'output':0,'sourceCost':0,'pricedTokens':0,'records':0,'pricedRecords':0})
        for field,n in zip(('input','cached','write','output'),delta):row[field]+=n
        row['records']+=1
        if cost is not None:row['sourceCost']+=cost;row['pricedTokens']+=sum(delta);row['pricedRecords']=row.get('pricedRecords',0)+1
    def record(self,r,checkpoint,baseline=False):
        kind=r.get('type');payload=r.get('payload') or {}
        if kind=='session_meta':
            checkpoint['sid']=digest(payload.get('id') or checkpoint['key'])
            try:checkpoint['historical']=stamp(r.get('timestamp'))<self.start or bool(payload.get('forked_from_id'))
            except ValueError:pass
            return
        if kind=='turn_context':checkpoint['model']=str(payload.get('model') or 'unknown')[:180];return
        when=stamp(r.get('timestamp'))
        if kind=='event_msg' and payload.get('type')=='token_count':
            usage=(payload.get('info') or {}).get('total_token_usage')
            if not isinstance(usage,dict):return
            key='codex:'+checkpoint.get('sid',checkpoint['key']);current=[count(usage.get(f)) for f in ('input_tokens','cached_input_tokens','cache_write_input_tokens','output_tokens')]
            times=self.state.setdefault('counterTimes',{})
            if key in times and when<stamp(times[key]):return
            previous=self.state['counters'].get(key)
            if previous is None:previous=current if checkpoint.get('historical') and when>=self.start else [0]*4
            # A cumulative reset is a new epoch, never a negative credit.
            raw=[max(0,n-p) for n,p in zip(current,previous)]
            cached=min(raw[0],raw[1]);write=min(raw[2],raw[0]-cached)
            delta=[raw[0]-cached-write,cached,write,raw[3]]
            event=digest((key,r.get('timestamp'),current))
            if event in self.state['seen']:return
            self.state['counters'][key]=current;times[key]=when.isoformat();self.state['seen'][event]=when.isoformat()
            if not baseline:self.add(when,'Codex',checkpoint.get('model','unknown'),'native',delta)
        elif kind=='assistant':
            msg=r.get('message') or {};usage=msg.get('usage')
            if not isinstance(usage,dict) or not msg.get('id'):return
            key='claude:'+digest(msg['id']);current=counters(usage);previous=self.state['counters'].get(key,[0]*4)
            # Streamed copies of a message update its maxima rather than counting it twice.
            delta=[max(0,n-p) for n,p in zip(current,previous)]
            self.state['counters'][key]=[max(n,p) for n,p in zip(current,previous)]
            if not baseline:self.add(when,'Claude Code',msg.get('model','unknown'),'native',delta)
    def scan_file(self,path,client):
        key=digest(str(path.resolve()));st=path.stat();cp=self.state['files'].get(key)
        if cp and cp.get('size')==st.st_size and cp.get('mtime')==st.st_mtime_ns:return
        if cp is None:
            cp={'key':key,'offset':0,'model':'unknown','sid':key}
            if st.st_mtime<self.start.timestamp():
                # Existing inactive logs are outside the requested collection window.
                cp.update(offset=st.st_size,size=st.st_size,mtime=st.st_mtime_ns,needsBaseline=True,historical=True);self.state['files'][key]=cp;return
        if cp.pop('needsBaseline',False):
            end=cp['offset']
            with path.open('rb') as f:
                first=f.readline()
                try:
                    meta=json.loads(first)
                    if meta.get('type')=='session_meta':self.record(meta,cp,True)
                except (ValueError,TypeError):pass
                f.seek(max(len(first),end-4*1024*1024))
                if f.tell()>len(first):f.readline()
                while f.tell()<end:
                    line=f.readline(min(8*1024*1024,end-f.tell()))
                    if not line:break
                    try:self.record(json.loads(line),cp,True)
                    except (ValueError,TypeError,KeyError):pass
        if st.st_size<cp['offset']:cp['offset']=0
        with path.open('rb') as f:
            f.seek(cp['offset']);budget=16*1024*1024
            while budget>0:
                offset=f.tell();line=f.readline(8*1024*1024+1)
                if not line:break
                if not line.endswith(b'\n'):
                    if len(line)>8*1024*1024:
                        while line and not line.endswith(b'\n'):line=f.readline(1024*1024)
                        cp['offset']=f.tell();self.errors[client]='超长日志行已跳过';continue
                    f.seek(offset);break
                cp['offset']=f.tell();budget-=len(line)
                try:
                    r=json.loads(line)
                    # Inspect only record envelopes and usage metadata. Content is never retained.
                    if client=='Codex' and r.get('type') not in ('session_meta','turn_context','event_msg'):continue
                    if client=='Claude Code' and r.get('type')!='assistant':continue
                    self.record(r,cp)
                except (ValueError,TypeError,OverflowError,KeyError):continue
        cp.update(size=st.st_size if cp['offset']>=st.st_size else -1,mtime=st.st_mtime_ns);self.state['files'][key]=cp
    def cc_switch(self,path):
        if not path.exists():return False
        with closing(sqlite3.connect(path.resolve().as_uri()+'?mode=ro',uri=True,timeout=1)) as conn:
            conn.row_factory=sqlite3.Row
            columns={r[1] for r in conn.execute('pragma table_info(proxy_request_logs)')}
            required={'request_id','app_type','model','created_at','input_tokens','output_tokens','cache_read_tokens','cache_creation_tokens','total_cost_usd'}
            if not required<=columns:raise ValueError('Unsupported CC Switch usage schema')
            names=sorted(required|({'input_token_semantics','pricing_model'}&columns))
            # Restrict reads to usage columns; never query credentials, messages, or provider URLs.
            query='select '+','.join(names)+' from proxy_request_logs where created_at>=? order by created_at'
            lower=max(self.start.timestamp(),self.state.get('ccCursor',self.start.timestamp())-7*86400)
            for r in conn.execute(query,(int(lower),)):
                client={'codex':'Codex','claude':'Claude Code'}.get(r['app_type'])
                if not client:continue
                when=stamp(r['created_at'])
                if when<self.start or self.cutoff and when>=self.cutoff:continue
                self.state['ccCursor']=max(self.state.get('ccCursor',0),when.timestamp())
                key='cc:'+digest(r['request_id'])
                inp=count(r['input_tokens']);cached=count(r['cache_read_tokens']);write=count(r['cache_creation_tokens']);out=count(r['output_tokens'])
                # Legacy Codex rows use total input; Claude rows use fresh input.
                semantics=r['input_token_semantics'] if 'input_token_semantics' in columns else 0
                if client=='Codex' and semantics!=2:inp=max(0,inp-cached-(write if semantics==1 else 0))
                cost=number(r['total_cost_usd'])
                if cost==0 and 'pricing_model' in columns and not r['pricing_model']:cost=None
                value={'when':when.isoformat(),'client':client,'model':r['model'],'tokens':[inp,cached,write,out],'cost':cost}
                old=self.state['ccRequests'].get(key)
                if old==value:continue
                if old:
                    day=stamp(old['when']).astimezone(CHINA).strftime('%Y-%m-%d');bucket=json.dumps([day,old['client'],str(old['model'] or 'unknown')[:180],'cc-switch'],ensure_ascii=False);prior=self.state['days'].get(bucket)
                    if prior:
                        for field,n in zip(('input','cached','write','output'),old['tokens']):prior[field]-=n
                        prior['records']-=1
                        if old['cost'] is not None:prior['sourceCost']-=old['cost'];prior['pricedTokens']-=sum(old['tokens']);prior['pricedRecords']=max(0,prior.get('pricedRecords',1)-1)
                self.add(when,client,r['model'],'cc-switch',value['tokens'],cost);self.state['ccRequests'][key]=value
        return True
    def run(self,write_snapshot=True):
        self.errors={}
        cfg=read_json(self.root/'ai.settings.json',{})
        sources={'Codex':Path(cfg.get('codexPath') or Path(os.environ.get('CODEX_HOME',str(self.home/'.codex')))/'sessions'),'Claude Code':Path(cfg.get('claudePath') or Path(os.environ.get('CLAUDE_CONFIG_DIR',str(self.home/'.claude')))/'projects')}
        status={}
        for client,folder in sources.items():
            folders=[folder]
            if client=='Codex':folders.append(Path(cfg.get('codexArchivePath') or folder.parent/'archived_sessions'))
            status[client]='已接入' if any(p.is_dir() for p in folders) else '未发现本地目录'
            for directory in folders:
              if directory.is_dir():
                for path in directory.rglob('*.jsonl'):
                    try:
                        cp=self.state['files'].get(digest(str(path.resolve())))
                        # Backfill freezes each fully read file at the activation boundary.
                        # The live collector owns later appends; the two time ranges never overlap.
                        if self.historical and cp and cp.get('size',-1)>=0:continue
                        self.scan_file(path,client)
                    except OSError:self.errors[client]='部分日志暂不可读，将重试'
        try:status['CC Switch']='已接入（独立来源）' if self.cc_switch(Path(cfg.get('ccSwitchPath') or self.home/'.cc-switch'/'cc-switch.db')) else '未发现数据库'
        except (OSError,sqlite3.Error,ValueError):status['CC Switch']='数据库暂不可读或版本不支持，将重试'
        rows=[];prices=cfg.get('prices',{})
        for key,r in self.state['days'].items():
            day,client,model,source=json.loads(key);total=sum(r[f] for f in ('input','cached','write','output'));rate=prices.get(model)
            estimate=None;currency=None;priced=0
            if source=='cc-switch' and r.get('pricedRecords',0)>0:estimate=max(0,r['sourceCost']);currency='USD';priced=r['pricedTokens']
            elif isinstance(rate,dict):
                rates=[number(rate.get(f)) for f in ('input','cached','write','output')]
                if all(n is not None for n in rates):estimate=sum(r[f]*n/1e6 for f,n in zip(('input','cached','write','output'),rates));currency=rate.get('currency','USD');priced=total
            rows.append(dict(r,date=day,client=client,model=model,source=source,tokens=total,cost=estimate,currency=currency,pricedTokens=priced))
        snapshot={'version':1,'startedAt':self.state['startedAt'],'updatedAt':datetime.now(UTC).isoformat(),'status':status,'errors':self.errors,'rows':rows,'note':'费用是来源估算或自定义单价估算，不是订阅账单；不同来源不相加。'}
        daily={}
        for r in rows:
            key=(r['date'],r['client'],r['source'],r['currency'])
            d=daily.setdefault(key,dict(date=r['date'],client=r['client'],source=r['source'],currency=r['currency'],tokens=0,cost=None,pricedTokens=0))
            d['tokens']+=r['tokens'];d['pricedTokens']+=r['pricedTokens']
            if r['cost'] is not None:d['cost']=(d['cost'] or 0)+r['cost']
        snapshot['daily']=list(daily.values())
        snapshot['revision']=digest(json.dumps([rows,status,self.errors],sort_keys=True))
        self.persist()
        if write_snapshot:
            # Replay historical envelopes separately so live cumulative counters/checkpoints
            # remain intact. Merge only disjoint timestamp ranges, never two source adapters.
            history=Monitor(self.root,self.home,datetime(1970,1,1,tzinfo=UTC),True,self.start)
            try:past=history.run(False)
            finally:history.db.close()
            merged={}
            for row in past['rows']+snapshot['rows']:
                key=(row['date'],row['client'],row['model'],row['source'],row['currency']);target=merged.get(key)
                if target is None:merged[key]=dict(row);continue
                for field in ('input','cached','write','output','sourceCost','pricedTokens','records','pricedRecords','tokens'):target[field]+=row[field]
                if row['cost'] is not None:
                    target['cost']=(target['cost'] or 0)+row['cost'];target['currency']=row['currency']
            snapshot['rows']=list(merged.values());daily={}
            for r in snapshot['rows']:
                key=(r['date'],r['client'],r['source'],r['currency']);d=daily.setdefault(key,dict(date=r['date'],client=r['client'],source=r['source'],currency=r['currency'],tokens=0,cost=None,pricedTokens=0))
                d['tokens']+=r['tokens'];d['pricedTokens']+=r['pricedTokens']
                if r['cost'] is not None:d['cost']=(d['cost'] or 0)+r['cost']
            snapshot['daily']=list(daily.values())
            pending=any(cp.get('size',-1)<0 for cp in history.state['files'].values())
            snapshot['backfill']={'status':'部分文件待重试' if past['errors'] else '回填中' if pending else '已导入可读取历史','earliestDate':min((r['date'] for r in snapshot['rows']),default=None),'boundary':self.start.isoformat()}
            snapshot['errors'].update({'历史 '+k:v for k,v in past['errors'].items()})
            snapshot['revision']=digest(json.dumps([snapshot['rows'],status,snapshot['errors'],snapshot['backfill']],sort_keys=True))
            atomic(self.root/'ai.snapshot.json',snapshot)
        return snapshot

def alive(pid):
    if os.name=='nt':
        kernel=ctypes.windll.kernel32;kernel.OpenProcess.restype=ctypes.c_void_p;h=kernel.OpenProcess(0x1000,False,pid)
        if not h:return False
        code=ctypes.c_ulong();kernel.GetExitCodeProcess(ctypes.c_void_p(h),ctypes.byref(code));kernel.CloseHandle(ctypes.c_void_p(h));return code.value==259
    try:os.kill(pid,0);return True
    except OSError:return False
def main():
    p=argparse.ArgumentParser();p.add_argument('--root',type=Path,required=True);p.add_argument('--watch',action='store_true');p.add_argument('--parent-pid',type=int);a=p.parse_args()
    a.root.mkdir(parents=True,exist_ok=True)
    with (a.root/'ai.collector.lock').open('a+b') as lock:
        if os.name=='nt':
            import msvcrt
            lock.write(b'0');lock.flush();lock.seek(0)
            for attempt in range(30):
                try:msvcrt.locking(lock.fileno(),msvcrt.LK_NBLCK,1);break
                except OSError:
                    if not a.watch or a.parent_pid and not alive(a.parent_pid):return
                    time.sleep(1)
            else:return
        try:monitor=Monitor(a.root)
        except Exception:
            atomic(a.root/'ai.collector.status.json',{'error':'AI 历史暂不可读，数据未重置；请检查本地文件与磁盘','updatedAt':datetime.now(UTC).isoformat()});return
        while True:
            if a.parent_pid and not alive(a.parent_pid):break
            try:
                monitor.run();atomic(a.root/'ai.collector.status.json',{'pid':os.getpid(),'parentPid':a.parent_pid,'status':'ok','updatedAt':datetime.now(UTC).isoformat()})
            except Exception:atomic(a.root/'ai.collector.status.json',{'error':'采集暂不可用，保留已保存数据并重试','updatedAt':datetime.now(UTC).isoformat()})
            if not a.watch:break
            for _ in range(20):
                if a.parent_pid and not alive(a.parent_pid):return
                time.sleep(1)
if __name__=='__main__':main()
