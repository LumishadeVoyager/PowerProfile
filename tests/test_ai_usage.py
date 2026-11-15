import importlib.util,json,os,sqlite3,tempfile,unittest
from datetime import datetime,timezone,timedelta
from pathlib import Path
spec=importlib.util.spec_from_file_location('ai_usage',Path(__file__).resolve().parents[1]/'PowerProfileAIUsage.py');ai=importlib.util.module_from_spec(spec);spec.loader.exec_module(ai)
class UsageTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)/'app';self.home=Path(self.tmp.name)/'home';self.now=datetime.now(timezone.utc)-timedelta(seconds=30);self.m=ai.Monitor(self.root,self.home,self.now);self.codex=self.home/'.codex/sessions/a.jsonl';self.codex.parent.mkdir(parents=True);self.claude=self.home/'.claude/projects/p/a.jsonl';self.claude.parent.mkdir(parents=True)
 def tearDown(self):
  for connection in getattr(self,'connections',[]):connection.close()
  self.m.db.close();self.tmp.cleanup()
 def line(self,path,r):
  with path.open('a',encoding='utf-8') as f:f.write(json.dumps(r)+'\n')
 def token(self,n,sec=1,cached=0,output=0):return {'type':'event_msg','timestamp':(self.now+timedelta(seconds=sec)).isoformat(),'payload':{'type':'token_count','info':{'total_token_usage':{'input_tokens':n,'cached_input_tokens':cached,'output_tokens':output,'reasoning_output_tokens':output}}}}
 def codex_meta(self):
  self.line(self.codex,{'type':'session_meta','timestamp':self.now.isoformat(),'payload':{'id':'session'}});self.line(self.codex,{'type':'turn_context','payload':{'model':'test-model'}})
 def rows(self,source='native'):return [r for r in self.m.run()['rows'] if r['source']==source]
 def test_codex_cumulative_and_cache_not_double_counted(self):
  self.codex_meta();self.line(self.codex,self.token(1000,cached=800,output=200));self.line(self.codex,self.token(1000,sec=2,cached=800,output=200));self.line(self.codex,self.token(1500,sec=3,cached=1000,output=300));r=self.rows()[0];self.assertEqual(r['tokens'],1800);self.assertEqual(r['cached'],1000);self.assertEqual(r['input'],500);self.assertIsNone(r['cost']);self.assertEqual(self.rows()[0]['tokens'],1800)
 def test_old_session_backfill_and_live_boundary_do_not_overlap(self):
  old=self.token(100000,sec=-3600);self.codex_meta();self.line(self.codex,old);os.utime(self.codex,(self.now.timestamp()-1,self.now.timestamp()-1));self.assertEqual(self.rows()[0]['tokens'],100000);self.line(self.codex,self.token(100100,sec=3));self.assertEqual(self.rows()[0]['tokens'],100100);self.assertEqual(self.rows()[0]['tokens'],100100)
 def test_archived_duplicate_session_is_not_counted_twice(self):
  self.codex_meta();self.line(self.codex,self.token(100,sec=-5));archive=self.home/'.codex/archived_sessions';archive.mkdir();(archive/'copy.jsonl').write_bytes(self.codex.read_bytes());self.assertEqual(self.rows()[0]['tokens'],100)
 def test_historical_and_live_cc_rows_keep_exact_total(self):
  c=self.make_cc();values=['old','codex','cc-model',int((self.now-timedelta(days=14)).timestamp()),1000,100,300,100,'0.01','cc-model'];c.execute('insert into proxy_request_logs values(?,?,?,?,?,?,?,?,?,?)',values);c.commit();rows=self.rows('cc-switch');self.assertEqual(sum(r['tokens'] for r in rows),2400);self.assertAlmostEqual(sum(r['cost'] or 0 for r in rows),0.01);self.assertEqual(sum(r['tokens'] for r in self.rows('cc-switch')),2400)
 def test_partial_tail_is_retried_after_newline(self):
  self.codex_meta();r=json.dumps(self.token(30));self.codex.write_text(self.codex.read_text(encoding='utf-8')+r,encoding='utf-8');self.assertEqual(self.rows(),[])
  with self.codex.open('a') as f:f.write('\n')
  self.assertEqual(self.rows()[0]['tokens'],30)
 def test_claude_duplicate_stream_updates_use_deltas(self):
  for output in (10,30,30):self.line(self.claude,{'type':'assistant','timestamp':(self.now+timedelta(seconds=2)).isoformat(),'message':{'id':'m','model':'proxy-model','content':[{'text':'SECRET CONTENT'}],'usage':{'input_tokens':100,'cache_read_input_tokens':200,'cache_creation_input_tokens':50,'output_tokens':output}}})
  r=self.rows()[0];self.assertEqual(r['tokens'],380);self.assertNotIn('SECRET CONTENT',self.m.path.read_text(encoding='utf-8'));self.assertNotIn('SECRET CONTENT',(self.root/'ai.snapshot.json').read_text(encoding='utf-8'))
 def test_rates_and_currency_unknown_is_not_zero(self):
  self.codex_meta();self.line(self.codex,self.token(1000,cached=500,output=100));self.assertIsNone(self.rows()[0]['cost']);ai.atomic(self.root/'ai.settings.json',{'prices':{'test-model':{'input':2,'cached':1,'write':0,'output':4,'currency':'CNY'}}});r=self.rows()[0];self.assertEqual(r['currency'],'CNY');self.assertAlmostEqual(r['cost'],0.0019)
 def test_resume_uses_sqlite_checkpoint(self):
  self.codex_meta();self.line(self.codex,self.token(100));self.rows();self.m.db.close();self.m=ai.Monitor(self.root,self.home);self.line(self.codex,self.token(150,sec=2));self.assertEqual(self.rows()[0]['tokens'],150)
 def test_cross_midnight_beijing(self):
  cp={'key':'x'};self.m.start=self.now-timedelta(days=4);base=self.now.astimezone(ai.CHINA).replace(hour=23,minute=59,second=59,microsecond=0)-timedelta(days=1)
  for i in range(2):r=self.token(10*(i+1));r['timestamp']=(base+timedelta(seconds=2*i)).isoformat();self.m.record(r,cp)
  self.assertEqual(len(self.m.state['days']),2)
 def make_cc(self,semantics=None):
  p=self.home/'.cc-switch/cc-switch.db';p.parent.mkdir(parents=True,exist_ok=True);c=sqlite3.connect(p);self.connections=getattr(self,'connections',[])+[c];c.execute('create table proxy_request_logs(request_id text,app_type text,model text,created_at integer,input_tokens integer,output_tokens integer,cache_read_tokens integer,cache_creation_tokens integer,total_cost_usd text,pricing_model text'+(',input_token_semantics integer' if semantics is not None else '')+')');values=['r','codex','cc-model',int((self.now+timedelta(seconds=2)).timestamp()),1000,100,300,100,None,'']+([semantics] if semantics is not None else []);c.execute('insert into proxy_request_logs values('+','.join('?' for _ in values)+')',values);c.commit();return c
 def test_cc_readonly_missing_cost_and_backfill(self):
  c=self.make_cc();r=self.rows('cc-switch')[0];self.assertEqual(r['tokens'],1200);self.assertIsNone(r['cost']);c.execute("update proxy_request_logs set total_cost_usd='0.02',pricing_model='cc-model'");c.commit();r=self.rows('cc-switch')[0];self.assertEqual(r['tokens'],1200);self.assertAlmostEqual(r['cost'],0.02);self.assertEqual(r['pricedTokens'],1200);c.close()
 def test_cc_explicit_total_semantics(self):
  c=self.make_cc(1);self.assertEqual(self.rows('cc-switch')[0]['tokens'],1100);c.close()
 def test_history_usd_and_live_custom_cny_are_not_added_together(self):
  c=self.make_cc();old=['old','codex','cc-model',int((self.now-timedelta(seconds=5)).timestamp()),1000,100,300,100,'0.01','cc-model'];c.execute('insert into proxy_request_logs values(?,?,?,?,?,?,?,?,?,?)',old);c.commit();ai.atomic(self.root/'ai.settings.json',{'prices':{'cc-model':{'input':2,'cached':1,'write':1,'output':4,'currency':'CNY'}}});rows=self.rows('cc-switch');self.assertEqual({r['currency'] for r in rows},{'USD','CNY'});self.assertEqual(sum(r['pricedTokens'] for r in rows),2400);self.assertAlmostEqual(next(r['cost'] for r in rows if r['currency']=='USD'),0.01)
 def test_sources_are_kept_separate(self):
  c=self.make_cc();self.codex_meta();self.line(self.codex,self.token(100));snapshot=self.m.run();self.assertEqual({r['source'] for r in snapshot['rows']},{'native','cc-switch'});c.close()
 def test_cumulative_reset_does_not_rebill_prior_context(self):
  self.codex_meta();self.line(self.codex,self.token(1000));self.line(self.codex,self.token(500,sec=2));self.line(self.codex,self.token(550,sec=3));self.assertEqual(self.rows()[0]['tokens'],1050)
 def test_corrupt_line_does_not_block_next_usage(self):
  self.codex.write_text('broken\n',encoding='utf-8');self.line(self.codex,self.token(7));self.assertEqual(self.rows()[0]['tokens'],7)
if __name__=='__main__':unittest.main()
