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
  # Around local midnight the historical and live increments belong to different daily rows.
  old=self.token(100000,sec=-3600);self.codex_meta();self.line(self.codex,old);os.utime(self.codex,(self.now.timestamp()-1,self.now.timestamp()-1));self.assertEqual(sum(r['tokens'] for r in self.rows()),100000);self.line(self.codex,self.token(100100,sec=3));self.assertEqual(sum(r['tokens'] for r in self.rows()),100100);self.assertEqual(sum(r['tokens'] for r in self.rows()),100100)
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
 def make_rollup(self,c,semantics=None):
  c.execute('create table usage_daily_rollups(date text,app_type text,model text,input_tokens integer,output_tokens integer,cache_read_tokens integer,cache_creation_tokens integer,total_cost_usd text,pricing_model text,request_count integer'+(',input_token_semantics integer' if semantics is not None else '')+')')
  day=(self.now-timedelta(days=160)).astimezone(ai.CHINA).strftime('%Y-%m-%d')
  values=[day,'codex','cc-model',1000,100,300,100,'0.05','cc-model',1]+([semantics] if semantics is not None else [])
  c.execute('insert into usage_daily_rollups values('+','.join('?' for _ in values)+')',values);c.commit();return day
 def test_daily_rollups_restore_old_history_and_survive_restart(self):
  c=self.make_cc();day=self.make_rollup(c);rows=self.rows('cc-switch');self.assertEqual(min(r['date'] for r in rows),day);self.assertEqual(sum(r['tokens'] for r in rows),2400);self.assertAlmostEqual(sum(r['cost'] or 0 for r in rows),0.05)
  self.m.db.close();self.m=ai.Monitor(self.root,self.home);self.assertEqual(sum(r['tokens'] for r in self.rows('cc-switch')),2400)
 def test_source_compaction_moves_detail_without_recounting_it(self):
  c=self.make_cc();self.assertEqual(sum(r['tokens'] for r in self.rows('cc-switch')),1200)
  self.make_rollup(c);c.execute('delete from proxy_request_logs');c.commit()
  rows=self.rows('cc-switch');self.assertEqual(sum(r['tokens'] for r in rows),1200);self.assertAlmostEqual(sum(r['cost'] or 0 for r in rows),0.05)
  c.execute("update usage_daily_rollups set total_cost_usd='0.08'");c.commit();self.assertAlmostEqual(sum(r['cost'] or 0 for r in self.rows('cc-switch')),0.08)
 def test_fresh_rollup_input_is_not_cache_subtracted_again(self):
  c=self.make_cc();self.make_rollup(c,2);c.execute('delete from proxy_request_logs');c.commit();self.assertEqual(self.rows('cc-switch')[0]['tokens'],1500)
 def test_unavailable_cc_database_preserves_imported_rollups(self):
  c=self.make_cc();self.make_rollup(c);self.rows('cc-switch');c.close();(self.home/'.cc-switch/cc-switch.db').unlink();self.assertEqual(sum(r['tokens'] for r in self.rows('cc-switch')),2400)
 def test_cc_proxy_session_mirrors_and_legacy_null_proxy_are_not_doubled(self):
  c=self.make_cc();c.execute('alter table proxy_request_logs add column data_source text');c.execute('alter table proxy_request_logs add column status_code integer');c.execute("update proxy_request_logs set status_code=200,total_cost_usd='0.01',pricing_model='cc-model'")
  c.execute("insert into proxy_request_logs select 'mirror',app_type,model,created_at,input_tokens,output_tokens,cache_read_tokens,cache_creation_tokens,total_cost_usd,pricing_model,'codex_session',200 from proxy_request_logs where request_id='r'");c.commit()
  rows=self.rows('cc-switch');self.assertEqual(sum(r['tokens'] for r in rows),1200);self.assertAlmostEqual(sum(r['cost'] or 0 for r in rows),0.01)
 def test_combined_view_takes_daily_client_max_and_keeps_unknown_cost(self):
  c=self.make_cc();c.execute("update proxy_request_logs set app_type='claude',total_cost_usd='0.02',pricing_model='cc-model'");c.commit()
  self.line(self.claude,{'type':'assistant','timestamp':(self.now+timedelta(seconds=2)).isoformat(),'message':{'id':'combined','model':'alias','usage':{'input_tokens':2000}}})
  rows=self.m.run()['combinedRows'];self.assertEqual(sum(r['tokens'] for r in rows),2000);self.assertAlmostEqual(sum(r['cost'] or 0 for r in rows),0.02);self.assertEqual(sum(r['pricedTokens'] for r in rows),1500);self.assertTrue(any(r['cost'] is None and r['tokens']==500 for r in rows))
 def test_combined_currencies_partition_tokens_and_keep_original_costs(self):
  def row(source,tokens,currency,cost):return dict(date='2026-05-25',client='Claude Code',source=source,input=tokens,cached=0,write=0,output=0,tokens=tokens,currency=currency,cost=cost,pricedTokens=tokens if cost is not None else 0)
  rows=ai.combine_rows([row('native',2000,None,None),row('cc-switch',500,'USD',0.02),row('cc-switch',1000,'CNY',0.1)])
  self.assertEqual(sum(r['tokens'] for r in rows),2000);self.assertEqual(sum(r['input'] for r in rows),2000);self.assertEqual({r['currency']:r['cost'] for r in rows},{'USD':0.02,'CNY':0.1,None:None});self.assertEqual(sum(r['pricedTokens'] for r in rows),1500)
 def test_cumulative_reset_does_not_rebill_prior_context(self):
  self.codex_meta();self.line(self.codex,self.token(1000));self.line(self.codex,self.token(500,sec=2));self.line(self.codex,self.token(550,sec=3));self.assertEqual(self.rows()[0]['tokens'],1050)
 def test_corrupt_line_does_not_block_next_usage(self):
  self.codex.write_text('broken\n',encoding='utf-8');self.line(self.codex,self.token(7));self.assertEqual(self.rows()[0]['tokens'],7)
if __name__=='__main__':unittest.main()
